defmodule Ryker.GitHub.Onboarding do
  @moduledoc """
  Resumable repository onboarding backed by the repository settings row.

  Each externally visible phase is saved before the next remote operation. A
  restart therefore resumes from the pinned source revision, and the remote
  publisher reconciles its stable branch and pull request before creating
  anything new.
  """

  require Logger

  alias Ryker.Settings

  @actor "github:onboarding"

  @callback pin(map(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback scan(map(), map(), String.t()) ::
              {:ok, %{content: String.t(), status: :accepted | :proposed}} | {:error, term()}
  @callback publish(map(), map(), String.t(), String.t()) ::
              {:ok, %{url: String.t()}} | {:error, term()}

  @spec run(String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def run(repository_ref, options \\ []) when is_binary(repository_ref) do
    api = Keyword.get(options, :api, Ryker.GitHub.Onboarding.Remote)

    with {:ok, repository, binding} <- repository(repository_ref),
         :ok <- available(repository),
         {:ok, source_commit} <- pin(repository, binding, api),
         {:ok, scan} <- scan(repository_ref, repository, binding, source_commit, api),
         {:ok, outcome} <- publish(repository_ref, repository, binding, source_commit, scan, api) do
      {:ok, outcome}
    else
      # Removed while it was being set up: there is nothing left to mark.
      {:error, :repository_removed} = removed ->
        removed

      {:error, reason} = error ->
        _ = block(repository_ref, reason)
        error
    end
  rescue
    # One repository's setup that raises stops that repository, never the
    # worker: a raising scan crash-looped every repository in "scanning" about
    # twice a second on 2026-09-27, with nothing in the log.
    error ->
      Logger.error(
        "repository #{repository_ref} setup raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      _ = block(repository_ref, {:setup_crashed, error.__struct__})
      {:error, {:setup_crashed, error.__struct__}}
  end

  defp repository(ref) do
    snapshot = Settings.fetch!()
    repository = Enum.find(snapshot.repositories, &(&1.ref == ref))
    binding = Enum.find(snapshot.github_bindings, &(&1.repository_ref == ref))

    cond do
      is_nil(repository) -> {:error, :repository_removed}
      is_nil(binding) -> {:error, :repository_binding_missing}
      true -> {:ok, repository, binding}
    end
  end

  defp available(%{github_access: :available}), do: :ok
  defp available(_repository), do: {:error, :repository_access_unavailable}

  defp pin(repository, binding, api) do
    with :ok <- transition(repository.ref, %{onboarding_state: :cloning, onboarding_error: nil}),
         do: source_commit(repository, binding, api)
  end

  defp source_commit(%{source_commit: commit}, _binding, _api) when is_binary(commit),
    do: {:ok, commit}

  defp source_commit(repository, binding, api) do
    with {:ok, commit} <- api.pin(binding, repository),
         :ok <- transition(repository.ref, %{source_commit: commit}),
         do: {:ok, commit}
  end

  defp scan(ref, repository, binding, source_commit, api) do
    with :ok <- transition(ref, %{onboarding_state: :scanning}),
         do: api.scan(binding, repository, source_commit)
  end

  defp publish(
         ref,
         _repository,
         _binding,
         source_commit,
         %{content: content, status: :accepted},
         _api
       ) do
    with :ok <-
           transition(
             ref,
             knowledge_attributes(content, source_commit, :accepted)
             |> Map.merge(%{onboarding_state: :ready, onboarding_error: nil})
           ),
         do: {:ok, :already_present}
  end

  defp publish(
         ref,
         repository,
         binding,
         source_commit,
         %{content: content, status: :proposed},
         api
       ) do
    with :ok <- transition(ref, %{onboarding_state: :publishing}),
         {:ok, %{url: url}} <- api.publish(binding, repository, source_commit, content),
         :ok <-
           transition(ref, %{
             knowledge_pull_request_url: url,
             knowledge_content: content,
             knowledge_status: :proposed,
             knowledge_source_commit: source_commit,
             knowledge_sha256: digest(content),
             onboarding_error: nil,
             onboarding_state: :ready
           }) do
      {:ok, :pull_request_opened}
    end
  end

  defp knowledge_attributes(content, source_commit, status) do
    %{
      knowledge_content: content,
      knowledge_status: status,
      knowledge_source_commit: source_commit,
      knowledge_sha256: digest(content)
    }
  end

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # A step writes only a repository that is still added, at the revision it
  # read it at. Removing a repository while its setup ran would otherwise
  # save it again, holding nothing but its setup state.
  defp transition(ref, attributes) do
    snapshot = Settings.fetch!()

    if Enum.any?(snapshot.repositories, &(&1.ref == ref)) do
      case Settings.put_repository(
             Map.put(attributes, :ref, ref),
             snapshot.installation.revision,
             @actor
           ) do
        {:ok, _snapshot} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :repository_removed}
    end
  end

  # A block that cannot be saved leaves the repository in the phase it was in,
  # where the worker takes it up again. That used to be swallowed whole, so a
  # repository read "cloning" forever and the log said nothing.
  defp block(ref, reason) do
    Logger.warning("repository #{ref} setup stopped: #{inspect(reason)}")

    case transition(ref, %{onboarding_error: failure(reason), onboarding_state: :blocked}) do
      :ok -> :ok
      {:error, error} -> unblocked(ref, inspect(error))
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      unblocked(ref, inspect(error.__struct__))
  end

  defp unblocked(ref, cause) do
    Logger.warning("repository #{ref} setup stopped but could not be marked blocked: #{cause}")
  end

  defp failure(:repository_binding_missing), do: "GitHub binding is missing."
  defp failure(:repository_access_unavailable), do: "GitHub access is unavailable."
  defp failure(:repository_empty), do: "The repository has no commit to scan."

  defp failure(:repository_too_large),
    do: "The repository is too large for the bounded setup scan."

  defp failure(:knowledge_pull_request_declined),
    do: "The earlier knowledge pull request was closed. Retry only after a new request."

  defp failure({:github_onboarding, :permission}),
    do: "The GitHub App is missing contents or pull-request permission."

  defp failure({:github_onboarding, :archived}),
    do:
      "This repository is archived on GitHub, so Ryker can read it but cannot open its " <>
        "knowledge pull request. Unarchive it on GitHub and retry, or remove it."

  defp failure({:github_onboarding, :not_found}),
    do: "The repository or base branch is no longer accessible."

  defp failure({:setup_crashed, _kind}),
    do: "Setup stopped on an unexpected error; Ryker logged it. Retry once it is fixed."

  defp failure(_reason), do: "Repository setup could not finish. Check GitHub access and retry."
end

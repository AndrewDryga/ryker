defmodule Ryker.GitHub.Onboarding do
  @moduledoc """
  Resumable repository onboarding backed by the repository settings row.

  Each externally visible phase is saved before the next remote operation. A
  restart therefore resumes from the pinned source revision, and the remote
  publisher reconciles its stable branch and pull request before creating
  anything new.
  """

  alias Ryker.{BundledCoop, Settings}

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
         :ok <- BundledCoop.materialize_repository(repository_ref),
         {:ok, scan} <- scan(repository_ref, repository, binding, source_commit, api),
         {:ok, outcome} <- publish(repository_ref, repository, binding, source_commit, scan, api) do
      {:ok, outcome}
    else
      {:error, reason} = error ->
        _ = block(repository_ref, reason)
        error
    end
  end

  defp repository(ref) do
    snapshot = Settings.fetch!()
    repository = Enum.find(snapshot.repositories, &(&1.ref == ref))
    binding = Enum.find(snapshot.github_bindings, &(&1.repository_ref == ref))

    if repository && binding,
      do: {:ok, repository, binding},
      else: {:error, :repository_binding_missing}
  end

  defp available(%{github_access: :available}), do: :ok
  defp available(_repository), do: {:error, :repository_access_unavailable}

  defp pin(repository, binding, api) do
    :ok = transition(repository.ref, %{onboarding_state: :cloning, onboarding_error: nil})

    case repository.source_commit do
      commit when is_binary(commit) ->
        {:ok, commit}

      nil ->
        with {:ok, commit} <- api.pin(binding, repository),
             :ok <- transition(repository.ref, %{source_commit: commit}) do
          {:ok, commit}
        end
    end
  end

  defp scan(ref, repository, binding, source_commit, api) do
    :ok = transition(ref, %{onboarding_state: :scanning})
    api.scan(binding, repository, source_commit)
  end

  defp publish(
         ref,
         _repository,
         _binding,
         source_commit,
         %{content: content, status: :accepted},
         _api
       ) do
    :ok =
      transition(
        ref,
        knowledge_attributes(content, source_commit, :accepted)
        |> Map.merge(%{onboarding_state: :ready, onboarding_error: nil})
      )

    {:ok, :already_present}
  end

  defp publish(
         ref,
         repository,
         binding,
         source_commit,
         %{content: content, status: :proposed},
         api
       ) do
    :ok = transition(ref, %{onboarding_state: :publishing})

    with {:ok, %{url: url}} <- api.publish(binding, repository, source_commit, content),
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

  defp transition(ref, attributes) do
    snapshot = Settings.fetch!()

    case Settings.put_repository(
           Map.put(attributes, :ref, ref),
           snapshot.installation.revision,
           @actor
         ) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp block(ref, reason) do
    transition(ref, %{
      onboarding_error: failure(reason),
      onboarding_state: :blocked
    })
  rescue
    _error -> :ok
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

  defp failure({:github_onboarding, :not_found}),
    do: "The repository or base branch is no longer accessible."

  defp failure(_reason), do: "Repository setup could not finish. Check GitHub access and retry."
end

defmodule Ryker.GitHub.Onboarding do
  @moduledoc """
  Resumable repository setup backed by the repository settings row.

  Setup pins the default branch head the repository's jobs start from, then
  hands the repository to the knowledge lane, which has a model read it and
  keeps its RYKER.md (`Ryker.RepositoryKnowledge`). Each externally visible
  phase is saved before the next remote operation, so a restart resumes from
  the pinned source revision.
  """

  require Logger
  alias Ryker.{RepositoryKnowledge, Settings}

  @actor "github:onboarding"

  @callback pin(map(), map()) :: {:ok, String.t()} | {:error, term()}

  @spec run(String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def run(repository_ref, options \\ []) when is_binary(repository_ref) do
    api = Keyword.get(options, :api, Ryker.GitHub.RepositoryFiles)

    with {:ok, repository, binding} <- repository(repository_ref),
         :ok <- available(repository),
         {:ok, _source_commit} <- pin(repository, binding, api),
         :ok <- ready(repository_ref) do
      {:ok, :ready}
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

  # Set up, then its RYKER.md asked for: the knowledge lane's first check
  # reads the repository at once. A setup that stops between the two is
  # checked when the lane next finds the repository without a row
  # (`Ryker.RepositoryKnowledge.Custody.ensure/1`).
  defp ready(ref) do
    with :ok <- transition(ref, %{onboarding_state: :ready, onboarding_error: nil}),
         do: RepositoryKnowledge.check_soon(ref)
  end

  # A step writes only a repository that is still added: removing one while
  # its setup ran would otherwise save it again, holding nothing but its setup
  # state. It writes at the current revision, so a person's save landing
  # during setup no longer blocks the repository.
  defp transition(ref, attributes) do
    case Settings.update_repository(ref, attributes, @actor) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
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
  defp failure(:repository_empty), do: "The repository has no commit to set up from."

  defp failure({:github_onboarding, :permission}),
    do: "The GitHub App cannot read this repository's code."

  defp failure({:github_onboarding, :not_found}),
    do: "The repository or base branch is no longer accessible."

  defp failure({:setup_crashed, _kind}),
    do: "Setup stopped on an unexpected error; Ryker logged it. Retry once it is fixed."

  defp failure(_reason), do: "Repository setup could not finish. Check GitHub access and retry."
end

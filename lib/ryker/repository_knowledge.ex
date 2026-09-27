defmodule Ryker.RepositoryKnowledge do
  @moduledoc """
  RYKER.md: what Ryker knows about each repository, written by a model that
  reads it, checked against it, and kept fresh.

  A newly added repository is checked as soon as setup pins it
  (`Ryker.GitHub.Onboarding`), and every ready repository once a day. The
  check (`Ryker.RepositoryKnowledge.Refresh`) has a model read the repository
  again when the default branch moved since the last write and a file that
  says how to work there changed, or a week passed and any code did. The
  model reads the repository read-only at its default branch head, in a
  worker session of its own, and answers with a strict contract
  (`Ryker.RepositoryKnowledge.Prompt`); the host keeps only the paths and
  commands the repository shows and writes RYKER.md from those
  (`Ryker.RepositoryKnowledge.Document`). When no model can finish and none
  ever wrote the file, an outline from the file list takes its place, and
  says so.

  The document is proposed in one pull request at a time: an open one is
  updated, and nothing is opened when the default branch already says the
  same. Work reads the proposed document while its pull request is open and
  the file on the default branch otherwise (`Ryker.Work.SubmissionBuilder`).
  "Refresh knowledge" on the Repositories page asks for a write at once
  (`refresh/2`).

  Every change to a repository's entry is announced after it commits
  (`subscribe/0`).
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge.{Custody, Entry}
  alias Ryker.Settings

  @refresh_reason "Someone asked for it on the Repositories page."

  @doc """
  Has RYKER.md written again now, as Refresh knowledge on the Repositories
  page does: `{:ok, :requested}`, or `{:ok, :already_writing}` while a model
  is reading the repository already. Only an added repository that is set
  up and that GitHub still grants can be refreshed.
  """
  @spec refresh(String.t(), String.t()) ::
          {:ok, :requested | :already_writing} | {:error, term()}
  def refresh(ref, actor) when is_binary(ref) and is_binary(actor) do
    snapshot = Settings.fetch!()
    repository = Enum.find(snapshot.repositories, &(&1.ref == ref))
    bound? = Enum.any?(snapshot.github_bindings, &(&1.repository_ref == ref))

    cond do
      is_nil(repository) -> {:error, :repository_not_found}
      repository.github_access != :available -> {:error, :github_access_unavailable}
      not bound? -> {:error, :repository_binding_missing}
      repository.onboarding_state != :ready -> {:error, :repository_not_ready}
      true -> Custody.request_write(ref, @refresh_reason, actor)
    end
  end

  @doc "Asks for a repository's check now: setup just pinned it."
  @spec check_soon(String.t()) :: :ok
  def check_soon(ref) when is_binary(ref), do: Custody.check_now(ref)

  @doc "Every repository's knowledge entry, by repository ref."
  @spec entries() :: %{String.t() => Entry.t()}
  def entries do
    Repo.all(from(entry in Entry, select: {entry.repository_ref, entry}))
    |> Map.new()
  end

  @doc "One repository's knowledge entry, or nil before its first check."
  @spec entry(String.t()) :: Entry.t() | nil
  def entry(ref) when is_binary(ref), do: Repo.get(Entry, ref)

  @doc """
  Why a step failed, in words a person can act on: each sentence stands on
  the repository's row by itself. Every reason the lane records has one; an
  unknown one still says what happened and what comes next.
  """
  @spec failure(term()) :: String.t()
  def failure({:github_onboarding, :archived}),
    do:
      "The repository is archived on GitHub, so Ryker cannot propose its RYKER.md. " <>
        "Unarchive it on GitHub, then refresh knowledge."

  def failure({:github_onboarding, :permission}),
    do:
      "The Ryker GitHub App cannot read this repository or open its RYKER.md pull request. " <>
        "Give it Contents and Pull requests (Read and write), then refresh knowledge."

  def failure({:github_onboarding, :not_found}),
    do:
      "GitHub no longer finds this repository or its default branch, so RYKER.md was not updated."

  def failure(:repository_empty),
    do: "The repository has no commits yet, so there is nothing to write RYKER.md from."

  def failure(:repository_too_large),
    do: "The repository has too many files for Ryker to check a RYKER.md against them."

  def failure(reason),
    do:
      "RYKER.md was not updated: #{cause(reason)} Ryker tries again with the next daily " <>
        "check, or refresh knowledge."

  defp cause(reason) when reason in [:output_contract_failed, :invalid_repository_knowledge],
    do: "the model's answers did not follow the form Ryker asks for."

  defp cause(:repository_knowledge_unusable),
    do: "the model named nothing Ryker could find in the repository."

  defp cause(:repository_knowledge_execution_timeout),
    do: "the model ran out of time reading the repository."

  defp cause(reason)
       when reason in [
              :repository_knowledge_provider_failed,
              :repository_knowledge_attempt_expired
            ],
       do: "the model stopped before it answered."

  defp cause(reason)
       when reason in [
              :repository_knowledge_session_not_isolated,
              :repository_knowledge_session_unaddressable
            ],
       do: "the worker could not give the model a read-only copy of the repository."

  defp cause(_reason), do: "Ryker could not finish reading the repository."

  @doc """
  Delivers `{:repository_knowledge_updated, ref}` after any change to a
  repository's knowledge entry or its runs commits.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Ryker.PubSub.subscribe(topic())

  def unsubscribe, do: Ryker.PubSub.unsubscribe(topic())

  @doc false
  @spec broadcast_updated(String.t()) :: :ok
  def broadcast_updated(ref) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(topic(), {:repository_knowledge_updated, ref})
    end)

    :ok
  end

  defp topic, do: "repository_knowledge"
end

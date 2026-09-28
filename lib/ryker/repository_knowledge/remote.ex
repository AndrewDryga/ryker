defmodule Ryker.RepositoryKnowledge.Remote do
  @moduledoc """
  What the knowledge lane asks GitHub (`Ryker.GitHub.RepositoryFiles`), as a
  behaviour so its rules are tested against a recorded repository instead of
  the network. `binding` is the repository's GitHub binding and `repository`
  its settings row; every error is a reason `Ryker.RepositoryKnowledge`
  can say in plain words.
  """

  @type binding :: map()
  @type repository :: map()

  @doc "Whether GitHub keeps the repository archived, which refuses every write."
  @callback repository(binding(), repository()) ::
              {:ok, %{archived: boolean()}} | {:error, term()}

  @doc "The commit the default branch points at now."
  @callback head(binding(), repository()) :: {:ok, String.t()} | {:error, term()}

  @doc "Every entry of the tree at `commit`: GitHub's recursive tree, bounded."
  @callback tree(binding(), repository(), String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  The text of one file at `ref`, or `:not_found`. A file Ryker cannot read,
  over 128,000 bytes, not text or not a file at all, is
  `{:error, :source_unavailable}`; GitHub failing to answer is another error.
  """
  @callback read(binding(), repository(), String.t(), String.t()) ::
              {:ok, String.t() | :not_found} | {:error, term()}

  @doc """
  The paths that changed between two commits, or `:unknown` when GitHub
  cannot list them: the older commit is gone, or the change is too large.
  """
  @callback changes(binding(), repository(), String.t(), String.t()) ::
              {:ok, [String.t()] | :unknown} | {:error, term()}

  @doc "Where Ryker's knowledge pull request stands."
  @callback pull_request(binding(), repository(), pos_integer()) ::
              {:ok, :open | :merged | :closed} | {:error, term()}

  @doc """
  Proposes `document` as RYKER.md: updates Ryker's knowledge pull request
  while one is open, opens one when the default branch says something else,
  and opens nothing when it already says the same. `proposed` is the
  document Ryker last proposed, as Work reads it, or nil: an open pull
  request whose RYKER.md says anything else was edited by a person, and is
  left as it is (`{:error, :repository_knowledge_proposal_edited}`).
  """
  @callback publish(binding(), repository(), %{
              document: String.t(),
              body: String.t(),
              proposed: String.t() | nil
            }) ::
              {:ok,
               %{
                 outcome: :opened | :updated | :unchanged,
                 url: String.t() | nil,
                 number: pos_integer() | nil,
                 base_commit: String.t(),
                 base_document: String.t() | nil
               }}
              | {:error, term()}
end

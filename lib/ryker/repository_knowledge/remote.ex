defmodule Ryker.RepositoryKnowledge.Remote do
  @moduledoc """
  What the knowledge lane reads from GitHub (`Ryker.GitHub.RepositoryFiles`),
  as a behaviour so its rules are tested against a recorded repository
  instead of the network. It only reads: RYKER.md is Ryker's own, and nothing
  is written to the repository. `binding` is the repository's GitHub binding
  and `repository` its settings row; every error is a reason
  `Ryker.RepositoryKnowledge` can say in plain words.
  """

  @type binding :: map()
  @type repository :: map()

  @doc "The commit the default branch points at now."
  @callback head(binding(), repository()) :: {:ok, String.t()} | {:error, term()}

  @doc "Every entry of the tree at `commit`: GitHub's recursive tree, bounded."
  @callback tree(binding(), repository(), String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  The text of one file at `ref`, or `:not_found`. A file Ryker cannot read,
  over 1 MB, not text or not a file at all, is `{:error, :source_unavailable}`;
  GitHub failing to answer is another error.
  """
  @callback read(binding(), repository(), String.t(), String.t()) ::
              {:ok, String.t() | :not_found} | {:error, term()}

  @doc """
  The paths that changed between two commits, or `:unknown` when GitHub
  cannot list them: the older commit is gone, or the change is too large.
  """
  @callback changes(binding(), repository(), String.t(), String.t()) ::
              {:ok, [String.t()] | :unknown} | {:error, term()}
end

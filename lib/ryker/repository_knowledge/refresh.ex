defmodule Ryker.RepositoryKnowledge.Refresh do
  @moduledoc """
  When a repository's RYKER.md is written again: the daily check's rules
  (`Ryker.RepositoryKnowledge.Dispatcher`).

  Ryker rewrites a document it wrote from a model's reading only once the
  default branch moved since that write, and then only when a file that
  describes how to work in the repository changed (a key file, as the
  prompt shows the model: `Ryker.RepositoryKnowledge.Document.key_file?/1`),
  or when a week has passed since the write and anything else changed. A
  model turn reads the whole repository, so a push that touches none of that
  costs nothing.

  A repository Ryker has no document for, or only the outline from a try no
  model could finish, is written at once. The rules read only what Ryker
  wrote: a RYKER.md the repository holds is one more file the model may read.
  """

  alias Ryker.RepositoryKnowledge.Document

  @stale_after_seconds 7 * 86_400

  @typedoc """
  The last document Ryker wrote: the default branch commit it read, when,
  and whether a model wrote it (`:model`) or it is the outline (`:outline`).
  """
  @type written :: %{
          commit: String.t() | nil,
          at: DateTime.t() | nil,
          by: :model | :outline | nil
        }

  @typedoc """
  What changed on the default branch since the written commit: the paths, or
  `:unknown` when GitHub cannot say (the commit is gone after a force push, or
  the change is too large to list).
  """
  @type changes :: [String.t()] | :unknown

  @doc """
  Whether RYKER.md is written again, and the plain reason, given the last
  write, the head commit, what changed since the write, and the time now.
  `changes` is read only when the rules need it, so a check that can decide
  without it asks GitHub for nothing more.
  """
  @spec decide(
          written(),
          String.t(),
          (-> {:ok, changes()} | {:error, term()}),
          DateTime.t()
        ) ::
          {:write, String.t()} | :current | {:error, term()}
  def decide(%{by: :model} = written, head, changes, now), do: rules(written, head, changes, now)

  def decide(%{by: :outline}, _head, _changes, _now),
    do: {:write, "RYKER.md is only an outline from the last try."}

  def decide(_written, _head, _changes, _now),
    do: {:write, "Ryker has no RYKER.md for this repository yet."}

  defp rules(%{commit: head}, head, _changes, _now), do: :current

  defp rules(written, _head, changes, now) do
    case changes.() do
      {:ok, :unknown} ->
        {:write, "The default branch changed more than GitHub can list."}

      {:ok, paths} ->
        key = Enum.filter(paths, &Document.key_file?/1)

        cond do
          key != [] ->
            {:write, "These files changed: #{Enum.join(Enum.take(key, 5), ", ")}."}

          week_old?(written, now) and paths != [] ->
            {:write, "A week has passed since the last write, and code changed."}

          true ->
            :current
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp week_old?(%{at: %DateTime{} = at}, now), do: DateTime.diff(now, at) >= @stale_after_seconds
  defp week_old?(_written, _now), do: true

  @doc "How long a week is, for the rules and the tests that hold them."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds, do: @stale_after_seconds
end

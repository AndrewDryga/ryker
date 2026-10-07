defmodule Ryker.ControlPlane.RepositoryNames do
  @moduledoc """
  The name people know each repository by, `owner/repo` as on GitHub, keyed
  by its ref. Pages show this name wherever a repository appears and keep the
  ref only for links and filters.

  Andrew, 2026-09-28: "repos must be named like on GH". A removed
  repository's requests, usage and learned topics keep its ref, so the name
  it had is kept when it is removed (`Ryker.Settings.delete_repository/3`).
  A ref known by neither is its own name.
  """

  alias Ryker.ControlPlane.PageRead
  alias Ryker.Repo
  alias Ryker.Settings.RepositoryQuery

  @doc """
  Every known name, keyed by ref; a repository still added wins over one
  removed. A page read reads them once (`Ryker.ControlPlane.PageRead`): each
  of its lists read them again (2026-10-04 review).
  """
  @spec all() :: %{String.t() => String.t()}
  def all, do: PageRead.memo({__MODULE__, :all}, &read/0)

  defp read do
    removed = Repo.all(RepositoryQuery.removed_names())
    current = Repo.all(RepositoryQuery.named())

    Map.new(removed ++ current)
  end

  @doc "The name `ref` is known by, read once a page read (`all/0`); nil stays nil."
  @spec name(String.t() | nil) :: String.t() | nil
  def name(nil), do: nil
  def name(ref), do: name(all(), ref)

  @doc "The name `ref` is known by in `names`, or the ref itself; nil stays nil."
  @spec name(%{String.t() => String.t()}, String.t() | nil) :: String.t() | nil
  def name(_names, nil), do: nil
  def name(names, ref), do: Map.get(names, ref, ref)
end

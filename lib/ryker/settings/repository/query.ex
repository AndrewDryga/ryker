defmodule Ryker.Settings.Repository.Query do
  @moduledoc "Repositories set up for work, for every read of `repository_settings`."
  use Ryker, :query
  alias Ryker.Settings.Repository

  def all, do: from(repositories in Repository, as: :repository_settings)

  @doc "Each repository people know by name, as `{ref, name}`: owner/repo from GitHub."
  def named do
    from(r in all(),
      where: coalesce(r.github_repository, r.display_name) != "",
      select: {r.ref, coalesce(r.github_repository, r.display_name)}
    )
  end

  @doc """
  The names removed repositories had, as `{ref, name}`, kept so their history
  still reads by name (`Ryker.Settings.delete_repository/3`).
  """
  def removed_names, do: from(row in "removed_repository_names", select: {row.ref, row.name})

  def by_refs(queryable \\ all(), refs),
    do: where(queryable, [repository_settings: r], r.ref in ^refs)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [repository_settings: r], r.ref == ^ref)

  def ordered_by_ref(queryable), do: order_by(queryable, [repository_settings: r], r.ref)

  def select_github_repositories(queryable),
    do: select(queryable, [repository_settings: r], r.github_repository)

  def select_descriptions(queryable),
    do: select(queryable, [repository_settings: r], {r.ref, r.description, r.display_name})
end

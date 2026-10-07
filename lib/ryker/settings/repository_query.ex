defmodule Ryker.Settings.RepositoryQuery do
  @moduledoc "Repositories set up for work, for every read of `repository_settings`."
  import Ecto.Query
  alias Ryker.Settings.Repository

  def all, do: from(repositories in Repository, as: :repository_settings)

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

defmodule Ryker.Publication.PublicationQuery do
  @moduledoc "Changes Work published, for every read of `episode_publications`."
  import Ecto.Query
  alias Ryker.Publication.Publication

  def all, do: from(publications in Publication, as: :episode_publications)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_publications: p], p.episode_id == ^episode_id)

  def newest_first(queryable),
    do: order_by(queryable, [episode_publications: p], desc: p.inserted_at, desc: p.id)

  def select_statuses(queryable), do: select(queryable, [episode_publications: p], p.status)
  def limit_to(queryable, count), do: limit(queryable, ^count)
end

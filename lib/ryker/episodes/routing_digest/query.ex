defmodule Ryker.Episodes.RoutingDigest.Query do
  @moduledoc "Each episode's routing digest, for every read of `episode_routing_digests`."
  import Ecto.Query
  alias Ryker.Episodes.RoutingDigest

  def all, do: from(digests in RoutingDigest, as: :episode_routing_digests)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_routing_digests: d], d.episode_id == ^episode_id)

  def by_episode_ids(queryable \\ all(), episode_ids),
    do: where(queryable, [episode_routing_digests: d], d.episode_id in ^episode_ids)

  def select_episode_ids(queryable \\ all()),
    do: select(queryable, [episode_routing_digests: d], d.episode_id)

  def select_titles(queryable) do
    queryable
    |> where([episode_routing_digests: d], not is_nil(d.title))
    |> select([episode_routing_digests: d], {d.episode_id, d.title})
  end

  def without_title(queryable, title) do
    where(
      queryable,
      [episode_routing_digests: d],
      is_nil(d.title) or d.title != ^title
    )
  end

  def without_embedding(queryable \\ all()),
    do: where(queryable, [episode_routing_digests: d], is_nil(d.embedding_model))

  @doc "Still as `digest` was read: not rewritten since."
  def unchanged_since(queryable, digest),
    do: where(queryable, [episode_routing_digests: d], d.updated_at == ^digest.updated_at)

  def ordered_by_recently_updated(queryable) do
    order_by(queryable, [episode_routing_digests: d],
      desc: d.updated_at,
      asc: d.episode_id
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
end

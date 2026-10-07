defmodule Ryker.Episodes.RoutingDigestQuery do
  @moduledoc "Each episode's routing digest, for every read of `episode_routing_digests`."
  import Ecto.Query
  alias Ryker.Episodes.RoutingDigest

  def all, do: from(digests in RoutingDigest, as: :episode_routing_digests)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_routing_digests: d], d.episode_id == ^episode_id)

  def without_embedding(queryable \\ all()),
    do: where(queryable, [episode_routing_digests: d], is_nil(d.embedding_model))

  @doc "Still as `digest` was read: not rewritten since."
  def unchanged_since(queryable, digest),
    do: where(queryable, [episode_routing_digests: d], d.updated_at == ^digest.updated_at)

  def recently_updated_first(queryable) do
    order_by(queryable, [episode_routing_digests: d],
      desc: d.updated_at,
      asc: d.episode_id
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
end

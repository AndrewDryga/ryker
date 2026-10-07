defmodule Ryker.Episodes.OriginQuery do
  @moduledoc "Where each request's inputs came from, for every read of `episode_input_origins`."
  import Ecto.Query
  alias Ryker.Episodes.{Episode, Origin}

  def all, do: from(origins in Origin, as: :episode_input_origins)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_input_origins: o], o.episode_id == ^episode_id)

  def by_native_input_id(queryable \\ all(), native_input_id),
    do: where(queryable, [episode_input_origins: o], o.native_input_id == ^native_input_id)

  def in_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [episode_input_origins: o],
      o.transport == ^transport and o.conversation_ref == ^conversation_ref
    )
  end

  @doc "The conversations episode `episode_id`'s inputs came from, each once, in order."
  def conversation_refs(episode_id) do
    from(o in by_episode_id(episode_id),
      where: not is_nil(o.conversation_ref),
      distinct: true,
      order_by: [asc: o.conversation_ref],
      select: o.conversation_ref
    )
  end

  def select_episode_ids(queryable),
    do: select(queryable, [episode_input_origins: o], o.episode_id)

  def select_native_input_ids(queryable),
    do: select(queryable, [episode_input_origins: o], o.native_input_id)

  def select_source_item_refs(queryable),
    do: select(queryable, [episode_input_origins: o], o.source_item_ref)

  @doc "Inputs a person sent: a Slack or Chat user, not an app, a bot or the scheduler."
  def from_people(queryable),
    do: where(queryable, [episode_input_origins: o], like(o.actor_ref, "%:user:%"))

  def by_input_refs(queryable, input_refs),
    do: where(queryable, [episode_input_origins: o], o.input_ref in ^input_refs)

  def latest_first(queryable),
    do: order_by(queryable, [episode_input_origins: o], desc: o.occurred_at, desc: o.sequence)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def in_occurrence_order(queryable),
    do: order_by(queryable, [episode_input_origins: o], asc: o.occurred_at, asc: o.sequence)

  @doc "The request that owns source item `native_input_id`, by its highest admitted revision."
  def current_owner(native_input_id, transport, execution_mode) do
    from(o in all(),
      join: e in Episode,
      on: e.id == o.episode_id,
      where:
        o.native_input_id == ^native_input_id and o.transport == ^transport and
          e.execution_mode == ^execution_mode,
      order_by: [desc: o.revision, asc: e.id],
      limit: 1,
      select: {e, o.revision}
    )
  end
end

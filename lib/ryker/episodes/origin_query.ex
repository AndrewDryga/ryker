defmodule Ryker.Episodes.OriginQuery do
  @moduledoc "Where each request's inputs came from, for every read of `episode_input_origins`."
  import Ecto.Query
  alias Ryker.Episodes.{Episode, Origin}

  def all, do: from(origins in Origin, as: :episode_input_origins)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_input_origins: o], o.episode_id == ^episode_id)

  @doc "Inputs a person sent: a Slack or Chat user, not an app, a bot or the scheduler."
  def from_people(queryable),
    do: where(queryable, [episode_input_origins: o], like(o.actor_ref, "%:user:%"))

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

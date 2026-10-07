defmodule Ryker.CoopFleet.EventQuery do
  @moduledoc "What workers reported about their sessions, for every read of `coop_worker_events`."
  import Ecto.Query
  alias Ryker.CoopFleet.Event

  def all, do: from(events in Event, as: :coop_worker_events)

  @doc """
  The event placement `placement_id` stored at `sequence`: a session event,
  or with `session_event?` false, any other kind. Session events and the
  coarse ones number their sequences apart.
  """
  def of_sessions(queryable \\ all(), session_ids),
    do: where(queryable, [coop_worker_events: e], e.session_id in ^session_ids)

  def excluding_kind(queryable, kind),
    do: where(queryable, [coop_worker_events: e], e.kind != ^kind)

  def in_order(queryable),
    do: order_by(queryable, [coop_worker_events: e], asc: e.inserted_at, asc: e.sequence)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def stored(placement_id, sequence, true) do
    where(
      all(),
      [coop_worker_events: e],
      e.placement_id == ^placement_id and e.sequence == ^sequence and e.kind == "session_event"
    )
  end

  def stored(placement_id, sequence, false) do
    where(
      all(),
      [coop_worker_events: e],
      e.placement_id == ^placement_id and e.sequence == ^sequence and e.kind != "session_event"
    )
  end
end

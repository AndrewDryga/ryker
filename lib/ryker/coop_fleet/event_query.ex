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

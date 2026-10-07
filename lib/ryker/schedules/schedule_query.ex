defmodule Ryker.Schedules.ScheduleQuery do
  @moduledoc "Scheduled automations, for every read of `episode_schedules`."
  import Ecto.Query
  alias Ryker.Schedules.Schedule

  def all, do: from(schedules in Schedule, as: :episode_schedules)

  def by_ref(queryable \\ all(), ref), do: where(queryable, [episode_schedules: s], s.ref == ^ref)

  def in_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [episode_schedules: s],
      s.destination_transport == ^transport and
        s.destination_conversation_ref == ^conversation_ref
    )
  end

  def not_deleted(queryable), do: where(queryable, [episode_schedules: s], s.status != :deleted)

  def soonest_first(queryable) do
    order_by(queryable, [episode_schedules: s],
      asc: s.next_occurrence_at,
      asc: s.inserted_at,
      asc: s.id
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end

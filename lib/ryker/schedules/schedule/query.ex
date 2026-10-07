defmodule Ryker.Schedules.Schedule.Query do
  @moduledoc "Scheduled automations, for every read of `episode_schedules`."
  import Ecto.Query
  alias Ryker.Schedules.Schedule

  def all, do: from(schedules in Schedule, as: :episode_schedules)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_schedules: s], s.id == ^id)
  def by_ref(queryable \\ all(), ref), do: where(queryable, [episode_schedules: s], s.ref == ^ref)

  def by_status(queryable \\ all(), status),
    do: where(queryable, [episode_schedules: s], s.status == ^status)

  def by_statuses(queryable \\ all(), statuses),
    do: where(queryable, [episode_schedules: s], s.status in ^statuses)

  def by_offer_record_id(queryable \\ all(), record_id),
    do: where(queryable, [episode_schedules: s], s.offer_record_id == ^record_id)

  @doc """
  Active and due at `now`: its occurrence has come, with no retry backoff or
  unrenewed lease left.
  """
  def due_at(now) do
    now
    |> occurrence_due_at()
    |> where([episode_schedules: s], is_nil(s.lease_ref) or s.lease_expires_at <= ^now)
  end

  @doc "Active schedules whose occurrence and retry are due at `now`, leased or not."
  def occurrence_due_at(now) do
    all()
    |> where(
      [episode_schedules: s],
      s.status == :active and s.next_occurrence_at <= ^now
    )
    |> where([episode_schedules: s], is_nil(s.next_attempt_at) or s.next_attempt_at <= ^now)
  end

  @doc """
  The earliest moment after `since` at which an active schedule becomes
  claimable by the clock alone: its next occurrence, the end of its retry's
  backoff or the end of an unrenewed lease, whichever it waits on last.
  """
  def next_due_after(since) do
    due =
      from(schedule in all(),
        where: schedule.status == :active and not is_nil(schedule.next_occurrence_at),
        select: %{
          due_at:
            type(
              fragment(
                "GREATEST(?, ?, CASE WHEN ? IS NOT NULL THEN ? END)",
                schedule.next_occurrence_at,
                schedule.next_attempt_at,
                schedule.lease_ref,
                schedule.lease_expires_at
              ),
              :utc_datetime_usec
            )
        }
      )

    from(schedule in subquery(due),
      where: schedule.due_at > ^since,
      select: min(schedule.due_at)
    )
  end

  def by_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [episode_schedules: s],
      s.destination_transport == ^transport and
        s.destination_conversation_ref == ^conversation_ref
    )
  end

  def not_deleted(queryable), do: where(queryable, [episode_schedules: s], s.status != :deleted)

  def ordered_by_next_occurrence_at(queryable) do
    order_by(queryable, [episode_schedules: s],
      asc: s.next_occurrence_at,
      asc: s.inserted_at,
      asc: s.id
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def by_source_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_schedules: s], s.source_episode_id == ^episode_id)

  def ordered_by_confirmed_at_desc(queryable),
    do: order_by(queryable, [episode_schedules: s], desc: s.confirmed_at, desc: s.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
end

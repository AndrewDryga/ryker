defmodule Ryker.Observability.Queues do
  @moduledoc """
  Depth and age of every custody queue, measured from the database clock.

  Each queue reports what is claimable now, what is leased, and how long the
  oldest of each has waited. Claimable work is counted with the eligibility
  its custody owner claims by, so a deliberate wait is never reported as a
  stall, and leases are counted apart so a stuck executor is still visible.
  """

  import Ecto.Query
  alias Ryker.Delivery.RoutingResponseQuery
  alias Ryker.Emisar.Approval
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.{Entry, EntryQuery}
  alias Ryker.Observability.Reads
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Publication.{Followup, Followups, LifecycleEvent, Publication}
  alias Ryker.Records.Record
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Schedules.Schedule
  alias Ryker.Work.Custody, as: WorkCustody
  alias Ryker.Work.Turn

  @type queue :: %{
          active_leases: non_neg_integer(),
          claimable: non_neg_integer(),
          name: atom(),
          oldest_active_age_seconds: non_neg_integer(),
          oldest_age_seconds: non_neg_integer()
        }

  @doc "Every queue at the database clock reading `now`, in the order they are reported."
  @spec snapshot(DateTime.t()) :: {:ok, [queue()]} | {:error, Reads.failure()}
  def snapshot(now) do
    [
      fn -> ingress(now) end,
      fn -> status_queue(Turn, :work, [:pending], :inserted_at, now) end,
      fn -> status_queue(Turn, :cancellation, [:cancel_pending], :updated_at, now) end,
      fn -> status_queue(Turn, :delivery, [:delivery_pending], :accepted_at, now) end,
      fn ->
        status_queue(RoutingResponseQuery.all(), :routing_delivery, [:pending], :inserted_at, now)
      end,
      fn ->
        status_queue(
          Publication,
          :publication,
          [:review_pending, :review_ready, :publish_pending, :published_ready],
          :updated_at,
          now
        )
      end,
      fn -> approval(now) end,
      fn -> publication_followup(now) end,
      fn -> publication_lifecycle(now) end,
      fn -> retention(now) end,
      fn -> due_schedule(now) end
    ]
    |> Reads.collect(& &1.())
  end

  @doc "Names of the queues whose oldest claimable work has waited past the bound."
  @spec stalled([queue()], pos_integer()) :: [atom()]
  def stalled(queues, stall_after_seconds) do
    queues
    |> Enum.filter(&(&1.claimable > 0 and &1.oldest_age_seconds > stall_after_seconds))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  @doc "Names of the queues holding a lease past the bound."
  @spec stalled_leases([queue()], pos_integer()) :: [atom()]
  def stalled_leases(queues, stall_after_seconds) do
    queues
    |> Enum.filter(&(&1.active_leases > 0 and &1.oldest_active_age_seconds > stall_after_seconds))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp ingress(now) do
    active =
      from(entry in Entry,
        where:
          entry.status == :pending and not is_nil(entry.lease_ref) and
            entry.lease_expires_at > ^now
      )

    projection(EntryQuery.claimable_at(now), active, :ingress, :inserted_at, now)
  end

  defp status_queue(schema, name, statuses, age_field, now) do
    base =
      from(row in schema,
        where: row.status in ^statuses,
        where: is_nil(row.next_attempt_at) or row.next_attempt_at <= ^now
      )

    leased_queue(base, name, age_field, now)
  end

  defp due_schedule(now) do
    base =
      from(schedule in Schedule,
        where: schedule.status == :active,
        where: schedule.next_occurrence_at <= ^now,
        where: is_nil(schedule.next_attempt_at) or schedule.next_attempt_at <= ^now
      )

    leased_queue(base, :schedule, :next_occurrence_at, now)
  end

  defp approval(now) do
    base =
      from(approval in Approval,
        join: record in Record,
        on: record.id == approval.record_id and record.episode_id == approval.episode_id,
        join: episode in Episode,
        on: episode.id == approval.episode_id,
        where: approval.status == :monitoring,
        where: record.kind == "emisar_approval" and record.status == :open,
        where:
          episode.state == :waiting_for_event and episode.owner_kind == :event and
            episode.owner_ref == record.ref,
        where: is_nil(approval.next_attempt_at) or approval.next_attempt_at <= ^now
      )

    leased_queue(base, :emisar_approval, :inserted_at, now)
  end

  defp publication_followup(now) do
    base =
      from(followup in Followup,
        where: followup.next_poll_at <= ^now
      )

    leased_queue(base, :publication_followup, :next_poll_at, now)
  end

  defp publication_lifecycle(now) do
    base =
      from(event in LifecycleEvent,
        where: event.delivery_state == :pending,
        where: is_nil(event.next_attempt_at) or event.next_attempt_at <= ^now
      )

    leased_queue(base, :publication_lifecycle, :inserted_at, now)
  end

  # Readiness reads the same eligibility custody claims from, so a Work or
  # learning backlog can never be counted differently by the two owners, and so
  # conversation plus grace time is never reported as cleanup stall.
  defp retention(now) do
    base = RetentionCustody.eligible_query(now)

    claimable =
      from([session: session] in base,
        where: is_nil(session.cleanup_lease_ref) or session.cleanup_lease_expires_at <= ^now
      )

    active =
      from([session: session] in base,
        where: not is_nil(session.cleanup_lease_ref) and session.cleanup_lease_expires_at > ^now
      )

    with {:ok, oldest_active} <-
           Reads.one(from([session: session] in active, select: min(session.updated_at))),
         {:ok, active_leases} <- Reads.count(active),
         {:ok, claimable_count} <- Reads.count(claimable),
         {:ok, oldest_claimable} <-
           Reads.read(fn -> RetentionCustody.oldest_eligible_at(claimable) end) do
      {:ok,
       %{
         active_leases: active_leases,
         claimable: claimable_count,
         name: :retention,
         oldest_active_age_seconds: Reads.age_seconds(now, oldest_active),
         oldest_age_seconds: Reads.age_seconds(now, oldest_claimable)
       }}
    end
  end

  defp leased_queue(base, name, age_field, now) do
    claimable =
      from(row in base,
        where: is_nil(row.lease_ref) or row.lease_expires_at <= ^now
      )
      |> runnable(name, now)

    active =
      from(row in base,
        where: not is_nil(row.lease_ref) and row.lease_expires_at > ^now
      )

    projection(claimable, active, name, age_field, now)
  end

  # Deliberate peer-custody waits are not stalled claimable work. Keep active
  # lease monitoring separate so a stuck executor is still visible.
  defp runnable(query, name, now) when name in [:work, :cancellation, :delivery] do
    phase = if name == :delivery, do: :delivery, else: :work
    episodes = WorkCustody.claimable_episode_ids_query(now, phase)
    from(turn in query, where: turn.episode_id in subquery(episodes))
  end

  # A routing response waits for every earlier one of its message to be
  # delivered; only the next in line is claimable.
  defp runnable(query, :routing_delivery, _now), do: RoutingResponseQuery.in_order(query)

  defp runnable(query, :publication, now) do
    publications =
      from(publication in PublicationCustody.claimable_query(now), select: publication.id)

    from(publication in query, where: publication.id in subquery(publications))
  end

  # A pull request's poll waits while the task's newer change is in review.
  defp runnable(query, :publication_followup, _now) do
    followups = from(followup in Followups.pollable_query(), select: followup.id)
    from(followup in query, where: followup.id in subquery(followups))
  end

  defp runnable(query, _name, _now), do: query

  defp projection(claimable, active, name, age_field, now) do
    with {:ok, oldest_claimable} <- Reads.one(oldest_due(claimable, age_field)),
         {:ok, oldest_active} <- Reads.one(from(row in active, select: min(row.updated_at))),
         {:ok, active_leases} <- Reads.count(active),
         {:ok, claimable_count} <- Reads.count(claimable) do
      {:ok,
       %{
         active_leases: active_leases,
         claimable: claimable_count,
         name: name,
         oldest_active_age_seconds: Reads.age_seconds(now, oldest_active),
         oldest_age_seconds: Reads.age_seconds(now, oldest_claimable)
       }}
    end
  end

  # A row that waits out a backoff or a poll interval falls due again when
  # that wait ends, so it has waited since the later of the two times. A
  # follow-up's next poll is already its due time.
  defp oldest_due(query, :next_poll_at), do: from(row in query, select: min(row.next_poll_at))

  defp oldest_due(query, age_field) do
    from(row in query,
      select: min(fragment("GREATEST(?, ?)", field(row, ^age_field), row.next_attempt_at))
    )
  end
end

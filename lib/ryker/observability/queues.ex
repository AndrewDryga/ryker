defmodule Ryker.Observability.Queues do
  @moduledoc """
  Depth and age of every custody queue, measured from the database clock.

  Each queue reports what is claimable now, what is leased, and how long the
  oldest of each has waited. Claimable work is counted with the eligibility
  its custody owner claims by, so a deliberate wait is never reported as a
  stall, and leases are counted apart so a stuck executor is still visible.
  """

  alias Ryker.Delivery.RoutingResponseQuery
  alias Ryker.Emisar.ApprovalQuery
  alias Ryker.Ingress.Inbox.EntryQuery
  alias Ryker.Observability.{ProjectionQuery, Reads}
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Publication.{FollowupQuery, LifecycleEventQuery, PublicationQuery}
  alias Ryker.Retention.CleanupQuery
  alias Ryker.Schedules.ScheduleQuery
  alias Ryker.Work.{OwningTurnQuery, TurnQuery}

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
      fn -> status_queue(TurnQuery.all(), :work, [:pending], :inserted_at, now) end,
      fn -> status_queue(TurnQuery.all(), :cancellation, [:cancel_pending], :updated_at, now) end,
      fn -> status_queue(TurnQuery.all(), :delivery, [:delivery_pending], :accepted_at, now) end,
      fn ->
        status_queue(RoutingResponseQuery.all(), :routing_delivery, [:pending], :inserted_at, now)
      end,
      fn ->
        status_queue(
          PublicationQuery.all(),
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
    projection(
      EntryQuery.claimable_at(now),
      EntryQuery.leased_at(now),
      :ingress,
      :inserted_at,
      now
    )
  end

  defp status_queue(queryable, name, statuses, age_field, now) do
    queryable
    |> ProjectionQuery.due_in_statuses(statuses, now)
    |> leased_queue(name, age_field, now)
  end

  defp due_schedule(now) do
    now
    |> ScheduleQuery.occurrence_due_at()
    |> leased_queue(:schedule, :next_occurrence_at, now)
  end

  defp approval(now) do
    ApprovalQuery.all()
    |> ApprovalQuery.with_origin()
    |> ApprovalQuery.with_status(:monitoring)
    |> ApprovalQuery.awaited()
    |> ApprovalQuery.due_at(now)
    |> leased_queue(:emisar_approval, :inserted_at, now)
  end

  defp publication_followup(now) do
    FollowupQuery.all()
    |> FollowupQuery.poll_due_at(now)
    |> leased_queue(:publication_followup, :next_poll_at, now)
  end

  defp publication_lifecycle(now) do
    LifecycleEventQuery.pending()
    |> ProjectionQuery.retry_due_at(now)
    |> leased_queue(:publication_lifecycle, :inserted_at, now)
  end

  # Readiness reads the same eligibility custody claims from, so a Work or
  # learning backlog can never be counted differently by the two owners, and so
  # conversation plus grace time is never reported as cleanup stall.
  defp retention(now) do
    base = CleanupQuery.eligible(now)
    claimable = CleanupQuery.unleased_at(base, now)
    active = CleanupQuery.leased_at(base, now)

    with {:ok, oldest_active} <- Reads.one(ProjectionQuery.select_oldest_update(active)),
         {:ok, active_leases} <- Reads.count(active),
         {:ok, claimable_count} <- Reads.count(claimable),
         {:ok, oldest_claimable} <- Reads.one(CleanupQuery.select_oldest_eligible_at(claimable)) do
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
    claimable = base |> ProjectionQuery.unleased_at(now) |> runnable(name, now)
    active = ProjectionQuery.leased_at(base, now)
    projection(claimable, active, name, age_field, now)
  end

  # Deliberate peer-custody waits are not stalled claimable work. Keep active
  # lease monitoring separate so a stuck executor is still visible.
  defp runnable(query, name, now) when name in [:work, :cancellation, :delivery] do
    phase = if name == :delivery, do: :delivery, else: :work
    ProjectionQuery.in_episodes(query, OwningTurnQuery.claimable_episode_ids(now, phase))
  end

  # A routing response waits for every earlier one of its message to be
  # delivered; only the next in line is claimable.
  defp runnable(query, :routing_delivery, _now), do: RoutingResponseQuery.in_order(query)

  defp runnable(query, :publication, now),
    do: ProjectionQuery.among(query, PublicationCustody.claimable(now))

  # A pull request's poll waits while the task's newer change is in review.
  defp runnable(query, :publication_followup, _now),
    do: ProjectionQuery.among(query, FollowupQuery.pollable())

  defp runnable(query, _name, _now), do: query

  defp projection(claimable, active, name, age_field, now) do
    with {:ok, oldest_claimable} <-
           Reads.one(ProjectionQuery.select_oldest_due(claimable, age_field)),
         {:ok, oldest_active} <- Reads.one(ProjectionQuery.select_oldest_update(active)),
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
end

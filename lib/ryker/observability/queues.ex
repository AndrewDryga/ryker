defmodule Ryker.Observability.Queues do
  @moduledoc """
  Depth and age of every custody queue, measured from the database clock.

  Each queue reports what is claimable now, what is leased, and how long the
  oldest of each has waited. Claimable work is counted with the eligibility
  its custody owner claims by, so a deliberate wait is never reported as a
  stall, and leases are counted apart so a stuck executor is still visible.
  """
  alias Ryker.Delivery
  alias Ryker.Emisar
  alias Ryker.Ingress
  alias Ryker.Observability.{Projection, Reads}
  alias Ryker.Publication
  alias Ryker.Retention
  alias Ryker.Schedules
  alias Ryker.Work

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
      fn -> status_queue(Work.Turn.Query.all(), :work, [:pending], :inserted_at, now) end,
      fn ->
        status_queue(Work.Turn.Query.all(), :cancellation, [:cancel_pending], :updated_at, now)
      end,
      fn ->
        status_queue(Work.Turn.Query.all(), :delivery, [:delivery_pending], :accepted_at, now)
      end,
      fn ->
        status_queue(
          Delivery.RoutingResponse.Query.all(),
          :routing_delivery,
          [:pending],
          :inserted_at,
          now
        )
      end,
      fn ->
        status_queue(
          Publication.Publication.Query.all(),
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
      Ingress.Inbox.Entry.Query.claimable_at(now),
      Ingress.Inbox.Entry.Query.leased_at(now),
      :ingress,
      :inserted_at,
      now
    )
  end

  defp status_queue(queryable, name, statuses, age_field, now) do
    queryable
    |> Projection.Query.due_in_statuses(statuses, now)
    |> leased_queue(name, age_field, now)
  end

  defp due_schedule(now) do
    now
    |> Schedules.Schedule.Query.occurrence_due_at()
    |> leased_queue(:schedule, :next_occurrence_at, now)
  end

  defp approval(now) do
    Emisar.Approval.Query.all()
    |> Emisar.Approval.Query.with_joined_origin()
    |> Emisar.Approval.Query.by_status(:monitoring)
    |> Emisar.Approval.Query.awaited()
    |> Emisar.Approval.Query.due_at(now)
    |> leased_queue(:emisar_approval, :inserted_at, now)
  end

  defp publication_followup(now) do
    Publication.Followup.Query.all()
    |> Publication.Followup.Query.poll_due_at(now)
    |> leased_queue(:publication_followup, :next_poll_at, now)
  end

  defp publication_lifecycle(now) do
    Publication.LifecycleEvent.Query.pending()
    |> Projection.Query.retry_due_at(now)
    |> leased_queue(:publication_lifecycle, :inserted_at, now)
  end

  # Readiness reads the same eligibility custody claims from, so a Work or
  # learning backlog can never be counted differently by the two owners, and so
  # conversation plus grace time is never reported as cleanup stall.
  defp retention(now) do
    base = Retention.Cleanup.Query.eligible(now)
    claimable = Retention.Cleanup.Query.unleased_at(base, now)
    active = Retention.Cleanup.Query.leased_at(base, now)

    with {:ok, oldest_active} <- Reads.one(Projection.Query.select_oldest_update(active)),
         {:ok, active_leases} <- Reads.count(active),
         {:ok, claimable_count} <- Reads.count(claimable),
         {:ok, oldest_claimable} <-
           Reads.one(Retention.Cleanup.Query.select_oldest_eligible_at(claimable)) do
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
    claimable = base |> Projection.Query.unleased_at(now) |> runnable(name, now)
    active = Projection.Query.leased_at(base, now)
    projection(claimable, active, name, age_field, now)
  end

  # Deliberate peer-custody waits are not stalled claimable work. Keep active
  # lease monitoring separate so a stuck executor is still visible.
  defp runnable(query, name, now) when name in [:work, :cancellation, :delivery] do
    phase = if name == :delivery, do: :delivery, else: :work

    Projection.Query.by_episode_ids(
      query,
      Work.OwningTurn.Query.claimable_episode_ids(now, phase)
    )
  end

  # A routing response waits for every earlier one of its message to be
  # delivered; only the next in line is claimable.
  defp runnable(query, :routing_delivery, _now),
    do: Delivery.RoutingResponse.Query.in_order(query)

  defp runnable(query, :publication, now),
    do: Projection.Query.among(query, Publication.Custody.claimable(now))

  # A pull request's poll waits while the task's newer change is in review.
  defp runnable(query, :publication_followup, _now),
    do: Projection.Query.among(query, Publication.Followup.Query.pollable())

  defp runnable(query, _name, _now), do: query

  defp projection(claimable, active, name, age_field, now) do
    with {:ok, oldest_claimable} <-
           Reads.one(Projection.Query.select_oldest_due(claimable, age_field)),
         {:ok, oldest_active} <- Reads.one(Projection.Query.select_oldest_update(active)),
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

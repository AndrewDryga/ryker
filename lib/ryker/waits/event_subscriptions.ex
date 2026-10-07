defmodule Ryker.Waits.EventSubscriptions do
  @moduledoc """
  Durable custody for one active event or timer wait per episode.

  Webhooks resume the exact episode through generic ingress. Event-only waits
  retain a bounded source matcher without a timer. Optional deadlines and earlier
  polling fallbacks protect waits that need verification after a missed webhook.
  Timers share that indexed wakeup time, anchored to the original record rather
  than each reconciliation.

  Event-only watches may remain open alongside a human question. The question
  owns continuation; source updates remain queued until the answer resumes Work.
  Reconciliation preserves the subscribed watch's exact matcher during the
  question and Work turn; with more than one watch, the oldest is subscribed.

  A follow-up started, resolved or cancelled is announced after the outermost
  commit (`subscribe_follow_ups/0`), on its request's topics too.

  A wait Ryker failed to schedule or resume is marked so (`fail/2`) and passed
  over, then tried again ten minutes on: the earliest wait was taken again on
  every poll, and one that kept failing held up every other.
  """

  require Logger
  alias Ryker.Episodes.Episode
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Records.RecordPayload
  alias Ryker.Repo
  alias Ryker.Waits.EventSubscription
  alias Ryker.Waits.EventWaitTiming

  @reconcile_limit 100

  # A `wait_error` naming Ryker's own failure, tried again after this long; every other one
  # names saved data that trying again cannot change.
  @failure_retry_seconds 600

  @spec ensure_in_transaction(Episode.t()) ::
          {:ok, :not_source_event | EventSubscription.t()} | {:error, term()}
  def ensure_in_transaction(%Episode{} = episode) do
    if Repo.in_transaction?() do
      ensure_locked(episode)
    else
      {:error, :event_subscription_transaction_required}
    end
  end

  @doc """
  Cancels subscriptions their wait no longer needs and subscribes waits that
  have none, each wait in its own transaction: one wait that cannot be
  subscribed rolled back every other's, and nothing resumed until it could be
  (2026-10-04 review).
  """
  @spec reconcile() :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile do
    with {:ok, cancelled} <- Repo.transaction(&cancel_stale_in_transaction/0) do
      {:ok, Enum.reduce(unsubscribed_waits(), cancelled, &subscribe/2)}
    end
  end

  defp unsubscribed_waits do
    Repo.now!()
    |> failure_retried_before()
    |> EventSubscription.Query.unsubscribed_waits(@reconcile_limit)
    |> Repo.all()
  end

  defp subscribe(%{episode: episode, record_id: record_id}, count) do
    case Repo.transaction(fn -> subscribe_locked(episode, record_id) end) do
      {:ok, %EventSubscription{}} ->
        count + 1

      {:ok, :not_source_event} ->
        count

      {:error, {:invalid_event_subscription, field}}
      when field in [:deadline, :poll_after, :timer_deadline, :source_kind, :cursor] ->
        fail(record_id, Atom.to_string(field))
        count

      {:error, reason} ->
        Logger.error("event wait #{record_id} could not be scheduled: #{inspect(reason)}")
        fail(record_id, "schedule_failed")
        count
    end
  end

  # A wait whose scheduling failed ten minutes ago is tried as if new; the mark comes back if it
  # fails again.
  defp subscribe_locked(episode, record_id) do
    record_id
    |> Record.Query.by_id()
    |> Record.Query.by_wait_error("schedule_failed")
    |> Repo.update_all(set: [wait_error: nil])

    case ensure_locked(episode) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Marks an open wait with why Ryker could not schedule or resume it, so the
  waits after it go first. `schedule_failed` and `resume_failed` are Ryker's
  own failures and are tried again (`failure_retried_before/1`); any other
  code names saved data that cannot be scheduled.
  """
  @spec fail(Ecto.UUID.t(), String.t()) :: :ok
  def fail(record_id, code) when is_binary(record_id) and is_binary(code) do
    {_count, failed} =
      record_id
      |> Record.Query.by_id()
      |> Record.Query.open()
      |> Record.Query.select_rows()
      |> Repo.update_all(set: [wait_error: code, updated_at: Repo.now!()])

    Enum.each(failed, &Records.broadcast_record_updated/1)
  end

  @doc "A wait Ryker failed on before this moment is tried again."
  @spec failure_retried_before(DateTime.t()) :: DateTime.t()
  def failure_retried_before(%DateTime{} = now),
    do: DateTime.add(now, -@failure_retry_seconds, :second)

  defp cancel_stale_in_transaction do
    stale = @reconcile_limit |> EventSubscription.Query.stale() |> Repo.all()

    now = Repo.now!()

    Enum.each(stale, fn item ->
      broadcast_follow_up_updated(item.subscription_id, item.episode_id)

      item.subscription_id
      |> EventSubscription.Query.by_id()
      |> EventSubscription.Query.active()
      |> Repo.update_all(
        set: [
          last_observation: %{"event_wait_ref" => item.ref, "kind" => "cancelled"},
          last_observed_at: now,
          resolution_kind: :cancelled,
          status: :cancelled,
          updated_at: now
        ],
        inc: [revision: 1]
      )

      {_count, dismissed} =
        item.record_id
        |> Record.Query.by_id()
        |> Record.Query.open()
        |> Record.Query.select_rows()
        |> Repo.update_all(set: [status: :dismissed, updated_at: now])

      Enum.each(dismissed, &Records.broadcast_record_updated/1)
    end)

    length(stale)
  end

  @doc false
  @spec resolve_wait_in_transaction(String.t(), atom()) :: :ok | {:error, term()}
  def resolve_wait_in_transaction(wait_ref, resolution_kind)
      when is_binary(wait_ref) and
             resolution_kind in [:input, :poll_fallback, :timer, :deadline, :cancelled] do
    if Repo.in_transaction?() do
      now = Repo.now!()
      {status, observation} = resolution(resolution_kind, wait_ref)

      {_count, resolved} =
        wait_ref
        |> EventSubscription.Query.resolving(status, resolution_kind, observation, now)
        |> Repo.update_all([])

      Enum.each(resolved, fn {id, episode_id} -> broadcast_follow_up_updated(id, episode_id) end)
    else
      {:error, :event_subscription_transaction_required}
    end
  end

  def resolve_wait_in_transaction(_wait_ref, _resolution_kind),
    do: {:error, :event_subscription_not_found}

  @spec fetch_due(DateTime.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_due(%DateTime{} = now),
    do: now |> EventSubscription.Query.due(failure_retried_before(now)) |> Repo.fetch()

  defp ensure_locked(
         %Episode{owner_kind: :event, owner_ref: wait_ref, state: :waiting_for_event} = episode
       ) do
    wait =
      episode.id
      |> Record.Query.open_wait(wait_ref)
      |> Record.Query.lock_for_update()
      |> Repo.one()

    case wait do
      %Record{} = record -> ensure_record(episode, record)
      nil -> {:ok, :not_source_event}
    end
  end

  # A question may leave event-only watches open beside it; production had two
  # (episode 0b0c3590, 2026-09-13). An episode keeps one active subscription, so
  # the watch that already holds it keeps it, and otherwise the oldest gets it.
  defp ensure_locked(%Episode{state: :waiting_for_input, owner_kind: :input} = episode) do
    records =
      episode.id
      |> Record.Query.by_episode_id()
      |> Record.Query.open()
      |> Record.Query.event_only_waits()
      |> Record.Query.ordered_by_oldest()
      |> Record.Query.lock_for_update()
      |> Repo.all()

    case Enum.find(records, &active_subscription?/1) || List.first(records) do
      %Record{} = record -> ensure_record(episode, record)
      nil -> {:ok, :not_source_event}
    end
  end

  defp ensure_locked(%Episode{}), do: {:ok, :not_source_event}

  defp active_subscription?(%Record{id: record_id}) do
    record_id
    |> EventSubscription.Query.by_record_id()
    |> EventSubscription.Query.active()
    |> Repo.exists?()
  end

  defp ensure_record(_episode, %Record{wait_error: error}) when not is_nil(error),
    do: {:ok, :not_source_event}

  defp ensure_record(episode, %Record{payload: %{"event_matcher" => trigger}} = record) do
    if trigger["type"] in ["source_event", "after", "at"] do
      case Repo.one(EventSubscription.Query.by_record_id(record.id)) do
        %EventSubscription{} = subscription ->
          {:ok, subscription}

        nil ->
          insert(episode, record, trigger)
      end
    else
      {:ok, :not_source_event}
    end
  end

  defp ensure_record(_episode, _record), do: {:ok, :not_source_event}

  defp insert(episode, record, trigger) do
    with :ok <- source_bounds(trigger),
         {:ok, deadline} <- subscription_deadline(record.payload, trigger),
         {:ok, poll_after} <- wakeup_at(record, trigger, deadline),
         :ok <- ordered(poll_after, deadline) do
      id = Ecto.UUID.generate()

      %{
        cursor: Map.get(trigger, "cursor"),
        deadline_at: deadline,
        episode_id: episode.id,
        id: id,
        matcher: Map.get(trigger, "match", %{}),
        poll_after: poll_after,
        record_id: record.id,
        ref: "event-subscription:#{id}",
        revision: 1,
        source_kind: trigger["source_kind"],
        status: :active
      }
      |> EventSubscription.Changeset.insert()
      |> Repo.insert()
      |> case do
        {:ok, subscription} ->
          broadcast_follow_up_updated(subscription.id, subscription.episode_id)
          {:ok, subscription}

        {:error, changeset} ->
          {:error, {:event_subscription_persistence_failed, changeset.errors}}
      end
    end
  end

  defp source_bounds(trigger) do
    case RecordPayload.source_wait_bounds(trigger) do
      :ok -> :ok
      {:error, field} -> {:error, {:invalid_event_subscription, field}}
    end
  end

  defp subscription_deadline(%{"deadline_at" => nil} = payload, %{"type" => "source_event"}) do
    case RecordPayload.prepare("event_wait", payload, "subscription:validation") do
      {:ok, _prepared} -> {:ok, nil}
      _invalid -> {:error, {:invalid_event_subscription, :deadline}}
    end
  end

  defp subscription_deadline(payload, _trigger), do: datetime(payload["deadline_at"], :deadline)

  defp wakeup_at(_record, %{"type" => "source_event"} = trigger, deadline),
    do: poll_after(trigger["poll_after"], deadline)

  defp wakeup_at(record, trigger, deadline) do
    with {:ok, due_at} <- EventWaitTiming.due_at(trigger, record.inserted_at),
         :lt <- DateTime.compare(due_at, deadline) do
      {:ok, due_at}
    else
      _invalid -> {:error, {:invalid_event_subscription, :timer_deadline}}
    end
  end

  defp poll_after(nil, deadline), do: {:ok, deadline}
  defp poll_after(value, _deadline), do: datetime(value, :poll_after)

  defp datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_event_subscription, field}}
    end
  end

  defp datetime(_value, field), do: {:error, {:invalid_event_subscription, field}}

  defp ordered(nil, nil), do: :ok

  defp ordered(poll_after, deadline) do
    if DateTime.compare(poll_after, deadline) in [:lt, :eq],
      do: :ok,
      else: {:error, {:invalid_event_subscription, :poll_after}}
  end

  defp resolution(:deadline, wait_ref),
    do: {:timed_out, %{"event_wait_ref" => wait_ref, "kind" => "deadline"}}

  defp resolution(:cancelled, wait_ref),
    do: {:cancelled, %{"event_wait_ref" => wait_ref, "kind" => "cancelled"}}

  defp resolution(kind, wait_ref),
    do: {:resolved, %{"event_wait_ref" => wait_ref, "kind" => Atom.to_string(kind)}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to follow-up changes: `{:follow_up_updated,
  subscription_id}` once Ryker starts waiting for an event or a time, or a
  wait is resolved or cancelled, and that change has committed.
  """
  def subscribe_follow_ups, do: Ryker.PubSub.subscribe(follow_ups_topic())

  def unsubscribe_follow_ups, do: Ryker.PubSub.unsubscribe(follow_ups_topic())

  defp follow_ups_topic, do: "follow_ups"

  defp broadcast_follow_up_updated(subscription_id, episode_id) do
    Ryker.Episodes.broadcast_episode_updated(episode_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(follow_ups_topic(), {:follow_up_updated, subscription_id})
    end)
  end
end

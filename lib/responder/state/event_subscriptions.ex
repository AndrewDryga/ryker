defmodule Responder.State.EventSubscriptions do
  @moduledoc """
  Durable custody for one active event or timer wait per episode.

  Webhooks remain the low-latency path through generic ingress. The stored
  poll cursor and fallback time ensure a lost webhook still wakes the exact
  episode for verification before its hard deadline. Timers share that indexed
  wakeup time, anchored to the original record rather than each reconciliation.
  """

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Repo

  alias Responder.State.{
    EventSubscription,
    EventSubscriptionChangeset,
    EventWaitTiming,
    Record,
    RecordPayload
  }

  @reconcile_limit 100

  @spec ensure_in_transaction(Episode.t()) ::
          {:ok, :not_source_event | EventSubscription.t()} | {:error, term()}
  def ensure_in_transaction(%Episode{} = episode) do
    if Repo.in_transaction?() do
      ensure_locked(episode)
    else
      {:error, :event_subscription_transaction_required}
    end
  end

  @spec reconcile() :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile do
    Repo.transaction(&reconcile_in_transaction/0)
    |> transaction_result()
  end

  defp reconcile_in_transaction do
    cancelled = cancel_stale_in_transaction()

    episodes =
      Repo.all(
        from(episode in Episode,
          join: record in Record,
          on: record.episode_id == episode.id and record.ref == episode.owner_ref,
          left_join: subscription in EventSubscription,
          on: subscription.record_id == record.id,
          where: episode.state == :waiting_for_event and episode.owner_kind == :event,
          where: record.kind == "event_wait" and record.status == :open,
          where: is_nil(record.wait_error),
          where: is_nil(subscription.id),
          where:
            fragment("?::jsonb->'event_matcher'->>'type'", record.payload) in [
              "after",
              "at",
              "source_event"
            ],
          order_by: [asc: episode.owner_deadline_at, asc: episode.id],
          limit: @reconcile_limit,
          select: %{episode: episode, record_id: record.id}
        )
      )

    Enum.reduce(episodes, cancelled, fn %{episode: episode, record_id: record_id}, count ->
      case ensure_locked(episode) do
        {:ok, :not_source_event} ->
          count

        {:ok, %EventSubscription{}} ->
          count + 1

        {:error, {:invalid_event_subscription, field}}
        when field in [:deadline, :poll_after, :timer_deadline, :source_kind, :cursor] ->
          Repo.update_all(
            from(record in Record, where: record.id == ^record_id and record.status == :open),
            set: [wait_error: Atom.to_string(field), updated_at: database_now!()]
          )

          count

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp cancel_stale_in_transaction do
    stale =
      Repo.all(
        from(subscription in EventSubscription,
          join: episode in Episode,
          on: episode.id == subscription.episode_id,
          join: record in Record,
          on: record.id == subscription.record_id,
          where:
            subscription.status == :active and
              (episode.state != :waiting_for_event or episode.owner_kind != :event or
                 fragment("? IS DISTINCT FROM ?", episode.owner_ref, record.ref) or
                 record.status != :open),
          order_by: [asc: subscription.id],
          limit: @reconcile_limit,
          select: %{record_id: record.id, ref: record.ref, subscription_id: subscription.id}
        )
      )

    now = database_now!()

    Enum.each(stale, fn item ->
      Repo.update_all(
        from(subscription in EventSubscription,
          where: subscription.id == ^item.subscription_id and subscription.status == :active
        ),
        set: [
          last_observation: %{"event_wait_ref" => item.ref, "kind" => "cancelled"},
          last_observed_at: now,
          resolution_kind: :cancelled,
          status: :cancelled,
          updated_at: now
        ],
        inc: [revision: 1]
      )

      Repo.update_all(
        from(record in Record, where: record.id == ^item.record_id and record.status == :open),
        set: [status: :dismissed, updated_at: now]
      )
    end)

    length(stale)
  end

  @doc false
  @spec resolve_wait_in_transaction(String.t(), atom()) :: :ok | {:error, term()}
  def resolve_wait_in_transaction(wait_ref, resolution_kind)
      when is_binary(wait_ref) and
             resolution_kind in [:input, :poll_fallback, :timer, :deadline, :cancelled] do
    if Repo.in_transaction?() do
      now = database_now!()
      {status, observation} = resolution(resolution_kind, wait_ref)

      query =
        from(subscription in EventSubscription,
          join: record in Record,
          on: record.id == subscription.record_id,
          where: record.ref == ^wait_ref and subscription.status == :active,
          update: [
            set: [
              status: ^status,
              resolution_kind: ^resolution_kind,
              last_observation: ^observation,
              last_observed_at: ^now,
              updated_at: ^now
            ],
            inc: [revision: 1]
          ]
        )

      _updated = Repo.update_all(query, [])
      :ok
    else
      {:error, :event_subscription_transaction_required}
    end
  end

  def resolve_wait_in_transaction(_wait_ref, _resolution_kind),
    do: {:error, :event_subscription_not_found}

  @spec due(DateTime.t()) :: nil | map()
  def due(%DateTime{} = now) do
    Repo.one(
      from(subscription in EventSubscription,
        join: episode in Episode,
        on: episode.id == subscription.episode_id,
        join: record in Record,
        on: record.id == subscription.record_id,
        where:
          subscription.status == :active and subscription.poll_after <= ^now and
            subscription.deadline_at > ^now,
        where: episode.state == :waiting_for_event and episode.owner_kind == :event,
        where: episode.owner_ref == record.ref and record.episode_id == episode.id,
        where: record.status == :open and is_nil(record.wait_error),
        where: subscription.deadline_at == episode.owner_deadline_at,
        where:
          fragment(
            "CASE WHEN pg_input_is_valid(?::jsonb->>'deadline_at', 'timestamptz') THEN (?::jsonb->>'deadline_at')::timestamptz = ? ELSE false END",
            record.payload,
            record.payload,
            episode.owner_deadline_at
          ),
        order_by: [asc: subscription.poll_after, asc: subscription.id],
        limit: 1,
        select: %{
          episode_id: episode.id,
          record_id: record.id,
          subscription_id: subscription.id
        }
      )
    )
  end

  defp ensure_locked(
         %Episode{owner_kind: :event, owner_ref: wait_ref, state: :waiting_for_event} = episode
       ) do
    case Repo.one(
           from(record in Record,
             where:
               record.episode_id == ^episode.id and record.ref == ^wait_ref and
                 record.kind == "event_wait" and record.status == :open,
             lock: "FOR UPDATE"
           )
         ) do
      %Record{} = record -> ensure_record(episode, record)
      nil -> {:ok, :not_source_event}
    end
  end

  defp ensure_locked(%Episode{}), do: {:ok, :not_source_event}

  defp ensure_record(_episode, %Record{wait_error: error}) when not is_nil(error),
    do: {:ok, :not_source_event}

  defp ensure_record(episode, %Record{payload: %{"event_matcher" => trigger}} = record) do
    if trigger["type"] in ["source_event", "after", "at"] do
      case Repo.get_by(EventSubscription, record_id: record.id) do
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
         {:ok, deadline} <- datetime(record.payload["deadline_at"], :deadline),
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
      |> EventSubscriptionChangeset.insert()
      |> Repo.insert()
      |> case do
        {:ok, subscription} ->
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

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end

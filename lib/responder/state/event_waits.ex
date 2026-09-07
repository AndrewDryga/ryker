defmodule Responder.State.EventWaits do
  @moduledoc """
  Resumes one due durable event wait from PostgreSQL time.

  The wakeup is a host-authored generic input in the same episode. It carries
  the stored matcher and verification request as evidence; it grants no
  external authority and starts exactly one deterministic continuation turn.
  """

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}
  alias Responder.Ingress.Input
  alias Responder.Repo
  alias Responder.State.{EventSubscription, EventSubscriptions, Record, RecordChangeset}

  @spec resume_due() :: {:ok, :idle | map()} | {:error, term()}
  def resume_due do
    with {:ok, _reconciled} <- EventSubscriptions.reconcile(),
         {:ok, now} <- database_now() do
      case EventSubscriptions.due(now) || due_wait(now) do
        nil ->
          {:ok, :idle}

        %{episode_id: episode_id, record_id: record_id} ->
          resume_at(record_id, episode_id, now)
      end
    end
  end

  defp due_wait(now) do
    Repo.one(
      from(episode in Episode,
        join: record in Record,
        on: record.episode_id == episode.id and record.ref == episode.owner_ref,
        left_join: subscription in EventSubscription,
        on: subscription.record_id == record.id,
        where: episode.state == :waiting_for_event and episode.owner_kind == :event,
        where: episode.owner_deadline_at <= ^now,
        where: record.kind == "event_wait" and record.status == :open,
        where:
          fragment(
            "CASE WHEN pg_input_is_valid(?::jsonb->>'deadline_at', 'timestamptz') THEN (?::jsonb->>'deadline_at')::timestamptz = ? ELSE false END",
            record.payload,
            record.payload,
            episode.owner_deadline_at
          ),
        where:
          is_nil(subscription.id) or
            (subscription.status == :active and subscription.episode_id == episode.id and
               subscription.deadline_at == episode.owner_deadline_at),
        order_by: [asc: episode.owner_deadline_at, asc: episode.id],
        limit: 1,
        select: %{episode_id: episode.id, record_id: record.id}
      )
    )
  end

  @doc false
  @spec resume_at(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, :idle | map()} | {:error, term()}
  def resume_at(record_id, episode_id, %DateTime{} = now)
      when is_binary(record_id) and is_binary(episode_id) do
    Repo.transaction(fn ->
      with %Episode{} = initial <- Repo.get(Episode, episode_id),
           {:ok, snapshot} <- Episodes.lock_current_in_transaction(initial.key),
           %Record{} = record <-
             Repo.one(from(value in Record, where: value.id == ^record_id, lock: "FOR UPDATE")),
           {:ok, resolution_kind, subscription} <- resolution(snapshot, record, now) do
        resume_locked(snapshot, record, now, resolution_kind, subscription)
      else
        nil -> Repo.rollback(:event_wait_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  defp resolution(_episode, record, now) do
    subscription =
      Repo.one(
        from(value in EventSubscription,
          where: value.record_id == ^record.id,
          lock: "FOR UPDATE"
        )
      )

    case subscription do
      %EventSubscription{status: :active, deadline_at: deadline} ->
        kind =
          cond do
            DateTime.compare(deadline, now) in [:lt, :eq] -> :deadline
            record.payload["event_matcher"]["type"] == "source_event" -> :poll_fallback
            true -> :timer
          end

        {:ok, kind, subscription}

      nil ->
        {:ok, :deadline, nil}

      _inactive ->
        {:error, :event_wait_already_resumed}
    end
  end

  defp resume_locked(snapshot, record, now, resolution_kind, subscription) do
    with :ok <- due_snapshot(snapshot, record, now, resolution_kind, subscription),
         {:ok, input} <- wakeup_input(snapshot, record, now, resolution_kind),
         admit <- admit_command(snapshot, input, record),
         resume <- resume_command(snapshot, admit, record, now),
         {:ok, [_admitted, resumed]} <-
           Episodes.apply_batch_in_transaction([admit, resume]),
         %Record{status: :open} = locked_record <-
           Repo.one(from(value in Record, where: value.id == ^record.id, lock: "FOR UPDATE")),
         {:ok, record} <- locked_record |> RecordChangeset.answer() |> Repo.update(),
         :ok <- EventSubscriptions.resolve_wait_in_transaction(record.ref, resolution_kind) do
      %{episode: resumed.episode, record: record}
    else
      nil -> Repo.rollback(:event_wait_not_found)
      {:error, {:stale_wait, _details}} -> Repo.rollback(:event_wait_already_resumed)
      {:error, reason} -> Repo.rollback(reason)
      %Record{} -> Repo.rollback(:event_wait_already_resumed)
    end
  end

  defp due_snapshot(
         %Episode{
           id: episode_id,
           owner_deadline_at: %DateTime{} = deadline,
           owner_kind: :event,
           owner_ref: wait_ref,
           state: :waiting_for_event
         },
         %Record{
           episode_id: episode_id,
           kind: "event_wait",
           ref: wait_ref,
           status: :open
         } = record,
         now,
         :deadline,
         nil
       ) do
    cond do
      not saved_deadline?(record, deadline) -> {:error, :event_wait_already_resumed}
      DateTime.compare(deadline, now) in [:lt, :eq] -> :ok
      true -> {:error, :event_wait_not_due}
    end
  end

  defp due_snapshot(
         %Episode{
           id: episode_id,
           owner_deadline_at: deadline,
           owner_kind: :event,
           owner_ref: wait_ref,
           state: :waiting_for_event
         },
         %Record{
           episode_id: episode_id,
           id: record_id,
           kind: "event_wait",
           ref: wait_ref,
           status: :open
         } = record,
         now,
         kind,
         %EventSubscription{
           episode_id: episode_id,
           record_id: record_id,
           status: :active,
           poll_after: poll_after,
           deadline_at: deadline
         }
       )
       when kind in [:poll_fallback, :timer, :deadline] do
    due? =
      if kind == :deadline,
        do: DateTime.compare(deadline, now) in [:lt, :eq],
        else:
          DateTime.compare(poll_after, now) in [:lt, :eq] and
            DateTime.compare(deadline, now) == :gt

    cond do
      not saved_deadline?(record, deadline) -> {:error, :event_wait_already_resumed}
      kind != :deadline and not is_nil(record.wait_error) -> {:error, :event_wait_not_due}
      due? -> :ok
      true -> {:error, :event_wait_not_due}
    end
  end

  defp due_snapshot(_episode, _record, _now, _kind, _subscription_id),
    do: {:error, :event_wait_already_resumed}

  defp saved_deadline?(%Record{payload: %{"deadline_at" => value}}, deadline)
       when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, saved, 0} -> DateTime.compare(saved, deadline) == :eq
      _invalid -> false
    end
  end

  defp saved_deadline?(_record, _deadline), do: false

  defp wakeup_input(episode, record, now, resolution_kind) do
    trigger = record.payload["event_matcher"]

    Input.new(%{
      actor: %{kind: :system, ref: "event-wait-#{resolution_kind}"},
      content: %{
        "cursor" => trigger["cursor"],
        "deadline_at" => record.payload["deadline_at"],
        "event_matcher" => trigger,
        "event_wait_ref" => record.ref,
        "kind" => wakeup_kind(resolution_kind),
        "verification" => record.payload["verification"]
      },
      destination: %{
        conversation_ref: episode.destination_conversation_ref,
        thread_ref: episode.destination_thread_ref,
        transport: episode.destination_transport
      },
      event_kind: :event,
      event_ref: "#{resolution_kind}:#{record.ref}",
      native_input_id: "state-event-wait:#{record.ref}",
      occurred_at: now,
      occurred_at_source: :ingress,
      revision: 1,
      source: %{kind: "system", ref: "responder"},
      source_capabilities: %{},
      source_item_ref: nil
    })
  end

  defp wakeup_kind(:poll_fallback), do: "poll_fallback_due"
  defp wakeup_kind(:timer), do: "timer_due"
  defp wakeup_kind(:deadline), do: "deadline_elapsed"

  defp admit_command(episode, input, record) do
    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: input.destination,
      episode_id: episode.id,
      episode_key: episode.key,
      linked_episode_id: episode.linked_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref(record.ref)
    }
  end

  defp resume_command(episode, admit, record, now) do
    %Command.ResumeWait{
      episode_key: episode.key,
      expected_wait: %{kind: :event, ref: record.ref},
      occurred_at: now,
      resolution_ref: Command.dedupe_key(admit),
      turn_ref: admit.turn_ref
    }
  end

  defp turn_ref(wait_ref) do
    digest = :crypto.hash(:sha256, wait_ref) |> Base.encode16(case: :lower)
    "turn:event-wait:#{binary_part(digest, 0, 32)}"
  end

  defp database_now do
    case Repo.query("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, now}
      {:error, reason} -> {:error, {:event_wait_clock_failed, reason}}
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, :event_wait_already_resumed}), do: {:ok, :idle}
  defp transaction_result({:error, reason}), do: {:error, reason}
end

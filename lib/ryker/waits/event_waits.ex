defmodule Ryker.Waits.EventWaits do
  @moduledoc """
  Resumes one due durable event wait from PostgreSQL time.

  The wakeup is a host-authored generic input in the same episode. It carries
  the stored matcher and verification request as evidence; it grants no
  external authority and starts exactly one deterministic continuation turn.
  """
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Waits.EventSubscription
  alias Ryker.Waits.EventSubscriptions

  @spec resume_due() :: {:ok, :idle | map()} | {:error, term()}
  def resume_due do
    with {:ok, _reconciled} <- EventSubscriptions.reconcile(),
         {:ok, now} <- database_now() do
      case fetch_due(now) do
        {:error, :not_found} ->
          {:ok, :idle}

        {:ok, %{episode_id: episode_id, record_id: record_id}} ->
          record_id |> resume_at(episode_id, now) |> passed_over(record_id)
      end
    end
  end

  # The next poll takes the waits due after this one first.
  defp passed_over({:error, reason}, record_id) do
    :ok = EventSubscriptions.fail(record_id, "resume_failed")
    {:error, {:event_wait_resume_failed, record_id, reason}}
  end

  defp passed_over(result, _record_id), do: result

  @doc """
  The earliest moment after `since` at which a wait falls due by the clock
  alone: a timer or a source wait's polling fallback, or a hard deadline.
  Nil when no wait is timed. A wait that starts, ends or hears its event is
  a change to its request, which is announced.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since) do
    subscriptions = since |> EventSubscription.Query.select_next_due_after() |> Repo.one()
    deadlines = since |> Episodes.Episode.Query.next_event_deadline_after() |> Repo.peek()

    UTCDateTime.earliest([deadlines | subscriptions])
  end

  # A subscription due on its own first, then a wait past its deadline.
  defp fetch_due(now) do
    with {:error, :not_found} <- EventSubscriptions.fetch_due(now) do
      now
      |> EventSubscription.Query.deadline_due(EventSubscriptions.failure_retried_before(now))
      |> Repo.fetch()
    end
  end

  @doc false
  @spec resume_at(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, :idle | map()} | {:error, term()}
  def resume_at(record_id, episode_id, %DateTime{} = now)
      when is_binary(record_id) and is_binary(episode_id) do
    Repo.transaction(fn ->
      # Admission and the fix loop lock the conversation before the episode.
      # Resuming locked them the other way round, so a resume and a message in
      # the same conversation could each wait for the other (2026-10-04
      # review).
      with {:ok, initial} <- fetch_wait_row(Episodes.Episode.Query.by_id(episode_id)),
           :ok <- Episodes.ConversationLock.lock(Repo, destination(initial)),
           {:ok, snapshot} <- Episodes.fetch_and_lock_current_in_transaction(initial.key),
           {:ok, record} <- fetch_and_lock_record(record_id),
           {:ok, resolution_kind, subscription} <- resolution(record, now) do
        resume_locked(snapshot, record, now, resolution_kind, subscription)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  defp fetch_and_lock_record(id) do
    id
    |> Records.Record.Query.by_id()
    |> Records.Record.Query.lock_for_update()
    |> fetch_wait_row()
  end

  defp fetch_wait_row(query) do
    with {:error, :not_found} <- Repo.fetch(query), do: {:error, :event_wait_not_found}
  end

  defp destination(episode),
    do: %{
      conversation_ref: episode.destination_conversation_ref,
      transport: episode.destination_transport
    }

  defp resolution(record, now) do
    subscription =
      record.id
      |> EventSubscription.Query.by_record_id()
      |> EventSubscription.Query.lock_for_update()
      |> Repo.fetch()

    case subscription do
      {:ok, %EventSubscription{status: :active, deadline_at: nil, poll_after: nil}} ->
        {:error, :event_wait_not_due}

      {:ok, %EventSubscription{status: :active, deadline_at: deadline} = active} ->
        kind =
          cond do
            DateTime.compare(deadline, now) in [:lt, :eq] -> :deadline
            record.payload["event_matcher"]["type"] == "source_event" -> :poll_fallback
            true -> :timer
          end

        {:ok, kind, active}

      {:error, :not_found} ->
        {:ok, :deadline, nil}

      {:ok, _inactive} ->
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
         {:ok, %Records.Record{status: :open} = locked_record} <- fetch_and_lock_record(record.id),
         {:ok, record} <- Repo.update(Records.Record.Changeset.answer_wait(locked_record)),
         :ok <- EventSubscriptions.resolve_wait_in_transaction(record.ref, resolution_kind) do
      Records.broadcast_record_updated(record)
      %{episode: resumed.episode, record: record}
    else
      {:ok, %Records.Record{}} -> Repo.rollback(:event_wait_already_resumed)
      {:error, {:stale_wait, _details}} -> Repo.rollback(:event_wait_already_resumed)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp due_snapshot(
         %Episodes.Episode{
           id: episode_id,
           owner_deadline_at: %DateTime{} = deadline,
           owner_kind: :event,
           owner_ref: wait_ref,
           state: :waiting_for_event
         },
         %Records.Record{
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
         %Episodes.Episode{
           id: episode_id,
           owner_deadline_at: deadline,
           owner_kind: :event,
           owner_ref: wait_ref,
           state: :waiting_for_event
         },
         %Records.Record{
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
      not saved_deadline?(record, deadline) ->
        {:error, :event_wait_already_resumed}

      kind != :deadline and record.wait_error not in [nil, "resume_failed"] ->
        {:error, :event_wait_not_due}

      due? ->
        :ok

      true ->
        {:error, :event_wait_not_due}
    end
  end

  defp due_snapshot(_episode, _record, _now, _kind, _subscription_id),
    do: {:error, :event_wait_already_resumed}

  defp saved_deadline?(%Records.Record{payload: %{"deadline_at" => value}}, deadline)
       when is_binary(value) do
    case UTCDateTime.parse(value) do
      {:ok, saved} -> DateTime.compare(saved, deadline) == :eq
      _invalid -> false
    end
  end

  defp saved_deadline?(_record, _deadline), do: false

  defp wakeup_input(episode, record, now, resolution_kind) do
    trigger = record.payload["event_matcher"]

    Ingress.Input.new(%{
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
      source: %{kind: "system", ref: "ryker"},
      source_capabilities: %{},
      source_item_ref: nil
    })
  end

  defp wakeup_kind(:poll_fallback), do: "poll_fallback_due"
  defp wakeup_kind(:timer), do: "timer_due"
  defp wakeup_kind(:deadline), do: "deadline_elapsed"

  defp admit_command(episode, input, record) do
    %Episodes.Command.AdmitInput{
      actor_ref: Ingress.Input.actor_ref(input),
      destination: input.destination,
      episode_id: episode.id,
      episode_key: episode.key,
      linked_episode_id: episode.linked_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Ingress.Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref(record.ref)
    }
  end

  defp resume_command(episode, admit, record, now) do
    %Episodes.Command.ResumeWait{
      episode_key: episode.key,
      expected_wait: %{kind: :event, ref: record.ref},
      occurred_at: now,
      resolution_ref: Episodes.Command.dedupe_key(admit),
      turn_ref: admit.turn_ref
    }
  end

  defp turn_ref(wait_ref) do
    digest = Crypto.sha256_hex(wait_ref)
    "turn:event-wait:#{binary_part(digest, 0, 32)}"
  end

  defp database_now do
    case Repo.now() do
      {:ok, now} -> {:ok, now}
      {:error, reason} -> {:error, {:event_wait_clock_failed, reason}}
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, :event_wait_already_resumed}), do: {:ok, :idle}
  defp transaction_result({:error, reason}), do: {:error, reason}
end

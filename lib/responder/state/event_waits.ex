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
  alias Responder.State.{EventSubscriptions, Record, RecordChangeset}

  @spec resume_due() :: {:ok, :idle | map()} | {:error, term()}
  def resume_due do
    with {:ok, _reconciled} <- EventSubscriptions.reconcile(),
         {:ok, now} <- database_now() do
      case EventSubscriptions.due(now) || due_wait(now) do
        nil ->
          {:ok, :idle}

        %{episode_id: episode_id, record_id: record_id, subscription_id: subscription_id} ->
          resume(record_id, episode_id, now, :poll_fallback, subscription_id)

        %{episode_id: episode_id, record_id: record_id} ->
          resume(record_id, episode_id, now, :deadline, nil)
      end
    end
  end

  defp due_wait(now) do
    Repo.one(
      from(episode in Episode,
        join: record in Record,
        on: record.episode_id == episode.id and record.ref == episode.owner_ref,
        where:
          episode.state == :waiting_for_event and episode.owner_kind == :event and
            episode.owner_deadline_at <= ^now and record.kind == "event_wait" and
            record.status == :open,
        order_by: [asc: episode.owner_deadline_at, asc: episode.id],
        limit: 1,
        select: %{episode_id: episode.id, record_id: record.id}
      )
    )
  end

  defp resume(record_id, episode_id, now, resolution_kind, subscription_id) do
    Repo.transaction(fn ->
      resume_locked(record_id, episode_id, now, resolution_kind, subscription_id)
    end)
    |> transaction_result()
  end

  defp resume_locked(record_id, episode_id, now, resolution_kind, subscription_id) do
    with %Episode{} = snapshot <- Repo.get(Episode, episode_id),
         %Record{} = record <- Repo.get(Record, record_id),
         :ok <- due_snapshot(snapshot, record, now, resolution_kind, subscription_id),
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
         },
         now,
         :deadline,
         nil
       ) do
    if DateTime.compare(deadline, now) in [:lt, :eq],
      do: :ok,
      else: {:error, :event_wait_not_due}
  end

  defp due_snapshot(
         %Episode{
           id: episode_id,
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
         },
         now,
         :poll_fallback,
         subscription_id
       ) do
    case Repo.get(Responder.State.EventSubscription, subscription_id) do
      %Responder.State.EventSubscription{
        episode_id: ^episode_id,
        record_id: ^record_id,
        status: :active,
        poll_after: poll_after,
        deadline_at: deadline
      } ->
        if DateTime.compare(poll_after, now) in [:lt, :eq] and
             DateTime.compare(deadline, now) == :gt,
           do: :ok,
           else: {:error, :event_wait_not_due}

      _stale ->
        {:error, :event_wait_already_resumed}
    end
  end

  defp due_snapshot(_episode, _record, _now, _kind, _subscription_id),
    do: {:error, :event_wait_already_resumed}

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

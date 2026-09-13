defmodule Ryker.Work.Custody.Delivery do
  @moduledoc """
  Delivery of an accepted result and the destination it answers.

  An accepted reply becomes one durable delivery intent that a worker confirms
  with the exact external receipt. A delivery that keeps failing is blocked and
  rearmed by an operator without changing its result or target, and an inactive
  destination pauses the episode until the same opaque pause reference resumes it.
  """

  import Ecto.Query
  import Ryker.Work.Custody.Locks

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, Origin}
  alias Ryker.Repo
  alias Ryker.State.EventSubscriptions
  alias Ryker.Work.Cancellation, as: WorkCancellation
  alias Ryker.Work.Custody.{Cancellation, Sessions}
  alias Ryker.Work.{DeliveryReceipt, Turn, TurnChangeset}

  @doc false
  @spec confirm_delivery(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, %{episode: Episode.t(), turn: Turn.t()}} | {:error, term()}
  def confirm_delivery(episode_id, episode_key, turn_ref, lease_ref, external_receipt) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, external_receipt} <- DeliveryReceipt.prepare(external_receipt) do
      receipt_fingerprint = DeliveryReceipt.fingerprint(external_receipt)

      Repo.transaction(fn ->
        confirm_delivery_locked(
          episode_id,
          episode_key,
          turn_ref,
          lease_ref,
          external_receipt,
          receipt_fingerprint
        )
      end)
    end
  end

  @doc false
  @spec pause_destination(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def pause_destination(episode_id, episode_key, pause_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(pause_ref, :pause_ref),
         {:ok, intent} <- WorkCancellation.new_block(destination_pause_reason(pause_ref)) do
      fingerprint = WorkCancellation.fingerprint(intent)

      Repo.transaction(fn ->
        pause_destination_locked(episode_id, episode_key, intent, fingerprint)
      end)
    end
  end

  @doc false
  @spec resume_destination(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_destination(episode_id, episode_key, pause_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(pause_ref, :pause_ref) do
      reason = destination_pause_reason(pause_ref)

      Repo.transaction(fn -> resume_destination_locked(episode_id, episode_key, reason) end)
    end
  end

  defp pause_destination_locked(episode_id, episode_key, intent, fingerprint) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id) do
      pause_destination_owner(episode, intent, fingerprint)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_destination_locked(episode_id, episode_key, reason) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id) do
      resume_destination_owner(episode, reason)
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  @doc false
  @spec block_delivery(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def block_delivery(episode_id, turn_ref, lease_ref, error_code, error_detail) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        block_delivery_locked(episode_id, turn_ref, lease_ref, error_code, error_detail)
      end)
    end
  end

  @doc false
  @spec retry_delivery(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  def retry_delivery(episode_id, turn_ref, delivery_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(delivery_ref, :delivery_ref) do
      Repo.transaction(fn -> retry_delivery_locked(episode_id, turn_ref, delivery_ref) end)
    end
  end

  defp confirm_delivery_locked(
         episode_id,
         episode_key,
         turn_ref,
         lease_ref,
         external_receipt,
         receipt_fingerprint
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id),
         {:ok, _session, turn} <- lock_turn_after_episode(episode_id, turn_ref),
         {:continue, command, delivered_at} <-
           prepare_delivery_confirmation(
             episode,
             turn,
             lease_ref,
             external_receipt,
             receipt_fingerprint
           ),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, turn} <-
           turn
           |> TurnChangeset.confirm_delivery(
             external_receipt,
             receipt_fingerprint,
             delivered_at
           )
           |> Repo.update()
           |> persistence_result(:work_delivery),
         {:ok, _subscription} <- EventSubscriptions.ensure_in_transaction(transition.episode) do
      %{episode: transition.episode, turn: turn}
    else
      {:delivered, turn} -> %{episode: episode_for_result!(episode_key), turn: turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pause_destination_owner(
         %Episode{state: :working, owner_kind: :turn} = episode,
         intent,
         fingerprint
       ) do
    case turn_identity(episode.id, episode.owner_ref) do
      nil ->
        block_unsubmitted_destination_turn(episode, intent, fingerprint)

      %Turn{} = identity ->
        Cancellation.request_cancellation_for_identity(
          episode,
          identity,
          episode.owner_ref,
          intent,
          fingerprint,
          nil
        )
    end
  end

  defp pause_destination_owner(
         %Episode{state: :working, owner_kind: :delivery} = episode,
         intent,
         _fingerprint
       ) do
    pause_destination_delivery(episode, intent)
  end

  defp pause_destination_owner(%Episode{} = episode, _intent, _fingerprint),
    do: %{episode: episode, status: :settled, turn: nil}

  defp block_unsubmitted_destination_turn(episode, intent, fingerprint) do
    with {:ok, session} <- Sessions.current_session(episode),
         {:ok, turn} <- Sessions.insert_turn(episode, session),
         {:ok, turn} <-
           turn
           |> TurnChangeset.prepare_cancellation(intent, fingerprint, nil)
           |> Repo.update()
           |> persistence_result(:work_destination_pause),
         {:ok, turn} <-
           turn
           |> TurnChangeset.block(%{
             last_error_code: "destination_paused",
             last_error_detail: intent["reason"],
             lease_expires_at: nil,
             lease_owner: nil,
             lease_ref: nil,
             next_attempt_at: nil,
             status: :blocked
           })
           |> Repo.update()
           |> persistence_result(:work_destination_pause) do
      %{episode: episode, status: :settled, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pause_destination_delivery(episode, intent) do
    now = Repo.now!()

    case lock_delivery_turn(episode.id, episode.owner_ref) do
      {:ok, %Turn{status: :delivery_pending} = turn} ->
        pause_pending_delivery(episode, turn, intent, now)

      {:ok, %Turn{status: :blocked} = turn} ->
        pause_blocked_delivery(episode, turn, intent)

      {:ok, %Turn{}} ->
        Repo.rollback(:work_delivery_not_pending)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp pause_pending_delivery(episode, turn, intent, now) do
    if current_lease?(turn, turn.lease_ref, now),
      do: %{episode: episode, status: :pending, turn: turn},
      else: block_destination_delivery(episode, turn, intent)
  end

  defp pause_blocked_delivery(episode, turn, intent) do
    cond do
      turn.last_error_code == "destination_paused" and
          turn.last_error_detail == intent["reason"] ->
        %{episode: episode, status: :settled, turn: turn}

      turn.last_error_code == "slack_incident_room_inactive" ->
        block_destination_delivery(episode, turn, intent)

      true ->
        %{episode: episode, status: :settled, turn: turn}
    end
  end

  defp block_destination_delivery(episode, turn, intent) do
    result =
      turn
      |> TurnChangeset.block(%{
        last_error_code: "destination_paused",
        last_error_detail: intent["reason"],
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :blocked
      })
      |> Repo.update()
      |> persistence_result(:work_destination_pause)

    case result do
      {:ok, turn} -> %{episode: episode, status: :settled, turn: turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_destination_owner(
         %Episode{state: :working, owner_kind: :turn} = episode,
         reason
       ) do
    case turn_identity(episode.id, episode.owner_ref) do
      %Turn{cancellation_intent: %{"action" => "block", "reason" => ^reason}} = turn ->
        resume_destination_turn(episode, turn)

      _not_this_pause ->
        %{episode: episode, status: :settled, turn: nil}
    end
  end

  defp resume_destination_owner(
         %Episode{state: :working, owner_kind: :delivery} = episode,
         reason
       ) do
    case lock_delivery_turn(episode.id, episode.owner_ref) do
      {:ok,
       %Turn{
         last_error_code: "destination_paused",
         last_error_detail: ^reason,
         status: :blocked
       } = turn} ->
        case turn |> TurnChangeset.retry_delivery() |> Repo.update() do
          {:ok, turn} ->
            %{episode: episode, status: :settled, turn: turn}

          {:error, changeset} ->
            Repo.rollback({:work_destination_resume_persistence_failed, changeset.errors})
        end

      {:ok, %Turn{} = turn} ->
        %{episode: episode, status: :settled, turn: turn}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp resume_destination_owner(%Episode{} = episode, _reason),
    do: %{episode: episode, status: :settled, turn: nil}

  defp resume_destination_turn(
         episode,
         %Turn{
           cancellation_receipt: nil,
           coop_turn_id: nil,
           status: :blocked,
           submission: nil
         } = turn
       ) do
    transfer_local_destination_block(episode, turn)
  end

  defp resume_destination_turn(episode, %Turn{status: status} = turn)
       when status in [:cancel_pending, :blocked] do
    new_turn_ref = "turn:resume-destination:#{turn.id}:v#{episode.semantic_version}"
    transfer_ref = "transfer:resume-destination:#{turn.id}:v#{episode.semantic_version}"

    case WorkCancellation.new_transfer(new_turn_ref, transfer_ref) do
      {:ok, intent} ->
        Cancellation.request_cancellation_for_identity(
          episode,
          turn,
          episode.owner_ref,
          intent,
          WorkCancellation.fingerprint(intent),
          nil
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp resume_destination_turn(episode, turn),
    do: %{episode: episode, status: :settled, turn: turn}

  defp transfer_local_destination_block(episode, turn) do
    new_turn_ref = "turn:resume-destination:#{turn.id}:v#{episode.semantic_version}"
    transfer_ref = "transfer:resume-destination:#{turn.id}:v#{episode.semantic_version}"

    with {:ok, intent} <- WorkCancellation.new_transfer(new_turn_ref, transfer_ref),
         {:ok, [transition]} <-
           Episodes.apply_batch_in_transaction(
             [WorkCancellation.command(intent, episode, Repo.now!())],
             settled_work_turn_id: turn.id
           ),
         {:ok, turn} <-
           turn
           |> TurnChangeset.replace_cancellation_disposition(
             turn.cancellation_intent,
             turn.cancellation_intent_fingerprint,
             "destination_resumed",
             "The destination became active before remote work was submitted.",
             :superseded
           )
           |> Repo.update()
           |> persistence_result(:work_destination_resume) do
      %{episode: transition.episode, status: :settled, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_delivery_turn(episode_id, delivery_ref) do
    case Repo.one(
           from(turn in Turn,
             where: turn.episode_id == ^episode_id and turn.delivery_ref == ^delivery_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_delivery_turn_not_found}
      %Turn{} = turn -> {:ok, turn}
    end
  end

  defp block_delivery_locked(episode_id, turn_ref, lease_ref, error_code, error_detail) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if turn.status == :delivery_pending do
      turn
      |> TurnChangeset.block(%{
        last_error_code: error_code,
        last_error_detail: error_detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :blocked
      })
      |> Repo.update()
      |> unwrap_or_rollback(:work_delivery_block)
    else
      Repo.rollback(:work_delivery_not_pending)
    end
  end

  defp retry_delivery_locked(episode_id, turn_ref, delivery_ref) do
    case turn_identity(episode_id, turn_ref) do
      %Turn{delivery_ref: ^delivery_ref} ->
        retry_delivery_owner_locked(episode_id, turn_ref, delivery_ref)

      %Turn{} ->
        Repo.rollback(:work_delivery_ref_mismatch)

      nil ->
        Repo.rollback(:work_turn_not_found)
    end
  end

  defp retry_delivery_owner_locked(episode_id, turn_ref, delivery_ref) do
    with {:ok, _episode} <- lock_episode_owner(episode_id, :delivery, delivery_ref),
         {:ok, turn} <- lock_turn(episode_id, turn_ref) do
      retry_delivery_turn_locked(turn, delivery_ref)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_delivery_turn_locked(
         %Turn{status: :blocked, delivery_ref: delivery_ref} = turn,
         delivery_ref
       ) do
    turn
    |> TurnChangeset.retry_delivery()
    |> Repo.update()
    |> unwrap_or_rollback(:work_delivery_retry)
  end

  defp retry_delivery_turn_locked(
         %Turn{status: :delivery_pending, delivery_ref: delivery_ref} = turn,
         delivery_ref
       ),
       do: turn

  defp retry_delivery_turn_locked(%Turn{}, _delivery_ref),
    do: Repo.rollback(:work_delivery_not_retryable)

  defp prepare_delivery_confirmation(
         episode,
         turn,
         lease_ref,
         external_receipt,
         receipt_fingerprint
       ) do
    now = Repo.now!()

    with :ok <- exact_delivery_ref(turn, external_receipt),
         :ok <- exact_delivery_destination(episode, turn, external_receipt) do
      prepare_identified_delivery(
        episode,
        turn,
        lease_ref,
        external_receipt,
        receipt_fingerprint,
        now
      )
    end
  end

  defp prepare_identified_delivery(episode, turn, lease_ref, receipt, fingerprint, now) do
    if delivery_already_settled?(turn, receipt, fingerprint) do
      {:delivered, turn}
    else
      validate_pending_delivery(episode, turn, lease_ref, now)
    end
  end

  defp validate_pending_delivery(episode, turn, lease_ref, now) do
    with :ok <- delivery_receipt_unset(turn),
         :ok <- current_delivery_owner(episode, turn),
         :ok <- delivery_pending(turn),
         :ok <- current_turn_lease(turn, lease_ref, now) do
      build_delivery_confirmation(episode, turn, now)
    end
  end

  defp exact_delivery_ref(turn, %{"delivery_ref" => delivery_ref})
       when delivery_ref == turn.delivery_ref,
       do: :ok

  defp exact_delivery_ref(_turn, _receipt), do: {:error, :work_delivery_receipt_mismatch}

  defp exact_delivery_destination(episode, turn, receipt) do
    target = delivery_target(episode, turn)

    if receipt["transport"] == target["transport"] and
         receipt["conversation_ref"] == target["conversation_ref"] and
         receipt["thread_ref"] == target["thread_ref"],
       do: :ok,
       else: {:error, :work_delivery_destination_mismatch}
  end

  @doc false
  @spec delivery_target(Episode.t(), Turn.t()) :: map()
  def delivery_target(%Episode{} = episode, %Turn{delivery_target: %{} = target}) do
    Map.merge(home_target(episode), target)
  end

  def delivery_target(%Episode{} = episode, _turn), do: home_target(episode)

  defp home_target(%Episode{} = episode) do
    %{
      "conversation_ref" => episode.destination_conversation_ref,
      "thread_ref" => episode.destination_thread_ref,
      "transport" => episode.destination_transport
    }
  end

  @doc false
  @spec reply_target(Episode.t(), Turn.t()) :: map() | nil
  def reply_target(%Episode{} = episode, %Turn{} = turn) do
    episode
    |> answering_origin(turn)
    |> case do
      nil ->
        nil

      origin ->
        %{
          "conversation_ref" => origin.conversation_ref,
          "thread_ref" => origin.thread_ref,
          "transport" => origin.transport
        }
    end
  end

  defp answering_origin(%Episode{} = episode, %Turn{selected_input_refs: refs})
       when is_list(refs) and refs != [] do
    newest_origin(episode, refs)
  end

  defp answering_origin(%Episode{} = episode, %Turn{selected_input_refs: nil} = turn),
    do: active_origin(episode, turn)

  defp answering_origin(%Episode{} = episode, %Turn{selected_input_refs: []} = turn),
    do: active_origin(episode, turn)

  defp answering_origin(_episode, _turn), do: nil

  defp active_origin(%Episode{active_input_refs: [_ | _] = refs} = episode, _turn),
    do: newest_origin(episode, refs)

  defp active_origin(_episode, _turn), do: nil

  # An episode may hold evidence from several conversations, so the input a
  # reply answers is the newest by occurrence, not by this episode's own
  # event sequence.
  defp newest_origin(%Episode{} = episode, refs) do
    Repo.one(
      from(origin in Origin,
        where:
          origin.episode_id == ^episode.id and origin.input_ref in ^refs and origin.effective,
        order_by: [desc: origin.occurred_at, desc: origin.sequence],
        limit: 1
      )
    )
  end

  defp delivery_already_settled?(turn, receipt, fingerprint),
    do:
      turn.status == :settled and turn.external_receipt == receipt and
        turn.external_receipt_fingerprint == fingerprint

  defp delivery_receipt_unset(%Turn{external_receipt: nil}), do: :ok
  defp delivery_receipt_unset(_turn), do: {:error, :work_delivery_receipt_conflict}

  defp current_delivery_owner(episode, turn) do
    if episode.state == :working and episode.owner_kind == :delivery and
         episode.owner_ref == turn.delivery_ref,
       do: :ok,
       else: {:error, :work_delivery_owner_lost}
  end

  defp delivery_pending(%Turn{status: :delivery_pending}), do: :ok
  defp delivery_pending(_turn), do: {:error, :work_delivery_not_pending}

  defp build_delivery_confirmation(episode, turn, now) do
    {next_turn_ref, next_wait} = delivery_continuation(episode, turn, now)

    command = %Command.ConfirmDelivery{
      episode_key: episode.key,
      expected_delivery_ref: turn.delivery_ref,
      next_turn_ref: next_turn_ref,
      next_wait: next_wait,
      occurred_at: now
    }

    {:continue, command, now}
  end

  @doc false
  def delivery_continuation(%Episode{queued_input_refs: [_first | _rest]}, turn, _now),
    do: {"turn:after:#{turn.id}", nil}

  def delivery_continuation(_episode, %{continuation: %{"kind" => "complete"}}, _now),
    do: {nil, nil}

  def delivery_continuation(
        _episode,
        %{
          continuation: %{
            "deadline_at" => nil,
            "kind" => "wait",
            "wait_kind" => "event",
            "wait_ref" => ref
          }
        },
        _now
      ),
      do: {nil, %{deadline_at: nil, kind: :event, ref: ref}}

  def delivery_continuation(
        _episode,
        %{
          continuation: %{
            "deadline_at" => nil,
            "kind" => "wait",
            "wait_kind" => "input",
            "wait_ref" => wait_ref
          }
        },
        _now
      ),
      do: {nil, %{deadline_at: nil, kind: :input, ref: wait_ref}}

  def delivery_continuation(
        _episode,
        %{
          continuation: %{
            "deadline_at" => deadline_at,
            "kind" => "wait",
            "wait_kind" => "event",
            "wait_ref" => wait_ref
          }
        } = turn,
        now
      ) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, 0} ->
        if DateTime.compare(deadline, now) == :gt,
          do: {nil, %{deadline_at: deadline, kind: :event, ref: wait_ref}},
          else: {"turn:after:#{turn.id}", nil}

      _elapsed_or_invalid ->
        {"turn:after:#{turn.id}", nil}
    end
  end

  defp destination_pause_reason(pause_ref), do: "destination_paused:#{pause_ref}"
end

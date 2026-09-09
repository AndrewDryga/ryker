defmodule Responder.Episodes.Reducer do
  @moduledoc """
  Pure state machine for episode ownership and continuation.

  It performs no IO and obtains no time or identifiers implicitly, making every
  accepted transition byte-for-byte replayable.
  """

  alias Responder.Episodes.Command

  alias Responder.Episodes.Command.{
    AcceptResult,
    AdmitInput,
    CancelEpisode,
    ConfirmDelivery,
    RecordReaction,
    ResumeWait,
    StartWait,
    TransferOwner
  }

  alias Responder.Episodes.{Episode, Event, Transition}

  # One admitted command may carry the full 64 KiB kernel envelope. Two fit
  # exactly inside Work's 160 KiB context ceiling, preserving the original
  # instruction plus one correction. Later inputs remain ordered in the queue
  # instead of being truncated or making the turn unbuildable.
  @maximum_active_inputs 2

  @type result :: {:ok, Transition.t()} | {:error, term()}

  @spec decide(Episode.t() | nil, Command.t()) :: result()
  def decide(episode, command) do
    command = Command.bind_episode(command, episode)

    with {:ok, command} <- Command.prepare(command) do
      decide_valid(episode, command)
    end
  end

  defp decide_valid(nil, %AdmitInput{} = command) do
    episode = %Episode{
      id: command.episode_id,
      key: command.episode_key,
      execution_mode: command.execution_mode,
      state: :working,
      owner_kind: :turn,
      owner_ref: command.turn_ref,
      destination_transport: command.destination.transport,
      destination_conversation_ref: command.destination.conversation_ref,
      destination_thread_ref: command.destination.thread_ref,
      linked_episode_id: command.linked_episode_id,
      semantic_version: 1,
      next_sequence: 2,
      input_revisions: %{command.native_input_id => command.revision},
      active_input_refs: [Command.dedupe_key(command)],
      queued_input_refs: [],
      queued_input_order_keys: []
    }

    applied(episode, command, 1, :input_admitted)
  end

  defp decide_valid(nil, _command), do: {:error, :episode_does_not_exist}

  defp decide_valid(%Episode{} = episode, command) do
    with :ok <- same_episode(episode, command) do
      decide_existing(episode, command)
    end
  end

  defp decide_existing(%Episode{} = episode, %AdmitInput{} = command) do
    with :ok <- same_episode_id(episode, command.episode_id),
         :ok <- same_linked_episode(episode, command.linked_episode_id),
         :ok <- same_execution_mode(episode, command.execution_mode),
         :ok <- same_destination(episode, command.destination),
         :ok <- accepts_input(episode),
         :ok <- newer_input_revision(episode, command) do
      input_ref = Command.dedupe_key(command)

      input_revisions =
        Map.put(episode.input_revisions, command.native_input_id, command.revision)

      episode =
        if episode.state == :complete do
          %{
            episode
            | state: :working,
              owner_kind: :turn,
              owner_ref: command.turn_ref,
              active_input_refs: [input_ref],
              queued_input_refs: [],
              queued_input_order_keys: [],
              input_revisions: input_revisions,
              semantic_version: episode.semantic_version + 1
          }
        else
          episode
          |> enqueue_input(input_ref, command.occurred_at)
          |> Map.put(:input_revisions, input_revisions)
          |> Map.update!(:semantic_version, &(&1 + 1))
        end

      append(episode, command, :input_admitted)
    end
  end

  defp decide_existing(%Episode{} = episode, %TransferOwner{} = command) do
    actual = %{kind: episode.owner_kind, ref: episode.owner_ref}

    cond do
      actual != command.expected_owner ->
        {:error, {:stale_owner, expected: command.expected_owner, actual: actual}}

      episode.owner_kind == :delivery ->
        {:error, :delivery_must_settle_before_transfer}

      command.new_owner.kind != episode.owner_kind ->
        {:error,
         {:owner_kind_change_requires_transition, episode.owner_kind, command.new_owner.kind}}

      command.new_owner.ref == episode.owner_ref ->
        {:error, :owner_unchanged}

      episode.state != :working ->
        {:error, {:invalid_state, episode.state, :transfer_owner}}

      not required_transfer_input_queued?(episode, command.required_input_ref) ->
        {:error, :required_input_not_queued}

      true ->
        episode =
          episode
          |> Map.put(:owner_ref, command.new_owner.ref)
          |> transfer_inputs(command.required_input_ref)

        append(episode, command, :owner_transferred)
    end
  end

  defp decide_existing(%Episode{} = episode, %StartWait{} = command) do
    with :ok <- current_turn(episode, command.expected_turn_ref),
         :ok <- queue_empty_before_wait(episode),
         :ok <- valid_wait(command) do
      state = if command.kind == :input, do: :waiting_for_input, else: :waiting_for_event
      event_kind = if command.kind == :input, do: :input_wait_started, else: :event_wait_started

      episode = %{
        episode
        | state: state,
          owner_kind: command.kind,
          owner_ref: command.wait_ref,
          owner_deadline_at: command.deadline_at,
          active_input_refs: [],
          semantic_version: episode.semantic_version + 1
      }

      append(episode, command, event_kind)
    end
  end

  defp decide_existing(%Episode{} = episode, %ResumeWait{} = command) do
    expected_state =
      if command.expected_wait.kind == :input,
        do: :waiting_for_input,
        else: :waiting_for_event

    cond do
      episode.state != expected_state or episode.owner_kind != command.expected_wait.kind or
          episode.owner_ref != command.expected_wait.ref ->
        {:error,
         {:stale_wait,
          expected: command.expected_wait,
          actual: %{kind: episode.owner_kind, ref: episode.owner_ref}}}

      episode.queued_input_refs == [] ->
        {:error, :wait_has_no_trigger_input}

      command.resolution_ref not in episode.queued_input_refs ->
        {:error,
         {:wait_trigger_not_admitted,
          expected: command.resolution_ref, queued: episode.queued_input_refs}}

      true ->
        episode =
          episode
          |> Map.merge(%{
            state: :working,
            owner_kind: :turn,
            owner_ref: command.turn_ref,
            owner_deadline_at: nil,
            semantic_version: episode.semantic_version + 1
          })
          |> activate_queued_inputs([], command.resolution_ref)

        append(episode, command, :wait_resumed)
    end
  end

  defp decide_existing(%Episode{} = episode, %AcceptResult{} = command) do
    with :ok <- current_turn(episode, command.expected_turn_ref),
         :ok <- queued_delivery_wait(episode, command),
         :ok <- valid_requested_wait(command),
         :ok <- next_turn_if_queued(episode, command.delivery, command.next_turn_ref) do
      episode = accept_result(episode, command)
      append(episode, command, :result_accepted)
    end
  end

  defp decide_existing(%Episode{} = episode, %ConfirmDelivery{} = command) do
    case valid_delivery_confirmation(episode, command) do
      :ok ->
        episode
        |> advance_after_delivery(command)
        |> append(command, :delivery_confirmed)

      {:error, _reason} = error ->
        error
    end
  end

  defp decide_existing(%Episode{} = episode, %CancelEpisode{} = command) do
    actual = %{kind: episode.owner_kind, ref: episode.owner_ref}

    cond do
      actual != command.expected_owner ->
        {:error, {:stale_owner, expected: command.expected_owner, actual: actual}}

      episode.owner_kind == :delivery ->
        {:error, :delivery_must_settle_before_cancel}

      true ->
        episode = %{
          episode
          | state: :cancelled,
            owner_kind: nil,
            owner_ref: nil,
            owner_deadline_at: nil,
            active_input_refs: [],
            queued_input_refs: [],
            queued_input_order_keys: [],
            semantic_version: episode.semantic_version + 1
        }

        append(episode, command, :episode_cancelled)
    end
  end

  defp decide_existing(%Episode{} = episode, %RecordReaction{} = command) do
    episode
    |> Map.update!(:semantic_version, &(&1 + 1))
    |> append(command, :reaction_recorded)
  end

  defp valid_delivery_confirmation(episode, command) do
    with :ok <- current_delivery(episode, command),
         :ok <- queued_delivery_turn(episode, command),
         :ok <- queued_delivery_wait(episode, command) do
      valid_requested_wait(command)
    end
  end

  defp current_delivery(
         %Episode{state: :working, owner_kind: :delivery, owner_ref: ref},
         %ConfirmDelivery{expected_delivery_ref: ref}
       ),
       do: :ok

  defp current_delivery(episode, command), do: stale_delivery(episode, command)

  defp queued_delivery_turn(%Episode{queued_input_refs: []}, _command), do: :ok

  defp queued_delivery_turn(_episode, %ConfirmDelivery{next_turn_ref: ref}) when is_binary(ref),
    do: :ok

  defp queued_delivery_turn(_episode, _command), do: {:error, :queued_inputs_require_next_turn}

  defp queued_delivery_wait(%Episode{queued_input_refs: []}, _command), do: :ok
  defp queued_delivery_wait(_episode, %{next_wait: nil}), do: :ok
  defp queued_delivery_wait(_episode, _command), do: {:error, :queued_inputs_prevent_wait}

  defp valid_requested_wait(%{next_wait: nil}), do: :ok

  defp valid_requested_wait(command) do
    if valid_delivery_wait?(command), do: :ok, else: {:error, :invalid_delivery_wait}
  end

  defp stale_delivery(episode, command) do
    {:error,
     {:stale_delivery,
      expected: command.expected_delivery_ref,
      actual: %{kind: episode.owner_kind, ref: episode.owner_ref}}}
  end

  defp same_episode(%Episode{key: key}, %{episode_key: key}), do: :ok

  defp same_episode(%Episode{} = episode, command),
    do: {:error, {:episode_key_conflict, episode.key, command.episode_key}}

  defp same_execution_mode(%Episode{execution_mode: mode}, mode), do: :ok

  defp same_execution_mode(%Episode{execution_mode: stored}, submitted),
    do: {:error, {:execution_mode_conflict, stored: stored, submitted: submitted}}

  defp same_episode_id(%Episode{id: id}, id), do: :ok

  defp same_episode_id(%Episode{} = episode, submitted) do
    {:error, {:episode_identity_conflict, expected: episode.id, submitted: submitted}}
  end

  defp same_linked_episode(%Episode{linked_episode_id: id}, id), do: :ok

  defp same_linked_episode(%Episode{} = episode, submitted) do
    {:error,
     {:linked_history_conflict, expected: episode.linked_episode_id, submitted: submitted}}
  end

  defp same_destination(%Episode{} = episode, destination) do
    expected = %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }

    if expected == destination,
      do: :ok,
      else: {:error, {:destination_conflict, %{expected: expected, submitted: destination}}}
  end

  defp accepts_input(%Episode{state: :cancelled}), do: {:error, :episode_cancelled}
  defp accepts_input(%Episode{}), do: :ok

  defp newer_input_revision(%Episode{} = episode, command) do
    case Map.get(episode.input_revisions, command.native_input_id) do
      nil ->
        :ok

      latest when command.revision > latest ->
        :ok

      latest ->
        {:error,
         {:stale_input_revision,
          native_input_id: command.native_input_id, submitted: command.revision, latest: latest}}
    end
  end

  defp queue_empty_before_wait(%Episode{queued_input_refs: []}), do: :ok
  defp queue_empty_before_wait(%Episode{}), do: {:error, :queued_inputs_must_run_before_wait}

  defp current_turn(%Episode{state: :working, owner_kind: :turn, owner_ref: ref}, ref), do: :ok

  defp current_turn(%Episode{} = episode, expected_ref) do
    {:error,
     {:stale_turn,
      expected: expected_ref,
      actual: %{kind: episode.owner_kind, ref: episode.owner_ref, state: episode.state}}}
  end

  defp valid_wait(%StartWait{kind: :input, deadline_at: nil}), do: :ok
  defp valid_wait(%StartWait{kind: :event, deadline_at: nil}), do: :ok

  defp valid_wait(%StartWait{kind: :event, deadline_at: %DateTime{} = deadline} = command) do
    if DateTime.compare(deadline, command.occurred_at) == :gt,
      do: :ok,
      else: {:error, :event_wait_requires_future_deadline}
  end

  defp valid_wait(%StartWait{kind: :event}), do: {:error, :event_wait_requires_future_deadline}

  defp next_turn_if_queued(%Episode{queued_input_refs: []}, _delivery, nil), do: :ok

  defp next_turn_if_queued(%Episode{queued_input_refs: []}, :none, ref)
       when is_binary(ref) and ref != "", do: :ok

  defp next_turn_if_queued(%Episode{queued_input_refs: []}, _delivery, _ref),
    do: {:error, :unexpected_next_turn}

  defp next_turn_if_queued(_episode, :reply, _next_turn_ref), do: :ok
  defp next_turn_if_queued(_episode, :none, ref) when is_binary(ref) and ref != "", do: :ok
  defp next_turn_if_queued(_episode, :none, nil), do: {:error, :queued_inputs_require_next_turn}

  defp accept_result(%Episode{} = episode, %AcceptResult{delivery: :reply} = command) do
    %{
      episode
      | owner_kind: :delivery,
        owner_ref: command.delivery_ref,
        active_input_refs: [],
        semantic_version: episode.semantic_version + 1
    }
  end

  defp accept_result(%Episode{queued_input_refs: []} = episode, %AcceptResult{
         delivery: :none,
         next_wait: %{} = wait
       }) do
    episode
    |> advance_after_delivery(%{next_wait: wait})
    |> Map.update!(:semantic_version, &(&1 + 1))
  end

  defp accept_result(%Episode{queued_input_refs: []} = episode, %AcceptResult{
         delivery: :none,
         next_turn_ref: nil
       }) do
    %{
      episode
      | state: :complete,
        owner_kind: nil,
        owner_ref: nil,
        active_input_refs: [],
        semantic_version: episode.semantic_version + 1
    }
  end

  defp accept_result(%Episode{} = episode, %AcceptResult{delivery: :none} = command) do
    episode
    |> Map.merge(%{
      owner_kind: :turn,
      owner_ref: command.next_turn_ref,
      semantic_version: episode.semantic_version + 1
    })
    |> activate_queued_inputs([])
  end

  defp advance_after_delivery(
         %Episode{queued_input_refs: []} = episode,
         %{next_wait: %{kind: kind, ref: ref, deadline_at: deadline_at}}
       ) do
    state = if kind == :input, do: :waiting_for_input, else: :waiting_for_event

    %{
      episode
      | state: state,
        owner_kind: kind,
        owner_ref: ref,
        owner_deadline_at: deadline_at,
        active_input_refs: []
    }
  end

  defp advance_after_delivery(
         %Episode{queued_input_refs: []} = episode,
         %ConfirmDelivery{next_turn_ref: next_turn_ref}
       )
       when is_binary(next_turn_ref) do
    %{
      episode
      | state: :working,
        owner_kind: :turn,
        owner_ref: next_turn_ref,
        owner_deadline_at: nil,
        active_input_refs: []
    }
  end

  defp advance_after_delivery(%Episode{queued_input_refs: []} = episode, _command) do
    %{episode | state: :complete, owner_kind: nil, owner_ref: nil, active_input_refs: []}
  end

  defp advance_after_delivery(%Episode{} = episode, command) do
    episode
    |> Map.merge(%{owner_kind: :turn, owner_ref: command.next_turn_ref})
    |> activate_queued_inputs([])
  end

  defp activate_queued_inputs(episode, active_refs, required_ref \\ nil) do
    slots = max(@maximum_active_inputs - length(active_refs), 0)
    queued = Enum.zip(episode.queued_input_refs, episode.queued_input_order_keys)
    {selected, remaining} = input_batch(queued, slots, required_ref)

    %{
      episode
      | active_input_refs: active_refs ++ Enum.map(selected, &elem(&1, 0)),
        queued_input_refs: Enum.map(remaining, &elem(&1, 0)),
        queued_input_order_keys: Enum.map(remaining, &elem(&1, 1))
    }
  end

  defp transfer_inputs(episode, nil),
    do: activate_queued_inputs(episode, episode.active_input_refs)

  defp transfer_inputs(episode, required_ref) do
    episode
    |> activate_queued_inputs(Enum.take(episode.active_input_refs, 1), required_ref)
  end

  defp required_transfer_input_queued?(_episode, nil), do: true

  defp required_transfer_input_queued?(episode, required_ref),
    do: required_ref in episode.queued_input_refs

  defp input_batch(queued, slots, nil), do: Enum.split(queued, slots)

  defp input_batch(queued, slots, required_ref) when slots > 0 do
    required = Enum.find(queued, &(elem(&1, 0) == required_ref))

    selected_refs =
      queued
      |> Enum.reject(&(elem(&1, 0) == required_ref))
      |> Enum.take(slots - 1)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()
      |> MapSet.put(required_ref)

    selected = Enum.filter(queued, &MapSet.member?(selected_refs, elem(&1, 0)))
    remaining = Enum.reject(queued, &MapSet.member?(selected_refs, elem(&1, 0)))

    if required == nil, do: Enum.split(queued, slots), else: {selected, remaining}
  end

  defp valid_delivery_wait?(%{
         next_wait: %{kind: :input, deadline_at: nil}
       }),
       do: true

  defp valid_delivery_wait?(%{next_wait: %{kind: :event, deadline_at: nil}}), do: true

  defp valid_delivery_wait?(%{
         next_wait: %{kind: :event, deadline_at: %DateTime{}}
       }),
       do: true

  defp valid_delivery_wait?(_command), do: false

  defp append(%Episode{} = episode, command, event_kind) do
    sequence = episode.next_sequence
    episode = %{episode | next_sequence: sequence + 1}
    applied(episode, command, sequence, event_kind)
  end

  defp enqueue_input(%Episode{} = episode, input_ref, occurred_at) do
    order_key = input_order_key(occurred_at, input_ref)

    ordered =
      episode.queued_input_refs
      |> Enum.zip(episode.queued_input_order_keys)
      |> Kernel.++([{input_ref, order_key}])
      |> Enum.sort_by(&elem(&1, 1))

    %{
      episode
      | queued_input_refs: Enum.map(ordered, &elem(&1, 0)),
        queued_input_order_keys: Enum.map(ordered, &elem(&1, 1))
    }
  end

  defp input_order_key(occurred_at, input_ref) do
    occurred_at
    |> DateTime.to_unix(:microsecond)
    |> Integer.to_string()
    |> String.pad_leading(20, "0")
    |> Kernel.<>(":" <> input_ref)
  end

  defp applied(%Episode{} = episode, command, sequence, kind) do
    event = %Event{
      sequence: sequence,
      kind: kind,
      dedupe_key: Command.dedupe_key(command),
      fingerprint: Command.fingerprint(command),
      payload: Command.document(command),
      occurred_at: command.occurred_at
    }

    {:ok, %Transition{episode: episode, event: event, status: :applied}}
  end
end

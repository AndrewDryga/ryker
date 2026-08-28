defmodule Responder.Slack.Admission.CommitTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Slack.{Admission, Inbox, Input}
  alias Responder.Slack.Admission.Decision

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "starts one episode under the current Slack message and reconciles a lost response" do
    entry = record_input!(content: %{"text" => "Please investigate this unfamiliar app card"})
    context = context!(entry)
    decision = decision!(:start_episode, nil, :unrelated)

    assert {:ok, first} = Admission.commit(context, decision, "decision-start-1")
    assert first.status == :applied
    assert first.entry.status == :decided
    assert first.entry.decision_action == :start_episode
    assert first.entry.episode_id == first.episode.id
    assert first.episode.destination_thread_ref == entry.message_ref
    assert first.episode.destination_conversation_ref == "slack:T123:C456"
    assert length(first.transitions) == 1

    assert [event] = Episodes.list_events(first.episode.key)
    assert event.payload["payload"]["content"]["text"] =~ "unfamiliar app card"

    assert {:ok, duplicate} = Admission.commit(context, decision, "decision-start-1")
    assert duplicate.status == :duplicate
    assert duplicate.entry.id == first.entry.id
    assert duplicate.episode.id == first.episode.id
    assert Episodes.list_events(first.episode.key) == [event]

    paraphrased = %{decision | reason: "Same decision, explained differently after reconnecting."}
    assert {:ok, duplicate} = Admission.commit(context, paraphrased, "decision-start-1")
    assert duplicate.status == :duplicate
    assert duplicate.entry.decision_document["reason"] == decision.reason

    assert {:error, {:decision_conflict, details}} =
             Admission.commit(context, decision, "decision-from-another-turn")

    assert details[:stored_decision_ref] == "decision-start-1"
    assert details[:submitted_decision_ref] == "decision-from-another-turn"
  end

  test "starts a new episode with old work as history without borrowing its thread" do
    old = create_episode!(thread_ref: "1787830000.000001", complete: true)
    entry = record_input!(message_ref: "1787832000.000100")
    context = context!(entry)
    candidate = candidate!(context, old.id)
    decision = decision!(:start_episode, candidate.ref, :history_only)

    assert {:ok, result} = Admission.commit(context, decision, "decision-history-1")

    assert result.episode.id != old.id
    assert result.episode.linked_episode_id == old.id
    assert result.episode.destination_thread_ref == entry.message_ref

    assert {:ok, unchanged_old} = Episodes.fetch_by_key(old.key)
    assert unchanged_old.destination_thread_ref == "1787830000.000001"
  end

  test "a direct reply uses the current message thread and preserves its action" do
    entry = record_input!(event_ref: "Ev-direct-reply")
    context = context!(entry)
    decision = decision!(:reply, nil, :unrelated)

    assert {:ok, result} = Admission.commit(context, decision, "decision-reply-1")
    assert result.entry.decision_action == :reply
    assert result.episode.destination_thread_ref == entry.message_ref
  end

  test "continues active work in its bound thread and queues the new input" do
    active = create_episode!(thread_ref: "1787830000.000001")
    entry = record_input!(message_ref: "1787832000.000100")
    context = context!(entry)
    candidate = candidate!(context, active.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} = Admission.commit(context, decision, "decision-continue-1")

    assert result.episode.id == active.id
    assert result.episode.destination_thread_ref == "1787830000.000001"
    assert result.episode.owner_ref == active.owner_ref
    assert length(result.episode.queued_input_refs) == 1

    assert Enum.map(Episodes.list_events(active.key), & &1.kind) == [
             :input_admitted,
             :input_admitted
           ]
  end

  test "an admitted trigger resumes a waiting episode in the same transaction" do
    waiting = create_episode!(thread_ref: "1787830000.000001", wait: :event)
    entry = record_input!()
    context = context!(entry)
    candidate = candidate!(context, waiting.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} = Admission.commit(context, decision, "decision-resume-1")

    assert result.episode.state == :working
    assert result.episode.owner_kind == :turn
    assert result.episode.owner_ref == "slack-turn:#{entry.id}"
    assert length(result.episode.active_input_refs) == 1
    assert Enum.map(result.transitions, & &1.event.kind) == [:input_admitted, :wait_resumed]
  end

  test "an input that occurred before a wait cannot satisfy that later wait" do
    waiting = create_episode!(thread_ref: "1787830000.000001", wait: :event)

    entry =
      record_input!(
        event_ref: "Ev-delayed-before-wait",
        occurred_at: DateTime.add(@now, -120, :second)
      )

    context = context!(entry)
    candidate = candidate!(context, waiting.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} = Admission.commit(context, decision, "decision-delayed-input")

    assert result.episode.state == :waiting_for_event
    assert result.episode.owner_ref == waiting.owner_ref
    assert length(result.episode.queued_input_refs) == 1
    assert Enum.map(result.transitions, & &1.event.kind) == [:input_admitted]
  end

  test "a wait started after context construction is resumed from locked current state" do
    active = create_episode!(thread_ref: "1787830000.000001")
    entry = record_input!(event_ref: "Ev-wait-race")
    context = context!(entry)
    candidate = candidate!(context, active.id)
    assert candidate.episode.state == :working

    assert {:ok, _waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: DateTime.add(@now, 3_600, :second),
               episode_key: active.key,
               expected_turn_ref: active.owner_ref,
               kind: :event,
               occurred_at: DateTime.add(@now, -1, :second),
               wait_ref: "wait-after-context"
             })

    decision = decision!(:continue_episode, candidate.ref, :same_work)
    assert {:ok, result} = Admission.commit(context, decision, "decision-wait-race")

    assert result.episode.state == :working
    assert result.episode.owner_ref == "slack-turn:#{entry.id}"
    assert Enum.map(result.transitions, & &1.event.kind) == [:input_admitted, :wait_resumed]
  end

  test "ignore and react decisions remain durable without inventing an episode" do
    for action <- [:ignore, :react] do
      entry = record_input!(event_ref: "Ev-#{action}")
      context = context!(entry)
      decision = decision!(action, nil, :unrelated)

      assert {:ok, result} = Admission.commit(context, decision, "decision-#{action}")
      assert result.status == :applied
      assert result.episode == nil
      assert result.transitions == []
      assert result.entry.decision_action == action
      assert result.entry.episode_id == nil

      if action == :react do
        assert result.entry.decision_document["reaction"] == %{"emoji_name" => "eyes"}
      else
        assert result.entry.decision_document["reaction"] == nil
      end
    end
  end

  test "a decision-store failure rolls back the episode transition" do
    first_entry = record_input!(event_ref: "Ev-first")
    first_context = context!(first_entry)
    ignore = decision!(:ignore, nil, :unrelated)
    assert {:ok, _result} = Admission.commit(first_context, ignore, "decision-collision")

    second_entry = record_input!(event_ref: "Ev-second", message_ref: "1787832001.000100")
    second_context = context!(second_entry)
    start = decision!(:start_episode, nil, :unrelated)

    assert {:error, {:persistence_failed, :admission_decision, _errors}} =
             Admission.commit(second_context, start, "decision-collision")

    assert {:ok, still_pending} = Inbox.fetch(Inbox.ref(second_entry))
    assert still_pending.status == :pending
    assert :error == Episodes.fetch_by_key("slack-input:#{second_entry.id}")
  end

  test "the natural input slot rejects a different decision after acceptance" do
    entry = record_input!(event_ref: "Ev-decision-conflict")
    context = context!(entry)
    ignore = decision!(:ignore, nil, :unrelated)
    react = decision!(:react, nil, :unrelated)

    assert {:ok, _result} = Admission.commit(context, ignore, "decision-original")

    assert {:error,
            {:decision_conflict,
             input_ref: input_ref,
             stored_decision_ref: "decision-original",
             submitted_decision_ref: "decision-replacement",
             stored_fingerprint: stored,
             submitted_fingerprint: submitted}} =
             Admission.commit(context, react, "decision-replacement")

    assert input_ref == Inbox.ref(entry)
    refute stored == submitted

    assert {:ok, decided} = Inbox.fetch(Inbox.ref(entry))
    assert decided.decision_action == :ignore
    assert decided.decision_ref == "decision-original"
  end

  test "a frozen empty context cannot split one thread after another input starts work" do
    first = record_input!(event_ref: "Ev-thread-first")

    second =
      record_input!(
        event_ref: "Ev-thread-second",
        message_ref: "1787832001.000100",
        occurred_at: DateTime.add(@now, 1, :second),
        thread_ref: first.message_ref
      )

    first_context = context!(first)
    second_context = context!(second)
    assert first_context.candidates == []
    assert second_context.candidates == []

    start = decision!(:start_episode, nil, :unrelated)
    assert {:ok, started} = Admission.commit(first_context, start, "decision-thread-first")

    assert {:error, {:admission_rejected, :context_stale}} =
             Admission.commit(
               second_context,
               start,
               "decision-thread-second-stale"
             )

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(second))
    assert pending.status == :pending

    fresh_context = context!(second)
    candidate = candidate!(fresh_context, started.episode.id)
    continue = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, continued} =
             Admission.commit(
               fresh_context,
               continue,
               "decision-thread-second-fresh"
             )

    assert continued.episode.id == started.episode.id
    assert :error == Episodes.fetch_by_key("slack-input:#{second.id}")
  end

  test "new work in another thread is reconsidered with the new candidate visible" do
    first =
      record_input!(
        event_ref: "Ev-independent-first",
        message_ref: "1787832000.000101"
      )

    second =
      record_input!(
        event_ref: "Ev-independent-second",
        message_ref: "1787832000.000102"
      )

    first_context = context!(first)
    second_context = context!(second)
    start = decision!(:start_episode, nil, :unrelated)

    assert {:ok, first_result} =
             Admission.commit(first_context, start, "decision-independent-first")

    assert {:error, {:admission_rejected, :context_stale}} =
             Admission.commit(second_context, start, "decision-independent-second-stale")

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(second))
    assert pending.status == :pending

    fresh_context = context!(second)
    assert Enum.any?(fresh_context.candidates, &(&1.episode.id == first_result.episode.id))

    assert {:ok, second_result} =
             Admission.commit(fresh_context, start, "decision-independent-second-fresh")

    refute first_result.episode.id == second_result.episode.id
    assert first_result.episode.destination_thread_ref == first.message_ref
    assert second_result.episode.destination_thread_ref == second.message_ref
  end

  test "a selected routing decision survives newer input on the same work" do
    active = create_episode!(thread_ref: "1787830000.000001")
    entry = record_input!(event_ref: "Ev-frozen-before-newer-input")
    context = context!(entry)
    candidate = candidate!(context, active.id)
    continue = decision!(:continue_episode, candidate.ref, :same_work)

    intervening =
      input!(
        content: %{"text" => "A newer lifecycle update arrived while routing."},
        event_ref: "Ev-intervening-update",
        message_ref: "1787832001.000200",
        occurred_at: DateTime.add(@now, 1, :second),
        thread_ref: active.destination_thread_ref
      )

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(intervening),
               destination: %{
                 conversation_ref: active.destination_conversation_ref,
                 thread_ref: active.destination_thread_ref,
                 transport: active.destination_transport
               },
               episode_id: active.id,
               episode_key: active.key,
               linked_episode_id: active.linked_episode_id,
               native_input_id: Input.message_key(intervening),
               occurred_at: intervening.occurred_at,
               payload: Input.document(intervening),
               revision: intervening.revision,
               turn_ref: "turn-intervening-update"
             })

    assert {:ok, result} =
             Admission.commit(context, continue, "decision-before-newer-input")

    assert result.episode.id == active.id
    assert length(result.episode.queued_input_refs) == 2
  end

  test "a selected routing decision can reopen work completed while admission was running" do
    active = create_episode!(thread_ref: "1787832000.000100")

    entry =
      record_input!(
        event_ref: "Ev-frozen-before-completion",
        message_ref: "1787832001.000100",
        thread_ref: active.destination_thread_ref
      )

    context = context!(entry)
    candidate = candidate!(context, active.id)
    assert candidate.allowed_relations == [:same_work, :history_only]

    assert {:ok, _completed} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason: "The earlier work completed while this input was being routed.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: active.key,
               expected_turn_ref: active.owner_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.add(@now, -1, :second),
               result_ref: "result-completed-during-admission"
             })

    continue = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} =
             Admission.commit(context, continue, "decision-before-completion")

    assert result.episode.id == active.id
    assert result.episode.state == :working
  end

  defp context!(entry) do
    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8
             )

    context
  end

  defp candidate!(context, episode_id) do
    Enum.find(context.candidates, &(&1.episode.id == episode_id)) ||
      flunk("episode #{episode_id} was not offered as a candidate")
  end

  defp decision!(action, episode_ref, relation) do
    reaction = if action == :react, do: %{"emoji_name" => "eyes"}, else: nil

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => Atom.to_string(action),
               "episode_ref" => episode_ref,
               "reaction" => reaction,
               "relation" => Atom.to_string(relation),
               "reason" => "Recorded model admission decision for this test."
             })

    decision
  end

  defp record_input!(overrides \\ []) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :user, ref: "U123"},
          channel_ref: "C456",
          content: %{"text" => "Current Slack input"},
          event_kind: :message,
          event_ref: "Ev-#{Ecto.UUID.generate()}",
          message_ref: "1787832000.000100",
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        ],
        overrides
      )

    assert {:ok, input} = Input.new(attributes)
    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp create_episode!(options) do
    episode_id = Ecto.UUID.generate()
    episode_key = "existing:#{episode_id}"
    thread_ref = Keyword.fetch!(options, :thread_ref)

    source_input =
      input!(
        actor: %{kind: :app, ref: "A-old"},
        content: %{"text" => "Earlier Slack work"},
        event_ref: "Ev-#{Ecto.UUID.generate()}",
        message_ref: thread_ref
      )

    admit = %Command.AdmitInput{
      actor_ref: "slack:app:A-old",
      destination: Input.destination(source_input),
      episode_id: episode_id,
      episode_key: episode_key,
      linked_episode_id: nil,
      native_input_id: Input.message_key(source_input),
      occurred_at: DateTime.add(@now, -60, :second),
      payload: Input.document(source_input),
      revision: 1,
      turn_ref: "turn-existing-#{episode_id}"
    }

    assert {:ok, _transition} = Episodes.apply(admit)

    case Keyword.get(options, :wait) do
      nil ->
        :ok

      kind ->
        assert {:ok, _transition} =
                 Episodes.apply(%Command.StartWait{
                   deadline_at: if(kind == :event, do: DateTime.add(@now, 3_600), else: nil),
                   episode_key: episode_key,
                   expected_turn_ref: admit.turn_ref,
                   kind: kind,
                   occurred_at: DateTime.add(@now, -30, :second),
                   wait_ref: "wait-#{episode_id}"
                 })
    end

    if Keyword.get(options, :complete, false) do
      assert {:ok, _transition} =
               Episodes.apply(%Command.AcceptResult{
                 decision_reason: "No visible reply was needed.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: episode_key,
                 expected_turn_ref: admit.turn_ref,
                 next_turn_ref: nil,
                 occurred_at: DateTime.add(@now, -30, :second),
                 result_ref: "result-#{episode_id}"
               })
    end

    assert {:ok, episode} = Episodes.fetch_by_key(episode_key)
    episode
  end

  defp input!(overrides) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :app, ref: "A123"},
          channel_ref: "C456",
          content: %{"text" => "A generic Slack message"},
          event_kind: :message,
          event_ref: "Ev123",
          message_ref: "1787832000.000100",
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        ],
        overrides
      )

    assert {:ok, input} = Input.new(attributes)
    input
  end
end

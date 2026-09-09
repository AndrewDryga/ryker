defmodule Responder.Episodes.ReducerTest do
  use ExUnit.Case, async: true
  alias Responder.Episodes.{Command, Reducer, Snapshot}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures

  describe "input admission" do
    test "only an admitted input can create an episode" do
      assert Reducer.decide(nil, EpisodeFixtures.transfer_owner()) ==
               {:error, :episode_does_not_exist}
    end

    test "whole-second timestamps are normalized for durable persistence" do
      command = EpisodeFixtures.admit_input(%{occurred_at: ~U[2026-08-27 12:00:00Z]})

      assert {:ok, transition} = Reducer.decide(nil, command)
      assert transition.event.occurred_at.microsecond == {0, 6}
      assert transition.event.payload["occurred_at"] == "2026-08-27T12:00:00.000000Z"
    end

    test "non-UTC timestamps are rejected before utc storage" do
      local = %{
        ~U[2026-08-27 12:00:00.000000Z]
        | time_zone: "America/Merida",
          zone_abbr: "CST",
          utc_offset: -21_600
      }

      assert Reducer.decide(nil, EpisodeFixtures.admit_input(%{occurred_at: local})) ==
               {:error, {:invalid_command, :occurred_at}}
    end

    test "malformed source identity cannot create an ownerless or unaddressable episode" do
      cases = [
        {:episode_key, %{episode_key: ""}},
        {:episode_id, %{episode_id: "not-a-uuid"}},
        {:native_input_id, %{native_input_id: ""}},
        {:turn_ref, %{turn_ref: ""}},
        {:revision, %{revision: 0}},
        {:destination,
         %{destination: %{transport: "slack", conversation_ref: "", thread_ref: nil}}}
      ]

      Enum.each(cases, fn {field, overrides} ->
        assert Reducer.decide(nil, EpisodeFixtures.admit_input(overrides)) ==
                 {:error, {:invalid_command, field}}
      end)
    end

    test "the first input binds one destination and one active turn" do
      command = EpisodeFixtures.admit_input()
      assert {:ok, transition} = Reducer.decide(nil, command)

      assert Snapshot.from_episode(transition.episode) == %{
               "active_inputs" => [Command.dedupe_key(command)],
               "destination" => %{
                 "conversation_ref" => "C-alerts",
                 "thread_ref" => "1787832000.000100",
                 "transport" => "slack"
               },
               "episode_key" => "grafana:rule-1:fingerprint-1:cycle-1",
               "input_revisions" => %{"slack:event:Ev1" => 1},
               "linked_episode_id" => nil,
               "owner" => %{"kind" => "turn", "ref" => "turn-1"},
               "queued_inputs" => [],
               "semantic_version" => 1,
               "state" => "working"
             }

      assert transition.event.kind == :input_admitted
      assert transition.event.sequence == 1
      assert transition.status == :applied
    end

    test "an episode cannot link to itself" do
      command = EpisodeFixtures.admit_input()
      self_linked = %{command | linked_episode_id: command.episode_id}

      assert Reducer.decide(nil, self_linked) ==
               {:error, {:invalid_command, :linked_episode_id}}
    end

    test "payloads must be bounded lossless JSON" do
      scalar = EpisodeFixtures.admit_input(%{payload: "not-an-object"})
      invalid = EpisodeFixtures.admit_input(%{payload: %{"value" => {:tuple, 1}}})
      collision = EpisodeFixtures.admit_input(%{payload: %{"same" => 1, same: 2}})
      null_character = EpisodeFixtures.admit_input(%{payload: %{"value" => <<0>>}})
      invalid_utf8 = EpisodeFixtures.admit_input(%{payload: %{"value" => <<255>>}})

      oversized =
        EpisodeFixtures.admit_input(%{payload: %{"text" => String.duplicate("x", 65_537)}})

      assert Reducer.decide(nil, scalar) == {:error, {:invalid_command, :payload}}
      assert Reducer.decide(nil, invalid) == {:error, {:invalid_command, :payload}}
      assert Reducer.decide(nil, collision) == {:error, {:invalid_command, :payload}}
      assert Reducer.decide(nil, null_character) == {:error, {:invalid_command, :payload}}
      assert Reducer.decide(nil, invalid_utf8) == {:error, {:invalid_command, :payload}}
      assert Reducer.decide(nil, oversized) == {:error, {:invalid_command, :payload}}
    end

    test "references must be valid Postgres text" do
      invalid_utf8 = EpisodeFixtures.admit_input(%{episode_key: <<255>>})
      null_character = EpisodeFixtures.admit_input(%{native_input_id: "source\0poison"})

      assert Reducer.decide(nil, invalid_utf8) ==
               {:error, {:invalid_command, :episode_key}}

      assert Reducer.decide(nil, null_character) ==
               {:error, {:invalid_command, :native_input_id}}
    end

    test "UUIDs are normalized before pure replay or persistence" do
      command =
        EpisodeFixtures.admit_input(%{
          episode_id: "01993D45-D400-7000-8000-000000000001",
          linked_episode_id: "01993D45-D400-7000-8000-000000000002"
        })

      assert {:ok, prepared} = Command.prepare(command)
      assert prepared.episode_id == "01993d45-d400-7000-8000-000000000001"
      assert prepared.linked_episode_id == "01993d45-d400-7000-8000-000000000002"
    end

    test "nested command maps require exact atom keys" do
      mixed_destination =
        EpisodeFixtures.admit_input(%{
          destination: %{
            "transport" => "evil",
            conversation_ref: "C-alerts",
            thread_ref: "1787832000.000100",
            transport: "slack"
          }
        })

      extra_owner =
        EpisodeFixtures.transfer_owner(%{
          expected_owner: %{kind: :turn, ref: "turn-1", lease: 2}
        })

      extra_wait =
        EpisodeFixtures.resume_wait(%{
          expected_wait: %{kind: :input, ref: "question-1", source: "other"}
        })

      assert Reducer.decide(nil, mixed_destination) ==
               {:error, {:invalid_command, :destination}}

      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      assert Reducer.decide(admitted.episode, extra_owner) ==
               {:error, {:invalid_command, :expected_owner}}

      assert Reducer.decide(admitted.episode, extra_wait) ==
               {:error, {:invalid_command, :expected_wait}}
    end

    test "new input queues behind active work without replacing its owner" do
      first = EpisodeFixtures.admit_input()
      assert {:ok, first_transition} = Reducer.decide(nil, first)

      second =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:Ev2",
          occurred_at: ~U[2026-08-27 12:00:01.000000Z],
          payload: %{"text" => "additional context"},
          turn_ref: "turn-must-not-take-over"
        })

      assert {:ok, second_transition} = Reducer.decide(first_transition.episode, second)
      episode = second_transition.episode

      assert episode.owner_ref == "turn-1"
      assert episode.active_input_refs == [Command.dedupe_key(first)]
      assert episode.queued_input_refs == [Command.dedupe_key(second)]
      assert episode.semantic_version == 2
    end

    test "queued inputs become the next turn in source chronology" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      later =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:later",
          occurred_at: ~U[2026-08-27 12:00:10.000000Z],
          payload: %{"text" => "later"}
        })

      earlier =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:earlier",
          occurred_at: ~U[2026-08-27 12:00:05.000000Z],
          payload: %{"text" => "earlier"}
        })

      assert {:ok, queued_later} = Reducer.decide(admitted.episode, later)
      assert {:ok, queued_both} = Reducer.decide(queued_later.episode, earlier)

      assert {:ok, accepted} =
               Reducer.decide(queued_both.episode, EpisodeFixtures.accept_result())

      assert {:ok, next_turn} =
               Reducer.decide(
                 accepted.episode,
                 EpisodeFixtures.confirm_delivery(%{next_turn_ref: "turn-chronological"})
               )

      assert next_turn.episode.active_input_refs == [
               Command.dedupe_key(earlier),
               Command.dedupe_key(later)
             ]
    end

    test "a stale source revision cannot re-enter after a newer revision" do
      newest = EpisodeFixtures.admit_input(%{revision: 2})
      assert {:ok, admitted} = Reducer.decide(nil, newest)

      stale =
        EpisodeFixtures.admit_input(%{
          occurred_at: ~U[2026-08-27 11:59:59.000000Z],
          payload: %{"status" => "older"},
          revision: 1
        })

      assert Reducer.decide(admitted.episode, stale) ==
               {:error,
                {:stale_input_revision,
                 native_input_id: stale.native_input_id, submitted: 1, latest: 2}}
    end

    test "a bound thread cannot be widened or moved" do
      command = EpisodeFixtures.admit_input()
      assert {:ok, transition} = Reducer.decide(nil, command)

      moved =
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: "C-alerts",
            thread_ref: nil,
            transport: "slack"
          },
          native_input_id: "slack:event:Ev2"
        })

      assert {:error, {:destination_conflict, details}} =
               Reducer.decide(transition.episode, moved)

      assert details.expected.thread_ref == "1787832000.000100"
      assert details.submitted.thread_ref == nil
    end

    test "an existing projection cannot be addressed through another episode key" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      other_key = EpisodeFixtures.accept_result(%{episode_key: "another:episode:key"})

      assert Reducer.decide(admitted.episode, other_key) ==
               {:error, {:episode_key_conflict, admitted.episode.key, "another:episode:key"}}
    end

    test "an existing episode binds a creation candidate id but rejects another history link" do
      command = EpisodeFixtures.admit_input()
      assert {:ok, transition} = Reducer.decide(nil, command)

      changed_id =
        EpisodeFixtures.admit_input(%{
          episode_id: "01993d45-d400-7000-8000-000000000009",
          native_input_id: "slack:event:Ev2"
        })

      assert {:ok, continued} = Reducer.decide(transition.episode, changed_id)
      assert continued.episode.id == command.episode_id
      assert continued.event.payload["episode_id"] == command.episode_id

      changed_history =
        EpisodeFixtures.admit_input(%{
          linked_episode_id: "01993d45-d400-7000-8000-000000000099",
          native_input_id: "slack:event:Ev3"
        })

      assert Reducer.decide(transition.episode, changed_history) ==
               {:error,
                {:linked_history_conflict,
                 expected: command.linked_episode_id, submitted: changed_history.linked_episode_id}}
    end

    test "a new input reopens a completed episode in the same destination" do
      first = EpisodeFixtures.admit_input()
      assert {:ok, admitted} = Reducer.decide(nil, first)

      result =
        EpisodeFixtures.accept_result(%{
          decision_reason: "exact duplicate lifecycle revision",
          delivery: :none,
          delivery_ref: nil,
          result_ref: "silent-result-1"
        })

      assert {:ok, completed} = Reducer.decide(admitted.episode, result)
      assert completed.episode.state == :complete

      followup =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:Ev-followup",
          payload: %{"text" => "please check again"},
          turn_ref: "turn-2"
        })

      assert {:ok, reopened} = Reducer.decide(completed.episode, followup)
      assert reopened.episode.state == :working
      assert reopened.episode.owner_ref == "turn-2"
      assert reopened.episode.destination_thread_ref == "1787832000.000100"
    end
  end

  describe "ownership" do
    test "a no-op transfer is rejected without consuming a future owner change" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      unchanged =
        EpisodeFixtures.transfer_owner(%{
          new_owner: %{kind: :turn, ref: "turn-1"},
          transfer_ref: "owner-transfer-no-op"
        })

      assert Reducer.decide(admitted.episode, unchanged) == {:error, :owner_unchanged}

      assert {:ok, transferred} =
               Reducer.decide(admitted.episode, EpisodeFixtures.transfer_owner())

      assert transferred.episode.owner_ref == "turn-1-replacement"
    end

    test "a replacement must name the exact current owner and cannot change its kind" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      transfer = EpisodeFixtures.transfer_owner()
      assert {:ok, transferred} = Reducer.decide(admitted.episode, transfer)

      assert transferred.episode.owner_ref == "turn-1-replacement"
      assert transferred.episode.semantic_version == admitted.episode.semantic_version

      assert Reducer.decide(transferred.episode, transfer) ==
               {:error,
                {:stale_owner,
                 expected: %{kind: :turn, ref: "turn-1"},
                 actual: %{kind: :turn, ref: "turn-1-replacement"}}}

      changed_kind =
        EpisodeFixtures.transfer_owner(%{new_owner: %{kind: :delivery, ref: "delivery-1"}})

      assert Reducer.decide(admitted.episode, changed_kind) ==
               {:error, {:owner_kind_change_requires_transition, :turn, :delivery}}
    end

    test "an owner transfer hands queued inputs to the replacement turn" do
      first = EpisodeFixtures.admit_input()
      assert {:ok, admitted} = Reducer.decide(nil, first)

      feedback =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:owner-transfer-feedback",
          occurred_at: ~U[2026-08-27 12:00:01.000000Z],
          payload: %{"text" => "Please retry with this correction."}
        })

      assert {:ok, queued} = Reducer.decide(admitted.episode, feedback)
      assert queued.episode.queued_input_refs == [Command.dedupe_key(feedback)]

      assert {:ok, transferred} =
               Reducer.decide(queued.episode, EpisodeFixtures.transfer_owner())

      assert transferred.episode.active_input_refs == [
               Command.dedupe_key(first),
               Command.dedupe_key(feedback)
             ]

      assert transferred.episode.queued_input_refs == []
      assert transferred.episode.queued_input_order_keys == []
    end

    test "a feedback transfer replaces an already-consumed correction with its triggering input" do
      first = EpisodeFixtures.admit_input()
      assert {:ok, admitted} = Reducer.decide(nil, first)

      first_correction =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:first-correction",
          occurred_at: ~U[2026-08-27 12:00:01.000000Z],
          payload: %{"text" => "Try the first correction."}
        })

      assert {:ok, first_queued} = Reducer.decide(admitted.episode, first_correction)

      assert {:ok, first_transfer} =
               Reducer.decide(first_queued.episode, EpisodeFixtures.transfer_owner())

      second_correction =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:second-correction",
          occurred_at: ~U[2026-08-27 12:00:02.000000Z],
          payload: %{"text" => "Use this newer correction instead."}
        })

      assert {:ok, second_queued} = Reducer.decide(first_transfer.episode, second_correction)

      transfer =
        EpisodeFixtures.transfer_owner(%{
          expected_owner: %{kind: :turn, ref: "turn-1-replacement"},
          new_owner: %{kind: :turn, ref: "turn-1-after-second-correction"},
          occurred_at: ~U[2026-08-27 12:00:03.000000Z],
          required_input_ref: Command.dedupe_key(second_correction),
          transfer_ref: "owner-transfer-second-correction"
        })

      assert {:ok, resumed} = Reducer.decide(second_queued.episode, transfer)

      assert resumed.episode.active_input_refs == [
               Command.dedupe_key(first),
               Command.dedupe_key(second_correction)
             ]

      refute Command.dedupe_key(first_correction) in resumed.episode.active_input_refs
      assert resumed.episode.queued_input_refs == []
    end

    test "an owner transfer requires a usable replacement reference" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      transfer = EpisodeFixtures.transfer_owner(%{new_owner: %{kind: :turn, ref: ""}})

      assert Reducer.decide(admitted.episode, transfer) ==
               {:error, {:invalid_command, :new_owner}}
    end

    test "a waiting owner cannot be replaced through the working-owner transition" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, waiting} = Reducer.decide(admitted.episode, EpisodeFixtures.start_wait())

      transfer =
        EpisodeFixtures.transfer_owner(%{
          expected_owner: %{kind: :input, ref: "question-1"},
          new_owner: %{kind: :input, ref: "question-2"},
          transfer_ref: "replace-question"
        })

      assert Reducer.decide(waiting.episode, transfer) ==
               {:error, {:invalid_state, :waiting_for_input, :transfer_owner}}
    end
  end

  describe "passive conversation feedback" do
    test "a reaction is ordered context but never starts or transfers model work" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      reaction = EpisodeFixtures.record_reaction()

      assert {:ok, recorded} = Reducer.decide(admitted.episode, reaction)
      assert recorded.event.kind == :reaction_recorded
      assert recorded.event.sequence == 2
      assert recorded.event.payload["action"] == "add"
      assert recorded.event.payload["emoji_name"] == "eyes"
      assert recorded.event.payload["target_delivery_ref"] == "slack-delivery-1"
      assert recorded.episode.owner_kind == admitted.episode.owner_kind
      assert recorded.episode.owner_ref == admitted.episode.owner_ref
      assert recorded.episode.state == admitted.episode.state
      assert recorded.episode.active_input_refs == admitted.episode.active_input_refs
      assert recorded.episode.queued_input_refs == []
      assert recorded.episode.semantic_version == admitted.episode.semantic_version + 1
    end

    test "reaction shape cannot inject authority or malformed emoji names" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      cases = [
        {:action, %{action: :approve}},
        {:actor_ref, %{actor_ref: ""}},
        {:emoji_name, %{emoji_name: "eyes:ship-it"}},
        {:event_ref, %{event_ref: ""}},
        {:source, %{source: %{kind: "slack", ref: "T1", extra: "authority"}}},
        {:target_delivery_ref, %{target_delivery_ref: ""}},
        {:target_message_ref, %{target_message_ref: ""}}
      ]

      Enum.each(cases, fn {field, overrides} ->
        assert Reducer.decide(admitted.episode, EpisodeFixtures.record_reaction(overrides)) ==
                 {:error, {:invalid_command, field}}
      end)
    end
  end

  describe "waits" do
    test "whole-second wait deadlines are normalized for durable persistence" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      wait =
        EpisodeFixtures.start_wait(%{
          deadline_at: ~U[2026-08-27 14:00:00Z],
          kind: :event,
          occurred_at: ~U[2026-08-27 12:00:01Z],
          wait_ref: "deployment-health"
        })

      assert {:ok, waiting} = Reducer.decide(admitted.episode, wait)
      assert waiting.episode.owner_deadline_at.microsecond == {0, 6}
      assert waiting.event.occurred_at.microsecond == {0, 6}
    end

    test "a turn must process already queued input before it can start a wait" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      queued_input =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:already-queued",
          occurred_at: ~U[2026-08-27 12:00:01.000000Z],
          turn_ref: "turn-already-queued"
        })

      assert {:ok, queued} = Reducer.decide(admitted.episode, queued_input)

      assert Reducer.decide(queued.episode, EpisodeFixtures.start_wait()) ==
               {:error, :queued_inputs_must_run_before_wait}
    end

    test "an input wait resumes only after a new input is durably queued" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      wait = EpisodeFixtures.start_wait()
      assert {:ok, waiting} = Reducer.decide(admitted.episode, wait)

      assert waiting.episode.state == :waiting_for_input
      assert waiting.episode.owner_kind == :input
      assert waiting.episode.owner_ref == "question-1"
      assert waiting.episode.active_input_refs == []

      assert Reducer.decide(waiting.episode, EpisodeFixtures.resume_wait()) ==
               {:error, :wait_has_no_trigger_input}

      answer =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:Ev-answer",
          payload: %{"text" => "yes"}
        })

      assert {:ok, queued} = Reducer.decide(waiting.episode, answer)
      assert {:ok, resumed} = Reducer.decide(queued.episode, EpisodeFixtures.resume_wait())

      assert resumed.episode.state == :working
      assert resumed.episode.owner_ref == "turn-2"
      assert resumed.episode.active_input_refs == [Command.dedupe_key(answer)]
      assert resumed.episode.queued_input_refs == []
    end

    test "an event wait can be event-only and rejects an elapsed explicit deadline" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      missing_deadline =
        EpisodeFixtures.start_wait(%{kind: :event, wait_ref: "deployment-health"})

      assert {:ok, event_only} = Reducer.decide(admitted.episode, missing_deadline)
      assert event_only.episode.state == :waiting_for_event
      assert event_only.episode.owner_deadline_at == nil

      assert Reducer.decide(admitted.episode, %{
               missing_deadline
               | deadline_at: missing_deadline.occurred_at
             }) ==
               {:error, :event_wait_requires_future_deadline}

      valid =
        EpisodeFixtures.start_wait(%{
          deadline_at: ~U[2026-08-27 14:00:00.000000Z],
          kind: :event,
          wait_ref: "deployment-health"
        })

      assert {:ok, waiting} = Reducer.decide(admitted.episode, valid)
      assert waiting.episode.state == :waiting_for_event
      assert waiting.episode.owner_kind == :event
    end

    test "an event wait also requires a durably admitted trigger" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      wait =
        EpisodeFixtures.start_wait(%{
          deadline_at: ~U[2026-08-27 14:00:00.000000Z],
          kind: :event,
          wait_ref: "deployment-health"
        })

      assert {:ok, waiting} = Reducer.decide(admitted.episode, wait)

      resume =
        EpisodeFixtures.resume_wait(%{
          expected_wait: %{kind: :event, ref: "deployment-health"},
          resolution_ref: "wakeup:deployment-health"
        })

      assert Reducer.decide(waiting.episode, resume) == {:error, :wait_has_no_trigger_input}
    end

    test "an event wait resumes only from its exact admitted trigger" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      wait =
        EpisodeFixtures.start_wait(%{
          deadline_at: ~U[2026-08-27 14:00:00.000000Z],
          kind: :event,
          wait_ref: "deployment-health"
        })

      assert {:ok, waiting} = Reducer.decide(admitted.episode, wait)

      unrelated =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:unrelated-message",
          occurred_at: ~U[2026-08-27 12:01:00.000000Z],
          payload: %{"text" => "unrelated conversation"},
          turn_ref: "turn-unrelated"
        })

      expected_trigger =
        EpisodeFixtures.admit_input(%{
          native_input_id: "wakeup:deployment-health",
          occurred_at: ~U[2026-08-27 12:02:00.000000Z],
          payload: %{"trigger" => "deployment-health"},
          turn_ref: "turn-deployment-health"
        })

      assert {:ok, unrelated_queued} = Reducer.decide(waiting.episode, unrelated)

      resume =
        EpisodeFixtures.resume_wait(%{
          expected_wait: %{kind: :event, ref: "deployment-health"},
          resolution_ref: Command.dedupe_key(expected_trigger),
          turn_ref: "turn-deployment-health"
        })

      assert Reducer.decide(unrelated_queued.episode, resume) ==
               {:error,
                {:wait_trigger_not_admitted,
                 expected: Command.dedupe_key(expected_trigger),
                 queued: [Command.dedupe_key(unrelated)]}}

      assert {:ok, trigger_queued} = Reducer.decide(unrelated_queued.episode, expected_trigger)
      assert {:ok, resumed} = Reducer.decide(trigger_queued.episode, resume)
      assert resumed.episode.active_input_refs == trigger_queued.episode.queued_input_refs
    end

    test "an input wait cannot carry a hidden timer" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      wait =
        EpisodeFixtures.start_wait(%{deadline_at: ~U[2026-08-27 14:00:00.000000Z]})

      assert Reducer.decide(admitted.episode, wait) ==
               {:error, {:invalid_command, :deadline_at}}
    end
  end

  describe "result and delivery custody" do
    test "a visible result stays working under delivery ownership until Slack confirms it" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      assert accepted.episode.state == :working
      assert accepted.episode.owner_kind == :delivery
      assert accepted.episode.owner_ref == "slack-delivery-1"
      assert accepted.episode.active_input_refs == []

      assert {:ok, completed} =
               Reducer.decide(accepted.episode, EpisodeFixtures.confirm_delivery())

      assert completed.episode.state == :complete
      assert completed.episode.owner_kind == nil
      assert completed.episode.owner_ref == nil
    end

    test "a queued message becomes the next turn only after delivery finishes" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      followup =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:Ev-feedback",
          payload: %{"text" => "also check the restart count"}
        })

      assert {:ok, queued} = Reducer.decide(accepted.episode, followup)

      assert Reducer.decide(queued.episode, EpisodeFixtures.confirm_delivery()) ==
               {:error, :queued_inputs_require_next_turn}

      confirmation = EpisodeFixtures.confirm_delivery(%{next_turn_ref: "turn-2"})
      assert {:ok, resumed} = Reducer.decide(queued.episode, confirmation)

      assert resumed.episode.state == :working
      assert resumed.episode.owner_kind == :turn
      assert resumed.episode.owner_ref == "turn-2"
      assert resumed.episode.active_input_refs == [Command.dedupe_key(followup)]
    end

    test "queued inputs advance in exact bounded pairs without losing chronology" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      queued =
        Enum.reduce(1..45, accepted.episode, fn index, episode ->
          input =
            EpisodeFixtures.admit_input(%{
              native_input_id: "slack:event:batch-#{index}",
              occurred_at: DateTime.add(~U[2026-08-27 12:00:00.000000Z], index, :second),
              payload: %{"text" => "batch #{index}"}
            })

          assert {:ok, transition} = Reducer.decide(episode, input)
          transition.episode
        end)

      assert {:ok, first_batch} =
               Reducer.decide(
                 queued,
                 EpisodeFixtures.confirm_delivery(%{next_turn_ref: "turn-batch-1"})
               )

      assert first_batch.episode.active_input_refs == Enum.take(queued.queued_input_refs, 2)
      assert length(first_batch.episode.queued_input_refs) == 43

      result =
        EpisodeFixtures.accept_result(%{
          decision_reason: "continue the remaining queued input batch",
          delivery: :none,
          delivery_ref: nil,
          expected_turn_ref: "turn-batch-1",
          next_turn_ref: "turn-batch-2",
          result_ref: "result-batch-1"
        })

      assert {:ok, second_batch} = Reducer.decide(first_batch.episode, result)

      assert second_batch.episode.active_input_refs ==
               Enum.take(first_batch.episode.queued_input_refs, 2)

      assert length(second_batch.episode.queued_input_refs) == 41
      assert length(second_batch.episode.queued_input_order_keys) == 41
    end

    test "a no-delivery result completes immediately when no input is queued" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      result =
        EpisodeFixtures.accept_result(%{
          decision_reason: "exact duplicate lifecycle revision",
          delivery: :none,
          delivery_ref: nil,
          result_ref: "duplicate-lifecycle-revision"
        })

      assert {:ok, completed} = Reducer.decide(admitted.episode, result)
      assert completed.episode.state == :complete
      assert completed.episode.owner_kind == nil
      assert completed.episode.semantic_version == 2
    end

    test "a silent result transfers custody to its wait without inventing a delivery" do
      # Unchanged TFC checks used to require a Slack message just to stay waiting.
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      result =
        EpisodeFixtures.accept_result(%{
          decision_reason: "No lifecycle change.",
          delivery: :none,
          delivery_ref: nil
        })
        |> Map.put(:next_wait, %{kind: :event, ref: "wait:tfc-run", deadline_at: nil})

      assert {:ok, waiting} = Reducer.decide(admitted.episode, result)
      assert waiting.episode.state == :waiting_for_event
      assert waiting.episode.owner_ref == "wait:tfc-run"
      assert waiting.episode.owner_kind == :event
      assert waiting.episode.owner_deadline_at == nil

      assert Snapshot.from_episode(waiting.episode)["owner"] == %{
               "kind" => "event",
               "ref" => "wait:tfc-run",
               "deadline_at" => nil
             }

      assert waiting.episode.active_input_refs == []
      assert waiting.episode.semantic_version == 2
      assert waiting.event.payload["next_wait"]["ref"] == "wait:tfc-run"

      input = EpisodeFixtures.admit_input(%{native_input_id: "slack:new-run-notification"})
      assert {:ok, queued} = Reducer.decide(admitted.episode, input)

      assert {:error, :queued_inputs_prevent_wait} =
               Reducer.decide(queued.episode, result)
    end

    test "an empty next-turn reference cannot strand queued input" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      followup =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:Ev-next",
          payload: %{"text" => "continue"}
        })

      assert {:ok, queued} = Reducer.decide(admitted.episode, followup)

      result =
        EpisodeFixtures.accept_result(%{
          decision_reason: "queued source revision needs a turn",
          delivery: :none,
          delivery_ref: nil,
          next_turn_ref: ""
        })

      assert Reducer.decide(queued.episode, result) ==
               {:error, {:invalid_command, :next_turn_ref}}
    end

    test "only a settled result may start immediate host verification without queued input" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      reply = EpisodeFixtures.accept_result(%{next_turn_ref: "turn-unused"})

      assert Reducer.decide(admitted.episode, reply) ==
               {:error, {:invalid_command, :next_turn_ref}}

      silent =
        EpisodeFixtures.accept_result(%{
          decision_reason: "the frozen wait elapsed during remote acceptance",
          delivery: :none,
          delivery_ref: nil,
          next_turn_ref: "turn-unused"
        })

      assert {:ok, verified} = Reducer.decide(admitted.episode, silent)
      assert verified.episode.state == :working
      assert verified.episode.owner_ref == "turn-unused"
      assert verified.episode.active_input_refs == []

      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      confirmation = EpisodeFixtures.confirm_delivery(%{next_turn_ref: "turn-immediate"})
      assert {:ok, immediate} = Reducer.decide(accepted.episode, confirmation)
      assert immediate.episode.state == :working
      assert immediate.episode.owner_ref == "turn-immediate"
      assert immediate.episode.active_input_refs == []
    end

    test "delivery can enter a durable wait without losing the Slack receipt transition" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      confirmation =
        EpisodeFixtures.confirm_delivery(%{
          next_wait: %{deadline_at: nil, kind: :input, ref: "question-1"}
        })

      assert {:ok, waiting} = Reducer.decide(accepted.episode, confirmation)
      assert waiting.episode.state == :waiting_for_input
      assert waiting.episode.owner_kind == :input
      assert waiting.episode.owner_ref == "question-1"
    end

    test "a silent result requires one bounded audited reason" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      missing =
        EpisodeFixtures.accept_result(%{
          decision_reason: nil,
          delivery: :none,
          delivery_ref: nil,
          result_ref: "silent-missing-reason"
        })

      assert Reducer.decide(admitted.episode, missing) ==
               {:error, {:invalid_command, :decision_reason}}

      visible = EpisodeFixtures.accept_result(%{decision_reason: "should not be present"})

      assert Reducer.decide(admitted.episode, visible) ==
               {:error, {:invalid_command, :decision_reason}}
    end

    test "a silent result can continue already queued work without delivery" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      followup =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:silent-continuation",
          payload: %{"text" => "continue with this"}
        })

      assert {:ok, queued} = Reducer.decide(admitted.episode, followup)

      result =
        EpisodeFixtures.accept_result(%{
          decision_reason: "the first input was an exact lifecycle duplicate",
          delivery: :none,
          delivery_ref: nil,
          next_turn_ref: "turn-followup",
          result_ref: "silent-then-continue"
        })

      assert {:ok, continued} = Reducer.decide(queued.episode, result)
      assert continued.episode.owner_ref == "turn-followup"
      assert continued.episode.active_input_refs == [Command.dedupe_key(followup)]
      assert continued.episode.queued_input_refs == []
    end
  end

  # Fifty-two production episodes were cancelled while active, blocked, or waiting. Stop must retire
  # their exact current custody; otherwise a late model result or Slack delivery can revive closed work.
  describe "cancellation" do
    test "an active owner can cancel the episode and no old turn can complete it" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, cancelled} = Reducer.decide(admitted.episode, EpisodeFixtures.cancel_episode())

      assert cancelled.episode.state == :cancelled
      assert cancelled.episode.owner_kind == nil
      assert cancelled.episode.owner_ref == nil
      assert cancelled.episode.active_input_refs == []
      assert cancelled.event.kind == :episode_cancelled

      assert {:error, {:stale_turn, _details}} =
               Reducer.decide(cancelled.episode, EpisodeFixtures.accept_result())

      assert Reducer.decide(cancelled.episode, EpisodeFixtures.admit_input(%{revision: 2})) ==
               {:error, :episode_cancelled}
    end

    test "cancelling a wait retires its deadline and queued trigger" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      wait =
        EpisodeFixtures.start_wait(%{
          deadline_at: ~U[2026-08-27 12:10:00.000000Z],
          kind: :event,
          wait_ref: "deployment-healthy"
        })

      assert {:ok, waiting} = Reducer.decide(admitted.episode, wait)

      trigger =
        EpisodeFixtures.admit_input(%{
          native_input_id: "slack:event:Ev-answer",
          occurred_at: ~U[2026-08-27 12:00:02.000000Z],
          payload: %{"text" => "the deployment is healthy"},
          revision: 2
        })

      assert {:ok, queued} = Reducer.decide(waiting.episode, trigger)
      assert queued.episode.owner_deadline_at == ~U[2026-08-27 12:10:00.000000Z]
      assert queued.episode.queued_input_refs == [Command.dedupe_key(trigger)]
      assert length(queued.episode.queued_input_order_keys) == 1

      cancel =
        EpisodeFixtures.cancel_episode(%{
          expected_owner: %{kind: :event, ref: "deployment-healthy"},
          occurred_at: ~U[2026-08-27 12:00:03.000000Z]
        })

      assert {:ok, cancelled} = Reducer.decide(queued.episode, cancel)
      assert cancelled.episode.state == :cancelled
      assert cancelled.episode.owner_deadline_at == nil
      assert cancelled.episode.active_input_refs == []
      assert cancelled.episode.queued_input_refs == []
      assert cancelled.episode.queued_input_order_keys == []

      resume =
        EpisodeFixtures.resume_wait(%{
          expected_wait: %{kind: :event, ref: "deployment-healthy"},
          occurred_at: ~U[2026-08-27 12:00:04.000000Z]
        })

      assert Reducer.decide(cancelled.episode, resume) ==
               {:error,
                {:stale_wait,
                 expected: %{kind: :event, ref: "deployment-healthy"},
                 actual: %{kind: nil, ref: nil}}}
    end

    test "an accepted reply must settle before cancellation can retire its episode" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      cancel =
        EpisodeFixtures.cancel_episode(%{
          expected_owner: %{kind: :delivery, ref: "slack-delivery-1"}
        })

      assert Reducer.decide(accepted.episode, cancel) ==
               {:error, :delivery_must_settle_before_cancel}

      assert {:ok, delivered} =
               Reducer.decide(accepted.episode, EpisodeFixtures.confirm_delivery())

      assert delivered.episode.state == :complete
    end

    test "an accepted reply must settle before delivery ownership can move" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())
      assert {:ok, accepted} = Reducer.decide(admitted.episode, EpisodeFixtures.accept_result())

      transfer =
        EpisodeFixtures.transfer_owner(%{
          expected_owner: %{kind: :delivery, ref: "slack-delivery-1"},
          new_owner: %{kind: :delivery, ref: "slack-delivery-2"}
        })

      assert Reducer.decide(accepted.episode, transfer) ==
               {:error, :delivery_must_settle_before_transfer}
    end

    test "cancellation is fenced to the exact durable owner" do
      assert {:ok, admitted} = Reducer.decide(nil, EpisodeFixtures.admit_input())

      stale =
        EpisodeFixtures.cancel_episode(%{
          expected_owner: %{kind: :turn, ref: "another-turn"}
        })

      assert Reducer.decide(admitted.episode, stale) ==
               {:error,
                {:stale_owner,
                 expected: %{kind: :turn, ref: "another-turn"},
                 actual: %{kind: :turn, ref: "turn-1"}}}
    end
  end
end

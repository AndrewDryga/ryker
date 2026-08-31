defmodule Responder.ControlPlane.ConversationLabTest do
  use Responder.DataCase, async: true

  alias Responder.ControlPlane.ConversationLab
  alias Responder.ControlPlane.Projection
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.WorkProfile
  alias Responder.Work.{Custody, Result, SubmissionBuilder}

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
  @event_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7"
  @now ~U[2026-08-30 18:00:00.000000Z]

  test "a local message enters ordinary ingress with host-owned routing and authority" do
    profile = profile()

    assert {:ok, %{status: :recorded, entry: entry}} =
             ConversationLab.send_message(
               @conversation_id,
               "Explain what this episode currently knows.",
               profile,
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert entry.source_kind == "control_plane"
    assert entry.source_ref == "local"
    assert entry.actor_kind == :user
    assert entry.actor_ref == "local-operator"
    assert entry.content == %{"text" => "Explain what this episode currently knows."}
    assert entry.destination_transport == "control_plane"

    assert entry.destination_conversation_ref ==
             "control-plane:lab:#{@conversation_id}"

    assert entry.destination_thread_ref == entry.destination_conversation_ref
    assert entry.work_policy == profile.policy
    assert entry.work_policy_digest == profile.policy_digest
    assert entry.repository_ref == nil
    assert {:ok, ^entry} = Inbox.fetch(Inbox.ref(entry))
  end

  test "invalid conversation IDs and empty or oversized messages fail before persistence" do
    assert ConversationLab.send_message("not-a-uuid", "hello", profile()) ==
             {:error, {:invalid_conversation_lab, :conversation_id}}

    assert ConversationLab.send_message(@conversation_id, "   ", profile()) ==
             {:error, {:invalid_conversation_lab, :message}}

    assert ConversationLab.send_message(
             @conversation_id,
             String.duplicate("x", 20_001),
             profile()
           ) == {:error, {:invalid_conversation_lab, :message}}
  end

  test "local routing and generators fail closed without widening the configured profile" do
    assert ConversationLab.conversation_ref(@conversation_id) ==
             {:ok, "control-plane:lab:#{@conversation_id}"}

    assert ConversationLab.conversation_ref("not-a-uuid") ==
             {:error, {:invalid_conversation_lab, :conversation_id}}

    assert ConversationLab.send_message(@conversation_id, "hello", %{}) ==
             {:error, {:invalid_conversation_lab, :work_profile}}

    assert ConversationLab.send_message(@conversation_id, "contains\0null", profile()) ==
             {:error, {:invalid_conversation_lab, :message}}

    for invalid_options <- [
          :not_options,
          [unknown: true],
          [now: fn -> @now end, now: fn -> @now end],
          [id_generator: :not_a_function],
          [now: :not_a_function]
        ] do
      assert ConversationLab.send_message(
               @conversation_id,
               "hello",
               profile(),
               invalid_options
             ) == {:error, {:invalid_conversation_lab, :options}}
    end

    assert ConversationLab.send_message(@conversation_id, "hello", profile(),
             id_generator: fn -> "not-a-uuid" end
           ) == {:error, {:invalid_conversation_lab, :event_id}}

    assert ConversationLab.send_message(@conversation_id, "hello", profile(),
             now: fn -> ~N[2026-08-30 18:00:00] end
           ) == {:error, {:invalid_conversation_lab, :now}}
  end

  test "the lab projects only its durable operator inputs and accepted visible replies" do
    assert {:ok, %{status: :recorded}} =
             ConversationLab.send_message(
               @conversation_id,
               "What changed in this conversation?",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    conversation_ref = "control-plane:lab:#{@conversation_id}"
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:conversation-lab:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "conversation-lab:#{@conversation_id}",
                 native_input_id: "control-plane-message:projected",
                 occurred_at: @now,
                 payload: %{"text" => "What changed in this conversation?"},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(
               transition.episode.id,
               profile().policy,
               profile().policy_digest
             )

    assert {:ok, claim} = Custody.claim_next("conversation-lab:projection", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:conversation-lab"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:conversation-lab"
             )

    candidate = ~s({"delivery":"reply","message":"The durable path is working."})
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, %{"message" => "The durable path is working."})

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, _accepted} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:conversation-lab"
             )

    assert [%{id: @conversation_id, message_count: 1}] = Projection.lab_index()

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert conversation.live
    assert conversation.pending == 1

    assert Enum.map(conversation.messages, &{&1.actor, &1.text}) == [
             {:operator, "What changed in this conversation?"},
             {:responder, "The durable path is working."}
           ]

    refute inspect(conversation) =~ candidate
    assert Projection.lab_conversation("not-a-uuid") == :not_found
  end

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    profile
  end
end

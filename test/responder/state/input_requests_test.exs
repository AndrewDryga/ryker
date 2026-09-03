defmodule Responder.State.InputRequestsTest do
  use Responder.DataCase, async: false

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.State.{InputRequests, Record, Records, Response}
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "one exact delivered question choice becomes one generic input" do
    fixture = delivered_question!()

    assert fixture.episode.state == :waiting_for_input
    assert fixture.episode.owner_ref == fixture.record.ref

    assert {:ok, answer} = InputRequests.answer(answer(fixture, 1, "answer-1"))
    assert answer.status == :recorded
    assert answer.response.choice == "Stop the rollout"
    assert answer.record.status == :answered

    assert {:ok, entry} = Inbox.fetch(answer.input_ref)
    assert entry.source_kind == "slack"
    assert entry.event_kind == :event
    assert entry.actor_ref == "U123"
    assert entry.content["choice"] == "Stop the rollout"
    assert entry.content["input_request_ref"] == fixture.record.ref
    assert entry.destination_thread_ref == "1787832000.000100"

    assert %Response{} = Repo.get_by(Response, record_id: fixture.record.id)
    assert Repo.get!(Record, fixture.record.id).status == :answered

    assert {:ok, duplicate} = InputRequests.answer(answer(fixture, 1, "answer-1"))
    assert duplicate.status == :duplicate
    assert duplicate.input_ref == answer.input_ref
    assert Repo.aggregate(Response, :count, :id) == 1

    assert InputRequests.answer(answer(fixture, 0, "answer-2")) ==
             {:error, :input_request_already_answered}
  end

  test "crossed delivery identity and stale wait ownership fail closed" do
    fixture = delivered_question!()

    crossed = put_in(answer(fixture, 0, "crossed"), [:target, :message_ref], "other-message")

    assert InputRequests.answer(crossed) == {:error, :input_request_delivery_mismatch}

    Repo.update_all(Record, set: [status: :dismissed])
    assert InputRequests.answer(answer(fixture, 0, "stale")) == {:error, :input_request_stale}
    assert Repo.aggregate(Response, :count, :id) == 0
  end

  test "a Conversation Lab choice resumes the same wait through generic ingress" do
    fixture = delivered_question!(:control_plane)

    assert {:ok, answer} =
             InputRequests.answer(
               fixture
               |> answer(0, "lab-answer-1")
               |> Map.put(:actor_ref, "local-operator")
             )

    assert answer.status == :recorded
    assert answer.response.choice == "Roll out to one percent"

    assert {:ok, entry} = Inbox.fetch(answer.input_ref)
    assert entry.source_kind == "control_plane"
    assert entry.source_ref == "local"
    assert entry.actor_kind == :user
    assert entry.actor_ref == "local-operator"
    assert entry.event_kind == :event
    assert entry.occurred_at_source == :ingress
    assert entry.source_capabilities == %{}
    assert entry.content["choice"] == "Roll out to one percent"
    assert entry.content["choice_index"] == 0
    assert entry.content["input_request_ref"] == fixture.record.ref
    assert entry.destination_transport == "control_plane"
    assert entry.destination_conversation_ref == fixture.receipt["conversation_ref"]
    assert entry.destination_thread_ref == fixture.receipt["thread_ref"]
  end

  defp delivered_question!(transport \\ :slack) do
    episode_id = Ecto.UUID.generate()
    destination = destination(transport)

    command =
      EpisodeFixtures.admit_input(%{
        destination: destination,
        episode_id: episode_id,
        episode_key: "input-request-source:#{episode_id}",
        native_input_id: "slack-message:question:#{episode_id}",
        occurred_at: @now,
        turn_ref: "turn:question:#{episode_id}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:question", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "question", "input_request", %{
               "choices" => ["Roll out to one percent", "Stop the rollout"],
               "question" => "Which rollout action should I take?"
             })

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode_id},
               "Ask the exact operator question.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:question"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:question"
             )

    candidate = ~s({"delivery":"reply","message":"Which rollout action should I take?"})
    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    delivery_document = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "I need one decision before I continue.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [record.ref],
        "state" => "waiting_for_input"
      }
    }

    assert {:ok, result} = Result.new(:reply, delivery_document, nil, record.continuation)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:question"
             )

    assert {:ok, delivery_claim} = Custody.claim_next("delivery:question", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               destination.transport,
               destination.conversation_ref,
               destination.thread_ref,
               "1787832001.000200"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{episode: settled.episode, receipt: receipt, record: record}
  end

  defp destination(:slack) do
    %{
      conversation_ref: "slack:T123:C456",
      thread_ref: "1787832000.000100",
      transport: "slack"
    }
  end

  defp destination(:control_plane) do
    conversation_ref = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    %{
      conversation_ref: conversation_ref,
      thread_ref: conversation_ref,
      transport: "control_plane"
    }
  end

  defp answer(fixture, choice_index, response_suffix) do
    %{
      actor_ref: "U123",
      choice_index: choice_index,
      occurred_at: DateTime.add(@now, 3, :second),
      record_ref: fixture.record.ref,
      response_ref: "interaction:#{response_suffix}",
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

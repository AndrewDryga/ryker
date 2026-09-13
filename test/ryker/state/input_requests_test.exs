defmodule Ryker.State.InputRequestsTest do
  use Ryker.DataCase, async: false

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Slack.InteractionAudit
  alias Ryker.State.{InputRequests, Record, Records, Response}
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

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

    repaint = Repo.get_by(InteractionAudit, event_ref: entry.event_ref)

    assert repaint,
           "a choice answer must retire its controls even if Socket Mode exits after commit"

    assert repaint.action_id == "choice_question_answer"
    assert repaint.repaint_status == :pending
    assert repaint.message_ref == fixture.receipt["message_ref"]

    assert %Response{} = Repo.get_by(Response, record_id: fixture.record.id)
    assert Repo.get!(Record, fixture.record.id).status == :answered

    assert {:ok, duplicate} = InputRequests.answer(answer(fixture, 1, "answer-1"))
    assert duplicate.status == :duplicate
    assert duplicate.input_ref == answer.input_ref
    assert Repo.aggregate(Response, :count, :id) == 1
    assert Repo.aggregate(InteractionAudit, :count, :id) == 1

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

  test "a question delivered to a joined input's origin thread can be answered from that thread" do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    fixture = delivered_question!(:slack, "1787832500.000700")

    assert fixture.episode.destination_thread_ref == "1787832000.000100"
    assert fixture.receipt["thread_ref"] == "1787832500.000700"

    assert {:ok, answer} = InputRequests.answer(answer(fixture, 1, "routed"))
    assert answer.status == :recorded
    assert answer.response.choice == "Stop the rollout"

    assert {:ok, entry} = Inbox.fetch(answer.input_ref)
    assert entry.destination_thread_ref == "1787832500.000700"

    # The control is still only answerable where it was delivered.
    elsewhere =
      put_in(
        answer(fixture, 0, "routed-elsewhere"),
        [:target, :thread_ref],
        fixture.episode.destination_thread_ref
      )

    assert InputRequests.answer(elsewhere) == {:error, :input_request_delivery_mismatch}
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

  test "typed answer association keeps one original without inventing a selected choice" do
    fixture = delivered_question!()
    entry = typed_answer!(fixture)

    assert {:error, :state_record_transaction_required} =
             InputRequests.associate_in_transaction(fixture.episode, entry)

    assert Repo.aggregate(Response, :count) == 0
    associate!(fixture, entry)
    associate!(fixture, entry)

    response = Repo.get_by!(Response, record_id: fixture.record.id)
    assert response.inbox_entry_id == entry.id
    assert is_nil(response.choice)
    assert is_nil(response.choice_index)
    assert Repo.aggregate(Response, :count) == 1
    assert Repo.get!(Record, fixture.record.id).status == :open
    assert Repo.aggregate(Ryker.State.MemoryEntry, :count) == 0
  end

  test "a bot, another thread, or a pre-question message cannot supply a typed answer" do
    fixture = delivered_question!()

    for attributes <- [
          %{actor: %{kind: :bot, ref: "B123"}},
          %{thread_ref: "1787832000.000999"},
          %{occurred_at: @now}
        ] do
      entry = typed_answer!(fixture, attributes)
      associate!(fixture, entry)
      assert Repo.aggregate(Response, :count) == 0
    end
  end

  test "a later typed reply does not overwrite an already accepted button answer" do
    fixture = delivered_question!()
    assert {:ok, accepted} = InputRequests.answer(answer(fixture, 1, "selected"))
    entry = typed_answer!(fixture)
    associate!(fixture, entry)
    assert Repo.get_by!(Response, record_id: fixture.record.id) == accepted.response
  end

  defp associate!(fixture, entry) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               InputRequests.associate_in_transaction(fixture.episode, entry)
             end)
  end

  defp typed_answer!(fixture, overrides \\ %{}) do
    attributes = %{
      actor: %{kind: :user, ref: "U123"},
      channel_ref: "C456",
      content: %{"text" => "Use one percent, then verify before expanding."},
      event_kind: :message,
      event_ref: "answer:#{Ecto.UUID.generate()}",
      message_ref: "1787832002.000300",
      occurred_at: DateTime.add(DateTime.utc_now(), 1),
      revision: 1,
      thread_ref: fixture.episode.destination_thread_ref,
      workspace_ref: "T123"
    }

    assert {:ok, input} = SlackInput.new(Map.merge(attributes, overrides))
    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp delivered_question!(transport \\ :slack, delivery_thread_ref \\ nil) do
    episode_id = Ecto.UUID.generate()
    destination = destination(transport)
    delivery_thread_ref = delivery_thread_ref || destination.thread_ref

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
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

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

    # Where this turn's question goes, exactly as `Custody.reply_target/2`
    # freezes it at acceptance: the answering input's own origin, which routing
    # can join into this episode from a thread other than its bound home.
    Repo.get_by!(Turn, episode_id: episode_id, turn_ref: turn.turn_ref)
    |> Ecto.Changeset.change(
      delivery_target: %{
        "conversation_ref" => destination.conversation_ref,
        "thread_ref" => delivery_thread_ref,
        "transport" => destination.transport
      }
    )
    |> Repo.update!()

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               destination.transport,
               destination.conversation_ref,
               delivery_thread_ref,
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

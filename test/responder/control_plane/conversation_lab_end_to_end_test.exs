defmodule Responder.ControlPlane.ConversationLabEndToEndTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Responder.Admission.Dispatcher, as: AdmissionDispatcher
  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{ConversationLab, Projection, Publisher}
  alias Responder.Delivery.Adapters
  alias Responder.Episodes.Episode
  alias Responder.Ingress.WorkProfile
  alias Responder.Repo
  alias Responder.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}
  alias Responder.Work.{Session, Turn}

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
  @first_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7"
  @second_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e8"
  @now ~U[2026-08-30 18:00:00.000000Z]
  @digest String.duplicate("a", 64)

  test "a local conversation uses the complete durable product path and continues one session" do
    assert {:ok, %{status: :recorded}} =
             send_message(
               @first_event_id,
               @now,
               "Explain what the durable runtime knows about this request."
             )

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, first_admission}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    episode = first_admission.result.episode
    assert episode.destination_transport == "control_plane"
    assert episode.destination_conversation_ref == conversation_ref()
    assert episode.destination_thread_ref == conversation_ref()

    {:ok, work} =
      FakeWorkCoopAPI.start_link(
        [
          work_reply("The first durable response is ready."),
          work_reply("The follow-up continued the same episode and Coop session.")
        ],
        on_validation_reject: fn violations ->
          raise "unexpected conversation-lab semantic rejection: #{inspect(violations)}"
        end
      )

    assert {:ok, {:executed, first_execution}} =
             Responder.Work.Dispatcher.run_once(work_options(work, "first"))

    assert first_execution.status == :accepted
    assert first_execution.turn.status == :delivery_pending
    first_session_id = first_execution.turn.session_id

    assert %Session{
             policy: "conversation-read",
             policy_digest: @digest,
             repository_ref: nil
           } = Repo.get!(Session, first_session_id)

    assert {:ok, {:delivered, :message, first_delivery_ref}} =
             Responder.Delivery.Dispatcher.run_once(delivery_options("first"))

    assert %Turn{status: :settled, external_receipt: first_receipt} =
             Repo.get!(Turn, first_execution.turn.id)

    assert first_receipt["delivery_ref"] == first_delivery_ref
    assert first_receipt["transport"] == "control_plane"
    assert first_receipt["conversation_ref"] == conversation_ref()

    assert {:ok, %{status: :recorded}} =
             send_message(
               @second_event_id,
               DateTime.add(@now, 60, :second),
               "Use the previous answer and tell me what persisted across the turn."
             )

    candidate_ref =
      "candidate:" <> CanonicalJSON.digest(["ingress-admission-candidate", episode.id])

    {:ok, follow_up_admission} =
      FakeCoopAPI.start_link([decision(:continue_episode, candidate_ref)])

    assert {:ok, {:decided, second_admission}} =
             AdmissionDispatcher.run_once(
               admission_options(follow_up_admission, DateTime.add(@now, 60, :second))
             )

    assert second_admission.result.entry.decision_action == :continue_episode
    assert second_admission.result.episode.id == episode.id

    assert {:ok, {:executed, second_execution}} =
             Responder.Work.Dispatcher.run_once(work_options(work, "second"))

    assert second_execution.status == :accepted
    assert second_execution.turn.session_id == first_session_id

    assert {:ok, {:delivered, :message, _second_delivery_ref}} =
             Responder.Delivery.Dispatcher.run_once(delivery_options("second"))

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)

    assert Enum.map(conversation.messages, &{&1.actor, &1.text}) == [
             {:operator, "Explain what the durable runtime knows about this request."},
             {:responder, "The first durable response is ready."},
             {:operator, "Use the previous answer and tell me what persisted across the turn."},
             {:responder, "The follow-up continued the same episode and Coop session."}
           ]

    assert [%{id: @conversation_id, message_count: 2}] = Projection.lab_index()
    refute conversation.live
    assert conversation.pending == 0

    turns =
      Repo.all(
        from(turn in Turn,
          where: turn.episode_id == ^episode.id,
          order_by: [asc: turn.inserted_at, asc: turn.id]
        )
      )

    assert [first_turn, second_turn] = turns
    assert first_turn.submission["context"]["mode"] == "full"
    assert second_turn.submission["context"]["mode"] == "continuation"

    assert second_turn.submission["context"]["parent_submission_ref"] ==
             first_turn.submission_fingerprint

    assert Repo.aggregate(
             from(session in Session, where: session.episode_id == ^episode.id),
             :count
           ) ==
             1

    assert %Episode{state: :complete} = Repo.get!(Episode, episode.id)
    assert FakeWorkCoopAPI.state(work).submit_count == 2
    assert FakeCoopAPI.state(admission).submit_count == 1
    assert FakeCoopAPI.state(follow_up_admission).submit_count == 1
  end

  defp send_message(event_id, now, message) do
    ConversationLab.send_message(@conversation_id, message, profile(),
      id_generator: fn -> event_id end,
      now: fn -> now end
    )
  end

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: @digest,
        repository_ref: nil
      })

    profile
  end

  defp admission_options(fake, now) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: fake,
        max_polls: 10,
        now: fn -> now end,
        policy: "admission-read-only",
        policy_digest: @digest,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "conversation-lab-admission:#{DateTime.to_unix(now)}"
    ]
  end

  defp work_options(fake, suffix) do
    [
      executor_options: [
        api: FakeWorkCoopAPI,
        client: fake,
        max_block_ms: 1_000,
        max_polls: 20,
        monotonic_ms: fn -> 0 end,
        now: fn -> @now end,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "conversation-lab-work:#{suffix}"
    ]
  end

  defp delivery_options(suffix) do
    {:ok, adapters} =
      Adapters.new(%{
        "control_plane" => %{
          binding: nil,
          message_publisher: Publisher,
          reaction_publisher: Publisher
        }
      })

    [
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "conversation-lab-delivery:#{suffix}"
    ]
  end

  defp decision(:start_episode, nil) do
    Jason.encode!(%{
      "action" => "start_episode",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "The first local message starts one durable conversation episode."
    })
  end

  defp decision(:continue_episode, candidate_ref) do
    Jason.encode!(%{
      "action" => "continue_episode",
      "episode_ref" => candidate_ref,
      "reaction" => nil,
      "relation" => "same_work",
      "reason" => "The local follow-up explicitly depends on the prior answer in this thread."
    })
  end

  defp work_reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp conversation_ref, do: "control-plane:lab:#{@conversation_id}"
end

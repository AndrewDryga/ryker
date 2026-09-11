defmodule Responder.Slack.EndToEndTest do
  use Responder.DataCase, async: true

  # A suite-owned workspace keeps conversation locks out of other async fixtures.

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission.Dispatcher, as: AdmissionDispatcher
  alias Responder.Delivery.{Adapters, Dispatcher}
  alias Responder.Ingress.Inbox
  alias Responder.Repo

  alias Responder.Slack.{
    Engagement,
    Gateway,
    InteractionAudit,
    InteractionHandler,
    InteractionRepaint,
    Publisher
  }

  alias Responder.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}
  alias Responder.Work.{Final, Session, Turn}

  @now ~U[2026-08-27 12:00:01.000200Z]
  @policy_digest String.duplicate("a", 64)

  defmodule Directory do
    @behaviour Responder.Slack.MemberDirectory

    @impl true
    def user_allowed(_client, "U123", "TSLACKENDTOEND"), do: {:ok, true}
  end

  defmodule SlackAPI do
    @behaviour Responder.Slack.API

    def start_link(test_pid), do: Agent.start_link(fn -> test_pid end)

    @impl true
    def find_message(_client, _channel, _thread, _delivery_ref), do: :not_found

    @impl true
    def post_message(agent, channel, thread, document, delivery_ref) do
      send(Agent.get(agent, & &1), {:posted, channel, thread, document, delivery_ref})
      {:ok, "1787832002.000300"}
    end

    @impl true
    def update_message(agent, channel, message_ref, document, delivery_ref) do
      send(Agent.get(agent, & &1), {:updated, channel, message_ref, document, delivery_ref})
      :ok
    end

    @impl true
    def find_files(_client, _channel, _thread, _filenames), do: :not_found

    @impl true
    def upload_files(_client, _channel, _thread, _body, _delivery_ref, _files),
      do: {:error, :not_used}

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  test "an authorized Slack mention reaches one validated turn and exactly its bound thread" do
    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(envelope(), gateway_settings())

    assert {:ok, entry} = Inbox.fetch(input_ref)
    assert entry.source_kind == "slack"
    assert entry.destination_conversation_ref == "slack:TSLACKENDTOEND:C456"
    assert entry.destination_thread_ref == "1787832001.000200"
    assert entry.work_policy == "conversation-read-only"
    assert entry.work_policy_digest == @policy_digest

    {:ok, admission} = FakeCoopAPI.start_link([admission_decision()])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission))

    assert admitted.result.entry.id == entry.id
    assert admitted.result.episode.destination_conversation_ref == "slack:TSLACKENDTOEND:C456"
    assert admitted.result.episode.destination_thread_ref == "1787832001.000200"

    assert %Session{policy: "conversation-read-only", policy_digest: policy_digest} =
             Repo.get_by!(Session, episode_id: admitted.result.episode.id)

    assert policy_digest == @policy_digest

    {:ok, work} =
      FakeWorkCoopAPI.start_link([
        work_reply("Checkout is healthy; the transient errors cleared after the rollout."),
        work_reply("Yes — I also checked the worker pool, and it has remained stable.")
      ])

    assert {:ok, {:executed, execution}} =
             Responder.Work.Dispatcher.run_once(work_options(work))

    assert execution.turn.status == :delivery_pending
    assert [submission] = FakeWorkCoopAPI.state(work).submissions
    assert submission.schema == Final.json_schema()

    assert [current] = execution.turn.submission["context"]["inputs"]["items"]

    assert current["content"]["content"]["text"] ==
             "<@UBOT> investigate checkout errors"

    {:ok, slack} = SlackAPI.start_link(self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TSLACKENDTOEND" => %{api: SlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    assert {:ok, {:delivered, :message, delivery_ref}} =
             Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "slack-delivery-e2e"
             )

    assert_receive {
      :posted,
      "C456",
      "1787832001.000200",
      %{"message" => "Checkout is healthy; the transient errors cleared after the rollout."},
      ^delivery_ref
    }

    assert %Turn{status: :settled, external_receipt: receipt} =
             Repo.get!(Turn, execution.turn.id)

    assert receipt["conversation_ref"] == "slack:TSLACKENDTOEND:C456"
    assert receipt["thread_ref"] == "1787832001.000200"
    assert receipt["message_ref"] == "1787832002.000300"

    audit = %InteractionAudit{
      workspace_ref: "TSLACKENDTOEND",
      channel_ref: "C456",
      thread_ref: "1787832001.000200",
      message_ref: "1787832002.000300"
    }

    assert :ok = InteractionRepaint.repaint(audit, %{api: SlackAPI, client: slack})

    assert_receive {
      :updated,
      "C456",
      "1787832002.000300",
      %{"message" => "Checkout is healthy; the transient errors cleared after the rollout."},
      ^delivery_ref
    }

    turn = Repo.get!(Turn, execution.turn.id)

    assert %Turn{} =
             turn
             |> Ecto.Changeset.change(delivery_document: %{"message" => "Rebuilt reply."})
             |> Repo.update!()

    assert :ok = InteractionRepaint.repaint(audit, %{api: SlackAPI, client: slack})

    assert_receive {
      :updated,
      "C456",
      "1787832002.000300",
      %{"message" => "Rebuilt reply."},
      ^delivery_ref
    }

    assert %Turn{} =
             turn
             |> Ecto.Changeset.change(delivery_document: %{"unexpected" => true})
             |> Repo.update!()

    assert InteractionRepaint.repaint(audit, %{api: SlackAPI, client: slack}) ==
             {:error, :slack_interaction_repaint_document_invalid}

    assert {:ack, {:recorded, followup_ref}} =
             Gateway.handle_envelope(followup_envelope(), gateway_settings())

    assert {:ok, followup_entry} = Inbox.fetch(followup_ref)
    assert followup_entry.destination_conversation_ref == "slack:TSLACKENDTOEND:C456"
    assert followup_entry.destination_thread_ref == "1787832001.000200"
    assert followup_entry.work_policy == "conversation-read-only"

    candidate_ref =
      "candidate:" <>
        Responder.CanonicalJSON.digest([
          "ingress-admission-candidate",
          admitted.result.episode.id
        ])

    {:ok, followup_admission} =
      FakeCoopAPI.start_link([followup_decision(candidate_ref)])

    assert {:ok, {:decided, continued}} =
             AdmissionDispatcher.run_once(admission_options(followup_admission))

    assert continued.result.entry.id == followup_entry.id
    assert continued.result.episode.id == admitted.result.episode.id
    assert continued.result.episode.destination_thread_ref == "1787832001.000200"
    assert Repo.aggregate(Session, :count, :id) == 1

    assert {:ok, {:executed, continuation}} =
             Responder.Work.Dispatcher.run_once(work_options(work))

    assert continuation.turn.session_id == execution.turn.session_id
    assert continuation.turn.submission["context"]["mode"] == "continuation"

    assert [current] = continuation.turn.submission["context"]["current_inputs"]["items"]
    assert current["content"]["content"]["text"] == "Did you check the worker pool too?"

    work_state = FakeWorkCoopAPI.state(work)
    assert work_state.create_count == 1
    assert work_state.submit_count == 2

    assert {:ok, {:delivered, :message, continuation_delivery_ref}} =
             Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "slack-delivery-e2e-continuation"
             )

    assert_receive {
      :posted,
      "C456",
      "1787832001.000200",
      %{"message" => "Yes — I also checked the worker pool, and it has remained stable."},
      ^continuation_delivery_ref
    }

    assert %Turn{status: :settled, external_receipt: continuation_receipt} =
             Repo.get!(Turn, continuation.turn.id)

    assert continuation_receipt["conversation_ref"] == "slack:TSLACKENDTOEND:C456"
    assert continuation_receipt["thread_ref"] == "1787832001.000200"

    assert {:ok, :idle} =
             Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "slack-delivery-e2e-second"
             )

    refute_receive {:posted, _channel, _thread, _document, _ref}
  end

  defp gateway_settings do
    %{
      client: :directory,
      continuation: &Engagement.continuation?/1,
      directory: Directory,
      identity: %{bot_ref: "B-BOT", bot_user_ref: "UBOT", workspace_ref: "TSLACKENDTOEND"},
      inbox: Inbox,
      interaction_handler: InteractionHandler,
      interaction_options: %{},
      effective_settings: &installation_participation/2,
      work_profile: fn "TSLACKENDTOEND", "slack:TSLACKENDTOEND:C456" ->
        {:ok,
         %{
           policy: "conversation-read-only",
           policy_digest: @policy_digest,
           repository_ref: "responder"
         }}
      end
    }
  end

  defp envelope do
    %{
      "envelope_id" => "env-slack-e2e",
      "payload" => %{
        "event" => %{
          "channel" => "C456",
          "event_ts" => "1787832001.000200",
          "text" => "<@UBOT> investigate checkout errors",
          "ts" => "1787832001.000200",
          "type" => "app_mention",
          "user" => "U123"
        },
        "event_id" => "Ev-slack-e2e",
        "event_time" => 1_787_832_001,
        "team_id" => "TSLACKENDTOEND",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp followup_envelope do
    %{
      "envelope_id" => "env-slack-e2e-followup",
      "payload" => %{
        "event" => %{
          "channel" => "C456",
          "event_ts" => "1787832003.000400",
          "text" => "Did you check the worker pool too?",
          "thread_ts" => "1787832001.000200",
          "ts" => "1787832003.000400",
          "type" => "message",
          "user" => "U123"
        },
        "event_id" => "Ev-slack-e2e-followup",
        "event_time" => 1_787_832_003,
        "team_id" => "TSLACKENDTOEND",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp admission_options(fake) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: fake,
        max_polls: 10,
        now: fn -> @now end,
        policy: "admission-read-only",
        policy_digest: @policy_digest,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> @now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "slack-admission-e2e"
    ]
  end

  defp work_options(fake) do
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
      worker_ref: "slack-work-e2e"
    ]
  end

  defp admission_decision do
    Jason.encode!(%{
      "action" => "start_episode",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "The direct mention requests an investigation.",
      "work_class" => "standard"
    })
  end

  defp followup_decision(candidate_ref) do
    Jason.encode!(%{
      "action" => "continue_episode",
      "episode_ref" => candidate_ref,
      "reaction" => nil,
      "relation" => "same_work",
      "reason" => "This unmentioned reply belongs to the exact existing Slack thread.",
      "work_class" => "standard"
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

  defp installation_participation(_workspace_ref, _conversation_ref) do
    %{
      proactive: %{source: :installation, value: false},
      shadow: %{source: :installation, value: false}
    }
  end
end

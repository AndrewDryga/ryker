defmodule Responder.Slack.QuestionEndToEndTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission.Dispatcher, as: AdmissionDispatcher
  alias Responder.Delivery.{Adapters, Dispatcher}
  alias Responder.Episodes
  alias Responder.Ingress.Inbox
  alias Responder.Repo
  alias Responder.Slack.{Engagement, Gateway, InteractionHandler, Publisher}
  alias Responder.State.{Record, Records}
  alias Responder.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}
  alias Responder.Work.{Custody, Executor, Session, Turn}

  @now ~U[2026-08-31 12:00:01.000200Z]
  @policy_digest String.duplicate("a", 64)

  defmodule Directory do
    @behaviour Responder.Slack.MemberDirectory

    @impl true
    def user_allowed(_client, "U123", "T123"), do: {:ok, true}
  end

  defmodule SlackAPI do
    @behaviour Responder.Slack.API

    def start_link(test_pid), do: Agent.start_link(fn -> %{count: 0, test_pid: test_pid} end)

    @impl true
    def find_message(_client, _channel, _thread, _delivery_ref), do: :not_found

    @impl true
    def post_message(agent, channel, thread, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        message_ref =
          case state.count do
            0 -> "1788264002.000300"
            1 -> "1788264005.000600"
          end

        send(state.test_pid, {:posted, channel, thread, document, delivery_ref, message_ref})
        {{:ok, message_ref}, %{state | count: state.count + 1}}
      end)
    end

    @impl true
    def update_message(_client, _channel, _message_ref, _document, _delivery_ref), do: :ok

    @impl true
    def find_files(_client, _channel, _thread, _filenames), do: :not_found

    @impl true
    def upload_files(_client, _channel, _thread, _body, _delivery_ref, _files),
      do: {:error, :not_used}

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  test "an ordinary Slack answer resumes one delivered question in the same Work session" do
    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(initial_envelope(), gateway_settings())

    {:ok, admission_api} = FakeCoopAPI.start_link([start_decision()])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission_api, "initial"))

    assert admitted.result.entry.id == input_id(input_ref)
    episode = admitted.result.episode

    assert {:ok, work_claim} = Custody.claim_next("slack-question-work", 60, :work)
    assert work_claim.episode.id == episode.id

    assert {:ok, request} =
             Records.create(Records.token(work_claim.turn), "rollout-choice", "input_request", %{
               "choices" => [],
               "question" => "Which rollout percentage should I use?"
             })

    {:ok, work_api} =
      FakeWorkCoopAPI.start_link([
        question_reply(request.ref),
        final_reply("I will use one percent and verify the rollout before expanding it.")
      ])

    assert {:ok, question} = Executor.run(work_claim, executor_options(work_api))
    assert question.turn.status == :delivery_pending

    {:ok, slack_api} = SlackAPI.start_link(self())
    adapters = adapters!(slack_api)

    assert {:ok, {:delivered, :message, question_delivery_ref}} =
             deliver_once(adapters, "question")

    assert_receive {
      :posted,
      "C456",
      "1788264001.000200",
      %{"message" => "Which rollout percentage should I use?"},
      ^question_delivery_ref,
      "1788264002.000300"
    }

    assert {:ok, waiting} = Episodes.fetch_by_key(episode.key)
    assert waiting.state == :waiting_for_input
    assert waiting.owner_kind == :input
    assert waiting.owner_ref == request.ref
    assert {:ok, nil} = Custody.claim_next("slack-question-no-work", 60, :work)

    assert {:ack, {:ignored, :not_engaged}} =
             Gateway.handle_envelope(unrelated_thread_envelope(), gateway_settings())

    events = Episodes.list_events(episode.key)
    wait_event = Enum.find(events, &(&1.kind == :delivery_confirmed))
    assert get_in(wait_event.payload, ["next_wait", "ref"]) == request.ref

    assert {:ack, {:recorded, answer_ref}} =
             Gateway.handle_envelope(answer_envelope(wait_event.occurred_at), gateway_settings())

    {:ok, answer_entry} = Inbox.fetch(answer_ref)
    assert answer_entry.destination_thread_ref == "1788264001.000200"
    assert answer_entry.content["text"] == "Use one percent, then verify before expanding."

    assert DateTime.compare(answer_entry.occurred_at, wait_event.occurred_at) == :gt

    {:ok, answer_admission_api} =
      FakeCoopAPI.start_link([continue_decision(candidate_ref(episode.id))])

    assert {:ok, {:decided, resumed}} =
             AdmissionDispatcher.run_once(admission_options(answer_admission_api, "answer"))

    assert resumed.result.episode.id == episode.id
    assert resumed.result.episode.state == :working
    assert Repo.get!(Record, request.id).status == :answered

    assert {:ok, continuation_claim} =
             Custody.claim_next("slack-question-continuation", 60, :work)

    assert continuation_claim.episode.id == episode.id
    assert continuation_claim.session.id == work_claim.session.id
    assert continuation_claim.turn.id != work_claim.turn.id

    assert {:ok, final} = Executor.run(continuation_claim, executor_options(work_api))
    assert final.turn.status == :delivery_pending

    [question_submission, answer_submission] = FakeWorkCoopAPI.state(work_api).submissions
    assert question_submission.prompt =~ "Which rollout percentage should I use?"
    assert answer_submission.prompt =~ "Use one percent, then verify before expanding."

    assert answer_submission.prompt =~ request.ref
    assert Repo.aggregate(Session, :count, :id) == 1
    assert FakeWorkCoopAPI.state(work_api).create_count == 1

    assert {:ok, {:delivered, :message, final_delivery_ref}} =
             deliver_once(adapters, "answer")

    assert_receive {
      :posted,
      "C456",
      "1788264001.000200",
      %{"message" => "I will use one percent and verify the rollout before expanding it."},
      ^final_delivery_ref,
      "1788264005.000600"
    }

    assert %Turn{status: :settled, session_id: session_id} = Repo.get!(Turn, final.turn.id)
    assert session_id == work_claim.session.id
    assert {:ok, :idle} = deliver_once(adapters, "idle")
  end

  defp adapters!(slack_api) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"T123" => %{api: SlackAPI, client: slack_api}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    adapters
  end

  defp deliver_once(adapters, suffix) do
    Dispatcher.run_once(
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "slack-question-delivery-#{suffix}"
    )
  end

  defp gateway_settings do
    %{
      client: :directory,
      continuation: &Engagement.continuation?/1,
      directory: Directory,
      identity: %{bot_ref: "B-BOT", bot_user_ref: "U-BOT", workspace_ref: "T123"},
      inbox: Inbox,
      interaction_handler: InteractionHandler,
      interaction_options: %{},
      watch_channels: MapSet.new(),
      work_profile: fn "T123", "slack:T123:C456" ->
        {:ok,
         %{
           policy: "conversation-read-only",
           policy_digest: @policy_digest,
           repository_ref: "responder"
         }}
      end
    }
  end

  defp initial_envelope do
    envelope(
      "initial",
      "Ev-slack-question-initial",
      "1788264001.000200",
      nil,
      "<@U-BOT> help me choose a safe rollout percentage"
    )
  end

  defp answer_envelope(wait_occurred_at) do
    envelope(
      "answer",
      "Ev-slack-question-answer",
      wait_occurred_at |> DateTime.add(1, :second) |> slack_timestamp(),
      "1788264001.000200",
      "Use one percent, then verify before expanding."
    )
  end

  defp unrelated_thread_envelope do
    envelope(
      "unrelated",
      "Ev-slack-question-unrelated",
      "1788264002.000400",
      "1788263999.000100",
      "Use fifty percent."
    )
  end

  defp envelope(suffix, event_id, message_ref, thread_ref, text) do
    [event_seconds | _fraction] = String.split(message_ref, ".", parts: 2)

    event = %{
      "channel" => "C456",
      "event_ts" => message_ref,
      "text" => text,
      "ts" => message_ref,
      "type" => if(is_nil(thread_ref), do: "app_mention", else: "message"),
      "user" => "U123"
    }

    event = if thread_ref, do: Map.put(event, "thread_ts", thread_ref), else: event

    %{
      "envelope_id" => "env-slack-question-#{suffix}",
      "payload" => %{
        "event" => event,
        "event_id" => event_id,
        "event_time" => String.to_integer(event_seconds),
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp admission_options(api, suffix) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: api,
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
      worker_ref: "slack-question-admission-#{suffix}"
    ]
  end

  defp executor_options(api) do
    [
      api: FakeWorkCoopAPI,
      client: api,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      now: fn -> @now end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp start_decision do
    Jason.encode!(%{
      "action" => "start_episode",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "The direct mention asks Responder to choose a rollout plan.",
      "work_class" => "standard"
    })
  end

  defp continue_decision(candidate_ref) do
    Jason.encode!(%{
      "action" => "continue_episode",
      "episode_ref" => candidate_ref,
      "reaction" => nil,
      "relation" => "same_work",
      "reason" => "This authorized answer belongs to the exact delivered question thread.",
      "work_class" => "standard"
    })
  end

  defp question_reply(record_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Which rollout percentage should I use?",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [record_ref],
        "state" => "waiting_for_input"
      }
    })
  end

  defp final_reply(message) do
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

  defp candidate_ref(episode_id) do
    "candidate:" <>
      Responder.CanonicalJSON.digest(["ingress-admission-candidate", episode_id])
  end

  defp slack_timestamp(datetime) do
    microseconds = DateTime.to_unix(datetime, :microsecond)
    seconds = div(microseconds, 1_000_000)
    fraction = microseconds |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    Integer.to_string(seconds) <> "." <> fraction
  end

  defp input_id("ingress-input:" <> id), do: id
end

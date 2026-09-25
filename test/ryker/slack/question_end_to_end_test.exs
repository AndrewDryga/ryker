defmodule Ryker.Slack.QuestionEndToEndTest do
  use Ryker.DataCase, async: true

  # A suite-owned workspace keeps conversation locks out of other async fixtures.

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Ryker.Admission.Dispatcher, as: AdmissionDispatcher
  alias Ryker.Delivery.{Adapters, Dispatcher}
  alias Ryker.Episodes
  alias Ryker.Ingress.Inbox
  alias Ryker.Repo
  alias Ryker.Slack.{Engagement, Gateway, InteractionHandler, Publisher}
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Slack.{InteractionAudit, InteractionFeedbackWorker}

  alias Ryker.State.{
    EventSubscription,
    EventSubscriptions,
    InputRequests,
    KnowledgeSnapshot,
    Memories,
    MemoryEntry,
    Record,
    Records,
    Response
  }

  alias Ryker.StateTools.{Router, Tools}
  alias Ryker.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}
  alias Ryker.Work.{Custody, Executor, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-31 12:00:01.000200Z]
  @policy_digest String.duplicate("a", 64)

  defmodule Directory do
    @behaviour Ryker.Slack.MemberDirectory

    @impl true
    def user_allowed(_client, "U123", "TQUESTIONENDTOEND"), do: {:ok, true}
  end

  defmodule SlackAPI do
    @behaviour Ryker.Slack.API
    alias Ryker.Slack.Renderer

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
    def update_message(client, channel, message_ref, document, _delivery_ref) do
      with {:ok, rendered} <- Renderer.render(document) do
        send(Agent.get(client, & &1.test_pid), {:updated, channel, message_ref, rendered})
        :ok
      end
    end

    @impl true
    def find_files(_client, _channel, _thread, _filenames), do: :not_found

    @impl true
    def upload_files(_client, _channel, _thread, _body, _delivery_ref, _files),
      do: {:error, :not_used}

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  test "an ordinary Slack answer resumes one delivered question in the same Work session" do
    exercise_question(:typed)
  end

  test "native radio submission saves the exact answer and resumes the same Work session" do
    exercise_question(:choice)
  end

  defp exercise_question(answer_kind) do
    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(initial_envelope(), gateway_settings())

    {:ok, admission_api} = FakeCoopAPI.start_link([start_decision()])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission_api, "initial"))

    assert admitted.result.entry.id == input_id(input_ref)
    episode = admitted.result.episode

    assert {:ok, work_claim} = Custody.claim_next("slack-question-work", 60, :work)
    assert work_claim.episode.id == episode.id

    # This fixture pre-creates a model tool result. Normal Executor exposure
    # precedes tools; initialize that empty custody before the synthetic record,
    # never retrospectively attest a transcript that already produced records.
    assert :ok = KnowledgeSnapshot.expose(work_claim, [])

    # The reported missing-project question must not discard the exact Terraform
    # watch while the user supplies the fact. Use its retained run identity.
    reported =
      "testdata/work/missing-project-clarification.json" |> File.read!() |> Jason.decode!()

    content = reported["inputs"]["rows"] |> hd() |> Enum.at(4)

    matcher = %{
      "bot_id" => content["bot_id"],
      "attachments" => [%{"title" => hd(content["attachments"])["title"]}]
    }

    assert {:ok, watch} =
             Records.create(Records.token(work_claim.turn), "run-watch", "event_wait", %{
               "deadline_at" => nil,
               "event_matcher" => %{
                 "type" => "source_event",
                 "source_kind" => "slack",
                 "match" => matcher,
                 "poll_after" => nil,
                 "on_timeout" => nil
               },
               "kind" => "source_event",
               "verification" => "Read the exact run and report material changes."
             })

    assert {:ok, request} =
             Records.create(Records.token(work_claim.turn), "rollout-choice", "input_request", %{
               "choices" => ["0.1%", "0.2%", "0.3%", "0.4%", "0.5%", "Stop", "One percent"],
               "question" => "Which rollout percentage should I use?",
               "remember" => %{
                 "subject" => "Initial rollout percentage",
                 "applicability" => "Ryker canary deployments"
               }
             })

    {:ok, work_api} =
      FakeWorkCoopAPI.start_link([
        question_reply(request.ref, watch.ref),
        final_reply(
          "I will use one percent and verify the rollout before expanding it.",
          watch.ref
        )
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
    subscription = Repo.get_by(EventSubscription, record_id: watch.id)
    assert subscription, "asking a question must retain the independent source-event watch"
    assert subscription.status == :active
    assert subscription.matcher == matcher
    assert {:ok, 0} = EventSubscriptions.reconcile()
    assert Repo.get!(EventSubscription, subscription.id).status == :active
    Repo.delete!(subscription)
    assert {:ok, 1} = EventSubscriptions.reconcile()
    subscription = Repo.get_by!(EventSubscription, record_id: watch.id)
    assert {:ok, nil} = Custody.claim_next("slack-question-no-work", 60, :work)

    assert {:ack, {:ignored, :not_engaged}} =
             Gateway.handle_envelope(unrelated_thread_envelope(), gateway_settings())

    events = Episodes.list_events(episode.key)
    wait_event = Enum.find(events, &(&1.kind == :delivery_confirmed))
    assert get_in(wait_event.payload, ["next_wait", "ref"]) == request.ref

    # A real retained TFC notification can arrive while the question is open.
    # It is contextual input, not an answer, and must reach resumed Work intact.
    assert {:ok, source_update} =
             SlackInput.new(%{
               actor: %{kind: :bot, ref: content["bot_id"]},
               channel_ref: "C456",
               content: content,
               event_kind: :message,
               event_ref: "question-run-update",
               message_ref: "1788264003.000400",
               occurred_at: DateTime.add(wait_event.occurred_at, 1, :microsecond),
               revision: 1,
               thread_ref: "1788264001.000200",
               workspace_ref: "TQUESTIONENDTOEND"
             })

    assert {:ok, _source_receipt} = Inbox.record(source_update)

    {:ok, source_admission_api} =
      FakeCoopAPI.start_link([continue_decision(candidate_ref(episode.id))],
        turn_id_override: "source-event-turn"
      )

    assert {:ok, {:decided, source_admitted}} =
             AdmissionDispatcher.run_once(
               admission_options(source_admission_api, "source-update")
             )

    assert source_admitted.result.episode.state == :waiting_for_input
    assert source_admitted.result.episode.queued_input_refs != []
    assert Repo.get!(Record, request.id).status == :open
    refute Repo.get_by(Response, record_id: request.id)
    assert Repo.get!(EventSubscription, subscription.id).status == :active

    answer_ref = submit_answer!(answer_kind, request, wait_event.occurred_at)

    {:ok, answer_entry} = Inbox.fetch(answer_ref)
    assert answer_entry.destination_thread_ref == "1788264001.000200"

    answer_text =
      if answer_kind == :typed,
        do: answer_entry.content["text"],
        else: answer_entry.content["choice"]

    assert answer_text ==
             if(answer_kind == :typed,
               do: "Use one percent, then verify before expanding.",
               else: "One percent"
             )

    assert DateTime.compare(answer_entry.occurred_at, wait_event.occurred_at) == :gt

    {:ok, answer_admission_api} =
      FakeCoopAPI.start_link([continue_decision(candidate_ref(episode.id))])

    assert {:ok, {:decided, resumed}} =
             AdmissionDispatcher.run_once(admission_options(answer_admission_api, "answer"))

    assert resumed.result.episode.id == episode.id
    assert resumed.result.episode.state == :working
    assert Repo.get!(Record, request.id).status == :answered
    assert {:ok, 0} = EventSubscriptions.reconcile()
    assert Repo.get!(EventSubscription, subscription.id).status == :active
    assert Repo.get!(Record, watch.id).status == :open

    # The missing-project flow must remember the answer to this question, not
    # whichever message happens to be latest after another event arrives.
    response = Repo.get_by(Response, record_id: request.id)
    assert response, "a typed answer must retain its exact question association"
    assert response.inbox_entry_id == answer_entry.id
    assert response.actor_ref == answer_entry.actor_ref
    assert response.response_ref == answer_entry.event_ref
    assert response.occurred_at == answer_entry.occurred_at
    assert response.choice_index == if(answer_kind == :typed, do: nil, else: 6)
    assert response.choice == if(answer_kind == :typed, do: nil, else: "One percent")

    audit = Repo.get_by(InteractionAudit, event_ref: answer_entry.event_ref)
    assert audit, "typed answers must durably retire the original question controls"
    assert audit.action_id == "#{answer_kind}_question_answer"
    assert audit.message_ref == "1788264002.000300"
    assert audit.repaint_status == :pending

    assert {:ok, {:repainted, _}} =
             InteractionFeedbackWorker.run_once(%{
               api: SlackAPI,
               client: slack_api,
               worker_ref: "typed-question-repaint",
               lease_seconds: 60,
               max_attempts: 3,
               retry_base_seconds: 1
             })

    assert_receive {:updated, "C456", "1788264002.000300", rendered_question}
    assert inspect(rendered_question["blocks"]) =~ request.payload["question"]
    refute Enum.any?(rendered_question["blocks"], &(&1["type"] == "actions"))
    refute inspect(rendered_question["blocks"]) =~ answer_text

    assert {:ok, continuation_claim} =
             Custody.claim_next("slack-question-continuation", 60, :work)

    assert continuation_claim.episode.id == episode.id
    assert continuation_claim.session.id == work_claim.session.id
    assert continuation_claim.turn.id != work_claim.turn.id

    authorize = &(&1.actor_kind == :user and &1.actor_ref == "U123")

    assert {:error, :answer_memory_unauthorized} =
             Memories.confirm_answer(continuation_claim, request.ref, "one percent", fn _ ->
               false
             end)

    assert Repo.aggregate(MemoryEntry, :count) == 0

    # A lost save transaction must leave the accepted answer available for the
    # same Work turn to retry, without claiming or duplicating remembered state.
    assert {:error, :interrupted_before_commit} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Memories.confirm_answer(
                          continuation_claim,
                          request.ref,
                          "one percent",
                          authorize
                        )

               Repo.rollback(:interrupted_before_commit)
             end)

    assert Repo.aggregate(MemoryEntry, :count) == 0
    assert Repo.get!(Response, response.id).inbox_entry_id == answer_entry.id

    options = %{
      binding: Map.put(continuation_claim, :state_token, Records.token(continuation_claim.turn)),
      answer_authorizer: authorize
    }

    assert {:ok, receipt} =
             Tools.call(
               "remember_answer",
               %{"question_ref" => request.ref, "value" => "one percent"},
               options
             )

    assert receipt["status"] == "remembered"
    remembered = %{memory: Repo.get_by!(MemoryEntry, ref: receipt["memory_ref"])}
    assert remembered.memory.payload["value"] == "one percent"
    assert remembered.memory.answer_provenance["source_revision"] == answer_entry.revision
    assert remembered.memory.answer_provenance["answer_ref"] == response.response_ref
    assert remembered.memory.confirmed_by_actor_ref == "slack:user:U123"

    assert {:ok, duplicate} =
             Memories.confirm_answer(continuation_claim, request.ref, "one percent", authorize)

    assert duplicate.memory.id == remembered.memory.id
    assert duplicate.status == :duplicate
    assert Repo.aggregate(MemoryEntry, :count) == 1

    # Twelve paid world-eval executions died after the model repeated this
    # exact retained watch on the answer turn. A semantic retry must return the
    # original watch: two open copies make subscription custody raise before
    # the otherwise valid continuation can be accepted.
    assert {:ok, repeated_watch} =
             Tools.call(
               "wait_for",
               %{
                 "deadline" => nil,
                 "on_timeout" => nil,
                 "trigger" => %{
                   "type" => "source_event",
                   "source_kind" => "slack",
                   "match" => matcher,
                   "poll_after" => nil
                 },
                 "verification" => "Read the exact run and report material changes."
               },
               options
             )

    assert repeated_watch["record_ref"] == watch.ref

    assert Repo.aggregate(
             from(record in Record,
               where: record.episode_id == ^episode.id and record.kind == "event_wait"
             ),
             :count
           ) == 1

    assert_recalled_in_new_channel!(remembered.memory, continuation_claim.session.id)

    assert {:error, :answer_memory_conflict} =
             Memories.confirm_answer(continuation_claim, request.ref, "ten percent", authorize)

    assert {:ok, _} = Memories.forget(remembered.memory.ref)

    assert {:error, :answer_memory_conflict} =
             Memories.confirm_answer(continuation_claim, request.ref, "one percent", authorize)

    assert Repo.get!(MemoryEntry, remembered.memory.id).status == :deleted

    assert {:ok, final} = Executor.run(continuation_claim, executor_options(work_api))
    assert final.turn.status == :delivery_pending

    [question_submission, answer_submission] = FakeWorkCoopAPI.state(work_api).submissions
    assert question_submission.prompt =~ "Which rollout percentage should I use?"
    assert answer_submission.prompt =~ answer_text
    assert answer_submission.prompt =~ hd(content["attachments"])["title"]

    assert answer_submission.prompt =~ request.ref
    assert Repo.get_by!(Session, episode_id: episode.id).id == work_claim.session.id
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
    assert {:ok, watching} = Episodes.fetch_by_key(episode.key)
    assert watching.state == :waiting_for_event
    assert watching.owner_ref == watch.ref
    assert Repo.get!(EventSubscription, subscription.id).matcher == matcher
    assert {:ok, :idle} = deliver_once(adapters, "idle")
  end

  defp assert_recalled_in_new_channel!(memory, original_session_id) do
    fresh =
      envelope(
        "recall",
        "Ev-question-recall",
        "1788265001.000200",
        nil,
        "<@UBOT> what is our initial rollout percentage?"
      )
      |> put_in(["payload", "event", "channel"], "COTHER")

    settings = gateway_settings()
    profile = settings.work_profile.("TQUESTIONENDTOEND", "slack:TQUESTIONENDTOEND:C456")

    settings = %{
      settings
      | work_profile: fn "TQUESTIONENDTOEND", "slack:TQUESTIONENDTOEND:COTHER" -> profile end
    }

    assert {:ack, {:recorded, _}} = Gateway.handle_envelope(fresh, settings)

    {:ok, admission_api} =
      FakeCoopAPI.start_link([start_decision()], turn_id_override: "new-channel-recall")

    assert {:ok, {:decided, _}} =
             AdmissionDispatcher.run_once(admission_options(admission_api, "recall"))

    assert {:ok, claim} = Custody.claim_next("question-recall-worker", 60, :work)
    assert claim.session.id != original_session_id
    assert claim.episode.destination_conversation_ref == "slack:TQUESTIONENDTOEND:COTHER"
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    options =
      Router.init(
        token: "question-recall-cursor-secret",
        binding: Map.put(claim, :state_token, Records.token(claim.turn))
      )

    assert {:ok, %{"memories" => [recalled]}} =
             Tools.call(
               "search_memory",
               %{
                 "query" => "rollout",
                 "scope" => "global",
                 "kinds" => ["fact"],
                 "limit" => 5,
                 "cursor" => nil,
                 "after" => nil,
                 "before" => nil,
                 "time_basis" => "changed"
               },
               options
             )

    assert recalled["memory_ref"] == memory.ref
    assert recalled["value"] == "one percent"
    assert recalled["applicability"] == "Ryker canary deployments"
    refute Map.has_key?(recalled, "source")
    refute inspect(recalled) =~ "C456"

    # The later conversation does not have to ask: the remembered answer is
    # already in the submission the model receives, still without its source.
    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert [fact] = get_in(submission, ["context", "operator_context", "memory"])
    assert fact["memory_ref"] == memory.ref
    assert fact["value"] == "one percent"
    refute inspect(fact) =~ "C456"
  end

  defp submit_answer!(:typed, _request, occurred_at) do
    assert {:ack, {:recorded, ref}} =
             Gateway.handle_envelope(answer_envelope(occurred_at), gateway_settings())

    ref
  end

  defp submit_answer!(:choice, request, _occurred_at) do
    radio = %{
      "type" => "radio_buttons",
      "action_id" => "ryker_question_choice",
      "selected_option" => %{"value" => "#{request.ref}|6"}
    }

    envelope = %{
      "type" => "interactive",
      "envelope_id" => "env-question-radio",
      "payload" => %{
        "type" => "block_actions",
        "team" => %{"id" => "TQUESTIONENDTOEND"},
        "user" => %{"id" => "U123"},
        "actions" => [radio],
        "container" => %{
          "type" => "message",
          "is_ephemeral" => false,
          "channel_id" => "C456",
          "message_ts" => "1788264002.000300",
          "thread_ts" => "1788264001.000200"
        },
        "state" => %{
          "values" => %{
            request.ref => %{"ryker_question_choice" => Map.delete(radio, "action_id")}
          }
        }
      }
    }

    assert {:ack, {:ignored, _}} = Gateway.handle_envelope(envelope, gateway_settings())
    refute Repo.get_by(Response, record_id: request.id)
    assert Repo.get!(Record, request.id).status == :open

    submit =
      envelope
      |> Map.put("envelope_id", "env-question-submit")
      |> put_in(["payload", "actions"], [
        %{"type" => "button", "action_id" => "ryker_submit_input", "value" => request.ref}
      ])

    assert {:ack, {:interaction, :recorded}} = Gateway.handle_envelope(submit, gateway_settings())
    accepted = Repo.get_by!(Response, record_id: request.id)

    assert {:ack, {:interaction, :duplicate}} =
             Gateway.handle_envelope(submit, gateway_settings())

    assert Repo.get_by!(Response, record_id: request.id).id == accepted.id
    {:ok, entry} = Inbox.fetch("ingress-input:#{accepted.inbox_entry_id}")
    Inbox.ref(entry)
  end

  defp adapters!(slack_api) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{
                   workspaces: %{"TQUESTIONENDTOEND" => %{api: SlackAPI, client: slack_api}}
                 },
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
      identity: %{bot_ref: "B-BOT", bot_user_ref: "UBOT", workspace_ref: "TQUESTIONENDTOEND"},
      inbox: Inbox,
      interaction_handler: InteractionHandler,
      interaction_options: %{
        client: :directory,
        directory: Directory,
        records: Records,
        answer_input_request: &InputRequests.answer/1
      },
      effective_settings: &installation_participation/2,
      work_profile: fn "TQUESTIONENDTOEND", "slack:TQUESTIONENDTOEND:C456" ->
        {:ok,
         %{
           policy: "conversation-read-only",
           policy_digest: @policy_digest,
           repository_ref: "ryker"
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
      "<@UBOT> help me choose a safe rollout percentage"
    )
  end

  defp answer_envelope(wait_occurred_at) do
    envelope(
      "answer",
      "Ev-slack-question-answer",
      wait_occurred_at |> DateTime.add(2, :microsecond) |> slack_timestamp(),
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
        "team_id" => "TQUESTIONENDTOEND",
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
      "repository_source" => nil,
      "reason" => "The direct mention asks Ryker to choose a rollout plan.",
      "work_class" => "standard"
    })
  end

  defp continue_decision(candidate_ref) do
    Jason.encode!(%{
      "action" => "continue_episode",
      "episode_ref" => candidate_ref,
      "reaction" => nil,
      "relation" => "same_work",
      "repository_source" => nil,
      "reason" => "This authorized answer belongs to the exact delivered question thread.",
      "work_class" => "standard"
    })
  end

  defp question_reply(record_ref, watch_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Which rollout percentage should I use?",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [record_ref, watch_ref],
        "state" => "waiting_for_input"
      }
    })
  end

  defp final_reply(message, watch_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [watch_ref],
        "state" => "waiting_for_event"
      }
    })
  end

  defp candidate_ref(episode_id) do
    "candidate:" <>
      binary_part(Ryker.CanonicalJSON.digest(["ingress-admission-candidate", episode_id]), 0, 12)
  end

  defp slack_timestamp(datetime) do
    microseconds = DateTime.to_unix(datetime, :microsecond)
    seconds = div(microseconds, 1_000_000)
    fraction = microseconds |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    Integer.to_string(seconds) <> "." <> fraction
  end

  defp input_id("ingress-input:" <> id), do: id

  defp installation_participation(_workspace_ref, _conversation_ref) do
    %{
      proactive: %{source: :installation, value: false},
      shadow: %{source: :installation, value: false}
    }
  end
end

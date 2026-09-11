defmodule Responder.Slack.TaskEndToEndTest do
  use Responder.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Responder.Delivery.Adapters
  alias Responder.Delivery.Dispatcher, as: DeliveryDispatcher
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.GitHub.{Auth, Binding, Router}
  alias Responder.Publication.{Dispatcher, FollowupDispatcher, LifecycleEvent, Publication}
  alias Responder.Repo

  alias Responder.Slack.{
    Gateway,
    InteractionHandler,
    Publisher,
    Renderer,
    TaskCard,
    TaskCardProjection,
    TaskCardWorker,
    WorkControls
  }

  alias Responder.State.{KnowledgeSnapshot, Record, Records, TaskOffers}
  alias Responder.TestSupport.FakeWorkCoopAPI
  alias Responder.Work.{Custody, Executor, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-31 13:00:00.000000Z]
  @github_secret String.duplicate("s", 32)
  @read_policy_digest String.duplicate("a", 64)
  @write_policy_digest String.duplicate("b", 64)
  @retained Jason.decode!(File.read!("priv/card_lab/legacy_task_records.json"))

  defmodule Directory do
    @behaviour Responder.Slack.MemberDirectory

    @impl true
    def user_allowed(_client, "U123", "T123"), do: {:ok, true}
    def user_allowed(_client, _actor_ref, "T123"), do: {:ok, false}
  end

  defmodule SlackAPI do
    @behaviour Responder.Slack.API

    def start_link(test_pid) do
      Agent.start_link(fn -> %{posts: [], test_pid: test_pid, updates: []} end)
    end

    def state(agent), do: Agent.get(agent, & &1)

    @impl true
    def find_message(_client, _channel, _thread, _delivery_ref), do: :not_found

    @impl true
    def post_message(agent, channel, thread, document, delivery_ref) do
      {:ok, rendered} = Renderer.render(document)

      message_ref =
        Agent.get_and_update(agent, fn state ->
          message_ref =
            "1788268001.#{state.posts |> length() |> Kernel.+(200) |> Integer.to_string() |> String.pad_leading(6, "0")}"

          send(state.test_pid, {:posted, channel, thread, rendered, delivery_ref, message_ref})

          {message_ref,
           %{state | posts: state.posts ++ [{channel, thread, rendered, delivery_ref}]}}
        end)

      {:ok, message_ref}
    end

    @impl true
    def update_message(agent, channel, message_ref, document, delivery_ref) do
      {:ok, rendered} = Renderer.render(document)

      Agent.update(agent, fn state ->
        send(state.test_pid, {:updated, channel, message_ref, rendered, delivery_ref})
        %{state | updates: state.updates ++ [{channel, message_ref, rendered, delivery_ref}]}
      end)

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

  defmodule PublicationCoop do
    def get_session(agent, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

    def run_review(agent, _session_id, key, expected_revision) do
      Agent.get_and_update(agent, fn state ->
        response = %{
          "operation" => %{
            "id" => state.review["operation_id"],
            "method" => "RunReview",
            "resource_id" => state.review["session_id"],
            "resource_type" => "review",
            "state" => "succeeded"
          },
          "review" => state.review
        }

        {{:ok, response},
         %{state | review_calls: state.review_calls ++ [{key, expected_revision}]}}
      end)
    end

    def get_review_patch(agent, artifact_id, digest, bytes) do
      Agent.get_and_update(agent, fn state ->
        call = {artifact_id, digest, bytes}
        {{:ok, state.patch}, %{state | patch_calls: state.patch_calls ++ [call]}}
      end)
    end
  end

  defmodule DraftPublisher do
    @behaviour Responder.Publication.Publisher

    def publish(request, agent) do
      Agent.get_and_update(agent, fn state ->
        receipt = %{
          "branch_ref" =>
            "refs/heads/responder/#{String.replace(request.publication_ref, ":", "-")}",
          "candidate_tree" => request.review["candidate_tree"],
          "commit_sha" => String.duplicate("9", 40),
          "pull_request_number" => 91,
          "pull_request_url" => "https://github.com/acme/responder/pull/91",
          "repository" => request.repository
        }

        {{:ok, receipt}, %{state | requests: state.requests ++ [request]}}
      end)
    end
  end

  defmodule FollowupStatusAPI do
    def get_publication_status(_client, _repository, _number), do: {:error, :not_used}
  end

  test "a confirmed Slack task checks readiness automatically and repairs GitHub review in the same session" do
    claim = claim_episode!()
    # Structural records are installed before the fake provider runs; initialize
    # their empty external-source custody at the real pre-disclosure boundary.
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    assert {:ok, offer} =
             Records.create(Records.token(claim.turn), "parser-task", "task_offer", %{
               "authority_limits" => ["Only change parser-owned files."],
               "instruction_ref" => "slack-message:task-e2e",
               "kind" => "engineering",
               "prompt" => "Fix parser retry handling and run focused tests.",
               "repository" => "responder",
               "source_refs" => ["slack-message:task-e2e"],
               "success_checks" => ["The parser retry regression passes."],
               "title" => "Fix parser retries"
             })

    {:ok, work_api} = FakeWorkCoopAPI.start_link([task_offer_reply(offer.ref)])
    assert {:ok, accepted} = Executor.run(claim, executor_options(work_api))
    assert accepted.turn.status == :delivery_pending

    {:ok, slack_api} = SlackAPI.start_link(self())
    adapters = adapters!(slack_api)

    assert {:ok, {:delivered, :message, delivery_ref}} = deliver_once(adapters)

    assert_receive {
      :posted,
      "C456",
      "1788268000.000100",
      offer_document,
      ^delivery_ref,
      "1788268001.000200"
    }

    rendered_offer = Jason.encode!(offer_document)
    assert rendered_offer =~ "responder_start_engineering_task"
    assert rendered_offer =~ offer.ref
    assert rendered_offer =~ "Fix parser retries"
    assert rendered_offer =~ "responder"

    assert Gateway.handle_envelope(
             task_interaction("U-NOT-A-MEMBER", offer.ref),
             gateway_settings()
           ) ==
             {:ack, {:interaction, :denied},
              %{
                "response_type" => "ephemeral",
                "text" => "You don't have permission to use that Responder control."
              }}

    assert Gateway.handle_envelope(task_interaction("U123", offer.ref), gateway_settings()) ==
             {:ack, {:interaction, :confirmed}}

    confirmed = Repo.get!(Record, offer.id)
    assert confirmed.status == :confirmed
    assert confirmed.confirmed_by_actor_ref == "slack:user:U123"
    assert confirmed.confirmation_ref == "interaction:task-e2e"

    assert {:ok, task_episode} = Episodes.fetch_by_key("task-offer:#{offer.ref}")
    assert task_episode.id == confirmed.confirmed_episode_id
    assert task_episode.linked_episode_id == claim.episode.id
    assert task_episode.destination_transport == "slack"
    assert task_episode.destination_conversation_ref == "slack:T123:C456"
    assert task_episode.destination_thread_ref == "1788268000.000100"

    task_session = Repo.get_by!(Session, episode_id: task_episode.id)
    assert task_session.policy == "responder-contributor"
    assert task_session.policy_digest == @write_policy_digest
    assert task_session.repository_ref == "responder"

    assert task_session.workspace_task == %{
             "authority_limits" => ["Only change parser-owned files."],
             "instruction_ref" => "slack-message:task-e2e",
             "offer_ref" => offer.ref,
             "prompt" => "Fix parser retry handling and run focused tests.",
             "source_refs" => ["slack-message:task-e2e"],
             "success_checks" => ["The parser retry regression passes."],
             "title" => "Fix parser retries"
           }

    assert {:ok, task_claim} = Custody.claim_next("task-e2e-child-work", 60, :work)
    assert task_claim.episode.id == task_episode.id
    assert task_claim.session.id == task_session.id
    assert task_claim.session.policy == "responder-contributor"
    assert :ok = KnowledgeSnapshot.expose(task_claim, [])

    assert {:ok, {:created, card_ref}} = TaskCardWorker.run_once(card_options(slack_api))
    assert {:ok, {:updated, ^card_ref}} = TaskCardWorker.run_once(card_options(slack_api))

    assert_receive {
      :updated,
      "C456",
      "1788268001.000200",
      updated_document,
      ^card_ref
    }

    updated_json = Jason.encode!(updated_document)
    assert updated_json =~ "Fix parser retries"
    assert updated_json =~ "responder_stop_work"

    card = Repo.get_by!(TaskCard, ref: card_ref)
    assert {:ok, projection} = TaskCardProjection.build(card)
    task_card = projection.document["task_card"]
    assert task_card["status"] == "working"
    assert task_card["title"] == "Fix parser retries"
    assert task_card["repository"] == "responder"
    assert "stop" in task_card["controls"]

    assert %TaskCard{
             episode_id: task_episode_id,
             message_ref: "1788268001.000200",
             thread_ref: "1788268000.000100"
           } = card

    assert task_episode_id == task_episode.id
    assert length(SlackAPI.state(slack_api).posts) == 1
    assert length(SlackAPI.state(slack_api).updates) == 1

    # A subtask must refresh the original card while the model turn is still
    # pending, without waiting for final delivery or posting another message.
    [retained_goal | _] = @retained["portal_goals"]["goals"]

    goal =
      retained_goal
      |> Map.take(~w(id requested_outcome completion_contract))
      |> Map.merge(%{
        "authority" => "read_only",
        "kind" => "check",
        "required" => false,
        "stage" => "implementation"
      })

    assert {:ok, _} = Records.create(Records.token(task_claim.turn), "live-goal", "goal", goal)

    for state <- ["working", "completed"] do
      assert {:ok, _} =
               Records.create(
                 Records.token(task_claim.turn),
                 "live-goal-#{state}",
                 "goal_state",
                 %{"goal_id" => goal["id"], "state" => state}
               )

      _ = refresh_card!(card, slack_api)
      assert_receive {:updated, "C456", "1788268001.000200", live_card, ^card_ref}
      rendered = Jason.encode!(live_card)

      # The worker has not bound its Coop session yet, so Workspace setup is the
      # stage waiting; the plan still counts its own subtask truthfully.
      assert rendered =~ "◷ Workspace setup · waiting for a worker"

      if state == "completed",
        do: assert(rendered =~ "✓ Implementation · 1/1 subtasks"),
        else: assert(rendered =~ "▸ Implementation · 0/1 subtasks")

      assert length(SlackAPI.state(slack_api).posts) == 1
    end

    _ = refresh_card!(card, slack_api)
    assert length(SlackAPI.state(slack_api).updates) == 3

    {:ok, task_api} =
      FakeWorkCoopAPI.start_link([writable_task_reply()],
        workspace_task: native_task_binding(task_session),
        changes: [workspace_changes()]
      )

    FakeWorkCoopAPI.update(task_api, fn state ->
      state
      |> put_in([:session, "id"], "remote_task_work")
      |> put_in([:session, "policy_digest"], @write_policy_digest)
    end)

    assert {:ok, %{status: :accepted, turn: %{status: :delivery_pending}} = task_accepted} =
             Executor.run(task_claim, executor_options(task_api))

    # Confirmed coding tasks stalled behind another readiness permission click.
    # Queue the trusted check atomically with acceptance, before Slack delivery
    # or retention can close the completed session. This is not a publish grant.
    ready_offer =
      Repo.get_by!(Record,
        episode_id: task_episode.id,
        turn_id: task_accepted.turn.id,
        kind: "publication_offer",
        operation_id: "host:publication:ready"
      )

    automatic_review = Repo.get_by(Publication, record_id: ready_offer.id)

    assert match?(%Publication{status: :review_pending}, automatic_review),
           "a confirmed task must queue readiness without another user interaction"

    assert automatic_review.episode_id == task_episode.id
    assert automatic_review.session_id == task_session.id
    assert automatic_review.repository == task_session.repository_ref
    assert automatic_review.review_requested_by_actor_ref == confirmed.confirmed_by_actor_ref

    assert automatic_review.offer_message_ref ==
             Repo.get!(Turn, claim.turn.id).external_receipt["message_ref"]

    assert automatic_review.approval_ref == nil

    assert {:ok, _duplicate} =
             Custody.accept_result(
               task_episode.id,
               task_episode.key,
               task_claim.turn.turn_ref,
               task_claim.lease_ref,
               task_accepted.turn.candidate_sha256,
               task_accepted.turn.candidate_attempt,
               task_accepted.turn.validation_receipt
             )

    assert [same_review] = Repo.all(from(p in Publication, where: p.record_id == ^ready_offer.id))
    assert same_review.id == automatic_review.id

    assert {:ok, {:delivered, :message, _task_delivery_ref}} = deliver_once(adapters)

    assert_receive {
      :posted,
      "C456",
      "1788268000.000100",
      _task_result_document,
      _task_delivery_ref,
      "1788268001.000201"
    }

    Repo.update_all(from(saved in TaskCard, where: saved.id == ^card.id),
      set: [card_checked_at: nil]
    )

    assert {:ok, {:updated, ^card_ref}} = TaskCardWorker.run_once(card_options(slack_api))

    card = Repo.get!(TaskCard, card.id)
    assert {:ok, ready_projection} = TaskCardProjection.build(card)
    ready_card = ready_projection.document["task_card"]
    assert ready_card["status"] == "reviewing"

    # The session is bound and the model result accepted, so the earlier stages
    # keep their completed disposition while the host review runs.
    assert Enum.map(ready_card["stages"], &{&1["stage"], &1["state"]}) == [
             {"workspace_setup", "completed"},
             {"planning", "completed"},
             {"implementation", "completed"},
             {"self_review", "running"},
             {"draft_pr", "pending"},
             {"ci", "pending"},
             {"review_and_merge", "pending"}
           ]

    assert ready_card["publication"]["publication_ref"] == automatic_review.ref
    assert ready_card["publication"]["controls"] == []

    publication = Repo.get!(Publication, automatic_review.id)
    assert publication.episode_id == task_episode.id
    assert publication.repository == "responder"
    assert publication.status == :review_pending

    task_session = Repo.get!(Session, task_session.id)
    patch = "diff --git a/lib/parser.ex b/lib/parser.ex\n+fixed retry handling\n"
    review = review_document(task_session, patch)

    {:ok, publication_coop} =
      Agent.start_link(fn ->
        %{
          patch: patch,
          patch_calls: [],
          review: review,
          review_calls: [],
          # Publication must review the real task session too. Reconstructing a
          # host-only ref here hid a readiness rejection for every engineering task.
          session:
            Map.merge(FakeWorkCoopAPI.state(task_api).session, %{
              "revision" => 7,
              "state" => "open"
            })
        }
      end)

    {:ok, draft_publisher} = Agent.start_link(fn -> %{requests: []} end)

    publication_options =
      publication_options(publication_coop, draft_publisher, adapters)

    assert {:ok, {:executed, %{phase: :reviewed}}} =
             Dispatcher.run_once(publication_options)

    assert {:ok, {:executed, %{phase: :delivered}}} =
             Dispatcher.run_once(publication_options)

    assert Repo.get!(Publication, publication.id).status == :reviewed

    card = refresh_card!(card, slack_api)
    assert {:ok, reviewed_projection} = TaskCardProjection.build(card)
    reviewed_card = reviewed_projection.document["task_card"]
    assert reviewed_card["status"] == "ready_to_publish"
    assert reviewed_card["publication"]["controls"] == ["publish", "update", "discard"]

    assert Gateway.handle_envelope(
             publication_interaction(
               card,
               "responder_task_publish",
               publication.ref,
               "publish"
             ),
             gateway_settings()
           ) == {:ack, {:interaction, :approved}}

    assert {:ok, {:executed, %{phase: :published}}} =
             Dispatcher.run_once(publication_options)

    assert {:ok, {:executed, %{phase: :delivered}}} =
             Dispatcher.run_once(publication_options)

    published = Repo.get!(Publication, publication.id)
    assert published.status == :published
    assert published.pull_request_url == "https://github.com/acme/responder/pull/91"
    assert published.publication_receipt["candidate_tree"] == review["candidate_tree"]

    card = refresh_card!(card, slack_api)
    assert {:ok, published_projection} = TaskCardProjection.build(card)
    published_card = published_projection.document["task_card"]
    assert published_card["status"] == "published"
    assert published_card["publication"]["pull_request_number"] == 91

    assert [request] = Agent.get(draft_publisher, & &1.requests)
    assert request.patch == patch
    assert request.repository == "responder"

    response =
      github_review_post(
        published.pull_request_number,
        "Please cover the nil retry state before merge."
      )

    assert response.status == 202

    assert %{"publication_event_ref" => event_ref, "status" => "recorded"} =
             Jason.decode!(response.resp_body)

    assert %LifecycleEvent{
             episode_id: lifecycle_episode_id,
             publication_id: lifecycle_publication_id,
             wakeup_state: :pending
           } = Repo.get_by!(LifecycleEvent, ref: event_ref)

    assert lifecycle_episode_id == task_episode.id
    assert lifecycle_publication_id == published.id

    assert {:ok, {:executed, %{phase: :delivery}}} =
             FollowupDispatcher.run_once(
               executor_options: [
                 adapters: adapters,
                 api: FollowupStatusAPI,
                 client: :not_used
               ],
               interval_seconds: 120,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "task-e2e-github-review-followup"
             )

    assert {
             :posted,
             "C456",
             "1788268000.000100",
             _lifecycle_document,
             _lifecycle_delivery_ref,
             _lifecycle_message_ref
           } = receive_post_containing!("Authenticated GitHub review feedback")

    assert {:ok, resumed} = Episodes.fetch_by_key(task_episode.key)
    assert resumed.id == task_episode.id
    assert resumed.state == :working
    assert resumed.destination_transport == "slack"
    assert resumed.destination_conversation_ref == "slack:T123:C456"
    assert resumed.destination_thread_ref == "1788268000.000100"

    assert {:ok, correction_claim} =
             Custody.claim_next("task-e2e-github-review-work", 60, :work)

    assert correction_claim.episode.id == task_episode.id
    assert correction_claim.session.id == task_session.id

    {:ok, correction_api} =
      FakeWorkCoopAPI.start_link([review_feedback_reply()],
        workspace_task: native_task_binding(task_session),
        changes: [workspace_changes()]
      )

    FakeWorkCoopAPI.update(correction_api, fn state ->
      # Resume the session returned by task creation, including its stable task
      # ref. Rebuilding it from the host's external ref creates a different authority.
      remote_session =
        Map.merge(FakeWorkCoopAPI.state(task_api).session, %{
          "revision" => 9,
          "state" => "open"
        })

      %{state | session: remote_session, submit_count: 1, turn: nil}
    end)

    assert {:ok, correction_submission} = SubmissionBuilder.build(correction_claim)

    assert {:ok, correction_turn} =
             Custody.freeze_submission(
               correction_claim.episode.id,
               correction_claim.turn.turn_ref,
               correction_claim.lease_ref,
               correction_submission
             )

    correction_claim = %{correction_claim | turn: correction_turn}

    assert {:ok, correction_execution} =
             Executor.run(correction_claim, executor_options(correction_api))

    assert correction_execution.turn.status == :delivery_pending
    assert correction_execution.turn.session_id == task_session.id
    assert Repo.aggregate(Session, :count, :id) == 2

    assert [current_review] =
             correction_execution.turn.submission["context"]["current_inputs"]["items"]

    assert current_review["content"]["content"]["event_name"] ==
             "pull_request_review_comment"

    assert current_review["content"]["content"]["payload"]["comment"]["body"] ==
             "Please cover the nil retry state before merge."

    assert {:ok, {:delivered, :message, final_delivery_ref}} = deliver_once(adapters)

    assert {
             :posted,
             "C456",
             "1788268000.000100",
             _final_document,
             ^final_delivery_ref,
             _final_message_ref
           } =
             receive_post_containing!(
               "Covered the nil retry state and updated the published review branch."
             )

    assert %Turn{status: :settled, external_receipt: final_receipt} =
             Repo.get!(Turn, correction_execution.turn.id)

    assert final_receipt["transport"] == "slack"
    assert final_receipt["conversation_ref"] == "slack:T123:C456"
    assert final_receipt["thread_ref"] == "1788268000.000100"

    # A completed correction must not mint another Publication and replace the
    # existing PR link with a fresh Create draft PR control.
    assert [same_publication] =
             Repo.all(from(p in Publication, where: p.episode_id == ^task_episode.id))

    assert same_publication.id == publication.id
    assert {:ok, after_correction} = TaskCardProjection.build(Repo.get!(TaskCard, card.id))

    assert after_correction.document["task_card"]["publication"]["pull_request_url"] ==
             same_publication.pull_request_url
  end

  defp claim_episode! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1788268000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "task-e2e:#{episode_id}",
                 native_input_id: "slack-message:task-e2e",
                 occurred_at: @now,
                 payload: %{"text" => "Please propose a task to fix parser retries."},
                 turn_ref: "turn:task-e2e:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "conversation-read-only", @read_policy_digest)

    assert {:ok, claim} = Custody.claim_next("task-e2e-parent-work", 60, :work)
    claim
  end

  defp task_interaction(actor_ref, offer_ref) do
    %{
      "envelope_id" => "task-e2e",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => "responder_start_engineering_task",
            "type" => "button",
            "value" => offer_ref
          }
        ],
        "container" => %{
          "channel_id" => "C456",
          "is_ephemeral" => false,
          "message_ts" => "1788268001.000200",
          "thread_ts" => "1788268000.000100",
          "type" => "message"
        },
        "team" => %{"id" => "T123"},
        "type" => "block_actions",
        "user" => %{"id" => actor_ref}
      },
      "type" => "interactive"
    }
  end

  defp publication_interaction(card, action_id, item_ref, suffix) do
    %{
      "envelope_id" => "task-readiness-e2e-#{suffix}",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => action_id,
            "type" => "button",
            "value" => "#{card.ref}|#{item_ref}"
          }
        ],
        "container" => %{
          "channel_id" => card.channel_ref,
          "is_ephemeral" => false,
          "message_ts" => card.message_ref,
          "thread_ts" => card.thread_ref,
          "type" => "message"
        },
        "team" => %{"id" => card.workspace_ref},
        "type" => "block_actions",
        "user" => %{"id" => "U123"}
      },
      "type" => "interactive"
    }
  end

  defp gateway_settings do
    %{
      client: :directory,
      directory: Directory,
      identity: %{workspace_ref: "T123"},
      interaction_audit: fn _interaction, _outcome -> {:ok, %{}} end,
      interaction_handler: InteractionHandler,
      interaction_options: %{
        client: :directory,
        confirm_task_offer: &TaskOffers.confirm/1,
        directory: Directory,
        operators: MapSet.new(["U123"]),
        approve_task_publication: &WorkControls.approve_publication/1,
        records: Records,
        repositories: %{
          "responder" => %{
            contributor_policy: %{
              digest: @write_policy_digest,
              name: "responder-contributor"
            }
          }
        }
      }
    }
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

  defp deliver_once(adapters) do
    DeliveryDispatcher.run_once(
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "task-e2e-delivery"
    )
  end

  defp publication_options(coop, publisher, adapters) do
    [
      executor_options: [
        adapters: adapters,
        api: PublicationCoop,
        client: coop,
        publisher: DraftPublisher,
        publisher_binding: publisher
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "task-e2e-publication"
    ]
  end

  defp refresh_card!(card, slack_api) do
    Repo.update_all(from(saved in TaskCard, where: saved.id == ^card.id),
      set: [card_checked_at: nil]
    )

    assert {:ok, {:updated, card_ref}} = TaskCardWorker.run_once(card_options(slack_api))
    assert card_ref == card.ref
    Repo.get!(TaskCard, card.id)
  end

  defp card_options(slack_api) do
    %{
      api: SlackAPI,
      check_interval_seconds: 60,
      client: slack_api,
      interval_ms: 1_000,
      lease_seconds: 60,
      retry_base_seconds: 1,
      worker_ref: "task-e2e-card"
    }
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

  defp task_offer_reply(offer_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "I prepared a repository-scoped task for your confirmation.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [offer_ref],
        "state" => "complete"
      }
    })
  end

  defp writable_task_reply do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The parser retry fix is committed and ready for review.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp review_feedback_reply do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Covered the nil retry state and updated the published review branch.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp github_review_post(pull_request_number, message) do
    payload = %{
      "action" => "created",
      "comment" => %{
        "body" => message,
        "created_at" => DateTime.to_iso8601(@now),
        "id" => 9_003,
        "in_reply_to_id" => 9_000,
        "line" => 17,
        "path" => "lib/parser.ex",
        "updated_at" => DateTime.to_iso8601(@now)
      },
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => pull_request_number},
      "repository" => %{"full_name" => "acme/responder", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }

    body = Jason.encode!(payload)

    conn(:post, "/v1/github", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-delivery", "task-e2e-review-feedback")
    |> put_req_header("x-github-event", "pull_request_review_comment")
    |> put_req_header("x-hub-signature-256", Auth.signature(@github_secret, body))
    |> Router.call(
      Router.init(bindings: %{"task-e2e" => github_binding!()}, secret: @github_secret)
    )
  end

  defp github_binding! do
    assert {:ok, binding} =
             Binding.new(%{
               authorized_actor_ids: [7],
               installation_id: 41,
               name: "task-e2e",
               repository_full_name: "acme/responder",
               repository_id: 99,
               responder_actor_id: 99,
               secret: @github_secret
             })

    binding
  end

  defp receive_post_containing!(expected) do
    receive do
      {:posted, _channel, _thread, document, _delivery_ref, _message_ref} = message ->
        if Jason.encode!(document) =~ expected,
          do: message,
          else: receive_post_containing!(expected)
    after
      1_000 -> flunk("did not receive Slack post containing #{inspect(expected)}")
    end
  end

  defp native_task_binding(session) do
    %{
      "offer_ref" => session.workspace_task["offer_ref"],
      "id" => "task-binding-e2e",
      "queue_id" => "queue-e2e",
      "task_id" => "task-e2e",
      "draft_sha256" => String.duplicate("d", 64)
    }
  end

  defp workspace_changes do
    %{
      "base_commit" => "base-commit",
      "committed" => [%{"path" => "lib/parser.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => "task-commit",
      "fork_tree" => "task-tree",
      "parent_head" => "base-commit",
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch_bytes" => 0,
      "patch_has_more" => false,
      "patch_next_offset" => 0,
      "patch_offset" => 0,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }
  end

  defp review_document(session, patch) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "operation:review:#{session.id}",
      "parent_head" => String.duplicate("5", 40),
      "parent_tree" => String.duplicate("4", 40),
      "patch_artifact_id" => "review-patch:#{session.id}",
      "patch_bytes" => byte_size(patch),
      "patch_digest" => digest(patch),
      "patch_truncated" => false,
      "policy_digest" => session.policy_digest,
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => nil,
      "rebase" => "clean",
      "session_id" => session.coop_session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

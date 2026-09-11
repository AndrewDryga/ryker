defmodule Responder.State.TaskOffersTest do
  use Responder.DataCase, async: false

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Publication.Changeset
  alias Responder.Repo
  alias Responder.Slack.{TaskCard, TaskCardProjection, TaskCards, TaskCardWorker}
  alias Responder.State.{KnowledgeSnapshot, Record, Records, TaskOffers}
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Session, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("b", 64)

  defmodule CardAPI do
    def update_message(agent, channel_ref, message_ref, document, delivery_ref) do
      Agent.update(
        agent,
        &Map.update!(&1, :updates, fn updates ->
          updates ++ [{channel_ref, message_ref, document, delivery_ref}]
        end)
      )

      :ok
    end
  end

  defmodule FailingCardAPI do
    def update_message(_client, _channel_ref, _message_ref, _document, _delivery_ref),
      do: {:error, :slack_unavailable}
  end

  test "the exact delivered offer creates one linked policy-pinned task episode" do
    fixture = delivered_offer!("confirm")

    assert {:ok, confirmation} = TaskOffers.confirm(confirmation(fixture))
    assert confirmation.status == :confirmed
    assert confirmation.episode.linked_episode_id == fixture.episode.id
    assert confirmation.episode.destination_transport == "slack"
    assert confirmation.episode.destination_conversation_ref == "slack:T123:C456"
    assert confirmation.episode.destination_thread_ref == "1787832000.000100"
    assert confirmation.session.policy == "responder-contributor"
    assert confirmation.session.policy_digest == @policy_digest
    assert confirmation.session.repository_ref == "responder"

    assert confirmation.session.workspace_task == %{
             "authority_limits" => [],
             "instruction_ref" => "",
             "offer_ref" => fixture.record.ref,
             "prompt" => "Change the parser and run focused tests.",
             "source_refs" => [],
             "success_checks" => ["Complete the confirmed task and run focused validation."],
             "title" => "Fix parser retries"
           }

    record = Repo.get!(Record, fixture.record.id)
    assert record.status == :confirmed
    assert record.confirmed_episode_id == confirmation.episode.id
    assert record.confirmed_by_actor_ref == "slack:user:U123"
    assert record.confirmation_ref == "interaction:confirm"

    assert [event] = Episodes.list_events(confirmation.episode.key)
    assert event.kind == :input_admitted
    assert event.payload["payload"]["task"] == fixture.record.payload

    assert %Session{} =
             Repo.get_by(Session,
               episode_id: confirmation.episode.id,
               policy: "responder-contributor"
             )

    assert {:ok, duplicate} =
             fixture
             |> confirmation()
             |> Map.put(:confirmation_ref, "interaction:confirm-retry")
             |> TaskOffers.confirm()

    assert duplicate.status == :duplicate
    assert duplicate.episode.id == confirmation.episode.id
    assert Repo.aggregate(Session, :count, :id) == 2
  end

  test "one parent can coordinate independent writable children without crossing repositories" do
    fixture =
      delivered_offers!("multi-repository", [
        %{
          "kind" => "engineering",
          "prompt" => "Change the API contract and run its focused tests.",
          "repository" => "backend",
          "title" => "Update the API contract"
        },
        %{
          "kind" => "engineering",
          "prompt" => "Adopt the API contract and run its focused tests.",
          "repository" => "frontend",
          "title" => "Adopt the API contract"
        }
      ])

    [backend_offer, frontend_offer] = fixture.records

    assert {:ok, backend} =
             fixture
             |> Map.put(:record, backend_offer)
             |> confirmation()
             |> put_in([:policy, :name], "backend-contributor")
             |> TaskOffers.confirm()

    assert {:ok, frontend} =
             fixture
             |> Map.put(:record, frontend_offer)
             |> confirmation()
             |> Map.put(:confirmation_ref, "interaction:confirm:frontend")
             |> put_in([:policy, :name], "frontend-contributor")
             |> TaskOffers.confirm()

    assert backend.episode.linked_episode_id == fixture.episode.id
    assert frontend.episode.linked_episode_id == fixture.episode.id
    refute backend.episode.id == frontend.episode.id
    assert backend.session.repository_ref == "backend"
    assert frontend.session.repository_ref == "frontend"
    assert backend.session.policy == "backend-contributor"
    assert frontend.session.policy == "frontend-contributor"

    assert Repo.get!(Record, backend_offer.id).confirmed_episode_id == backend.episode.id
    assert Repo.get!(Record, frontend_offer.id).confirmed_episode_id == frontend.episode.id
  end

  test "a repository-set offer pins one writable primary and frozen read-only companions" do
    fixture =
      delivered_offers!("repository-set", [
        %{
          "kind" => "engineering",
          "prompt" => "Update the service using the infrastructure contract.",
          "repository" => "platform",
          "title" => "Update the platform"
        }
      ])
      |> Map.put(:record, nil)

    fixture = %{fixture | record: hd(fixture.records)}

    repository_context = %{
      "context_ref" => "platform",
      "parallel_goal_limit" => 2,
      "primary_repository" => "service",
      "read_only_repositories" => ["infrastructure", "runbooks"]
    }

    attributes =
      fixture
      |> confirmation()
      |> Map.put(:policy, %{
        digest: @policy_digest,
        name: "platform-contributor",
        repository_context: repository_context,
        repository_ref: "service"
      })

    assert {:ok, confirmed} = TaskOffers.confirm(attributes)
    assert confirmed.session.repository_ref == "service"
    assert confirmed.session.repository_context == repository_context
    assert confirmed.episode.linked_episode_id == fixture.episode.id

    malformed = put_in(attributes, [:policy, :repository_context, "primary_repository"], "other")

    assert TaskOffers.confirm(malformed) ==
             {:error, {:invalid_task_offer_confirmation, :repository_context}}
  end

  test "crossed and undelivered controls cannot create work" do
    fixture = delivered_offer!("crossed")

    crossed =
      fixture
      |> confirmation()
      |> put_in([:target, :message_ref], "1787832999.999999")

    assert TaskOffers.confirm(crossed) == {:error, :task_offer_delivery_mismatch}
    assert Repo.get!(Record, fixture.record.id).status == :open
    assert Repo.aggregate(Session, :count, :id) == 1

    Repo.update_all(Record, set: [status: :dismissed])

    assert TaskOffers.confirm(confirmation(fixture)) == {:error, :task_offer_stale}
    assert Repo.aggregate(Session, :count, :id) == 1
  end

  test "a top-level offer makes its exact delivered card the task thread root" do
    fixture = delivered_offer!("top-level", nil)

    assert {:ok, confirmation} = TaskOffers.confirm(confirmation(fixture))
    assert confirmation.episode.destination_thread_ref == fixture.receipt["message_ref"]
  end

  test "a confirmed Slack task repairs and updates one durable card on the delivered offer" do
    fixture = delivered_offer!("card")
    assert {:ok, confirmation} = TaskOffers.confirm(confirmation(fixture))
    agent = start_supervised!({Agent, fn -> %{updates: []} end})
    options = card_worker_options(agent)

    assert {:ok, {:created, card_ref}} = TaskCardWorker.run_once(options)
    card = Repo.get_by!(TaskCard, ref: card_ref)
    assert card.record_id == fixture.record.id
    assert card.episode_id == confirmation.episode.id
    assert card.channel_ref == "C456"
    assert card.thread_ref == "1787832000.000100"
    assert card.message_ref == "1787832001.000200"

    assert {:ok, {:updated, ^card_ref}} = TaskCardWorker.run_once(options)

    assert [
             {"C456", "1787832001.000200", %{"task_card" => task}, ^card_ref}
           ] = Agent.get(agent, & &1.updates)

    assert task["title"] == "Fix parser retries"
    assert task["repository"] == "responder"
    assert task["status"] == "working"
    assert task["session_generation"] == 1
    assert task["controls"] == ["close", "timeline", "evidence", "handoff"]

    stored = Repo.get!(TaskCard, card.id)
    assert stored.card_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert stored.card_ui_revision == 6

    assert Enum.map(task["stages"], &{&1["stage"], &1["state"]}) == [
             {"workspace_setup", "waiting"},
             {"planning", "pending"},
             {"implementation", "pending"},
             {"self_review", "pending"},
             {"draft_pr", "pending"},
             {"ci", "pending"},
             {"review_and_merge", "pending"}
           ]

    refute stored.lease_ref

    assert {:ok, :idle} = TaskCardWorker.run_once(options)
    assert Agent.get(agent, &length(&1.updates)) == 1

    assert {:ok, claim} = Custody.claim_next("task-card-progress", 60, :work)
    assert claim.episode.id == confirmation.episode.id
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    assert {:ok, _progress} =
             Records.create(Records.token(claim.turn), "task-progress", "progress", %{
               "next_due_at" => nil,
               "phase" => "verifying",
               "summary" => "The focused parser tests pass; the full repository gate is running."
             })

    stored
    |> Ecto.Changeset.change(card_checked_at: DateTime.add(stored.card_checked_at, -10, :second))
    |> Repo.update!()

    Agent.update(agent, &Map.put(&1, :updates, []))
    options = Map.put(options, :check_interval_seconds, 1)
    assert {:ok, {:updated, ^card_ref}} = TaskCardWorker.run_once(options)

    assert [{_, _, %{"task_card" => progress_task}, _}] = Agent.get(agent, & &1.updates)

    assert progress_task["summary"] ==
             "The focused parser tests pass; the full repository gate is running."

    assert {:ok, _bound} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:task-card-progress"
             )

    assert {:ok, bound_projection} = TaskCardProjection.build(stored)
    assert "view_diff" in bound_projection.document["task_card"]["controls"]
  end

  test "task cards explain waits, terminal work, and blocked custody from durable state" do
    waiting = confirmed_card!("waiting")
    assert {:ok, waiting_claim} = Custody.claim_next("task-card:waiting", 60, :work)
    assert :ok = KnowledgeSnapshot.expose(waiting_claim, [])

    assert {:ok, question} =
             Records.create(
               Records.token(waiting_claim.turn),
               "task-question",
               "input_request",
               %{
                 "choices" => ["Production", "Staging"],
                 "question" => "Which environment should receive the parser fix?"
               }
             )

    assert {:ok, _wait} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: waiting.episode.key,
                 expected_turn_ref: waiting.episode.owner_ref,
                 wait_ref: question.ref
               })
             )

    assert {:ok, waiting_projection} = TaskCardProjection.build(waiting.card)
    waiting_task = waiting_projection.document["task_card"]
    assert waiting_task["status"] == "waiting_for_input"
    assert waiting_task["action_needed"] =~ "Which environment"
    refute "stop" in waiting_task["controls"]

    event_wait = confirmed_card!("event-wait")

    assert {:ok, _event_wait} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: DateTime.add(@now, 3_600, :second),
                 episode_key: event_wait.episode.key,
                 expected_turn_ref: event_wait.episode.owner_ref,
                 kind: :event,
                 wait_ref: "event-wait:#{event_wait.episode.id}"
               })
             )

    assert {:ok, event_projection} = TaskCardProjection.build(event_wait.card)
    assert event_projection.document["task_card"]["status"] == "waiting_for_event"
    assert event_projection.document["task_card"]["action_needed"] =~ "external verification"

    complete = confirmed_card!("complete")

    assert {:ok, _complete} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "The requested work is already complete.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: complete.episode.key,
                 expected_turn_ref: complete.episode.owner_ref,
                 result_ref: "result:task-card:complete"
               })
             )

    assert {:ok, complete_projection} = TaskCardProjection.build(complete.card)
    assert complete_projection.document["task_card"]["status"] == "completed"
    refute "close" in complete_projection.document["task_card"]["controls"]

    cancelled = confirmed_card!("cancelled")

    assert {:ok, _cancelled} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:task-card:#{cancelled.episode.id}",
                 episode_key: cancelled.episode.key,
                 expected_owner: %{kind: :turn, ref: cancelled.episode.owner_ref}
               })
             )

    assert {:ok, cancelled_projection} = TaskCardProjection.build(cancelled.card)
    assert cancelled_projection.document["task_card"]["status"] == "cancelled"

    assert TaskCardProjection.build(%TaskCard{
             id: Ecto.UUID.generate(),
             episode_id: Ecto.UUID.generate(),
             record_id: Ecto.UUID.generate()
           }) == {:error, :task_card_source_not_found}

    assert TaskCardProjection.build(:invalid) == {:error, :invalid_task_card}
  end

  test "task-card refresh failures defer exact custody and workers reject unsafe options" do
    fixture = delivered_offer!("defer")
    assert {:ok, _confirmation} = TaskOffers.confirm(confirmation(fixture))
    agent = start_supervised!({Agent, fn -> %{updates: []} end})
    options = card_worker_options(agent)

    assert {:ok, {:created, card_ref}} = TaskCardWorker.run_once(options)

    failing = %{options | api: FailingCardAPI}
    assert {:ok, {:deferred, ^card_ref}} = TaskCardWorker.run_once(failing)

    deferred = Repo.get_by!(TaskCard, ref: card_ref)
    assert deferred.last_error_code == "slack_unavailable"
    assert deferred.next_attempt_at
    refute deferred.lease_ref

    valid = TaskCardWorker.options!(Map.put(options, :name, :task_card_worker_test))
    assert valid.name == :task_card_worker_test

    {:ok, worker} = start_supervised({TaskCardWorker, valid})
    assert Process.alive?(worker)

    for invalid <- [
          :invalid,
          [],
          [api: CardAPI, api: FailingCardAPI],
          Map.delete(options, :api),
          Map.put(options, :interval_ms, 10),
          Map.put(options, :lease_seconds, 0),
          Map.put(options, :unknown, true)
        ] do
      assert_raise ArgumentError, fn -> TaskCardWorker.options!(invalid) end
    end
  end

  test "task cards project review, approval, publication, and blocked work from canonical custody" do
    review = confirmed_card!("publication-review")
    publication = publication!(review, "review")

    assert_task_publication(review.card, "reviewing", :review_pending, [])

    publication =
      update_publication!(publication, %{
        last_error_code: "coop_unavailable",
        last_error_detail: "The review worker is temporarily unavailable.",
        next_attempt_at: DateTime.add(@now, 300, :second)
      })

    assert_task_publication(review.card, "action_required", :review_pending, ["retry"])

    publication =
      update_publication!(publication, %{
        last_error_code: nil,
        last_error_detail: nil,
        next_attempt_at: nil
      })

    publication =
      update_publication!(publication, %{
        review_document: %{"gate" => "passed", "publishable" => true},
        review_fingerprint: digest("review:ready"),
        review_expected_revision: 3,
        reviewed_at: @now,
        status: :review_ready
      })

    assert_task_publication(review.card, "reviewing", :review_ready, [])

    publication =
      update_publication!(publication, %{
        review_delivery_receipt: %{"message_ref" => "review-message"},
        review_delivery_receipt_fingerprint: digest("review:receipt"),
        status: :reviewed
      })

    assert_task_publication(review.card, "ready_to_publish", :reviewed, [
      "publish",
      "update",
      "discard"
    ])

    publication =
      update_publication!(publication, %{
        approval_ref: "approval:publish",
        approved_at: DateTime.add(@now, 1, :second),
        approved_by_actor_ref: "slack:user:U123",
        status: :publish_pending
      })

    assert_task_publication(review.card, "reviewing", :publish_pending, [])

    publication =
      update_publication!(publication, %{
        last_error_code: "publication_branch_already_exists",
        last_error_detail: "The branch changed before the first exact publication completed."
      })

    assert_task_publication(review.card, "action_required", :publish_pending, ["discard"])

    publication =
      update_publication!(publication, %{
        branch_ref: "refs/heads/responder/task-card",
        commit_sha: String.duplicate("a", 40),
        expected_remote_head_sha: String.duplicate("b", 40),
        github_repository: "emisar/responder",
        pull_request_number: 91,
        pull_request_url: "https://github.com/emisar/responder/pull/91"
      })

    assert_task_publication(review.card, "action_required", :publish_pending, [
      "open",
      "update",
      "discard"
    ])

    publication =
      update_publication!(publication, %{
        expected_remote_head_sha: nil,
        last_error_code: nil,
        last_error_detail: nil,
        publication_receipt: %{"pull_request" => 91},
        publication_receipt_fingerprint: digest("publication:receipt"),
        published_at: DateTime.add(@now, 2, :second),
        pull_request_number: 91,
        pull_request_url: "https://github.com/emisar/responder/pull/91",
        status: :published_ready
      })

    assert_task_publication(review.card, "reviewing", :published_ready, ["open"])

    publication =
      update_publication!(publication, %{
        published_delivery_receipt: %{"message_ref" => "published-message"},
        published_delivery_receipt_fingerprint: digest("published:receipt"),
        status: :published
      })

    assert_task_publication(review.card, "published", :published, ["open", "check"])

    _publication =
      update_publication!(publication, %{
        expected_remote_head_sha: String.duplicate("b", 40)
      })

    assert {:ok, stale_projection} = TaskCardProjection.build(review.card)
    stale_task = stale_projection.document["task_card"]
    assert stale_task["status"] == "action_required"
    assert stale_task["action_needed"] =~ "head changed"

    assert stale_task["publication"]["controls"] == [
             "open",
             "check",
             "update",
             "discard"
           ]

    assert {:ok, _complete} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "The pull request is published.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: review.episode.key,
                 expected_turn_ref: review.episode.owner_ref,
                 result_ref: "result:publication-review-complete"
               })
             )

    blocked = confirmed_card!("publication-blocked")

    blocked_publication =
      blocked
      |> publication!("blocked")
      |> update_publication!(%{
        last_error_detail: "The branch protection review could not be verified.",
        review_document: %{"gate" => "failed", "publishable" => false},
        review_fingerprint: digest("review:blocked"),
        review_delivery_receipt: %{"message_ref" => "blocked-message"},
        review_delivery_receipt_fingerprint: digest("blocked:receipt"),
        reviewed_at: @now,
        status: :blocked
      })

    assert blocked_publication.status == :blocked
    assert {:ok, projection} = TaskCardProjection.build(blocked.card)
    task = projection.document["task_card"]
    assert task["status"] == "action_required"
    assert task["action_needed"] =~ "operator attention"
    refute task["action_needed"] =~ "branch protection"
    assert task["publication"]["controls"] == ["update", "discard"]
  end

  test "task cards expose event verification and stop-in-progress without losing their thread" do
    event_wait = confirmed_card!("event-record")
    assert {:ok, claim} = Custody.claim_next("task-card:event-record", 60, :work)
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    deadline = ~U[2099-08-28 13:00:00.000000Z]

    assert {:ok, wait_record} =
             Records.create(Records.token(claim.turn), "task-event-wait", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{"deployment" => "responder"},
               "kind" => "deployment_health",
               "verification" => "Verify every production allocation is healthy."
             })

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: event_wait.episode.key,
                 expected_turn_ref: event_wait.episode.owner_ref,
                 kind: :event,
                 wait_ref: wait_record.ref
               })
             )

    assert {:ok, projection} = TaskCardProjection.build(event_wait.card)
    assert projection.document["task_card"]["action_needed"] =~ "production allocation"

    stopping = confirmed_card!("stopping")
    assert {:ok, stopping_claim} = Custody.claim_next("task-card:stopping", 60, :work)

    assert {:ok, %{status: :pending}} =
             Custody.request_block(
               stopping.episode.id,
               stopping.episode.key,
               stopping_claim.turn.turn_ref,
               stopping_claim.lease_ref,
               "A protocol mismatch requires safe remote cleanup."
             )

    assert {:ok, projection} = TaskCardProjection.build(stopping.card)
    task = projection.document["task_card"]
    assert task["status"] == "stopping"
    refute "close" in task["controls"]
  end

  defp delivered_offer!(suffix, thread_ref \\ "1787832000.000100") do
    fixture = delivered_offers!(suffix, [default_task_offer()], thread_ref)
    Map.put(fixture, :record, hd(fixture.records))
  end

  defp delivered_offers!(suffix, payloads, thread_ref \\ "1787832000.000100") do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: thread_ref,
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "task-offer-source:#{suffix}:#{episode_id}",
        native_input_id: "slack-message:task-offer:#{suffix}:#{episode_id}",
        occurred_at: @now,
        turn_ref: "turn:task-offer:#{suffix}:#{episode_id}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:task-offer:#{suffix}", 60, :work)

    # These existing structural task fixtures disclose no external knowledge;
    # attest that explicitly instead of treating missing lineage as authority.
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    records =
      payloads
      |> Enum.with_index(1)
      |> Enum.map(fn {payload, index} ->
        assert {:ok, record} =
                 Records.create(
                   Records.token(claim.turn),
                   "task-offer-#{index}",
                   "task_offer",
                   payload
                 )

        record
      end)

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode_id},
               "Handle the task offer source.",
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
               "coop-session:task-offer:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:task-offer:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"I can prepare that change."})
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

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "I can prepare that change.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => Enum.map(records, & &1.ref),
                 "state" => "complete"
               }
             })

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
               "validation-receipt:task-offer:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:task-offer:#{suffix}", 60, :delivery)

    assert delivery_claim.turn.id == accepted.turn.id

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               thread_ref,
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

    %{episode: settled.episode, receipt: receipt, records: records}
  end

  defp default_task_offer do
    %{
      "kind" => "engineering",
      "prompt" => "Change the parser and run focused tests.",
      "repository" => "responder",
      "title" => "Fix parser retries"
    }
  end

  defp card_worker_options(agent) do
    %{
      api: CardAPI,
      check_interval_seconds: 60,
      client: agent,
      interval_ms: 1_000,
      lease_seconds: 60,
      retry_base_seconds: 1,
      worker_ref: "task-card-test"
    }
  end

  defp confirmed_card!(suffix) do
    fixture = delivered_offer!(suffix)
    assert {:ok, confirmation} = TaskOffers.confirm(confirmation(fixture))
    assert {:ok, card} = TaskCards.ensure_one()
    %{card: card, episode: confirmation.episode}
  end

  defp publication!(fixture, suffix) do
    record = Repo.get!(Record, fixture.card.record_id)
    session = Repo.get_by!(Session, episode_id: fixture.episode.id)

    %{
      body: "Publish the reviewed parser retry fix.",
      destination_conversation_ref: fixture.episode.destination_conversation_ref,
      destination_thread_ref: fixture.episode.destination_thread_ref,
      destination_transport: fixture.episode.destination_transport,
      episode_id: fixture.episode.id,
      id: Ecto.UUID.generate(),
      offer_message_ref: "offer-message:#{suffix}",
      record_id: record.id,
      ref: "publication:task-card:#{suffix}:#{record.id}",
      repository: "responder",
      review_request_ref: "review-request:#{suffix}:#{record.id}",
      review_requested_at: @now,
      review_requested_by_actor_ref: "slack:user:U123",
      session_id: session.id,
      status: :review_pending,
      title: "Fix parser retries"
    }
    |> Changeset.insert()
    |> Repo.insert!()
  end

  defp update_publication!(publication, attributes) do
    publication |> Changeset.update(attributes) |> Repo.update!()
  end

  defp assert_task_publication(card, status, publication_status, controls) do
    assert {:ok, projection} = TaskCardProjection.build(card)
    task = projection.document["task_card"]
    assert task["status"] == status
    assert task["publication"]["status"] == Atom.to_string(publication_status)
    assert task["publication"]["controls"] == controls
    assert task["publication"]["recovery_generation"] == 1
  end

  defp confirmation(fixture) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:confirm",
      occurred_at: DateTime.add(@now, 2, :second),
      policy: %{digest: @policy_digest, name: "responder-contributor"},
      record_ref: fixture.record.ref,
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

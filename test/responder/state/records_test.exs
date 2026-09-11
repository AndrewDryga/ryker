defmodule Responder.State.RecordsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Slack.Event
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.State.{RecordChangeset, Records}
  alias Responder.Work.{Custody, Validator}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)

  test "a relative timer that cannot precede its deadline leaves no record" do
    # A real Airflow run promised a ten-minute verification, but no timer was
    # scheduled. Reject impossible promises at the tool, before final acceptance.
    claim = claim!("timer-deadline")
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    payload = %{
      "deadline_at" => now |> DateTime.add(300, :second) |> DateTime.to_iso8601(),
      "event_matcher" => %{
        "delay" => "10m",
        "on_timeout" => "Report the verification gap.",
        "type" => "after"
      },
      "kind" => "after",
      "verification" => "Verify Airflow after the observation window."
    }

    assert {:error, {:invalid_state_record, :timer_deadline}} =
             Records.create(Records.token(claim.turn), "impossible-timer", "event_wait", payload)

    assert Records.retained_records(claim.episode.id) == []
  end

  test "retrying a timer creation retains its original record and timing anchor" do
    claim = claim!("timer-idempotence")
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    payload = %{
      "deadline_at" => now |> DateTime.add(900, :second) |> DateTime.to_iso8601(),
      "event_matcher" => %{
        "delay" => "10m",
        "on_timeout" => "Report the verification gap.",
        "type" => "after"
      },
      "kind" => "after",
      "verification" => "Verify Airflow after the observation window."
    }

    token = Records.token(claim.turn)
    assert {:ok, original} = Records.create(token, "timer", "event_wait", payload)
    assert {:ok, retried} = Records.create(token, "timer", "event_wait", payload)
    assert retried.id == original.id
    assert retried.inserted_at == original.inserted_at
    assert retried.payload == original.payload
  end

  test "a source-event wait resumes only for its typed recursive matcher" do
    claim = claim!("source-event-matcher")

    assert {:ok, wait} =
             Records.create(Records.token(claim.turn), "deployment-wait", "event_wait", %{
               "deadline_at" => "2099-08-28T13:00:00.000000Z",
               "event_matcher" => %{
                 "cursor" => %{"revision" => "abc123"},
                 "match" => %{
                   "deployment" => %{"id" => "deploy-1"},
                   "state" => "healthy"
                 },
                 "on_timeout" => "Report that deployment verification timed out.",
                 "poll_after" => "2099-08-28T12:30:00.000000Z",
                 "source_kind" => "slack",
                 "type" => "source_event"
               },
               "kind" => "source_event",
               "verification" => "Verify all allocations are healthy."
             })

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :app, ref: "A123"},
               channel_ref: "C456",
               content: %{
                 "deployment" => %{"id" => "deploy-1", "region" => "va1"},
                 "state" => "healthy"
               },
               event_kind: :message,
               event_ref: "Ev-source-event-match",
               message_ref: "1787832000.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: "TAABB028FCC2E"
             })

    assert Records.user_resumable_wait?(wait.ref, input)
    assert Records.user_resumable_wait?(wait.ref)
    refute Records.user_resumable_wait?(nil)
    refute Records.user_resumable_wait?(wait.ref, %{input | content: %{"state" => "healthy"}})

    refute Records.user_resumable_wait?(wait.ref, %{
             input
             | source: %{kind: "github", ref: "main"}
           })

    assert {:ok, untyped_source} =
             Records.create(Records.token(claim.turn), "untyped-source", "event_wait", %{
               "deadline_at" => "2099-08-28T13:00:00.000000Z",
               "event_matcher" => %{
                 "match" => %{"state" => "healthy"},
                 "on_timeout" => "Report that verification timed out.",
                 "poll_after" => "2099-08-28T12:30:00.000000Z",
                 "type" => "source_event"
               },
               "kind" => "source_event",
               "verification" => "Verify the state."
             })

    assert Records.user_resumable_wait?(untyped_source.ref, %{
             input
             | source: %{kind: "github", ref: "main"}
           })

    assert {:ok, legacy_wait} =
             Records.create(Records.token(claim.turn), "legacy-event", "event_wait", %{
               "deadline_at" => "2099-08-28T13:00:00.000000Z",
               "event_matcher" => %{"deployment" => "responder"},
               "kind" => "deployment_health",
               "verification" => "Verify the legacy deployment wait."
             })

    assert Records.user_resumable_wait?(legacy_wait.ref, input)
  end

  test "an exact Terraform run wait matches enriched attachments but rejects other runs and bots" do
    # The recovered live episode saved this partial attachment matcher. Literal
    # list equality would ignore its next notification and force a fallback poll.
    claim = claim!("terraform-run-wait")
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    run = message["attachments"] |> hd() |> Map.take(["title", "title_link"])

    assert {:ok, wait} =
             Records.create(Records.token(claim.turn), "terraform-run", "event_wait", %{
               "deadline_at" => "2099-08-28T13:00:00.000000Z",
               "event_matcher" => %{
                 "match" => %{"bot_id" => message["bot_id"], "attachments" => [run]},
                 "on_timeout" => "Recheck the exact Terraform run; never apply changes.",
                 "poll_after" => "2099-08-28T12:30:00.000000Z",
                 "source_kind" => "slack",
                 "type" => "source_event"
               },
               "kind" => "source_event",
               "verification" => "Monitor the exact Terraform run through its terminal outcome."
             })

    assert {:ok, %{input: input}} =
             Event.from_socket(
               %{
                 "type" => "events_api",
                 "payload" => %{
                   "type" => "event_callback",
                   "team_id" => "T0BHXKZJVDX",
                   "event_id" => "Ev-terraform-run-wait",
                   "event" => message
                 }
               },
               %{
                 workspace_ref: "T0BHXKZJVDX",
                 bot_ref: "B-RESPONDER",
                 bot_user_ref: "U-RESPONDER"
               }
             )

    assert Records.user_resumable_wait?(wait.ref, input)

    reordered = Map.update!(input.content, "attachments", &Enum.reverse/1)
    assert Records.user_resumable_wait?(wait.ref, %{input | content: reordered})

    for wrong <- [
          Map.put(input.content, "bot_id", "B-OTHER"),
          Map.put(input.content, "attachments", []),
          Map.put(input.content, "attachments", [%{run | "title" => "Run another-run"}]),
          Map.put(input.content, "attachments", [Map.delete(run, "title_link")]),
          Map.put(input.content, "attachments", [
            Map.delete(run, "title"),
            Map.delete(run, "title_link")
          ])
        ] do
      refute Records.user_resumable_wait?(wait.ref, %{input | content: wrong})
    end
  end

  test "one active turn creates inert task, question, and event-wait records idempotently" do
    claim = claim!("typed-records")
    token = Records.token(claim.turn)

    task = %{
      "kind" => "engineering",
      "prompt" => "Change the parser and run its focused tests.",
      "repository" => "responder",
      "title" => "Fix parser retries"
    }

    assert {:ok, task_record} =
             Records.create(token, "task-offer", "task_offer", task)

    assert task_record.kind == "task_offer"
    assert task_record.payload == task
    assert task_record.ref =~ ~r/^record:task_offer:[0-9a-f]{32}$/
    assert task_record.continuation == nil

    assert {:ok, duplicate} =
             Records.create(token, "task-offer", "task_offer", task)

    assert duplicate.id == task_record.id

    changed = %{task | "title" => "A different task"}

    assert {:error, :state_record_operation_conflict} =
             Records.create(token, "task-offer", "task_offer", changed)

    assert {:ok, question} =
             Records.create(token, "operator-question", "input_request", %{
               "choices" => ["Production", "Staging"],
               "question" => "Which environment should I inspect?"
             })

    assert question.continuation == %{
             "deadline_at" => nil,
             "kind" => "wait",
             "wait_kind" => "input",
             "wait_ref" => question.ref
           }

    records = Records.validation_records(claim.episode.id)

    assert records[task_record.ref] == %{
             "continuation" => nil,
             "kind" => "task_offer"
           }

    candidate =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Which environment should I inspect?",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [question.ref],
          "state" => "waiting_for_input"
        }
      })

    assert {:accept, accepted} =
             Validator.validate(
               candidate,
               %{
                 "artifact_delivery_supported" => true,
                 "artifact_metadata" => [],
                 "artifact_refs" => [],
                 "execution_mode" => "live",
                 "open_required_goals" => [],
                 "records" => records,
                 "slack_mentions" => nil,
                 "visible_reply_required" => true,
                 "workspace" => nil
               },
               @now
             )

    assert accepted.result.continuation == question.continuation

    assert {:ok, event_wait} =
             Records.create(token, "deployment-wait", "event_wait", %{
               "deadline_at" => "2099-08-28T13:00:00.000000Z",
               "event_matcher" => %{"deployment_id" => "deploy-1"},
               "kind" => "deployment",
               "verification" => "All allocations are healthy."
             })

    assert event_wait.continuation == %{
             "deadline_at" => "2099-08-28T13:00:00.000000Z",
             "kind" => "wait",
             "wait_kind" => "event",
             "wait_ref" => event_wait.ref
           }
  end

  test "a record capability is scoped to the exact live episode turn" do
    claim = claim!("record-capability")
    task = task_payload()

    assert {:error, :state_record_unauthorized} =
             Records.create("state:not-a-turn", "task", "task_offer", task)

    assert {:ok, _cancelled} =
             Custody.request_cancel(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               "cancel:records",
               "Stop this work."
             )

    assert {:error, :state_record_unauthorized} =
             Records.create(Records.token(claim.turn), "task", "task_offer", task)
  end

  test "shadow turns can retain evidence but cannot create offers, waits, or authority" do
    claim = claim!("shadow-records", :shadow)
    token = Records.token(claim.turn)

    assert {:ok, evidence} =
             Records.create(token, "shadow-evidence", "evidence", %{
               "claim_id" => "service.health",
               "observation" => "The current read-only probe returned 503.",
               "source_name" => "service probe",
               "source_type" => "monitoring",
               "target" => "service.production"
             })

    assert evidence.kind == "evidence"

    assert Records.create(token, "shadow-task", "task_offer", task_payload()) ==
             {:error, :state_record_shadow_forbidden}

    assert Records.create(token, "shadow-question", "input_request", %{
             "choices" => [],
             "question" => "Should I continue?"
           }) == {:error, :state_record_shadow_forbidden}
  end

  test "destinations without an operator confirmation surface cannot create inert offers" do
    claim = claim!("unsupported-offers", :live, "email")
    token = Records.token(claim.turn)

    for {kind, payload} <- [
          {"task_offer", task_payload()},
          {"publication_offer", %{"body" => "Ready for review.", "title" => "Review it"}},
          {"memory_offer",
           %{
             "expires_in" => "30d",
             "kind" => "fact",
             "repository" => nil,
             "scope" => "conversation",
             "subject" => "service_owner",
             "value" => "platform",
             "visibility" => "conversation"
           }}
        ] do
      assert Records.create(token, "unsupported-#{kind}", kind, payload) ==
               {:error, :state_record_confirmation_unsupported}
    end

    assert {:ok, _question} =
             Records.create(token, "unsupported-question", "input_request", %{
               "choices" => [],
               "question" => "Which rollout should I inspect?"
             })
  end

  test "record payloads are strict and bounded before anything is persisted" do
    claim = claim!("record-validation")
    token = Records.token(claim.turn)

    cases = [
      {"task_offer", Map.put(task_payload(), "unknown", true), :fields},
      {"task_offer", %{task_payload() | "kind" => "deploy"}, :kind},
      {"input_request", %{"choices" => [], "question" => " "}, :question},
      {"input_request",
       %{"choices" => Enum.map(1..11, &Integer.to_string/1), "question" => "Pick"}, :choices},
      {"event_wait",
       %{
         "deadline_at" => "not-a-time",
         "event_matcher" => %{},
         "kind" => "other",
         "verification" => "Check it."
       }, :deadline_at},
      {"unknown", %{}, :kind}
    ]

    Enum.with_index(cases, fn {kind, payload, field}, index ->
      assert Records.create(token, "invalid-#{index}", kind, payload) ==
               {:error, {:invalid_state_record, field}}
    end)
  end

  test "investigation records carry evidence, findings, goals, progress, and assessments" do
    claim = claim!("investigation-ledger")
    token = Records.token(claim.turn)

    evidence_payload = %{
      "claim" => "The API is serving healthy responses.",
      "claim_id" => "api.current_health",
      "confidence" => "high",
      "dimensions" => %{"http_status" => 200, "ready" => true},
      "freshness" => "current probe",
      "health_effect" => "none",
      "observation" => "The production health probe returned ready with no failing checks.",
      "observed_at" => "2026-08-28T12:00:00.000000Z",
      "relation" => "supports",
      "scope_note" => "The public API endpoint only.",
      "source_id" => "probe-20260828-1200",
      "source_name" => "production health probe",
      "source_type" => "monitoring",
      "supersedes" => [],
      "target" => "api.production"
    }

    assert {:ok, evidence} =
             Records.create(token, "evidence-api-health", "evidence", evidence_payload)

    assert evidence.payload["dimensions"] == %{"http_status" => 200, "ready" => true}

    assert {:ok, coverage} =
             Records.create(token, "coverage-api", "coverage", %{
               "claim_ids" => ["api.current_health"],
               "detail" => "The public API path is healthy; background workers were not sampled.",
               "layer" => "application",
               "observed_at" => "2026-08-28T12:00:00.000000Z",
               "source" => "production health probe",
               "status" => "healthy"
             })

    assert {:ok, finding} =
             Records.create(token, "finding-worker-gap", "finding", %{
               "alternatives" => [
                 %{
                   "claim_id" => "worker.current_health",
                   "hypothesis" => "The workers are also healthy.",
                   "not_checkable" => "No worker metric was available in this turn."
                 }
               ],
               "cause_evidence" => [],
               "reason" => nil,
               "scope" => "Background workers",
               "status" => "unexplained",
               "what" => "Background-worker health was not verified."
             })

    assert {:ok, progress} =
             Records.create(token, "progress-health", "progress", %{
               "next_due_at" => "2026-08-28T12:10:00.000000Z",
               "phase" => "verifying",
               "summary" => "The API is healthy; worker verification remains."
             })

    assert {:ok, goal} =
             Records.create(token, "goal-workers", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "A current worker-health observation is recorded.",
               "id" => "verify-workers",
               "kind" => "check",
               "prerequisite_goal_ids" => [],
               "read_only_repositories" => [],
               "requested_outcome" => "Verify background-worker health",
               "required" => true,
               "stage" => "implementation",
               "writable_repository" => nil
             })

    assert goal.subject_ref == "verify-workers"

    assert [%{"id" => "verify-workers", "state" => "ready"}] =
             Records.open_required_goals(claim.episode.id)

    assert {:ok, assessment} =
             Records.create(token, "assessment-api", "alert_assessment", %{
               "cause" => nil,
               "cause_claim_ids" => [],
               "cause_status" => nil,
               "evidence_refs" => [],
               "immediate_action" => "Inspect a current worker-health signal.",
               "immediate_action_kind" => "investigation",
               "impact" => "The public API is healthy, but worker health is not verified.",
               "long_term_solution" => nil,
               "scope" => %{
                 "checked_targets" => ["api.production"],
                 "evidence_refs" => [evidence.ref],
                 "status" => "bounded",
                 "unverified_targets" => ["workers.production"],
                 "universe_evidence_ref" => nil
               },
               "verification" => nil,
               "verdict" => "unverified"
             })

    assert {:ok, goal_state} =
             Records.create(token, "goal-workers-blocked", "goal_state", %{
               "detail" => "No worker metric was available.",
               "goal_id" => "verify-workers",
               "state" => "blocked"
             })

    assert [%{"id" => "verify-workers", "state" => "blocked"}] =
             Records.open_required_goals(claim.episode.id)

    assert Enum.map(
             [evidence, coverage, finding, progress, goal, assessment, goal_state],
             & &1.kind
           ) ==
             ~w(evidence coverage finding progress goal alert_assessment goal_state)
  end

  test "required goals block completion until a durable terminal goal state exists" do
    claim = claim!("required-goal")
    token = Records.token(claim.turn)

    assert {:ok, _goal} =
             Records.create(token, "goal-plan", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "The exact service state is observed.",
               "id" => "check-service",
               "kind" => "check",
               "prerequisite_goal_ids" => [],
               "read_only_repositories" => [],
               "requested_outcome" => "Check the service",
               "required" => true,
               "stage" => "implementation",
               "writable_repository" => nil
             })

    complete =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "The service is healthy.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    validation_context = %{
      "artifact_delivery_supported" => true,
      "artifact_metadata" => [],
      "artifact_refs" => [],
      "execution_mode" => "live",
      "open_required_goals" => Records.open_required_goals(claim.episode.id),
      "records" => Records.validation_records(claim.episode.id),
      "slack_mentions" => nil,
      "visible_reply_required" => true,
      "workspace" => nil
    }

    assert {:reject, [violation]} = Validator.validate(complete, validation_context, @now)
    assert violation =~ "check-service"
    assert violation =~ "update_goal"

    assert {:ok, _state} =
             Records.create(token, "goal-complete", "goal_state", %{
               "detail" => "The production health check is current.",
               "goal_id" => "check-service",
               "state" => "completed"
             })

    assert [] = Records.open_required_goals(claim.episode.id)

    assert {:accept, _accepted} =
             Validator.validate(
               complete,
               %{validation_context | "open_required_goals" => []},
               @now
             )
  end

  test "parent goals finalize only after children and prerequisites reach terminal state" do
    claim = claim!("goal-dependencies")
    token = Records.token(claim.turn)

    assert {:ok, _parent} =
             Records.create(token, "goal-parent", "goal", goal("deliver-change"))

    assert Records.create(
             token,
             "goal-missing-parent",
             "goal",
             goal("orphan", %{"parent_goal_id" => "missing"})
           ) == {:error, {:invalid_state_record, :parent_goal_id}}

    assert {:ok, _implementation} =
             Records.create(
               token,
               "goal-implementation",
               "goal",
               goal("implement", %{"parent_goal_id" => "deliver-change"})
             )

    assert {:ok, _verification} =
             Records.create(
               token,
               "goal-verification",
               "goal",
               goal("verify", %{
                 "parent_goal_id" => "deliver-change",
                 "prerequisite_goal_ids" => ["implement"]
               })
             )

    assert Records.create(token, "start-verification-early", "goal_state", %{
             "goal_id" => "verify",
             "state" => "working"
           }) == {:error, {:invalid_state_record, :prerequisite_goal_ids}}

    assert Records.create(token, "complete-parent-early", "goal_state", %{
             "goal_id" => "deliver-change",
             "state" => "completed"
           }) == {:error, {:invalid_state_record, :child_goal_ids}}

    for {operation, goal_id, state} <- [
          {"start-implementation", "implement", "working"},
          {"complete-implementation", "implement", "completed"},
          {"start-verification", "verify", "working"},
          {"complete-verification", "verify", "completed"},
          {"complete-parent", "deliver-change", "completed"}
        ] do
      assert {:ok, _state} =
               Records.create(token, operation, "goal_state", %{
                 "goal_id" => goal_id,
                 "state" => state
               })
    end

    assert [] = Records.open_required_goals(claim.episode.id)

    assert Records.create(token, "reopen-parent", "goal_state", %{
             "goal_id" => "deliver-change",
             "state" => "working"
           }) == {:error, {:invalid_state_record, :goal_state}}
  end

  test "independent working goals are bounded and capacity returns after one stops" do
    claim = claim!("goal-parallelism")
    token = Records.token(claim.turn)

    Enum.each(1..4, fn index ->
      assert {:ok, _goal} =
               Records.create(token, "plan-#{index}", "goal", goal("goal-#{index}"))
    end)

    Enum.each(1..3, fn index ->
      assert {:ok, _state} =
               Records.create(token, "start-#{index}", "goal_state", %{
                 "goal_id" => "goal-#{index}",
                 "state" => "working"
               })
    end)

    assert Records.create(token, "start-4", "goal_state", %{
             "goal_id" => "goal-4",
             "state" => "working"
           }) == {:error, {:invalid_state_record, :parallel_goal_limit}}

    assert {:ok, _state} =
             Records.create(token, "complete-1", "goal_state", %{
               "goal_id" => "goal-1",
               "state" => "completed"
             })

    assert {:ok, _state} =
             Records.create(token, "start-4", "goal_state", %{
               "goal_id" => "goal-4",
               "state" => "working"
             })

    limited = claim!("goal-parallelism-limited")
    limited_token = Records.token(limited.turn)

    for id <- ["one", "two"] do
      assert {:ok, _goal} =
               Records.create(limited_token, "plan-limited-#{id}", "goal", goal(id))
    end

    assert {:ok, _state} =
             Records.create(
               limited_token,
               "start-limited-one",
               "goal_state",
               %{"goal_id" => "one", "state" => "working"},
               parallel_goal_limit: 1
             )

    assert Records.create(
             limited_token,
             "start-limited-two",
             "goal_state",
             %{"goal_id" => "two", "state" => "working"},
             parallel_goal_limit: 1
           ) == {:error, {:invalid_state_record, :parallel_goal_limit}}
  end

  test "implementation subtasks count current leaves once, never parent headings or self-review goals" do
    # The old card counted every goal in one flat list, so a parent heading,
    # its two children and a review goal read as "1 of 4 completed" while the
    # actual implementation plan was half done.
    claim = claim!("stage-local-counts")
    token = Records.token(claim.turn)

    assert {:ok, _plan} =
             Records.create(
               token,
               "plan-approach",
               "goal",
               goal("choose-approach", %{"stage" => "planning"})
             )

    assert {:ok, _parent} = Records.create(token, "plan-parent", "goal", goal("deliver-change"))

    for id <- ["persist-checkpoints", "restore-checkpoints"] do
      assert {:ok, _child} =
               Records.create(
                 token,
                 "plan-#{id}",
                 "goal",
                 goal(id, %{"parent_goal_id" => "deliver-change"})
               )
    end

    assert {:ok, _review} =
             Records.create(
               token,
               "plan-review",
               "goal",
               goal("review-retry-correctness", %{"stage" => "self_review"})
             )

    assert {:ok, _state} =
             Records.create(token, "complete-persist", "goal_state", %{
               "goal_id" => "persist-checkpoints",
               "state" => "completed"
             })

    plan = Records.plan(claim.episode.id)

    assert %{"completed" => 1, "excluded" => 0, "total" => 2} =
             Map.take(plan["implementation"], ~w(completed excluded total))

    assert Enum.map(plan["implementation"]["goals"], &{&1["id"], &1["leaf"]}) == [
             {"deliver-change", false},
             {"persist-checkpoints", true},
             {"restore-checkpoints", true}
           ]

    assert %{"completed" => 0, "total" => 1} = Map.take(plan["planning"], ~w(completed total))
    assert %{"completed" => 0, "total" => 1} = Map.take(plan["self_review"], ~w(completed total))
    assert plan["unassigned"]["goals"] == []

    # An excluded leaf leaves the denominator and is reported separately; the
    # count must never silently become 1/1.
    assert {:ok, _state} =
             Records.create(token, "exclude-restore", "goal_state", %{
               "detail" => "Restoring after restart is covered by the existing supervisor test.",
               "goal_id" => "restore-checkpoints",
               "state" => "excluded"
             })

    assert %{"completed" => 1, "excluded" => 1, "total" => 1} =
             Map.take(
               Records.plan(claim.episode.id)["implementation"],
               ~w(completed excluded total)
             )
  end

  test "a successor attempt links to its terminal predecessor without mutating the old result" do
    claim = claim!("successor-attempts")
    token = Records.token(claim.turn)

    assert {:ok, _goal} =
             Records.create(
               token,
               "plan-checks",
               "goal",
               goal("run-checks", %{"stage" => "self_review"})
             )

    assert Records.create(
             token,
             "premature-successor",
             "goal",
             goal("run-checks-2", %{"stage" => "self_review", "successor_of" => "run-checks"})
           ) == {:error, {:invalid_state_record, :successor_of}}

    assert {:ok, _state} =
             Records.create(token, "complete-checks", "goal_state", %{
               "goal_id" => "run-checks",
               "state" => "completed"
             })

    assert Records.create(
             token,
             "cross-stage-successor",
             "goal",
             goal("run-checks-2", %{"stage" => "implementation", "successor_of" => "run-checks"})
           ) == {:error, {:invalid_state_record, :stage}}

    assert {:ok, successor} =
             Records.create(
               token,
               "successor",
               "goal",
               goal("run-checks-2", %{"stage" => "self_review", "successor_of" => "run-checks"})
             )

    assert successor.payload["successor_of"] == "run-checks"

    assert Records.create(
             token,
             "second-successor",
             "goal",
             goal("run-checks-3", %{"stage" => "self_review", "successor_of" => "run-checks"})
           ) == {:error, {:invalid_state_record, :successor_of}}

    goals = Map.new(Records.goals(claim.episode.id), &{&1["id"], &1})
    assert goals["run-checks"]["state"] == "completed"
    assert goals["run-checks"]["successor_id"] == "run-checks-2"
    assert goals["run-checks-2"]["state"] == "ready"
    assert goals["run-checks-2"]["successor_of"] == "run-checks"

    assert Records.create(token, "reopen-checks", "goal_state", %{
             "goal_id" => "run-checks",
             "state" => "working"
           }) == {:error, {:invalid_state_record, :goal_state}}

    plan = Records.plan(claim.episode.id)["self_review"]
    assert Enum.map(plan["goals"], & &1["id"]) == ["run-checks-2"]
    assert %{"completed" => 0, "total" => 1} = Map.take(plan, ~w(completed total))
  end

  test "a child goal cannot claim a different stage than its parent" do
    claim = claim!("stage-conflict")
    token = Records.token(claim.turn)

    assert {:ok, _parent} = Records.create(token, "plan-parent", "goal", goal("deliver-change"))

    assert Records.create(
             token,
             "plan-child",
             "goal",
             goal("verify-change", %{
               "parent_goal_id" => "deliver-change",
               "stage" => "self_review"
             })
           ) == {:error, {:invalid_state_record, :stage}}
  end

  test "a parent heading never consumes working capacity from its subtasks" do
    claim = claim!("parent-capacity")
    token = Records.token(claim.turn)

    assert {:ok, _parent} = Records.create(token, "plan-parent", "goal", goal("deliver-change"))

    for index <- 1..4 do
      assert {:ok, _child} =
               Records.create(
                 token,
                 "plan-child-#{index}",
                 "goal",
                 goal("child-#{index}", %{"parent_goal_id" => "deliver-change"})
               )
    end

    assert {:ok, _state} =
             Records.create(token, "start-parent", "goal_state", %{
               "goal_id" => "deliver-change",
               "state" => "working"
             })

    for index <- 1..3 do
      assert {:ok, _state} =
               Records.create(token, "start-child-#{index}", "goal_state", %{
                 "goal_id" => "child-#{index}",
                 "state" => "working"
               })
    end

    assert Records.create(token, "start-child-4", "goal_state", %{
             "goal_id" => "child-4",
             "state" => "working"
           }) == {:error, {:invalid_state_record, :parallel_goal_limit}}
  end

  test "goal evidence must resolve to this episode's own evidence records" do
    claim = claim!("goal-evidence")
    token = Records.token(claim.turn)

    assert {:ok, _goal} =
             Records.create(
               token,
               "plan-checks",
               "goal",
               goal("run-checks", %{"stage" => "self_review"})
             )

    assert Records.create(token, "complete-unbacked", "goal_state", %{
             "evidence_refs" => ["record:evidence:missing"],
             "goal_id" => "run-checks",
             "state" => "completed"
           }) == {:error, {:invalid_state_record, :evidence_refs}}

    assert {:ok, evidence} =
             Records.create(token, "evidence-tests", "evidence", %{
               "claim_id" => "checks.focused",
               "observation" => "The focused suite passed on the current workspace.",
               "source_name" => "mix test",
               "source_type" => "repository"
             })

    assert {:ok, state} =
             Records.create(token, "complete-backed", "goal_state", %{
               "evidence_refs" => [evidence.ref],
               "goal_id" => "run-checks",
               "state" => "completed"
             })

    assert state.payload["evidence_refs"] == [evidence.ref]
    assert [goal] = Records.goals(claim.episode.id)
    assert goal["evidence_refs"] == [evidence.ref]
  end

  test "historical goals without a stage stay explicitly unrecorded" do
    # Records persisted before typed membership existed carry no stage. They
    # must surface as unassigned, never be backfilled into a plausible stage.
    claim = claim!("legacy-goal")

    legacy = %{
      "authority" => "read_only",
      "completion_contract" => "Backend service endpoint health observed.",
      "id" => "goal-1",
      "kind" => "check",
      "requested_outcome" => "Confirm the portal backend actually recovered",
      "required" => true
    }

    assert {:ok, _record} =
             %{
               continuation: nil,
               episode_id: claim.episode.id,
               id: Ecto.UUID.generate(),
               kind: "goal",
               operation_id: "legacy-goal",
               payload: legacy,
               payload_fingerprint: String.duplicate("0", 64),
               ref: "record:goal:legacy",
               status: :open,
               subject_ref: "goal-1",
               turn_id: claim.turn.id
             }
             |> RecordChangeset.insert()
             |> Repo.insert()

    assert [%{"id" => "goal-1", "stage" => nil, "state" => "ready"}] =
             Records.goals(claim.episode.id)

    plan = Records.plan(claim.episode.id)
    assert Enum.map(plan["unassigned"]["goals"], & &1["id"]) == ["goal-1"]
    assert plan["implementation"]["goals"] == []
    assert plan["implementation"]["total"] == 0
  end

  test "investigation relationships cannot cite missing or contradictory host records" do
    claim = claim!("investigation-relationships")
    token = Records.token(claim.turn)

    assert Records.create(token, "missing-goal-state", "goal_state", %{
             "goal_id" => "missing-goal",
             "state" => "completed"
           }) == {:error, {:invalid_state_record, :goal_id}}

    goal = %{
      "authority" => "read_only",
      "completion_contract" => "An observation exists.",
      "id" => "observe-service",
      "kind" => "check",
      "requested_outcome" => "Observe service health",
      "required" => true,
      "stage" => "implementation"
    }

    assert {:ok, _goal} = Records.create(token, "goal-one", "goal", goal)

    assert Records.create(token, "goal-duplicate", "goal", goal) ==
             {:error, :state_record_subject_conflict}

    self_dependent =
      Map.merge(goal, %{
        "id" => "self-dependent",
        "prerequisite_goal_ids" => ["self-dependent"]
      })

    assert Records.create(token, "goal-self", "goal", self_dependent) ==
             {:error, {:invalid_state_record, :prerequisite_goal_ids}}

    assert Records.create(token, "finding-missing-evidence", "finding", %{
             "cause_evidence" => ["record:evidence:missing"],
             "status" => "explained",
             "what" => "The service failed."
           }) == {:error, {:invalid_state_record, :cause_evidence}}

    assert {:ok, evidence} =
             Records.create(token, "evidence-service", "evidence", %{
               "claim_id" => "service.health",
               "observation" => "The service returned an error.",
               "source_name" => "service probe",
               "source_type" => "monitoring",
               "target" => "service.production"
             })

    assert Records.create(token, "assessment-wrong-claim", "alert_assessment", %{
             "cause" => "The service returned an error.",
             "cause_claim_ids" => ["different.claim"],
             "cause_status" => "identified",
             "evidence_refs" => [evidence.ref],
             "immediate_action" => "Mitigate the failing service.",
             "impact" => "Production requests fail.",
             "long_term_solution" => "Repair the service.",
             "verification" => "The probe is healthy.",
             "verdict" => "confirmed_issue"
           }) == {:error, {:invalid_state_record, :cause_claim_ids}}

    assert Records.create(token, "assessment-wrong-target", "alert_assessment", %{
             "impact" => "The checked target is unhealthy.",
             "immediate_action" => "Inspect it.",
             "scope" => %{
               "checked_targets" => ["different.target"],
               "evidence_refs" => [evidence.ref],
               "status" => "bounded",
               "unverified_targets" => ["workers.production"]
             },
             "verdict" => "unverified"
           }) == {:error, {:invalid_state_record, :checked_targets}}
  end

  defp claim!(suffix, execution_mode \\ :live, transport \\ "slack") do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "state:#{suffix}",
        destination: %{
          conversation_ref: "#{transport}:conversation:#{suffix}",
          thread_ref: "#{transport}:thread:#{suffix}",
          transport: transport
        },
        execution_mode: execution_mode,
        native_input_id: "source:#{suffix}",
        payload: %{"text" => "Please help."},
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "test-policy", @policy_digest)

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    claim
  end

  defp task_payload do
    %{
      "kind" => "engineering",
      "prompt" => "Make the requested repository change.",
      "repository" => "responder",
      "title" => "Implement the change"
    }
  end

  defp goal(id, overrides \\ %{}) do
    Map.merge(
      %{
        "authority" => "read_only",
        "completion_contract" => "The requested outcome is demonstrably complete.",
        "id" => id,
        "kind" => "check",
        "prerequisite_goal_ids" => [],
        "read_only_repositories" => [],
        "requested_outcome" => "Complete #{id}",
        "required" => true,
        "stage" => "implementation",
        "writable_repository" => nil
      },
      overrides
    )
  end
end

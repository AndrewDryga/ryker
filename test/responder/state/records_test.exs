defmodule Responder.State.RecordsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.State.Records
  alias Responder.Work.{Custody, Validator}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)

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
    claim = claim!("github-offers", :live, "github")
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
             Records.create(token, "github-question", "input_request", %{
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
      "required" => true
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
end

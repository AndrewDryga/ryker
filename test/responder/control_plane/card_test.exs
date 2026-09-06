defmodule Responder.ControlPlane.CardTest do
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.{Card, HTML}
  alias Responder.Publication.Publication
  alias Responder.State.{Record, RecordPayload}

  @digest String.duplicate("a", 64)
  @git String.duplicate("b", 40)

  test "a completed goal transition never displays the record storage status as Open" do
    # Harvested from Lab bd9abb20: a successful acceptance still showed GOAL STATE OPEN.
    payload = %{
      "detail" =>
        "Read README.md and /etc/os-release successfully (both exit 0); called Emisar list_packs exactly once, which returned ok:true and isError:false. No repository, infrastructure, or communication-platform changes performed.",
      "goal_id" => "read-only-acceptance",
      "state" => "completed"
    }

    assert {:ok, card} = Card.project(record("goal_state", payload))
    assert card.title == "Completed"
    assert Card.display_status(card) == nil
    assert card.label == "Goal updated"
    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ "Completed"
    refute html =~ ">open<"
  end

  test "publication review and result cards expose only typed host actions" do
    publication = %Publication{
      ref: "publication:lab:one",
      repository: "responder",
      review_document: %{
        "candidate_tree" => @git,
        "gate" => "passed",
        "not_publishable_reasons" => [],
        "patch_bytes" => 4_096,
        "patch_digest" => @digest,
        "policy_findings" => [],
        "publishable" => true,
        "rebase" => "clean"
      },
      status: :reviewed,
      title: "Finish Conversation Lab parity"
    }

    assert {:ok, review} = Card.project_publication(publication, "record:publication_offer:one")
    assert review.kind == "publication_review"
    assert review.action == :approve_publication
    assert review.ref == "record:publication_offer:one"
    assert review.status == :reviewed
    assert {"Gate", "passed"} in review.details
    assert {"Patch", "4096 bytes"} in review.details
    assert review.url == nil

    published = %{
      publication
      | publication_receipt: %{
          "branch_ref" => "responder/lab-parity",
          "commit_sha" => @git,
          "pull_request_number" => 42,
          "pull_request_url" => "https://github.com/example/responder/pull/42"
        },
        status: :published
    }

    assert {:ok, result} = Card.project_publication(published, "record:publication_offer:one")
    assert result.kind == "publication_result"
    assert result.action == :check_publication
    assert result.status == :published
    assert result.url == "https://github.com/example/responder/pull/42"
    assert {"Pull request", "#42"} in result.details

    unsafe = put_in(published.publication_receipt["pull_request_url"], "javascript:alert(1)")
    assert {:ok, safe} = Card.project_publication(unsafe, "record:publication_offer:one")
    assert safe.url == nil

    blocked = %{
      publication
      | review_document: %{
          publication.review_document
          | "not_publishable_reasons" => ["The focused gate failed."],
            "publishable" => false
        },
        status: :blocked
    }

    assert {:ok, blocked_card} =
             Card.project_publication(blocked, "record:publication_offer:one")

    assert blocked_card.action == nil
    assert blocked_card.summary == "The focused gate failed."

    no_reasons = put_in(blocked.review_document["not_publishable_reasons"], [])
    assert {:ok, no_reasons_card} = Card.project_publication(no_reasons, publication.ref)
    assert no_reasons_card.summary == "The candidate is not publishable."

    invalid_review = %{publication | review_document: %{}, status: :reviewed}
    assert Card.project_publication(invalid_review, publication.ref) == :ignore
    assert Card.project_publication(%Publication{}, publication.ref) == :ignore
  end

  test "every source-neutral Slack-equivalent record has a typed Lab card" do
    cases = [
      {"task_offer",
       %{
         "kind" => "incident",
         "prompt" => "Investigate the alert.",
         "repository" => nil,
         "title" => "Investigate API health"
       }, "Local incident", :open_incident},
      {"publication_offer",
       %{"body" => "Publish only after review.", "title" => "Review the patch"},
       "Publication review", :review_publication},
      {"schedule_offer",
       %{
         "authority" => "read_only",
         "catch_up" => "latest",
         "expires_at" => nil,
         "recurrence" => %{"kind" => "daily", "time" => "09:00:00"},
         "repository" => nil,
         "task" => "Review the current Emisar workspace health.",
         "timezone" => "Etc/UTC",
         "title" => "Daily Emisar health"
       }, "Schedule", :confirm_schedule},
      {"automation_change_offer",
       %{
         "action" => "pause",
         "after" => %{"status" => "paused"},
         "automation_id" => "automation:daily-health",
         "automation_kind" => "time",
         "before" => %{"status" => "active"},
         "patch" => %{"status" => "paused"},
         "revision" => 1
       }, "Automation change", :confirm_automation},
      {"memory_offer",
       %{
         "expires_in" => "90d",
         "kind" => "alias",
         "repository" => nil,
         "scope" => "conversation",
         "subject" => "primary service",
         "value" => "The API is the primary service in this conversation.",
         "visibility" => "conversation"
       }, "Memory proposal", :confirm_memory},
      {"preference_offer",
       %{
         "expires_in" => "90d",
         "key" => "response_detail",
         "repository" => nil,
         "scope" => "conversation",
         "value" => "detailed"
       }, "Behavior preference", :confirm_behavior},
      {"guidance_offer",
       %{
         "expires_in" => "30d",
         "repository" => nil,
         "scope" => "conversation",
         "subject" => "Investigation style",
         "summary" => "Lead with evidence.",
         "text" => "Lead with current evidence before recommending a change.",
         "visibility" => "conversation"
       }, "Guidance", :confirm_behavior},
      {"standing_assignment_offer",
       %{
         "action" => "review_terraform_plan",
         "expires_in" => "30d",
         "repository" => "responder",
         "source_filter" => "app",
         "task" => "Review an exact Terraform plan.",
         "trigger" => "terraform_plan"
       }, "Standing assignment", :confirm_behavior},
      {"slack_post_offer",
       %{
         "conversation_ref" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "destination_ref" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "instruction_ref" => "admit_input:lab-message",
         "message" => "Post this additional message only after I confirm it.",
         "requested_by_actor_ref" => "control-plane:local",
         "thread_ref" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "transport" => "control_plane"
       }, "Additional message", :confirm_post},
      {"input_request", %{"choices" => ["Staging", "Production"], "question" => "Which?"},
       "Input needed", :answer_input},
      {"input_request", %{"choices" => [], "question" => "What should change?"}, "Input needed",
       nil},
      {"event_wait",
       %{
         "deadline_at" => "2099-01-01T00:00:00.000000Z",
         "event_matcher" => %{"deployment" => "release-1"},
         "kind" => "deployment",
         "verification" => "Verify the deployed revision."
       }, "Waiting for event", nil},
      {"emisar_approval",
       %{
         "action_id" => "deploy",
         "approval_url" => "https://emisar.example/app/runs/run-1/approvals/request-1",
         "expires_at" => "2099-01-01T00:00:00.000000Z",
         "operation_id" => "operation-1",
         "pack_ref" => "pack:deploy",
         "request_id" => "request-1",
         "run_id" => "run-1",
         "runner_ref" => "runner-1",
         "status" => "pending_approval"
       }, "Governed action", nil},
      {"evidence",
       %{
         "claim_id" => "api.health",
         "observation" => "The exact health probe returned ready.",
         "source_name" => "health probe",
         "source_type" => "monitoring"
       }, "Evidence", nil},
      {"coverage",
       %{
         "claim_ids" => ["api.health"],
         "detail" => "The application path was checked.",
         "layer" => "application",
         "observed_at" => "2026-08-28T12:00:00.000000Z",
         "source" => "health probe",
         "status" => "healthy"
       }, "Coverage", nil},
      {"finding",
       %{
         "scope" => "background workers",
         "status" => "unexplained",
         "what" => "Worker health was not verified."
       }, "Finding", nil},
      {"progress",
       %{
         "next_due_at" => "2026-08-28T12:10:00.000000Z",
         "phase" => "verifying",
         "summary" => "The application is healthy; worker verification remains."
       }, "Progress", nil},
      {"goal",
       %{
         "authority" => "read_only",
         "completion_contract" => "A current worker-health observation is recorded.",
         "id" => "verify-workers",
         "kind" => "check",
         "requested_outcome" => "Verify background-worker health",
         "required" => true
       }, "Goal", nil},
      {"goal_state", %{"goal_id" => "verify-workers", "state" => "blocked"}, "Goal updated", nil},
      {"alert_assessment",
       %{
         "immediate_action" => "Inspect a current worker signal.",
         "impact" => "Worker health is not verified.",
         "verification" => "Obtain a current worker observation.",
         "verdict" => "unverified"
       }, "Alert assessment", nil}
    ]

    Enum.each(cases, fn {kind, payload, label, action} ->
      assert {:ok, card} = Card.project(record(kind, payload))
      assert card.kind == kind
      assert card.label == label
      assert card.action == action
      assert card.status == :open
      assert is_binary(card.title)
    end)

    assert cases |> Enum.map(&elem(&1, 0)) |> MapSet.new() ==
             RecordPayload.kinds() |> MapSet.new()

    assert {:ok, closed} =
             Card.project(
               record(
                 "publication_offer",
                 %{"body" => "Already handled.", "title" => "Handled"},
                 :confirmed
               )
             )

    assert closed.action == nil
  end

  test "malformed, unsupported, and unprojectable task records stay inert" do
    assert Card.project(record("unknown", %{})) == :ignore
    assert Card.project(record("task_offer", %{"kind" => "engineering"})) == :ignore

    assert Card.project(
             record("slack_post_offer", %{
               "conversation_ref" => "slack:T123:C789",
               "destination_ref" => "slack-source:v1:T123:C789:thread:1787832888.000300",
               "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
               "message" => "The deployment is healthy.",
               "requested_by_actor_ref" => "slack:user:U123",
               "thread_ref" => "1787832888.000300",
               "transport" => "slack"
             })
           ) == :ignore

    assert Card.project(
             record(
               "task_offer",
               %{
                 "kind" => "engineering",
                 "prompt" => "A task whose child episode is unavailable.",
                 "repository" => "responder",
                 "title" => "Unavailable task"
               },
               :confirmed
             )
           ) == :ignore
  end

  defp record(kind, payload, status \\ :open) do
    %Record{
      kind: kind,
      payload: payload,
      ref: "record:#{kind}:card-test",
      status: status
    }
  end
end

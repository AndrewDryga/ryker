defmodule Responder.State.RecordPayloadTest do
  use ExUnit.Case, async: true

  alias Responder.State.RecordPayload

  test "rejects non-object records and unsafe repository or matcher values" do
    assert RecordPayload.prepare("unknown", %{}, "record:1") ==
             {:error, {:invalid_state_record, :kind}}

    for kind <- [
          "task_offer",
          "publication_offer",
          "schedule_offer",
          "automation_change_offer",
          "memory_offer",
          "preference_offer",
          "guidance_offer",
          "standing_assignment_offer",
          "input_request",
          "event_wait"
        ] do
      assert RecordPayload.prepare(kind, "not-an-object", "record:1") ==
               {:error, {:invalid_state_record, :payload}}
    end

    assert RecordPayload.prepare(
             "task_offer",
             %{
               "kind" => "incident",
               "prompt" => "Investigate.",
               "repository" => "unsafe/repository",
               "title" => "Incident"
             },
             "record:1"
           ) == {:error, {:invalid_state_record, :repository}}

    assert {:ok, _prepared} =
             RecordPayload.prepare(
               "task_offer",
               %{
                 "kind" => "incident",
                 "prompt" => "Investigate.",
                 "repository" => "responder",
                 "title" => "Incident"
               },
               "record:1"
             )

    assert RecordPayload.prepare(
             "event_wait",
             %{
               "deadline_at" => "2026-08-29T12:00:00.000000Z",
               "event_matcher" => "not-an-object",
               "kind" => "deployment",
               "verification" => "Verify it."
             },
             "record:1"
           ) == {:error, {:invalid_state_record, :event_matcher}}

    assert RecordPayload.prepare(
             "event_wait",
             %{
               "deadline_at" => 42,
               "event_matcher" => %{},
               "kind" => "deployment",
               "verification" => "Verify it."
             },
             "record:1"
           ) == {:error, {:invalid_state_record, :deadline_at}}
  end

  test "engineering task offers retain the exact approved checklist and authority" do
    payload = %{
      "authority_limits" => ["must not deploy"],
      "instruction_ref" => "input:trusted:1",
      "kind" => "engineering",
      "prompt" => "Change the parser without widening its authority.",
      "repository" => "responder",
      "source_refs" => ["artifact:incident:1"],
      "success_checks" => ["focused tests pass", "retry remains idempotent"],
      "title" => "Fix parser retries"
    }

    assert {:ok, %{payload: ^payload}} =
             RecordPayload.prepare("task_offer", payload, "record:task_offer:1")

    assert RecordPayload.prepare(
             "task_offer",
             put_in(payload["success_checks"], []),
             "record:task_offer:1"
           ) == {:error, {:invalid_state_record, :success_checks}}
  end

  test "automation changes preserve one exact revision-fenced before and after definition" do
    before = %{
      "automation_id" => "schedule:daily-health",
      "catch_up" => "latest",
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "next_occurrence_at" => "2026-08-30T13:00:00.000000Z",
      "prompt" => "Inspect current service health.",
      "repository" => nil,
      "revision" => 1,
      "status" => "active",
      "title" => "Daily service health",
      "trigger" => %{
        "recurrence" => "daily",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    }

    payload = %{
      "action" => "pause",
      "after" => before |> Map.put("revision", 2) |> Map.put("status", "paused"),
      "automation_id" => before["automation_id"],
      "automation_kind" => "time",
      "before" => before,
      "patch" => %{},
      "revision" => 1
    }

    assert {:ok, prepared} =
             RecordPayload.prepare(
               "automation_change_offer",
               payload,
               "record:automation_change_offer:1"
             )

    assert prepared.payload == payload

    assert RecordPayload.prepare(
             "automation_change_offer",
             Map.put(payload, "revision", 0),
             "record:automation_change_offer:2"
           ) == {:error, {:invalid_state_record, :revision}}
  end

  test "durable behavior offers stay inside closed host-enforced catalogs" do
    assert {:ok, preference} =
             RecordPayload.prepare(
               "preference_offer",
               %{
                 "expires_in" => "90d",
                 "key" => "health_check_depth",
                 "repository" => nil,
                 "scope" => "operator",
                 "value" => "deep"
               },
               "record:preference:1"
             )

    assert preference.payload["value"] == "deep"

    assert RecordPayload.prepare(
             "preference_offer",
             %{
               "expires_in" => "90d",
               "key" => "response_location",
               "repository" => "responder",
               "scope" => "repository",
               "value" => "prefer_thread"
             },
             "record:preference:2"
           ) == {:error, {:invalid_state_record, :preference}}

    assert {:ok, guidance} =
             RecordPayload.prepare(
               "guidance_offer",
               %{
                 "expires_in" => "30d",
                 "repository" => nil,
                 "scope" => "conversation",
                 "subject" => "terraform_review_style",
                 "summary" => "Lead with availability risk and drift.",
                 "text" =>
                   "When reviewing Terraform here, lead with availability risk and drift, not resource counts.",
                 "visibility" => "conversation"
               },
               "record:guidance:1"
             )

    assert guidance.payload["subject"] == "terraform_review_style"

    assert {:ok, assignment} =
             RecordPayload.prepare(
               "standing_assignment_offer",
               %{
                 "action" => "review_terraform_plan",
                 "expires_in" => "30d",
                 "repository" => "responder",
                 "source_filter" => "app",
                 "task" => "Review the exact posted Terraform plan and report material risk.",
                 "trigger" => "terraform_plan"
               },
               "record:assignment:1"
             )

    assert assignment.payload["action"] == "review_terraform_plan"

    assert RecordPayload.prepare(
             "standing_assignment_offer",
             %{
               "action" => "triage_alert",
               "expires_in" => "30d",
               "repository" => nil,
               "source_filter" => "any",
               "task" => "Do something.",
               "trigger" => "terraform_plan"
             },
             "record:assignment:2"
           ) == {:error, {:invalid_state_record, :standing_assignment}}

    assert {:ok, response_location} =
             RecordPayload.prepare(
               "preference_offer",
               %{
                 "expires_in" => "7d",
                 "key" => "response_location",
                 "repository" => nil,
                 "scope" => "conversation",
                 "value" => "prefer_thread"
               },
               "record:preference:location"
             )

    assert response_location.payload["value"] == "prefer_thread"

    for {scope, repository, visibility} <- [
          {"operator", nil, "private"},
          {"repository", "responder", "conversation"},
          {"repository", "responder", "workspace"},
          {"workspace", nil, "workspace"}
        ] do
      assert {:ok, _guidance} =
               RecordPayload.prepare(
                 "guidance_offer",
                 %{
                   "expires_in" => "365d",
                   "repository" => repository,
                   "scope" => scope,
                   "subject" => "review_style",
                   "summary" => "Keep the exact trusted scope.",
                   "text" => "Keep the exact trusted scope and never widen authority.",
                   "visibility" => visibility
                 },
                 "record:guidance:#{scope}:#{visibility}"
               )
    end

    assert RecordPayload.prepare(
             "guidance_offer",
             %{
               "expires_in" => "30d",
               "repository" => nil,
               "scope" => "operator",
               "subject" => "review_style",
               "summary" => "Unsafe visibility.",
               "text" => "This should not widen private operator guidance.",
               "visibility" => "workspace"
             },
             "record:guidance:invalid-visibility"
           ) == {:error, {:invalid_state_record, :visibility}}

    for {trigger, action} <- [
          {"deployment", "verify_deployment"},
          {"operational_alert", "triage_alert"}
        ] do
      assert {:ok, _assignment} =
               RecordPayload.prepare(
                 "standing_assignment_offer",
                 %{
                   "action" => action,
                   "expires_in" => "30d",
                   "repository" => nil,
                   "source_filter" => "any",
                   "task" => "Handle only the exact matching event.",
                   "trigger" => trigger
                 },
                 "record:assignment:#{trigger}"
               )
    end
  end

  test "operational memory offers are typed, scoped, and non-executable" do
    assert {:ok, prepared} =
             RecordPayload.prepare(
               "memory_offer",
               %{
                 "expires_in" => "90d",
                 "kind" => "repository_binding",
                 "repository" => nil,
                 "scope" => "conversation",
                 "subject" => "primary_repository",
                 "value" => "responder",
                 "visibility" => "conversation"
               },
               "record:memory_offer:1"
             )

    assert prepared.payload["value"] == "responder"
    assert prepared.continuation == nil

    assert RecordPayload.prepare(
             "memory_offer",
             %{
               "expires_in" => "90d",
               "kind" => "entity_relationship",
               "repository" => nil,
               "scope" => "workspace",
               "subject" => "checkout",
               "value" => "production database password is secret",
               "visibility" => "conversation"
             },
             "record:memory_offer:2"
           ) == {:error, {:invalid_state_record, :visibility}}

    assert {:ok, repository_memory} =
             RecordPayload.prepare(
               "memory_offer",
               %{
                 "expires_in" => "365d",
                 "kind" => "repository_binding",
                 "repository" => "responder",
                 "scope" => "repository",
                 "subject" => "primary_repository",
                 "value" => "responder",
                 "visibility" => "conversation"
               },
               "record:memory_offer:repository"
             )

    assert repository_memory.payload["repository"] == "responder"
  end

  test "schedule offers bind recurrence, expiry, and repository authority before confirmation" do
    expiry = "2026-09-30T12:00:00.000000Z"

    payload = %{
      "authority" => "repository_write",
      "catch_up" => "latest",
      "expires_at" => expiry,
      "recurrence" => %{"kind" => "daily", "time" => "09:00:00"},
      "repository" => "responder",
      "task" => "Review repository health.",
      "timezone" => "Etc/UTC",
      "title" => "Daily repository health"
    }

    assert {:ok, prepared} = RecordPayload.prepare("schedule_offer", payload, "record:schedule:1")
    assert prepared.payload["expires_at"] == expiry
    assert prepared.payload["repository"] == "responder"

    assert RecordPayload.prepare(
             "schedule_offer",
             %{payload | "authority" => "read_only", "repository" => "responder"},
             "record:schedule:crossed-authority"
           ) == {:error, {:invalid_state_record, :repository}}

    assert RecordPayload.prepare(
             "schedule_offer",
             %{payload | "expires_at" => "not-a-date"},
             "record:schedule:invalid-expiry"
           ) == {:error, {:invalid_state_record, :expires_at}}
  end

  test "publication offers contain only inert human-facing draft PR metadata" do
    assert {:ok, prepared} =
             RecordPayload.prepare(
               "publication_offer",
               %{
                 "body" => "Implements the requested retry boundary and focused coverage.",
                 "title" => "Fix retry reconciliation"
               },
               "record:publication_offer:1"
             )

    assert prepared.continuation == nil
    assert prepared.subject_ref == nil

    assert RecordPayload.prepare(
             "publication_offer",
             %{
               "body" => "Publish it.",
               "repository" => "attacker/other",
               "title" => "Unsafe"
             },
             "record:publication_offer:1"
           ) == {:error, {:invalid_state_record, :fields}}
  end

  test "the aggregate canonical payload remains bounded" do
    assert {:ok, _prepared} =
             RecordPayload.prepare(
               "task_offer",
               %{
                 "kind" => "engineering",
                 "prompt" => String.duplicate("x", 12_000),
                 "repository" => "responder",
                 "title" => String.duplicate("t", 120)
               },
               "record:1"
             )

    invalid_utf8 = <<255>>

    assert RecordPayload.prepare(
             "task_offer",
             %{
               "kind" => "engineering",
               "prompt" => invalid_utf8,
               "repository" => "responder",
               "title" => "Invalid"
             },
             "record:1"
           ) == {:error, {:invalid_state_record, :prompt}}
  end
end

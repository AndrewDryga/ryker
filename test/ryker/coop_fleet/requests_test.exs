defmodule Ryker.CoopFleet.RequestsTest do
  use Ryker.DataCase, async: true
  alias Ryker.CoopFleet.Requests

  test "every Work operation becomes an ordinary Coop API request" do
    intent = %{
      "coop_session_id" => "session-1",
      "coop_turn_id" => "turn-1",
      "expected_revision" => 3,
      "candidate_sha256" => String.duplicate("a", 64),
      "verdict" => "accept",
      "violations" => [],
      "plan_operation_id" => "plan-1",
      "artifact_ref" => "artifact-1",
      "artifact_id" => "review-1",
      "operation_id" => "checkpoint-1",
      "operation_key" => "key:one",
      "patch_offset" => 0,
      "patch_limit" => 100,
      "task" => %{"offer_ref" => "offer:1"},
      "session_ref" => "work-1",
      "repository_ref" => "repo-1"
    }

    for {kind, method, path} <- [
          {"get_session", "GET", "/v1/sessions/session-1"},
          {"get_session_evidence", "GET", "/v1/sessions/session-1/evidence"},
          {"get_changes", "GET", "/v1/sessions/session-1/changes"},
          {"get_turn", "GET", "/v1/sessions/session-1/turns/turn-1"},
          {"ensure_workspace", "POST", "/v1/sessions/session-1/workspace"},
          {"checkpoint_workspace", "POST", "/v1/sessions/session-1/checkpoint"},
          {"run_review", "POST", "/v1/sessions/session-1/review"},
          {"get_review", "GET", "/v1/sessions/session-1/reviews/checkpoint-1"},
          {"get_checkpoint_bundle", "GET", "/v1/operations/checkpoint-1/checkpoint-bundle"},
          {"get_output_artifact", "GET",
           "/v1/sessions/session-1/turns/turn-1/artifacts/artifact-1"},
          {"plan_discard", "POST", "/v1/sessions/session-1/discard-plan"},
          {"discard_session", "POST", "/v1/sessions/session-1/discard"},
          {"close_session", "POST", "/v1/sessions/session-1/close"},
          {"prepare_session", "POST", "/v1/sessions/session-1/prepare"},
          {"cancel_turn", "POST", "/v1/sessions/session-1/turns/turn-1/cancel"},
          {"validate_candidate", "POST", "/v1/sessions/session-1/turns/turn-1/validation"}
        ] do
      assert {:ok, %{"method" => ^method, "path" => ^path} = request} =
               Requests.encode(kind, intent, %{generation: 2})

      refute Map.has_key?(request, "kind")
      refute Map.has_key?(Map.get(request, "body", %{}), "coop_session_id")
    end

    assert {:ok, %{"body" => %{"placement_generation" => 2}}} =
             Requests.encode("checkpoint_workspace", intent, %{generation: 2})

    assert {:ok, %{"body" => %{"task" => task}}} =
             Requests.encode("ensure_workspace", intent, %{generation: 2})

    assert task == intent["task"]

    # Coop prepares only the revision the caller saw, and reads nothing else.
    assert {:ok, %{"body" => %{"expected_revision" => 3} = prepare}} =
             Requests.encode("prepare_session", intent, %{generation: 2})

    assert map_size(prepare) == 1
  end

  # A red review said only "gate failed" (emisar, 2026-09-28). Andrew: "Ryker
  # should get full access to errors, warnings and all other output to work,
  # like any llm model would, it's a sandbox!!" Coop serves a review gate's
  # output page by page, from the cursor the previous page returned.
  test "a review's gate output is read page by page from the cursor Coop returned" do
    first = %{"coop_session_id" => "session-1", "operation_id" => "review-1", "cursor" => nil}

    assert {:ok, %{"method" => "GET", "path" => path} = request} =
             Requests.encode("get_review_gate_output", first, %{generation: 2})

    assert path == "/v1/sessions/session-1/reviews/review-1/gate-output"
    refute Map.has_key?(request, "body")

    assert {:ok, %{"path" => next}} =
             Requests.encode(
               "get_review_gate_output",
               %{first | "cursor" => "1048576"},
               %{generation: 2}
             )

    assert next == "/v1/sessions/session-1/reviews/review-1/gate-output?cursor=1048576"
  end

  test "create requires one frozen job and does not revive local policy selection" do
    job = %{"job_ref" => "job-1"}
    digest = String.duplicate("a", 64)

    assert {:ok,
            %{"body" => %{"task" => "task-1", "job" => ^job, "expected_job_digest" => ^digest}}} =
             Requests.encode(
               "create_session",
               %{"external_ref" => "task-1", "job" => job, "job_digest" => digest},
               nil
             )

    assert {:error, :invalid_coop_request} =
             Requests.encode(
               "create_session",
               %{"external_ref" => "task-1", "policy" => "old"},
               nil
             )
  end

  test "frozen turn uses the service output contract and excludes Ryker bookkeeping" do
    payload = %{
      "coop_session_id" => "s",
      "expected_revision" => 7,
      "submission" => %{
        "prompt" => "exact instructions",
        "output_schema" => %{"type" => "object"},
        "input_artifact_refs" => []
      },
      "submission_sha256" => "private metadata",
      "turn_ref" => "private metadata"
    }

    assert {:ok, %{"body" => body}} = Requests.encode("submit_turn", payload, nil)
    assert body["prompt"] == "exact instructions"
    assert body["expected_revision"] == 7
    assert body["output_contract"]["require_semantic_validation"]
    refute Map.has_key?(body, "submission_sha256")
    refute Map.has_key?(body, "turn_ref")
  end

  test "frozen input artifacts travel in the ordinary turn body with exact bytes" do
    data = "authenticated context"

    assert {:ok, artifact} =
             Ryker.Artifacts.put(%{
               data: data,
               media_type: "text/plain",
               name: "context.txt",
               source_kind: "github",
               source_ref: "github:generic-input:#{Ecto.UUID.generate()}"
             })

    payload = %{
      "coop_session_id" => "s",
      "expected_revision" => 1,
      "submission" => %{
        "prompt" => "Read this",
        "output_schema" => %{"type" => "object"},
        "input_artifact_refs" => [artifact.ref]
      }
    }

    assert {:ok, %{"body" => %{"artifacts" => [delivered]}}} =
             Requests.encode("submit_turn", payload, nil)

    assert delivered == %{
             "data" => Base.encode64(data),
             "sha256" => artifact.sha256,
             "name" => "context.txt",
             "media_type" => "text/plain"
           }

    assert {:error, _} =
             Requests.encode(
               "submit_turn",
               put_in(payload, ["submission", "input_artifact_refs"], ["artifact:missing"]),
               nil
             )
  end

  test "new private API endpoints do not need a worker command kind" do
    request = %{
      "method" => "POST",
      "path" => "/v1/sessions/s/publications",
      "body" => %{"draft" => true}
    }

    assert {:ok, ^request} = Requests.encode("api_request", request, nil)
  end
end

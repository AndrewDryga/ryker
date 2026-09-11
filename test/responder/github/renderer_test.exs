defmodule Responder.GitHub.RendererTest do
  use ExUnit.Case, async: true

  alias Responder.GitHub.Renderer

  test "event-only waits do not crash a visible reply or expose internal instructions" do
    # A shared wait contract must remain deliverable outside Slack as well.
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()

    wait =
      record("event_wait", %{
        "deadline_at" => nil,
        "kind" => "source_event",
        "event_matcher" => %{
          "type" => "source_event",
          "source_kind" => "slack",
          "match" => %{
            "bot_id" => message["bot_id"],
            "attachments" => [message["attachments"] |> hd() |> Map.take(["title", "title_link"])]
          },
          "poll_after" => nil,
          "on_timeout" => nil
        },
        "verification" => "Internal instruction to inspect the exact run."
      })

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "I will report the outcome.", "records" => [wait]})

    assert rendered == "I will report the outcome."
  end

  test "projects governed approvals and durable questions without inventing GitHub authority" do
    document = %{
      "message" => "The action has not run.",
      "records" => [
        %{
          "kind" => "emisar_approval",
          "payload" => %{
            "action_id" => "nomad.alloc_restart",
            "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
            "expires_at" => "2099-08-29T12:00:00.000000Z",
            "operation_id" => "op-1",
            "pack_ref" => "nomad@1#sha256:abc",
            "request_id" => "apr-1",
            "run_id" => "run-1",
            "runner_ref" => "production-runner",
            "status" => "pending_approval"
          },
          "ref" => "record:emisar_approval:abc123",
          "status" => "open"
        },
        %{
          "kind" => "input_request",
          "payload" => %{
            "choices" => ["One percent", "Stop"],
            "question" => "Which rollout should continue?"
          },
          "ref" => "record:input_request:def456",
          "status" => "open"
        }
      ]
    }

    assert {:ok, rendered} = Renderer.render(document)
    assert rendered =~ "The action has not run."
    assert rendered =~ "Approval required in Emisar"
    assert rendered =~ "https://emisar.example/app/acme/approvals/apr-1"
    assert rendered =~ "GitHub cannot approve this action"
    assert rendered =~ "Which rollout should continue?"
    assert rendered =~ "Reply in this thread"
  end

  test "fails closed on malformed or unsupported record projections" do
    assert Renderer.render(%{
             "message" => "Waiting.",
             "records" => [
               %{
                 "kind" => "emisar_approval",
                 "payload" => %{"approval_url" => "https://evil.example"},
                 "ref" => "record:emisar_approval:bad",
                 "status" => "open"
               }
             ]
           }) == {:error, {:invalid_github_render, :record}}

    assert Renderer.render(%{"message" => "Done."}) == {:ok, "Done."}
  end

  test "renders exact governed run status as read-only Markdown" do
    status = %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => "policy denied this target",
      "request_id" => "apr-1",
      "review" => %{
        "request_id" => "apr-1",
        "status" => "denied",
        "required_approvals" => 2,
        "approved_count" => 1,
        "reason" => "Restart the stuck allocation.",
        "decisions" => [
          %{
            "actor" => "Jane Doe",
            "decision" => "approve",
            "decided_at" => "2026-09-11T08:07:23.379141Z"
          },
          %{
            "actor" => "Sam Reviewer",
            "decision" => "deny",
            "decided_at" => "2026-09-11T08:09:10.100000Z",
            "reason" => "Please narrow the query."
          }
        ]
      },
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => "denied"
    }

    assert {:ok, rendered} = Renderer.render(%{"emisar_approval_status" => status})
    assert rendered =~ "Denied in Emisar"

    # The review reads the same here as it does in Slack: the outcome once, then
    # the decisions that produced it, oldest first.
    assert rendered =~ "✕ Review denied by Sam Reviewer."
    assert rendered =~ "✓ Review granted by Jane Doe."
    assert rendered =~ "✕ Review denied by Sam Reviewer. Reason: Please narrow the query."
    assert rendered =~ "policy denied this target"
    assert rendered =~ "Open the exact run"
    assert rendered =~ "GitHub cannot approve this action"

    assert {:ok, exact_run} =
             Renderer.render(%{
               "emisar_approval_status" =>
                 status
                 |> Map.put("remote_error", nil)
                 |> Map.put("run_url", nil)
             })

    assert exact_run =~ "Exact run: `run-1`"

    assert Renderer.render(%{
             "emisar_approval_status" => %{status | "status" => "model_invented"}
           }) == {:error, {:invalid_github_render, :emisar_approval_status}}
  end

  test "projects every durable investigation and offer with bounded textual controls" do
    records = [
      record("event_wait", %{
        "deadline_at" => "2099-08-29T12:00:00.000000Z",
        "event_matcher" => %{"deployment_id" => "deploy-1"},
        "kind" => "deployment",
        "verification" => "Verify the exact deployment became healthy."
      }),
      record(
        "evidence",
        %{
          "claim_id" => "claim-health",
          "observation" => "The workload is healthy.",
          "source_name" => "Emisar",
          "source_type" => "emisar"
        },
        "confirmed"
      ),
      record(
        "coverage",
        %{
          "claim_ids" => ["claim-health"],
          "detail" => "All allocations are healthy.",
          "layer" => "workload",
          "observed_at" => "2026-08-29T12:00:00.000000Z",
          "source" => "Emisar allocation inspection",
          "status" => "healthy"
        },
        "confirmed"
      ),
      record(
        "finding",
        %{
          "status" => "unexplained",
          "what" => "One latency spike remains under investigation."
        },
        "confirmed"
      ),
      record(
        "progress",
        %{
          "phase" => "verification",
          "summary" => "Checking the application after rollout."
        },
        "confirmed"
      ),
      record(
        "goal",
        %{
          "authority" => "read_only",
          "completion_contract" => "Verify the workload and application.",
          "id" => "goal-health",
          "kind" => "check",
          "requested_outcome" => "Confirm production health.",
          "required" => true,
          "stage" => "self_review"
        },
        "confirmed"
      ),
      record(
        "goal_state",
        %{
          "detail" => "Verification is complete.",
          "goal_id" => "goal-health",
          "state" => "completed"
        },
        "confirmed"
      ),
      record(
        "alert_assessment",
        %{
          "impact" => "No customer impact was observed.",
          "verdict" => "not_issue"
        },
        "confirmed"
      ),
      record("task_offer", %{
        "kind" => "engineering",
        "prompt" => "Implement and verify the bounded retry fix.",
        "repository" => "responder",
        "title" => "Fix retry reconciliation"
      }),
      record("task_offer", %{
        "kind" => "incident",
        "prompt" => "Investigate the current incident without making changes.",
        "repository" => nil,
        "title" => "Investigate the incident"
      }),
      record("publication_offer", %{
        "body" => "The committed workspace is ready for review.",
        "title" => "Publish the retry fix"
      }),
      record("schedule_offer", %{
        "authority" => "read_only",
        "catch_up" => "latest",
        "expires_at" => nil,
        "recurrence" => %{"kind" => "daily", "time" => "09:00:00"},
        "repository" => nil,
        "task" => "Check production health.",
        "timezone" => "Etc/UTC",
        "title" => "Daily health review"
      }),
      record("memory_offer", %{
        "expires_in" => "90d",
        "kind" => "repository_binding",
        "repository" => nil,
        "scope" => "conversation",
        "subject" => "primary_repository",
        "value" => "responder",
        "visibility" => "conversation"
      }),
      record("preference_offer", %{
        "expires_in" => "90d",
        "key" => "response_detail",
        "repository" => nil,
        "scope" => "conversation",
        "value" => "concise"
      }),
      record("guidance_offer", %{
        "expires_in" => "30d",
        "repository" => nil,
        "scope" => "conversation",
        "subject" => "review_style",
        "summary" => "Lead with risk.",
        "text" => "Lead with availability risk and verified impact.",
        "visibility" => "conversation"
      }),
      record("standing_assignment_offer", %{
        "action" => "review_terraform_plan",
        "expires_in" => "30d",
        "repository" => "responder",
        "source_filter" => "app",
        "task" => "Review each exact Terraform plan.",
        "trigger" => "terraform_plan"
      })
    ]

    assert {:ok, rendered} = Renderer.render(%{"message" => "Current work", "records" => records})
    assert rendered =~ "Waiting for an external event"
    assert rendered =~ "Evidence — claim-health"
    assert rendered =~ "Coverage — workload / healthy"
    assert rendered =~ "Finding — unexplained"
    assert rendered =~ "Progress — verification"
    assert rendered =~ "Goal — goal-health (required)"
    assert rendered =~ "Alert assessment — not_issue"
    assert rendered =~ "Proposed engineering task"
    assert rendered =~ "Proposed incident task"
    assert rendered =~ "explicit operator confirmation in a supported Responder control surface"
    assert rendered =~ "Publication review offered"
    assert rendered =~ "Schedule offered"
    assert rendered =~ "Responder offer — primary_repository"
    assert rendered =~ "Responder offer — response_detail"
    assert rendered =~ "Responder offer — Lead with risk."
    assert rendered =~ "Responder offer — Review each exact Terraform plan."
    assert rendered =~ "/responder confirm record:task_offer:"
    assert rendered =~ "/responder confirm record:schedule_offer:"
    assert rendered =~ "/responder confirm record:memory_offer:"
    assert rendered =~ "/responder confirm record:preference_offer:"
    assert rendered =~ "/responder confirm record:guidance_offer:"
    assert rendered =~ "/responder confirm record:standing_assignment_offer:"
    refute rendered =~ "/responder confirm record:publication_offer:"
    refute rendered =~ "<button"
  end

  test "rejects crossed record status, excess records, and non-document input" do
    invalid_record =
      record(
        "task_offer",
        %{
          "kind" => "engineering",
          "prompt" => "Do the work.",
          "repository" => "responder",
          "title" => "Task"
        },
        "settled"
      )

    assert Renderer.render(%{"message" => "Unsafe", "records" => [invalid_record]}) ==
             {:error, {:invalid_github_render, :record}}

    records = List.duplicate(invalid_record, 65)

    assert Renderer.render(%{"message" => "Too many", "records" => records}) ==
             {:error, {:invalid_github_render, :document}}

    assert Renderer.render(%{"records" => []}) ==
             {:error, {:invalid_github_render, :document}}
  end

  defp record(kind, payload, status \\ "open") do
    %{
      "kind" => kind,
      "payload" => payload,
      "ref" => "record:#{kind}:#{System.unique_integer([:positive])}",
      "status" => status
    }
  end
end

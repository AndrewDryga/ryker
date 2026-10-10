defmodule Ryker.GitHub.RendererTest do
  use ExUnit.Case, async: true
  alias Ryker.Fixtures.TaskOffer
  alias Ryker.GitHub.Renderer

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
    assert rendered =~ "- One percent"
    assert rendered =~ "Reply in this thread"
  end

  # The comment named the runner `emisar-p02r~63f5…` and the pack `docker@0.2.30/sha256:2d6b…`
  # (manual test, 2026-10-10): Emisar's ids, where people know the runner and pack by name.
  test "a governed action names its runner and pack as people know them" do
    payload = %{
      "action_id" => "docker.image_inspect",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" =>
        "docker@0.2.30/sha256:2d6b487daccd827f1ca4ff88e253b10f9c878571ca6c25b9bad7ce5843251fd1",
      "request_id" => "apr-1",
      "run_id" => "run-1",
      "runner_ref" => "emisar-p02r~63f54795da1ec7f90b34d6a688612829",
      "status" => "pending_approval"
    }

    record = %{
      "kind" => "emisar_approval",
      "payload" => payload,
      "ref" => "record:emisar_approval:abc123",
      "status" => "open"
    }

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "The action has not run.", "records" => [record]})

    assert rendered =~ "on `emisar-p02r`"
    assert rendered =~ "Pack: `docker@0.2.30`"
    refute rendered =~ "sha256"
    refute rendered =~ "~"
  end

  # Andrew, 2026-10-04, of a question asked in a reply and again under it: "in the reply". The
  # comment adds only the answers and how to give one.
  test "a question is asked once, in the reply" do
    record = fn choices ->
      %{
        "kind" => "input_request",
        "payload" => %{"choices" => choices, "question" => "Which region is primary?"},
        "ref" => "record:input_request:region",
        "status" => "open"
      }
    end

    for choices <- [[], ["eu-west-1", "us-east-1"]] do
      assert {:ok, rendered} =
               Renderer.render(%{
                 "message" => "One question first: which region is primary?",
                 "records" => [record.(choices)]
               })

      refute rendered =~ "Which region is primary?"
      refute rendered =~ "Input needed"
      assert rendered =~ "Reply in this thread"
    end
  end

  # The Chat card said "Reply below or choose one of the offered answers." over
  # a question with no answers, and the GitHub comment said the same in its own
  # words: a reader looked for choices that were never offered.
  test "a question offers choices only when it has some" do
    question = fn choices ->
      Renderer.render(%{
        "message" => "One question first.",
        "records" => [
          %{
            "kind" => "input_request",
            "payload" => %{"choices" => choices, "question" => "Which region is primary?"},
            "ref" => "record:input_request:region",
            "status" => "open"
          }
        ]
      })
    end

    assert {:ok, open} = question.([])
    assert open =~ "Reply in this thread with your answer."
    refute open =~ "choice"

    assert {:ok, choices} = question.(["eu-west-1", "us-east-1"])
    assert choices =~ "- eu-west-1"
    assert choices =~ "Reply in this thread with one of these or your own answer."
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

    assert {:ok, rendered} = Renderer.render(%{"emisar_approval_statuses" => [status]})
    assert rendered =~ "Denied in Emisar"

    # The review reads the same here as it does in Slack: the outcome once, then
    # the decisions that produced it, oldest first.
    assert rendered =~ "✕ Review denied by Sam Reviewer."
    assert rendered =~ "✓ Review granted by Jane Doe."
    assert rendered =~ "✕ Review denied by Sam Reviewer. Reason: Please narrow the query."
    assert rendered =~ "policy denied this target"
    assert rendered =~ "[Open run]("
    assert rendered =~ "GitHub cannot approve this action"

    assert {:ok, exact_run} =
             Renderer.render(%{
               "emisar_approval_statuses" => [
                 status
                 |> Map.put("remote_error", nil)
                 |> Map.put("run_url", nil)
               ]
             })

    assert exact_run =~ "Run: `run-1`"

    assert Renderer.render(%{
             "emisar_approval_statuses" => [%{status | "status" => "model_invented"}]
           }) == {:error, {:invalid_github_render, :emisar_approval_statuses}}

    # A comment that asked for two approvals keeps both when one changes.
    other =
      %{status | "request_id" => "apr-2", "runner_ref" => "web-2", "status" => "pending_approval"}
      |> Map.merge(%{
        "approval_url" => "https://emisar.example/app/acme/approvals/apr-2",
        "review" => nil
      })

    assert {:ok, both} = Renderer.render(%{"emisar_approval_statuses" => [status, other]})
    assert [first, second] = String.split(both, "\n\n---\n\n")
    assert first =~ "on `production-runner`"
    assert second =~ "on `web-2`"
    assert String.ends_with?(second, "GitHub cannot approve these actions.")
  end

  # Andrew, 2026-09-30, of Ryker's reply on emisar#87 (this document, harvested): "this is too
  # much text, we need it to be shorter, use simple english and not leak internal mechanics (like
  # Evidence, citation ids, Findings, etc) and just act like human would instead". Slack never
  # showed these records under an answer; GitHub printed each one after it.
  test "a pull request reply is the answer alone, without the evidence and findings behind it" do
    document =
      "test/ryker/github/fixtures/pr87_pack_pins_reply.json" |> File.read!() |> Jason.decode!()

    assert {:ok, rendered} = Renderer.render(document)
    assert rendered == document["message"]
    refute rendered =~ "citation:"
    refute rendered =~ "Evidence"
    refute rendered =~ "Finding"
  end

  test "offers and waits carry their textual controls, and what an answer rests on stays out" do
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
      record(
        "task_offer",
        TaskOffer.payload(%{
          "kind" => "engineering",
          "prompt" => "Implement and verify the bounded retry fix.",
          "repository" => "ryker",
          "title" => "Fix retry reconciliation"
        })
      ),
      record(
        "task_offer",
        TaskOffer.payload(%{
          "kind" => "incident",
          "prompt" => "Investigate the current incident without making changes.",
          "repository" => nil,
          "title" => "Investigate the incident"
        })
      ),
      record("publication_offer", %{
        "body" => "The committed workspace is ready for review.",
        "title" => "Publish the retry fix"
      }),
      record("schedule_offer", %{
        "authority" => "read_only",
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
        "value" => "ryker",
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
        "context_channel" => "github:github-main:repository:99",
        "delivery_channel" => "github:github-main:repository:99",
        "expires_at" => nil,
        "filter" => %{"action" => "submitted"},
        "hold" => nil,
        "repository" => "ryker",
        "source_kind" => "github",
        "task" => "Review each submitted pull request review.",
        "title" => "Review pull request reviews"
      })
    ]

    assert {:ok, rendered} = Renderer.render(%{"message" => "Current work", "records" => records})
    assert rendered =~ "Waiting for an external event"
    refute rendered =~ "claim-health"
    refute rendered =~ "Coverage"
    refute rendered =~ "unexplained"
    refute rendered =~ "Progress"
    refute rendered =~ "goal-health"
    refute rendered =~ "not_issue"
    assert rendered =~ "Proposed engineering task"
    assert rendered =~ "Proposed incident task"
    assert rendered =~ "explicit operator confirmation in a supported Ryker control surface"
    assert rendered =~ "Publication review offered"
    assert rendered =~ "Schedule offered"
    assert rendered =~ "Ryker offer — primary_repository"
    assert rendered =~ "Ryker offer — response_detail"
    assert rendered =~ "Ryker offer — Lead with risk."
    assert rendered =~ "Ryker offer — Review each submitted pull request review."
    assert rendered =~ "/ryker confirm record:task_offer:"
    assert rendered =~ "/ryker confirm record:schedule_offer:"
    assert rendered =~ "/ryker confirm record:memory_offer:"
    assert rendered =~ "/ryker confirm record:preference_offer:"
    assert rendered =~ "/ryker confirm record:guidance_offer:"
    assert rendered =~ "/ryker confirm record:standing_assignment_offer:"
    refute rendered =~ "/ryker confirm record:publication_offer:"
    refute rendered =~ "<button"
  end

  # QA, 2026-09-25, Chat 878b84df: a schedule offer's words were the model's
  # own title and task, "Every weekday at 09:00 UTC", over a Monday-only
  # schedule. A GitHub comment offering a schedule named no cadence at all.
  test "a schedule offer comment says how often from its recurrence, whatever its title claims" do
    offer =
      record("schedule_offer", %{
        "authority" => "read_only",
        "expires_at" => nil,
        "recurrence" => %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "monday"},
        "repository" => nil,
        "task" => "Every weekday at 09:00 UTC, post a one-line status of open incidents.",
        "timezone" => "Etc/UTC",
        "title" => "Weekday open incident status"
      })

    assert {:ok, rendered} = Renderer.render(%{"message" => "Prepared.", "records" => [offer]})
    assert rendered =~ "When: Every Monday at 09:00 UTC"

    weekdays =
      put_in(offer, ["payload", "recurrence"], %{"kind" => "weekdays", "time" => "09:00:00"})

    assert {:ok, rendered} = Renderer.render(%{"message" => "Prepared.", "records" => [weekdays]})
    assert rendered =~ "When: Every weekday at 09:00 UTC"
  end

  test "rejects crossed record status, excess records, and non-document input" do
    invalid_record =
      record(
        "task_offer",
        TaskOffer.payload(%{
          "kind" => "engineering",
          "prompt" => "Do the work.",
          "repository" => "ryker",
          "title" => "Task"
        }),
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

defmodule Ryker.ControlPlane.CardTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{Card, HTML}
  alias Ryker.Publication.Publication
  alias Ryker.State.{Record, RecordPayload}

  @digest String.duplicate("a", 64)
  @git String.duplicate("b", 40)

  test "an unschedulable wait explains its failure and hard deadline without presenting success" do
    payload = %{
      "deadline_at" => "2026-09-07T12:00:00Z",
      "event_matcher" => %{
        "type" => "after",
        "delay" => "10m",
        "on_timeout" => "Report verification gap."
      },
      "kind" => "after",
      "verification" => "Check Airflow health."
    }

    source = record("event_wait", payload) |> Map.put(:wait_error, "timer_deadline")
    assert {:ok, card} = Card.project(source)
    assert card.wait_warning =~ "cannot run before its deadline"
    assert card.wait_warning =~ "2026-09-07T12:00:00Z"
    assert card.summary == nil
    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ "Timer scheduling failed"
    assert html =~ "Current scheduling status:"
    refute html =~ "timer_deadline"
  end

  test "a scheduling diagnostic never prints an invalid retained deadline as diagnostic prose" do
    warning =
      Card.wait_warning(%Record{
        kind: "event_wait",
        wait_error: "deadline",
        payload: %{"deadline_at" => "password=retained-secret"}
      })

    assert warning =~ "deadline is invalid"
    refute warning =~ "retained-secret"
  end

  test "every wait warning validates its deadline before producing diagnostic prose" do
    # Lab's diagnostic fallback was safe, but the episode called this shared
    # formatter directly, leaking malformed strings or crashing on JSON objects.
    for error <- ~w(timer_deadline poll_after),
        deadline <- [nil, 42, "password=retained-secret", %{"password" => "retained-secret"}] do
      source = record("event_wait", %{"deadline_at" => deadline}) |> Map.put(:wait_error, error)
      assert Card.wait_warning(source) == "Wait scheduling failed: its saved deadline is invalid."
    end
  end

  test "only supported wait errors on event waits produce scheduling warnings" do
    for {kind, error} <- [
          {"event_wait", nil},
          {"event_wait", "unknown-secret"},
          {"finding", "poll_after"},
          {"finding", "deadline"},
          {"finding", "source_kind"},
          {"finding", "cursor"},
          {"finding", "timer_deadline"}
        ] do
      source =
        record(kind, %{"deadline_at" => "2099-09-07T12:00:00Z"})
        |> Map.put(:wait_error, error)

      assert Card.wait_warning(source) == nil
    end
  end

  test "valid UTC deadlines retain their specific timer or polling explanation" do
    for {error, phrase} <- [
          {"timer_deadline", "cannot run before its deadline"},
          {"poll_after", "polling time is invalid"}
        ] do
      source =
        record("event_wait", %{"deadline_at" => "2099-09-07T12:00:00Z"})
        |> Map.put(:wait_error, error)

      warning = Card.wait_warning(source)
      assert warning =~ phrase
      assert warning =~ "2099-09-07T12:00:00Z"
    end
  end

  for {error, phrase} <- [
        {"source_kind", "source identifier is invalid or exceeds 120 bytes"},
        {"cursor", "cursor is invalid or exceeds 16 KiB"},
        {"deadline", "deadline is invalid"},
        {"timer_deadline", "cannot run before its deadline"},
        {"poll_after", "polling time is invalid"}
      ] do
    test "a retained invalid wait still shows its bounded #{error} diagnostic without raw data" do
      # Revalidating retained payloads hid scheduling failures from Lab entirely.
      source =
        record("event_wait", %{
          "deadline_at" => "2099-09-07T12:00:00Z",
          "verification" => "unvalidated-verification",
          "event_matcher" => %{"cursor" => "unvalidated-cursor"}
        })
        |> Map.put(:wait_error, unquote(error))

      assert {:ok, card} = Card.project(source)
      assert card.wait_warning =~ unquote(phrase)
      assert card.action == nil
      assert card.choices == []
      assert card.url == nil
      assert {"Hard deadline", "2099-09-07T12:00:00Z"} in card.details
      refute inspect(card) =~ "unvalidated-"

      html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
      assert html =~ "Current scheduling status:"
      assert html =~ unquote(phrase)
      refute html =~ "unvalidated-"
      refute html =~ "<form"
    end
  end

  test "an invalid diagnostic card never renders a malformed deadline or an unknown error" do
    for deadline <- [nil, 42, "password=retained-secret"] do
      source =
        record("event_wait", %{"deadline_at" => deadline})
        |> Map.put(:wait_error, "timer_deadline")

      assert {:ok, card} = Card.project(source)
      refute inspect(card) =~ "retained-secret"
      refute {"Deadline", deadline} in card.details
    end

    for {kind, error} <- [
          {"event_wait", nil},
          {"event_wait", "unknown-secret"},
          {"finding", "source_kind"}
        ] do
      assert :ignore = Card.project(record(kind, %{}) |> Map.put(:wait_error, error))
    end
  end

  test "finding cards redact all prose before either Lab or timeline rendering" do
    # Findings has more than one presentation sink; escaping HTML is not secret redaction.
    payload = %{
      "what" => "Diagnosis password=finding-body-secret",
      "status" => "expected",
      "reason" => "Expected because password=finding-reason-secret",
      "scope" => "Scoped password=finding-scope-secret"
    }

    source = record("finding", payload)
    assert {:ok, card} = Card.project(source)

    for secret <- ~w(finding-body-secret finding-reason-secret finding-scope-secret) do
      refute inspect(card) =~ secret
      refute HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary() =~ secret
    end

    assert source.payload == payload
    assert card.ref == source.ref
  end

  test "a goal card shows the stage it belongs to and the attempt it replaces" do
    # The 2026-09-12 audit found the episode view renders neither. A goal's stage is
    # what says whether the work is planning or self-review, and successor_of is the
    # only thing distinguishing a fresh attempt from a reopened goal, which the host
    # never does. Both were in the payload and neither reached the operator.
    payload = %{
      "authority" => "read_only",
      "completion_contract" => "A current worker-health observation is recorded.",
      "id" => "verify-workers-2",
      "kind" => "check",
      "requested_outcome" => "Verify background-worker health",
      "required" => true,
      "stage" => "self_review",
      "successor_of" => "verify-workers"
    }

    assert {:ok, card} = Card.project(record("goal", payload))
    assert {"Stage", "Self review"} in card.details
    assert {"Replaces attempt", "verify-workers"} in card.details
  end

  test "a completed check reports the evidence it was completed on" do
    # Same audit: evidence_refs is the receipt a completion claim rests on, and the
    # card dropped it, so a completion and an unevidenced assertion looked identical.
    payload = %{
      "detail" => "Both workers reported healthy.",
      "evidence_refs" => ["record:evidence:aa11", "record:evidence:bb22"],
      "goal_id" => "verify-workers",
      "state" => "completed"
    }

    assert {:ok, card} = Card.project(record("goal_state", payload))
    assert {"Evidence", "record:evidence:aa11, record:evidence:bb22"} in card.details
  end

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

  test "a confirmed memory card keeps only readable information that helps evaluate it" do
    # A confirmed memory proposal used to spend an entire header column saying
    # CONFIRMED, then repeat conversation as both Scope and Visibility. Neither
    # changed what the reader could understand or do, and the stacked raw enum
    # values made a short fact occupy most of the conversation viewport.
    payload = %{
      "expires_in" => "90d",
      "kind" => "entity_relationship",
      "repository" => nil,
      "scope" => "conversation",
      "subject" => "Temporary validation codename",
      "value" => "The temporary validation codename is saffron.",
      "visibility" => "conversation"
    }

    assert {:ok, card} = Card.project(record("memory_offer", payload, :confirmed))
    assert Card.display_status(card) == nil

    assert card.details == [
             {"Kind", "Entity relationship"},
             {"Scope", "This conversation"},
             {"Expires", "90 days"}
           ]

    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ ~s(<dl class="lab-card-details">)

    assert html =~
             ~s(<div class="lab-card-detail"><dt>Kind</dt><dd>Entity relationship</dd></div>)

    refute html =~ ">confirmed<"
    refute html =~ ">Visibility<"
  end

  test "publication review and result cards expose only typed host actions" do
    publication = %Publication{
      ref: "publication:lab:one",
      repository: "ryker",
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
          "branch_ref" => "ryker/lab-parity",
          "commit_sha" => @git,
          "pull_request_number" => 42,
          "pull_request_url" => "https://github.com/example/ryker/pull/42"
        },
        status: :published
    }

    assert {:ok, result} = Card.project_publication(published, "record:publication_offer:one")
    assert result.kind == "publication_result"
    assert result.action == :check_publication
    assert result.status == :published
    assert result.url == "https://github.com/example/ryker/pull/42"
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
         "repository" => "ryker",
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
         "required" => true,
         "stage" => "self_review"
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
                 "repository" => "ryker",
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

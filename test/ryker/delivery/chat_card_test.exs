defmodule Ryker.Delivery.ChatCardTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.HTML
  alias Ryker.Delivery.ChatCard
  alias Ryker.Publication.Publication
  alias Ryker.Records.Record
  alias Ryker.Records.RecordPayload

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
    assert {:ok, card} = ChatCard.project(source)
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
      ChatCard.wait_warning(%Record{
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

      assert ChatCard.wait_warning(source) ==
               "Wait scheduling failed: its saved deadline is invalid."
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

      assert ChatCard.wait_warning(source) == nil
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

      warning = ChatCard.wait_warning(source)
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

      assert {:ok, card} = ChatCard.project(source)
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

      assert {:ok, card} = ChatCard.project(source)
      refute inspect(card) =~ "retained-secret"
      refute {"Deadline", deadline} in card.details
    end

    for {kind, error} <- [
          {"event_wait", nil},
          {"event_wait", "unknown-secret"},
          {"finding", "source_kind"}
        ] do
      assert :ignore = ChatCard.project(record(kind, %{}) |> Map.put(:wait_error, error))
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
    assert {:ok, card} = ChatCard.project(source)

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

    assert {:ok, card} = ChatCard.project(record("goal", payload))
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

    assert {:ok, card} = ChatCard.project(record("goal_state", payload))
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

    assert {:ok, card} = ChatCard.project(record("goal_state", payload))
    assert card.title == "Completed"
    assert ChatCard.display_status(card) == nil
    assert card.label == "Goal updated"
    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ "Completed"
    refute html =~ ">open<"
  end

  # QA, 2026-09-25, Chat 878b84df: the card read "Every weekday at 09:00 UTC"
  # because its only cadence was the model's own task text, while the offer
  # under it was Mondays only. Confirming it created "Every Monday".
  test "a schedule offer says how often from its recurrence, whatever its title claims" do
    payload = %{
      "authority" => "read_only",
      "expires_at" => nil,
      "recurrence" => %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "monday"},
      "repository" => nil,
      "task" => "Every weekday at 09:00 UTC, post a one-line status of open incidents here.",
      "timezone" => "Etc/UTC",
      "title" => "Weekday open incident status"
    }

    assert {:ok, monday} = ChatCard.project(record("schedule_offer", payload))
    assert {"How often", "Every Monday at 09:00 UTC"} in monday.details

    html = HTML.lab_message_extras(%{cards: [monday]}) |> IO.iodata_to_binary()
    assert html =~ "<dt>How often</dt><dd>Every Monday at 09:00 UTC</dd>"

    weekdays = put_in(payload, ["recurrence"], %{"kind" => "weekdays", "time" => "09:00:00"})
    assert {:ok, card} = ChatCard.project(record("schedule_offer", weekdays))
    assert {"How often", "Every weekday at 09:00 UTC"} in card.details
  end

  # Andrew, 2026-10-04, of a question asked in a reply and again on the card under it: "in the
  # reply". A question answered by typing gets no card; one with answers gets a card holding
  # only the answers.
  test "a question is asked once, in the reply, and its card holds only the answers" do
    question = "Which timezone should I use for the weekday 9:00 status?"

    assert :ignore =
             ChatCard.project(record("input_request", %{"choices" => [], "question" => question}))

    assert {:ok, choosing} =
             ChatCard.project(
               record("input_request", %{
                 "choices" => ["UTC", "Europe/Berlin"],
                 "question" => question
               })
             )

    assert choosing.title == nil
    assert choosing.choices == ["UTC", "Europe/Berlin"]
    assert choosing.action == :answer_input
  end

  # QA, 2026-09-25: every question card said "Reply below or choose one of the
  # offered answers." whether it offered answers or not, and kept saying it
  # after the question had been answered.
  test "a question card asks for a reply and mentions answers only when it offers some" do
    question = "Which timezone should I use for the weekday 9:00 status?"

    assert {:ok, choosing} =
             ChatCard.project(
               record("input_request", %{
                 "choices" => ["UTC", "Europe/Berlin"],
                 "question" => question
               })
             )

    assert choosing.summary == "Reply below or choose an answer."
    assert choosing.action == :answer_input
    assert choosing.choices == ["UTC", "Europe/Berlin"]

    assert {:ok, answered} =
             ChatCard.project(
               record(
                 "input_request",
                 %{"choices" => ["UTC", "Europe/Berlin"], "question" => question},
                 :answered
               )
             )

    assert answered.summary == nil
    refute HTML.lab_message_extras(%{cards: [answered]}) |> IO.iodata_to_binary() =~ "Reply"
  end

  # QA re-test, 2026-09-26: a question replaced by an edit read "superseded"
  # (after it had wrongly read "answered"). The question itself is in the reply.
  test "a question card says what became of it in words" do
    payload = %{"choices" => ["Paste it", "Skip it"], "question" => "Can you paste the error?"}

    words =
      for status <- [:answered, :dismissed, :superseded] do
        {:ok, card} = ChatCard.project(record("input_request", payload, status))
        ChatCard.display_status(card)
      end

    assert words == ["Answered", "Closed", "Replaced by your edit"]
  end

  # QA, 2026-09-25: chat cards printed "SOURCE admit_input:63c450cc…", a digest
  # nobody can open, beside "AUTHORITY read_only", "KIND Entity relationship"
  # and "SCOPE Workspace": stored values a person can neither read nor act on.
  test "offer and evidence cards say what matters in words, never stored values" do
    schedule = %{
      "authority" => "read_only",
      "expires_at" => "2026-12-31T17:00:00.000000Z",
      "recurrence" => %{"kind" => "weekdays", "time" => "09:00:00"},
      "repository" => nil,
      "task" => "Post a one-line status of open incidents here.",
      "timezone" => "Etc/UTC",
      "title" => "Weekday open incident status"
    }

    assert {:ok, reading} = ChatCard.project(record("schedule_offer", schedule))

    assert reading.details == [
             {"How often", "Every weekday at 09:00 UTC"},
             {"What it may do", "Read-only"},
             {"Stops", "31 Dec 2026, 17:00 UTC"}
           ]

    writing = %{schedule | "authority" => "repository_write", "repository" => "checkout-api"}
    assert {:ok, writer} = ChatCard.project(record("schedule_offer", writing))
    assert {"What it may do", "Can change code in checkout-api"} in writer.details

    memory = %{
      "expires_in" => "90d",
      "kind" => "entity_relationship",
      "repository" => nil,
      "scope" => "workspace",
      "subject" => "Staging Emisar account",
      "value" => "The staging Emisar account is named acme-staging.",
      "visibility" => "workspace"
    }

    assert {:ok, remembered} = ChatCard.project(record("memory_offer", memory))

    assert remembered.details == [
             {"Applies to", "Everyone in this workspace"},
             {"Expires", "90 days"}
           ]

    digest = "admit_input:63c450ccc15dd8fb105ed9574cdec80d95645bc20891a5fdefb3640b230cda46"

    evidence = %{
      "claim" => "Operator-reported production checkout-api v2.3.1 timeline",
      "claim_id" => "citation:0f3b7c2a91d44e6b8a5c1d2e3f405162",
      "confidence" => nil,
      "dimensions" => %{},
      "freshness" => nil,
      "health_effect" => nil,
      "observation" => "The operator reports the rollout at 08:00 and the alert at 08:04.",
      "observed_at" => nil,
      "relation" => "supports",
      "scope_note" => nil,
      "source_id" => digest,
      "source_name" => digest,
      "source_type" => "other",
      "supersedes" => [],
      "target" => "Operator-reported production checkout-api v2.3.1 timeline"
    }

    assert {:ok, cited} = ChatCard.project(record("evidence", evidence))
    assert cited.details == []

    trigger = %{
      "recurrence" => "weekdays",
      "time" => "09:00:00",
      "timezone" => "Etc/UTC",
      "type" => "time"
    }

    automation = "schedule:5b0c8f0e-2d1c-4b7e-9d53-0d8d2b1c9e41"

    change = %{
      "action" => "update",
      "after" => %{"title" => "Weekday open incident status", "trigger" => trigger},
      "automation_id" => automation,
      "automation_kind" => "time",
      "before" => %{"title" => "Weekday open incident status"},
      "patch" => %{"trigger" => trigger},
      "revision" => 3
    }

    assert {:ok, changing} = ChatCard.project(record("automation_change_offer", change))

    assert changing.details == [
             {"Automation", "Weekday open incident status"},
             {"How often", "Every weekday at 09:00 UTC"}
           ]

    conversation = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    post = %{
      "conversation_ref" => conversation,
      "destination_ref" => conversation,
      "instruction_ref" => "admit_input:lab-message",
      "message" => "Post this additional message only after I confirm it.",
      "requested_by_actor_ref" => "control_plane:user:local-operator",
      "thread_ref" => conversation,
      "transport" => "control_plane"
    }

    assert {:ok, posting} = ChatCard.project(record("slack_post_offer", post))
    assert posting.details == []

    html =
      HTML.lab_message_extras(%{cards: [reading, writer, remembered, cited, changing, posting]})
      |> IO.iodata_to_binary()

    for stored <- [
          "read_only",
          "repository_write",
          "entity_relationship",
          "admit_input",
          automation,
          conversation
        ] do
      refute html =~ stored
    end

    refute html =~ "Entity relationship"
    refute html =~ ">Workspace<"
    refute html =~ ">Authority<"
    refute html =~ ">Revision<"
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

    assert {:ok, card} = ChatCard.project(record("memory_offer", payload, :confirmed))
    assert ChatCard.display_status(card) == nil

    assert card.details == [
             {"Applies to", "This conversation"},
             {"Expires", "90 days"}
           ]

    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ ~s(<dl class="lab-card-details">)

    assert html =~
             ~s(<div class="lab-card-detail"><dt>Applies to</dt><dd>This conversation</dd></div>)

    refute html =~ ">confirmed<"
    refute html =~ ">Shown to<"
    refute html =~ "Entity relationship"
  end

  test "publication review and result cards expose only typed host actions" do
    publication = %Publication{
      ref: "publication:lab:one",
      repository: "ryker",
      review_document: %{
        "candidate_tree" => @git,
        "gate" => "passed",
        "not_publishable_reasons" => [],
        "policy_findings" => [],
        "publishable" => true,
        "rebase" => "clean"
      },
      status: :reviewed,
      title: "Finish Conversation Lab parity"
    }

    assert {:ok, review} =
             ChatCard.project_publication(publication, "record:publication_offer:one")

    assert review.kind == "publication_review"
    assert review.action == :approve_publication
    assert review.ref == "record:publication_offer:one"
    assert review.status == :reviewed
    assert {"Gate", "passed"} in review.details
    refute Enum.any?(review.details, fn {label, _value} -> label == "Patch" end)
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

    assert {:ok, result} = ChatCard.project_publication(published, "record:publication_offer:one")
    assert result.kind == "publication_result"
    # Ryker looks at an open pull request by itself; the card only links it (2026-09-30).
    assert result.action == nil
    assert result.status == :published
    assert result.url == "https://github.com/example/ryker/pull/42"
    assert {"Pull request", "#42"} in result.details

    unsafe = put_in(published.publication_receipt["pull_request_url"], "javascript:alert(1)")
    assert {:ok, safe} = ChatCard.project_publication(unsafe, "record:publication_offer:one")
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
             ChatCard.project_publication(blocked, "record:publication_offer:one")

    assert blocked_card.action == nil
    assert blocked_card.summary == "The focused gate failed."

    no_reasons = put_in(blocked.review_document["not_publishable_reasons"], [])
    assert {:ok, no_reasons_card} = ChatCard.project_publication(no_reasons, publication.ref)
    assert no_reasons_card.summary == "The candidate is not publishable."

    invalid_review = %{publication | review_document: %{}, status: :reviewed}
    assert ChatCard.project_publication(invalid_review, publication.ref) == :ignore
    assert ChatCard.project_publication(%Publication{}, publication.ref) == :ignore
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
         "context_channel" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "delivery_channel" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "expires_at" => nil,
         "filter" => %{},
         "hold" => nil,
         "repository" => "ryker",
         "source_kind" => "webhook",
         "task" => "Review each alert the webhook sends.",
         "title" => "Review alerts"
       }, "Standing assignment", :confirm_behavior},
      {"slack_post_offer",
       %{
         "conversation_ref" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "destination_ref" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "instruction_ref" => "admit_input:lab-message",
         "message" => "Post this additional message only after I confirm it.",
         "requested_by_actor_ref" => "control_plane:user:local-operator",
         "thread_ref" => "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
         "transport" => "control_plane"
       }, "Additional message", :confirm_post},
      {"input_request", %{"choices" => ["Staging", "Production"], "question" => "Which?"},
       "Input needed", :answer_input},
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
      assert {:ok, card} = ChatCard.project(record(kind, payload))
      assert card.kind == kind
      assert card.label == label
      assert card.action == action
      assert card.status == :open
      # A question's words are in the reply above its card.
      assert is_binary(card.title) or kind == "input_request"
    end)

    assert cases |> Enum.map(&elem(&1, 0)) |> MapSet.new() ==
             RecordPayload.kinds() |> MapSet.new()

    assert {:ok, closed} =
             ChatCard.project(
               record(
                 "publication_offer",
                 %{"body" => "Already handled.", "title" => "Handled"},
                 :confirmed
               )
             )

    assert closed.action == nil
  end

  test "malformed, unsupported, and unprojectable task records stay inert" do
    assert ChatCard.project(record("unknown", %{})) == :ignore
    assert ChatCard.project(record("task_offer", %{"kind" => "engineering"})) == :ignore

    assert ChatCard.project(
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

    assert ChatCard.project(
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

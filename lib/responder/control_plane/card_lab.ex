defmodule Responder.ControlPlane.CardLab do
  @moduledoc """
  Deterministic, side-effect-free catalog of every Slack presentation state.

  Message specimens pass through `Responder.Slack.Renderer`; App Home and modal
  specimens pass through their production view builders. Transition edges only
  select another checked-in specimen and never invoke a Slack or domain action.
  """

  alias Responder.Emisar.RunState
  alias Responder.Slack.{AppHome, AppHomeEditor, Renderer, ThreadStatusProjection}

  @task_statuses ~w(working waiting_for_input waiting_for_event action_required stopping reviewing ready_for_review ready_to_publish published completed cancelled)
  @incident_statuses ~w(provisioning investigating action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)
  @spec catalog() :: [map()]
  def catalog do
    key = {__MODULE__, :catalog, __MODULE__.module_info(:md5)}

    case :persistent_term.get(key, :missing) do
      :missing ->
        catalog = build_catalog()
        :persistent_term.put(key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  defp build_catalog do
    [
      task_cards(),
      incident_rooms(),
      channel_setup(),
      governed_actions(),
      work_diffs(),
      task_offers(),
      publication_cards(),
      schedule_offers(),
      automation_changes(),
      memory_offers(),
      behavior_offers(),
      slack_post_offers(),
      input_and_waits(),
      investigation_records(),
      ordinary_messages(),
      app_home(),
      app_home_modal(),
      thread_statuses()
    ]
  end

  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, :card_lab_specimen_not_found}
  def fetch(card_id, state_id) when is_binary(card_id) and is_binary(state_id) do
    catalog = catalog()

    with %{} = card <- Enum.find(catalog, &(&1.id == card_id)),
         %{} = state <- Enum.find(card.states, &(&1.id == state_id)) do
      {:ok,
       %{card: card, catalog: catalog_summary(catalog), rendered: state.rendered, state: state}}
    else
      nil -> {:error, :card_lab_specimen_not_found}
    end
  end

  def fetch(_card_id, _state_id), do: {:error, :card_lab_specimen_not_found}

  @spec default() :: map()
  def default do
    catalog = catalog()
    [card | _rest] = catalog
    [state | _rest] = card.states

    %{
      card: card,
      catalog: catalog_summary(catalog),
      rendered: state.rendered,
      state: state
    }
  end

  @spec transition(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :card_lab_specimen_not_found | :card_lab_transition_not_found}
  def transition(card_id, state_id, transition_id) do
    with {:ok, %{state: state}} <- fetch(card_id, state_id),
         %{} = transition <- Enum.find(state.transitions, &(&1.id == transition_id)) do
      fetch(card_id, transition.to)
    else
      nil -> {:error, :card_lab_transition_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec coverage() :: map()
  def coverage do
    cards = catalog()

    %{
      card_count: length(cards),
      emisar_statuses: covered(cards, :emisar_status),
      incident_statuses: covered(cards, :incident_status),
      record_kinds: covered(cards, :record_kind),
      record_states: covered(cards, :record_state),
      setup_states: covered(cards, :setup_state),
      setup_statuses: covered(cards, :setup_status),
      setup_steps: covered(cards, :setup_step),
      specimen_count: Enum.sum(Enum.map(cards, &length(&1.states))),
      surfaces: cards |> Enum.map(& &1.surface) |> MapSet.new(),
      task_statuses: covered(cards, :task_status),
      thread_phases: covered(cards, :thread_phase)
    }
  end

  defp catalog_summary(catalog) do
    Enum.map(catalog, fn card ->
      %{
        first_state_id: hd(card.states).id,
        id: card.id,
        state_count: length(card.states),
        surface: card.surface,
        title: card.title
      }
    end)
  end

  defp covered(cards, key) do
    cards
    |> Enum.flat_map(& &1.states)
    |> Enum.flat_map(fn state -> List.wrap(Map.get(state.covers, key)) end)
    |> Enum.uniq()
  end

  defp task_cards do
    states =
      @task_statuses
      |> Enum.map(fn status ->
        state(slug(status), humanize(status), task_description(status), task_document(status), %{
          task_status: status
        })
      end)
      |> insert_after("ready-for-review", [
        state(
          "readiness-offered",
          "Readiness offered",
          "The committed candidate can enter its read-only readiness check.",
          task_document("ready_for_review", publication("offered", ["readiness"])),
          %{task_status: "ready_for_review"}
        ),
        state(
          "reviewed-publication",
          "Reviewed candidate",
          "The exact reviewed candidate can be published as a draft pull request.",
          task_document("ready_to_publish", publication("reviewed", ["publish"])),
          %{task_status: "ready_to_publish"}
        ),
        state(
          "blocked-publication",
          "Publication blocked",
          "A recoverable publication failure offers refresh or discard controls.",
          task_document("action_required", publication("blocked", ["update", "discard"], 3)),
          %{task_status: "action_required"}
        ),
        state(
          "conflicted-publication",
          "Publication conflict",
          "A stale or conflicting candidate remains operator-owned and recoverable.",
          task_document(
            "action_required",
            publication("publish_pending", ["open", "update", "discard"], 4, true)
          ),
          %{task_status: "action_required"}
        ),
        state(
          "published-stale-head",
          "Published, newer head",
          "The draft PR exists but the retained workspace has newer unpublished work.",
          task_document(
            "published",
            publication("published", ["open", "check", "update", "discard"], 5, true)
          ),
          %{task_status: "published"}
        )
      ])

    states =
      put_transitions(states, %{
        "working" => [
          t("wait-input", "Need operator input", "waiting-for-input"),
          t("wait-event", "Wait for event", "waiting-for-event"),
          t("need-action", "Raise blocker", "action-required"),
          t("stop", "Stop current run", "stopping"),
          t("review", "Start review", "reviewing")
        ],
        "waiting-for-input" => [t("resume", "Resume work", "working")],
        "waiting-for-event" => [t("event-arrived", "Event arrived", "working")],
        "action-required" => [t("correct", "Apply correction", "working")],
        "stopping" => [t("stopped", "Finish stopping", "cancelled")],
        "reviewing" => [t("ready", "Readiness result", "ready-for-review")],
        "ready-for-review" => [t("offer-readiness", "Offer readiness check", "readiness-offered")],
        "readiness-offered" => [
          t("reviewed", "Pass readiness", "reviewed-publication"),
          t("blocked", "Block publication", "blocked-publication")
        ],
        "reviewed-publication" => [t("publish", "Publish draft", "published")],
        "blocked-publication" => [
          t("refresh", "Review latest state", "reviewed-publication"),
          t("discard", "Discard candidate", "cancelled")
        ],
        "conflicted-publication" => [
          t("refresh", "Review latest state", "reviewed-publication"),
          t("discard", "Discard candidate", "cancelled")
        ],
        "ready-to-publish" => [t("publish", "Publish draft", "published")],
        "published" => [
          t("new-head", "Detect newer head", "published-stale-head"),
          t("complete", "Delivery complete", "completed")
        ],
        "published-stale-head" => [
          t("update", "Review latest head", "reviewed-publication"),
          t("complete", "Keep published draft", "completed")
        ]
      })

    family(
      "task-card",
      "Task card",
      "Pinned engineering work, publication recovery, and terminal outcomes.",
      :message,
      states
    )
  end

  defp incident_rooms do
    states =
      @incident_statuses
      |> Enum.map(fn status ->
        state(
          slug(status),
          humanize(status),
          incident_description(status),
          incident_document(status),
          %{
            incident_status: status
          }
        )
      end)
      |> sequence()

    family(
      "incident-room",
      "Incident room",
      "Pinned incident anchor from provisioning through resolution or cancellation.",
      :message,
      states
    )
  end

  defp channel_setup do
    base = setup_document("asking", "participation")

    states = [
      state("welcome", "Welcome", "Safe defaults or customization entry point.", base, %{
        setup_state: "welcome",
        setup_status: "asking",
        setup_step: "participation"
      }),
      state(
        "participation",
        "Participation",
        "Mentions, proactive, or shadow participation.",
        put_in(base, ["channel_setup", "draft", "customizing"], true),
        %{setup_state: "participation", setup_status: "asking", setup_step: "participation"}
      ),
      state(
        "repository",
        "Repository",
        "Select configured code context.",
        setup_document("asking", "repository"),
        %{setup_state: "repository", setup_status: "asking", setup_step: "repository"}
      ),
      state(
        "alerts",
        "Alert policy",
        "Choose how authenticated app alerts escalate.",
        setup_document("asking", "alerts"),
        %{setup_state: "alerts", setup_status: "asking", setup_step: "alerts"}
      ),
      state(
        "audience",
        "Incident audience",
        "Choose additional incident-room audience.",
        setup_document("asking", "audience"),
        %{setup_state: "audience", setup_status: "asking", setup_step: "audience"}
      ),
      state(
        "confirming",
        "Confirm",
        "Review the complete draft before saving.",
        setup_document("confirming", "confirm"),
        %{setup_state: "confirming", setup_status: "confirming", setup_step: "confirm"}
      ),
      state(
        "saved",
        "Saved",
        "The exact channel configuration was saved.",
        setup_document("saved", "confirm"),
        %{setup_state: "saved", setup_status: "saved", setup_step: "confirm"}
      ),
      state(
        "cancelled",
        "Cancelled",
        "No setting changed.",
        setup_document("cancelled", "confirm"),
        %{setup_state: "cancelled", setup_status: "cancelled", setup_step: "confirm"}
      ),
      state(
        "expired",
        "Expired",
        "The draft expired without changing settings.",
        setup_document("expired", "confirm"),
        %{setup_state: "expired", setup_status: "expired", setup_step: "confirm"}
      )
    ]

    family(
      "channel-setup",
      "Channel setup",
      "Interactive setup wizard and every terminal state.",
      :message,
      sequence(states)
    )
  end

  defp governed_actions do
    states =
      RunState.statuses()
      |> Enum.map(fn status ->
        error =
          if status in ~w(failed error validation_failed unknown_action),
            do: "The exact remote run reported a bounded failure.",
            else: nil

        state(
          slug(status),
          humanize(status),
          "Authoritative Emisar run status: #{status}.",
          %{
            "emisar_approval_status" => approval_status(status, error)
          },
          %{emisar_status: status}
        )
      end)
      |> sequence()

    family(
      "governed-action",
      "Governed action",
      "Read-only Slack projection of every Emisar run status.",
      :message,
      states
    )
  end

  defp work_diffs do
    digest = String.duplicate("a", 64)

    states = [
      diff_state("first-page", "First page", 0, 2_400, 7_200, true, digest),
      diff_state("middle-page", "Middle page", 2_400, 4_800, 7_200, true, digest),
      diff_state("last-page", "Last page", 4_800, 7_200, 7_200, false, digest),
      diff_state("single-page", "Single page", 0, 1_200, 1_200, false, digest)
    ]

    family(
      "work-diff",
      "Workspace diff",
      "Snapshot-bound diff paging controls.",
      :message,
      sequence(states)
    )
  end

  defp task_offers do
    states = [
      record_state(
        "engineering",
        "Engineering task",
        "Create isolated repository work after confirmation.",
        "task_offer",
        %{
          "kind" => "engineering",
          "prompt" => "Repair the parser and run focused tests.",
          "repository" => "responder",
          "title" => "Fix parser retries"
        }
      ),
      record_state(
        "incident",
        "Incident offer",
        "Open a coordinated incident room after confirmation.",
        "task_offer",
        %{
          "kind" => "incident",
          "prompt" => "Coordinate the current production symptoms.",
          "repository" => nil,
          "title" => "Checkout errors"
        }
      )
    ]

    family(
      "task-offer",
      "Task offers",
      "Operator confirmation before repository or incident work.",
      :message,
      sequence(states)
    )
  end

  defp publication_cards do
    review = %{
      "candidate_tree" => String.duplicate("7", 40),
      "gate" => "passed",
      "patch_bytes" => 4_096,
      "patch_digest" => String.duplicate("8", 64),
      "policy_findings" => [],
      "publishable" => true,
      "reasons" => [],
      "rebase" => "clean",
      "repository" => "responder",
      "title" => "Fix retry reconciliation"
    }

    states = [
      record_state(
        "offer",
        "Publication offer",
        "Committed work can enter a read-only review.",
        "publication_offer",
        %{
          "body" => "Implements the requested retry boundary.",
          "title" => "Fix retry reconciliation"
        }
      ),
      publication_state("review-publishable", "Publishable review", review, "open"),
      publication_state(
        "review-blocked",
        "Blocked review",
        %{review | "gate" => "failed", "publishable" => false, "reasons" => ["gate_failed"]},
        "open"
      ),
      state(
        "published",
        "Draft published",
        "The exact draft PR has open and delivery-check controls.",
        render_record(
          "publication_result",
          %{
            "branch_ref" => "refs/heads/responder/fix-42",
            "commit_sha" => String.duplicate("a", 40),
            "pull_request_number" => 42,
            "pull_request_url" => "https://github.com/acme/responder/pull/42",
            "repository" => "responder",
            "title" => "Fix lifecycle tracking"
          },
          "confirmed",
          "publication:published42"
        ),
        %{record_kind: "publication_result", record_state: "publication_result:confirmed"}
      )
    ]

    family(
      "publication",
      "Publication cards",
      "Offer, review verdicts, and published draft receipt.",
      :message,
      sequence(states)
    )
  end

  defp schedule_offers do
    recurrences = [
      {"once", %{"at" => "2099-09-04T14:00:00.000000Z", "kind" => "once"}},
      {"interval",
       %{
         "every_seconds" => 3_600,
         "kind" => "interval",
         "starts_at" => "2099-09-04T14:00:00.000000Z"
       }},
      {"daily", %{"kind" => "daily", "time" => "09:00:00"}},
      {"weekly", %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "monday"}},
      {"monthly", %{"day" => 15, "kind" => "monthly", "time" => "09:00:00"}}
    ]

    states =
      Enum.map(recurrences, fn {id, recurrence} ->
        record_state(id, humanize(id), "A #{id} recurring-work offer.", "schedule_offer", %{
          "authority" => "read_only",
          "catch_up" => "latest",
          "expires_at" => nil,
          "recurrence" => recurrence,
          "repository" => nil,
          "task" => "Inspect current service health and report material changes.",
          "timezone" => "Etc/UTC",
          "title" => "Service health"
        })
      end)

    family(
      "schedule-offer",
      "Schedule offer",
      "Every supported recurrence shape before creation.",
      :message,
      sequence(states)
    )
  end

  defp automation_changes do
    before = automation_document("active", 1)

    states =
      ~w(update pause resume delete)
      |> Enum.map(fn action ->
        after_status = if action == "pause", do: "paused", else: "active"
        after_document = automation_document(after_status, 2)
        after_document = if action == "delete", do: %{}, else: after_document

        record_state(
          action,
          humanize(action),
          "Review the exact before/after #{action}.",
          "automation_change_offer",
          %{
            "action" => action,
            "after" => after_document,
            "automation_id" => before["automation_id"],
            "automation_kind" => "time",
            "before" => before,
            "patch" => %{},
            "revision" => 1
          }
        )
      end)

    family(
      "automation-change",
      "Automation change",
      "Update, pause, resume, and delete confirmations.",
      :message,
      sequence(states)
    )
  end

  defp memory_offers do
    kinds = [
      {"alias", "checkout-api", "payments-api"},
      {"repository-binding", "primary_repository", "responder"},
      {"evidence-route", "production_metrics", "Use the Emisar monitoring pack."},
      {"entity-relationship", "checkout_dependency", "checkout depends on payments"}
    ]

    states =
      Enum.map(kinds, fn {id, subject, value} ->
        kind = String.replace(id, "-", "_")

        record_state(id, humanize(id), "Scoped #{humanize(id)} memory offer.", "memory_offer", %{
          "expires_in" => "90d",
          "kind" => kind,
          "repository" => nil,
          "scope" => "conversation",
          "subject" => subject,
          "value" => value,
          "visibility" => "conversation"
        })
      end)

    family(
      "memory-offer",
      "Memory offer",
      "Every supported operational-memory kind.",
      :message,
      sequence(states)
    )
  end

  defp behavior_offers do
    states = [
      record_state(
        "preference",
        "Preference",
        "A bounded operator preference.",
        "preference_offer",
        %{
          "expires_in" => "90d",
          "key" => "response_detail",
          "repository" => nil,
          "scope" => "operator",
          "value" => "concise"
        }
      ),
      record_state(
        "guidance",
        "Guidance",
        "Advisory conversational guidance.",
        "guidance_offer",
        %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "conversation",
          "subject" => "terraform-review",
          "summary" => "Lead with availability risk.",
          "text" => "Explain availability and drift before resource counts.",
          "visibility" => "conversation"
        }
      ),
      record_state(
        "standing-assignment",
        "Standing assignment",
        "Legacy typed standing assignment.",
        "standing_assignment_offer",
        %{
          "action" => "review_terraform_plan",
          "expires_in" => "30d",
          "repository" => "responder-infra",
          "source_filter" => "app",
          "task" => "Review every exact Terraform plan posted here.",
          "trigger" => "terraform_plan"
        }
      ),
      record_state(
        "source-event",
        "Source-event automation",
        "Generic GitHub or platform event automation.",
        "standing_assignment_offer",
        %{
          "catch_up" => "skip",
          "context_channel" => "slack:T123:C456",
          "delivery_channel" => "slack:T123:C456",
          "expires_at" => nil,
          "filter" => %{"action" => "submitted"},
          "hold" => nil,
          "repository" => "responder",
          "source_kind" => "github",
          "task" => "Review every submitted pull request review.",
          "title" => "Review pull request reviews"
        }
      )
    ]

    family(
      "behavior-offer",
      "Behavior offers",
      "Preferences, guidance, and standing assignments.",
      :message,
      sequence(states)
    )
  end

  defp slack_post_offers do
    payload = %{
      "conversation_ref" => "slack:T123:C789",
      "destination_ref" => "slack-source:v1:T123:C789:thread:1787832888.000300",
      "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
      "message" => "The deployment is healthy.",
      "requested_by_actor_ref" => "slack:user:U123",
      "thread_ref" => "1787832888.000300",
      "transport" => "slack"
    }

    states = [
      record_state(
        "open",
        "Awaiting confirmation",
        "No additional message has been posted.",
        "slack_post_offer",
        payload
      ),
      state(
        "confirmed",
        "Confirmed",
        "The durable delivery worker is reconciling the post.",
        render_record("slack_post_offer", payload, "confirmed"),
        %{record_kind: "slack_post_offer", record_state: "slack_post_offer:confirmed"}
      )
    ]

    family(
      "slack-post",
      "Additional Slack post",
      "Requester-owned confirmation and delivery handoff.",
      :message,
      sequence(states)
    )
  end

  defp input_and_waits do
    states = [
      record_state(
        "choices",
        "Input choices",
        "A bounded choice can continue the waiting episode.",
        "input_request",
        %{
          "choices" => ["Roll out to 1%", "Stop the rollout"],
          "question" => "Which rollout action should I take?"
        }
      ),
      record_state(
        "freeform",
        "Freeform input",
        "The operator replies in the thread rather than clicking a choice.",
        "input_request",
        %{"choices" => [], "question" => "What exact threshold should I use?"}
      ),
      record_state(
        "event",
        "External event wait",
        "The episode is waiting for a matching external observation.",
        "event_wait",
        %{
          "deadline_at" => "2099-09-05T12:00:00.000000Z",
          "event_matcher" => %{"deployment" => "responder"},
          "kind" => "deployment_health",
          "verification" => "Verify the new allocation is healthy."
        }
      ),
      record_state(
        "emisar-approval",
        "Emisar approval hold",
        "Slack links to Emisar but cannot approve the action.",
        "emisar_approval",
        approval_record()
      )
    ]

    family(
      "wait-record",
      "Questions and waits",
      "Durable input, external-event, and governed-action waits.",
      :message,
      sequence(states)
    )
  end

  defp investigation_records do
    evidence = [
      {"evidence-observed",
       %{
         "claim_id" => "api.health",
         "observation" => "The API probe is ready.",
         "relation" => nil,
         "source_name" => "production probe",
         "source_type" => "monitoring"
       }},
      {"evidence-contradicts",
       %{
         "claim_id" => "api.health",
         "observation" => "The worker probe contradicts overall health.",
         "relation" => "contradicts",
         "source_name" => "worker probe",
         "source_type" => "monitoring"
       }}
    ]

    coverage =
      Enum.map(
        ~w(healthy degraded unhealthy unknown not_applicable),
        &{"coverage-#{slug(&1)}",
         %{
           "claim_ids" => ["api.health"],
           "detail" => "The application layer was sampled.",
           "layer" => "application",
           "observed_at" => "2026-09-04T12:00:00.000000Z",
           "source" => "production probe",
           "status" => &1
         }}
      )

    finding = [
      {"finding-unexplained",
       %{"status" => "unexplained", "what" => "Worker health is not yet known."}},
      {"finding-explained",
       %{
         "cause_evidence" => ["evidence:worker"],
         "status" => "explained",
         "what" => "Worker health failed because the queue is stalled."
       }},
      {"finding-expected",
       %{
         "reason" => "This is an intentional maintenance window.",
         "status" => "expected",
         "what" => "One replica is absent."
       }},
      {"finding-out-of-scope",
       %{
         "reason" => "Owned by the upstream provider.",
         "status" => "out_of_scope",
         "what" => "External DNS control-plane latency."
       }}
    ]

    goal_states =
      Enum.map(
        ~w(ready working waiting completed blocked excluded cancelled),
        &{"goal-#{slug(&1)}", %{"goal_id" => "check-workers", "state" => &1}}
      )

    assessments = [
      {"assessment-confirmed", issue_assessment("confirmed_issue")},
      {"assessment-likely", issue_assessment("likely_issue")},
      {"assessment-not-issue",
       %{"impact" => "No customer impact remains.", "verdict" => "not_issue"}},
      {"assessment-unverified",
       %{
         "impact" => "Workers are not yet verified.",
         "immediate_action" => "Inspect a current worker signal.",
         "verdict" => "unverified"
       }}
    ]

    records =
      Enum.map(evidence, &investigation_state(&1, "evidence")) ++
        Enum.map(coverage, &investigation_state(&1, "coverage")) ++
        Enum.map(finding, &investigation_state(&1, "finding")) ++
        [
          investigation_state(
            {"progress",
             %{"phase" => "verifying", "summary" => "The API is healthy; workers remain."}},
            "progress"
          )
        ] ++
        [
          investigation_state(
            {"goal",
             %{
               "authority" => "read_only",
               "completion_contract" => "A current worker observation exists.",
               "id" => "check-workers",
               "kind" => "check",
               "parent_goal_id" => "verify-service",
               "prerequisite_goal_ids" => ["check-api"],
               "read_only_repositories" => ["runbooks"],
               "requested_outcome" => "Check worker health",
               "required" => true
             }},
            "goal"
          )
        ] ++
        Enum.map(goal_states, &investigation_state(&1, "goal_state")) ++
        Enum.map(assessments, &investigation_state(&1, "alert_assessment"))

    confirmed = [
      investigation_state(
        {"evidence-confirmed", elem(hd(evidence), 1)},
        "evidence",
        "confirmed"
      ),
      investigation_state(
        {"coverage-confirmed", elem(hd(coverage), 1)},
        "coverage",
        "confirmed"
      ),
      investigation_state(
        {"finding-confirmed", elem(hd(finding), 1)},
        "finding",
        "confirmed"
      ),
      investigation_state(
        {"progress-confirmed",
         %{"phase" => "verified", "summary" => "The exact progress note was confirmed."}},
        "progress",
        "confirmed"
      ),
      investigation_state(
        {"goal-confirmed",
         %{
           "authority" => "read_only",
           "completion_contract" => "A current worker observation exists.",
           "id" => "check-workers",
           "kind" => "check",
           "requested_outcome" => "Check worker health",
           "required" => true
         }},
        "goal",
        "confirmed"
      ),
      investigation_state(
        {"goal-state-confirmed", elem(hd(goal_states), 1)},
        "goal_state",
        "confirmed"
      ),
      investigation_state(
        {"assessment-confirmed-record", elem(List.last(assessments), 1)},
        "alert_assessment",
        "confirmed"
      )
    ]

    family(
      "investigation-record",
      "Investigation records",
      "Every inert evidence, coverage, finding, goal, and assessment state.",
      :message,
      sequence(records ++ confirmed)
    )
  end

  defp ordinary_messages do
    states = [
      state(
        "plain",
        "Plain response",
        "Ordinary model prose without interactive records.",
        %{"message" => "The current deployment is healthy.\n\nNo action is required."},
        %{}
      ),
      state(
        "typed-mentions",
        "Typed mentions",
        "Only host-authorized typed mentions become Slack controls.",
        %{
          "message" => "Thanks [@Bruno](slack-user:U123). Raw <!everyone> stays inert.",
          "records" => [],
          "slack_mentions" => %{
            "broadcasts" => [],
            "channels" => [],
            "user_groups" => [],
            "users" => ["slack-user:U123"],
            "workspace_ref" => "T123"
          }
        },
        %{}
      )
    ]

    family(
      "message",
      "Ordinary messages",
      "Plain replies and host-authorized Slack mentions.",
      :message,
      sequence(states)
    )
  end

  defp app_home do
    states = [
      view_state(
        "restricted",
        "Restricted member",
        "No private operational state is disclosed.",
        AppHome.render(:restricted, %{})
      ),
      view_state(
        "operator-empty",
        "Operator · quiet",
        "No work currently needs attention.",
        AppHome.render(:operator, home_snapshot())
      ),
      view_state(
        "operator-active",
        "Operator · active",
        "Attention, work, incidents, controls, and counts together.",
        AppHome.render(:operator, active_home_snapshot())
      ),
      view_state(
        "memory-review-stale",
        "Stale memory review",
        "Editable stale memory with keep, edit, and forget controls.",
        AppHome.render(:operator, %{
          home_snapshot()
          | memory_review_count: 1,
            memory_reviews: [stale_memory_review()]
        })
      ),
      view_state(
        "memory-review-duplicate",
        "Duplicate memory review",
        "Duplicate memories can remain separate, merge, or be forgotten.",
        AppHome.render(:operator, %{
          home_snapshot()
          | memory_review_count: 1,
            memory_reviews: [duplicate_memory_review()]
        })
      )
    ]

    family(
      "app-home",
      "App Home",
      "Restricted and operator Home views, including actionable memory review.",
      :app_home,
      sequence(states)
    )
  end

  defp app_home_modal do
    {:ok, view} = AppHomeEditor.memory_review_view("memory-review:stale-1", stale_memory_review())

    family(
      "app-home-modal",
      "App Home editor",
      "The exact modal used to edit one stale memory.",
      :modal,
      [view_state("memory-edit", "Edit memory", "Bounded subject and guidance inputs.", view)]
    )
  end

  defp thread_statuses do
    statuses = [
      {:blocked, "", "Admission or execution needs operator attention."},
      {:admitting, "is deciding how to respond...", "Admission owns the input."},
      {:admission_retry, "is waiting to retry admission...", "Admission is durably retrying."},
      {:queued, "is queued...", "The input is accepted and queued."},
      {:delivery, "is preparing the response...", "The accepted result is being delivered."},
      {:working, "is working...", "A model turn owns the episode."},
      {:waiting_for_input, "is waiting for your answer...", "The episode needs human input."},
      {:waiting_for_event, "is waiting for an external event...",
       "The episode awaits external verification."},
      {:clear, "", "Terminal state clears Slack's assistant status."}
    ]

    if Enum.map(statuses, &elem(&1, 0)) != ThreadStatusProjection.phases(),
      do: raise(ArgumentError, "Card Lab thread statuses do not match the production projection")

    states =
      Enum.map(statuses, fn {phase, status, description} ->
        id = phase |> Atom.to_string() |> slug()

        view_state(
          id,
          humanize(id),
          description,
          %{
            "blocks" => [],
            "status" => status,
            "type" => "thread_status"
          },
          %{thread_phase: phase}
        )
      end)

    family(
      "thread-status",
      "Assistant thread status",
      "Every ephemeral Slack assistant-thread status projection.",
      :thread_status,
      sequence(states)
    )
  end

  defp family(id, title, description, surface, states),
    do: %{description: description, id: id, states: states, surface: surface, title: title}

  defp state(id, label, description, document, covers) do
    rendered =
      case Renderer.render(document) do
        {:ok, rendered} ->
          rendered

        {:error, reason} ->
          raise ArgumentError, "invalid Card Lab fixture #{id}: #{inspect(reason)}"
      end

    %{
      covers: covers,
      description: description,
      id: id,
      label: label,
      rendered: rendered,
      transitions: []
    }
  end

  defp view_state(id, label, description, rendered, covers \\ %{}),
    do: %{
      covers: covers,
      description: description,
      id: id,
      label: label,
      rendered: rendered,
      transitions: []
    }

  defp record_state(id, label, description, kind, payload, status \\ "open") do
    state(id, label, description, render_record(kind, payload, status), %{
      record_kind: kind,
      record_state: "#{kind}:#{status}"
    })
  end

  defp publication_state(id, label, payload, status) do
    state(
      id,
      label,
      "Trusted read-only publication verdict.",
      render_record("publication_review", payload, status, "publication:#{id}"),
      %{record_kind: "publication_review", record_state: "publication_review:#{status}"}
    )
  end

  defp investigation_state({id, payload}, kind, status \\ "open"),
    do:
      record_state(
        id,
        humanize(id),
        "Inert #{humanize(kind)} record.",
        kind,
        payload,
        status
      )

  defp render_record(kind, payload, status, ref \\ nil) do
    %{
      "message" => "Current #{humanize(kind)} state.",
      "records" => [
        %{
          "kind" => kind,
          "payload" => payload,
          "ref" => ref || "record:#{kind}:card-lab",
          "status" => status
        }
      ]
    }
  end

  defp sequence(states) do
    ids = Enum.map(states, & &1.id)

    states
    |> Enum.with_index()
    |> Enum.map(fn {state, index} ->
      transitions =
        [
          if(index > 0, do: t("previous", "Previous state", Enum.at(ids, index - 1))),
          if(index < length(ids) - 1, do: t("next", "Next state", Enum.at(ids, index + 1)))
        ]
        |> Enum.reject(&is_nil/1)

      %{state | transitions: transitions}
    end)
  end

  defp put_transitions(states, transitions) do
    Enum.map(states, fn state -> %{state | transitions: Map.get(transitions, state.id, [])} end)
  end

  defp insert_after(states, id, inserted) do
    {left, right} = Enum.split_while(states, &(&1.id != id))

    case right do
      [matched | rest] -> left ++ [matched] ++ inserted ++ rest
      [] -> states ++ inserted
    end
  end

  defp t(id, label, to), do: %{id: id, label: label, to: to}

  defp task_document(status, publication \\ nil) do
    action_needed =
      if status == "action_required",
        do: "Review the current blocker and choose a recovery path.",
        else: nil

    controls =
      if status in ~w(completed cancelled stopping),
        do: ["timeline", "evidence", "handoff"],
        else: ["stop", "view_diff", "close", "timeline", "evidence", "handoff"]

    %{
      "task_card" => %{
        "action_needed" => action_needed,
        "confirmed_at" => "2026-09-04T12:00:00.000000Z",
        "confirmed_by" => "slack:user:U123",
        "controls" => controls,
        "episode_state" => task_episode_state(status),
        "publication" => publication,
        "repository" => "responder",
        "session_generation" => 2,
        "status" => status,
        "summary" => task_description(status),
        "task_ref" => "task-card:card-lab-123",
        "title" => "Fix parser retries",
        "ui_revision" => 7,
        "updated_at" => "2026-09-04T12:04:00.000000Z",
        "work_state" => task_work_state(status)
      }
    }
  end

  defp publication(status, controls, generation \\ 1, published \\ false) do
    %{
      "controls" => controls,
      "publication_ref" => if(status == "offered", do: nil, else: "publication:card-lab"),
      "pull_request_number" => if(published, do: 91, else: nil),
      "pull_request_url" =>
        if(published, do: "https://github.com/acme/responder/pull/91", else: nil),
      "recovery_generation" => if(status == "offered", do: nil, else: generation),
      "review_offer_ref" =>
        if(status == "offered", do: "record:publication_offer:card-lab", else: nil),
      "status" => status
    }
  end

  defp task_episode_state(status) when status in ~w(completed), do: "complete"
  defp task_episode_state(status) when status in ~w(cancelled), do: "cancelled"

  defp task_episode_state(status) when status in ~w(waiting_for_input waiting_for_event),
    do: status

  defp task_episode_state(_status), do: "working"

  defp task_work_state(status)
       when status in ~w(completed cancelled published ready_to_publish ready_for_review),
       do: "settled"

  defp task_work_state("action_required"), do: "blocked"
  defp task_work_state(_status), do: "pending"

  defp task_description("working"), do: "The parser fix is running focused validation."

  defp task_description("waiting_for_input"),
    do: "One exact operator decision is required before work can continue."

  defp task_description("waiting_for_event"),
    do: "Work is waiting for an external verification event."

  defp task_description("action_required"),
    do: "The current attempt is blocked and needs a bounded recovery decision."

  defp task_description("stopping"),
    do: "The active run is being cancelled while custody remains durable."

  defp task_description("reviewing"),
    do: "The committed candidate is in a trusted read-only review."

  defp task_description("ready_for_review"), do: "Changes are ready for a readiness check."

  defp task_description("ready_to_publish"),
    do: "The reviewed candidate is ready for operator publication."

  defp task_description("published"),
    do: "The reviewed change is available as a draft pull request."

  defp task_description("completed"),
    do: "The requested outcome and its verification contract are complete."

  defp task_description("cancelled"),
    do: "The task is closed; its durable history remains available."

  defp incident_document(status) do
    %{
      "incident_room" => %{
        "action_needed" =>
          if(status in ~w(action_required waiting_for_input),
            do: "Review the current blocker.",
            else: nil
          ),
        "alert" => %{
          "impact" => "Checkout traffic is affected.",
          "verdict" => if(status == "resolved", do: "not_issue", else: "confirmed_issue")
        },
        "controls" =>
          if(status in ~w(resolved cancelled),
            do: ["timeline", "evidence", "handoff", "postmortem"],
            else: ["stop", "view_diff", "close", "timeline", "evidence", "handoff", "postmortem"]
          ),
        "episode_state" => incident_episode_state(status),
        "opened_at" => "2026-09-04T11:45:00.000000Z",
        "opened_by" => "slack:user:U123",
        "repository" => "responder",
        "room_ref" => "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342",
        "session_generation" => 2,
        "severity" => "high",
        "signals" => %{"firing" => if(status == "resolved", do: 0, else: 2), "total" => 3},
        "source" => %{
          "channel_ref" => "C123",
          "message_ref" => "1787832000.000100",
          "thread_ref" => "1787832000.000100"
        },
        "status" => status,
        "summary" => incident_description(status),
        "title" => "Checkout errors",
        "ui_revision" => 9,
        "updated_at" => "2026-09-04T12:04:00.000000Z"
      }
    }
  end

  defp incident_episode_state(status) when status in ~w(resolved), do: "complete"
  defp incident_episode_state(status) when status in ~w(cancelled), do: "cancelled"

  defp incident_episode_state(status) when status in ~w(waiting_for_input waiting_for_event),
    do: status

  defp incident_episode_state(_status), do: "working"

  defp incident_description("provisioning"), do: "The private incident room is being provisioned."

  defp incident_description("investigating"),
    do: "Current signals are being correlated across the service path."

  defp incident_description("action_required"), do: "A bounded operator action is required."

  defp incident_description("waiting_for_input"),
    do: "The investigation needs one operator decision."

  defp incident_description("waiting_for_event"),
    do: "The incident is waiting for current verification."

  defp incident_description("stopping"), do: "The active investigation turn is stopping."

  defp incident_description("resolved"),
    do: "Recovery has been verified and the incident is resolved."

  defp incident_description("cancelled"),
    do: "The incident was closed without deleting its history."

  defp incident_description("paused"),
    do: "The Slack room is inactive; durable incident state remains."

  defp setup_document(status, step) do
    draft = %{
      "alert_policy" => "offer",
      "customizing" => false,
      "default_repository" => "responder",
      "invite_user_group_refs" => [],
      "invite_user_refs" => ["U123"],
      "participation" => "proactive",
      "repository_options" => [
        "responder",
        "emisar",
        "responder-infra",
        "runbooks",
        "frontend",
        "platform"
      ],
      "repository_ref" => "responder"
    }

    %{
      "channel_setup" => %{
        "draft" => draft,
        "expires_at" => "2099-09-04T12:30:00.000000Z",
        "revision" => 1,
        "session_ref" => "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
        "status" => status,
        "step" => step
      }
    }
  end

  defp approval_status(status, error) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-card-lab",
      "expires_at" => "2099-09-04T12:30:00.000000Z",
      "operation_id" => "op-card-lab",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => error,
      "request_id" => "apr-card-lab",
      "run_id" => "run-card-lab",
      "run_url" => "https://emisar.example/app/acme/runs/run-card-lab",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end

  defp approval_record do
    approval_status("pending_approval", nil)
    |> Map.delete("remote_error")
    |> Map.delete("run_url")
  end

  defp diff_state(id, label, offset, next_offset, bytes, more, digest) do
    state(
      id,
      label,
      "Snapshot-bound patch page at byte #{offset}.",
      %{
        "work_diff" => %{
          "message" =>
            "Workspace diff for task-card:card-lab-123\n@@ parser.ex @@\n- retry(old)\n+ retry(current)",
          "patch_bytes" => bytes,
          "patch_digest" => digest,
          "patch_has_more" => more,
          "patch_next_offset" => next_offset,
          "patch_offset" => offset,
          "work_ref" => "task-card:card-lab-123"
        }
      },
      %{}
    )
  end

  defp automation_document(status, revision),
    do: %{
      "automation_id" => "schedule:daily-health",
      "catch_up" => "latest",
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "next_occurrence_at" => "2099-09-05T13:00:00.000000Z",
      "prompt" => "Inspect current service health.",
      "repository" => nil,
      "revision" => revision,
      "status" => status,
      "title" => "Daily service health",
      "trigger" => %{
        "recurrence" => "daily",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    }

  defp issue_assessment(verdict),
    do: %{
      "cause" => "The worker queue is stalled.",
      "cause_claim_ids" => ["worker.queue"],
      "cause_status" => "identified",
      "evidence_refs" => ["record:evidence:worker"],
      "impact" => "Checkout processing is delayed.",
      "immediate_action" => "Drain the stalled worker.",
      "long_term_solution" => "Add a queue-age SLO.",
      "verification" => "Observe queue age below 30 seconds.",
      "verdict" => verdict
    }

  defp home_snapshot do
    %{
      behaviors: [],
      counts: %{},
      incidents: [],
      memories: [],
      memory_review_count: 0,
      memory_reviews: [],
      needs_attention: [],
      schedules: [],
      work: []
    }
  end

  defp active_home_snapshot do
    %{
      home_snapshot()
      | behaviors: [
          %{
            kind: :guidance,
            ref: "behavior:1",
            revision: 3,
            status: :active,
            subject: "Production reviews",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        counts: %{
          active_behaviors: 1,
          active_commitments: 2,
          active_memory: 1,
          active_schedules: 1,
          blocked_work: 1,
          incident_history: 4,
          open_incidents: 1,
          published_work: 2,
          retained_workspaces: 1
        },
        incidents: [
          %{
            ref: "incident-room:card-lab",
            status: :investigating,
            title: "Checkout errors",
            url: "https://slack.com/app_redirect?channel=CINCIDENT"
          }
        ],
        memories: [
          %{
            kind: :repository_binding,
            ref: "memory:1",
            subject: "Primary repository",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        needs_attention: [
          %{
            controls: ["retry", "discard"],
            kind: :publication,
            recovery_generation: 2,
            ref: "publication:card-lab",
            title: "Publication needs review",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        schedules: [
          %{
            next_occurrence_at: ~U[2099-09-05 09:00:00Z],
            ref: "schedule:1",
            revision: 2,
            status: :active,
            title: "Daily health",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        work: [
          %{
            next_action: :continue_work,
            ref: "task-card:card-lab",
            state: :working,
            title: "Fix parser retries",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ]
    }
  end

  defp stale_memory_review do
    %{
      "entries" => [
        %{
          "memory_ref" => "memory:stale",
          "scope" => "workspace",
          "scope_ref" => "T123",
          "subject" => "primary_repository",
          "url" => "https://slack.com/app_redirect?channel=C123",
          "value" => "responder",
          "visibility" => "workspace"
        }
      ],
      "kind" => "stale",
      "reason" => "This mapping has not been confirmed recently.",
      "review_ref" => "memory-review:stale-1"
    }
  end

  defp duplicate_memory_review do
    %{
      "entries" => [
        %{
          "memory_ref" => "memory:duplicate-1",
          "scope" => "workspace",
          "scope_ref" => "T123",
          "subject" => "primary_repository",
          "url" => "https://slack.com/app_redirect?channel=C123",
          "value" => "responder",
          "visibility" => "workspace"
        },
        %{
          "memory_ref" => "memory:duplicate-2",
          "scope" => "workspace",
          "scope_ref" => "T123",
          "subject" => "primary_repo",
          "url" => "https://slack.com/app_redirect?channel=C123",
          "value" => "responder",
          "visibility" => "workspace"
        }
      ],
      "kind" => "duplicate",
      "reason" => "These entries describe the same mapping.",
      "review_ref" => "memory-review:duplicate-1"
    }
  end

  defp slug(value), do: String.replace(value, "_", "-")

  defp humanize(value),
    do: value |> to_string() |> String.replace(["_", "-"], " ") |> String.capitalize()
end

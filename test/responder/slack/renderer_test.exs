defmodule Responder.Slack.RendererTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Renderer

  test "a confirmed recorded automation replaces the enable button with its saved state" do
    captured = Jason.decode!(File.read!("testdata/work/terraform-automation-recovery.json"))
    proposal = hd(captured["automation_arguments"]["proposals"])

    record = %{
      "kind" => "standing_assignment_offer",
      "ref" => hd(captured["accepted_candidate"]["outcome"]["record_refs"]),
      "status" => "confirmed",
      "payload" => %{
        "catch_up" => proposal["catch_up"],
        "context_channel" => "slack:T0BHXKZJVDX:C0BHTRPHXP0",
        "delivery_channel" => "slack:T0BHXKZJVDX:C0BHTRPHXP0",
        "expires_at" => nil,
        "filter" => proposal["trigger"]["filter"],
        "hold" => nil,
        "repository" => nil,
        "source_kind" => proposal["trigger"]["source_kind"],
        "task" => proposal["prompt"],
        "title" => proposal["title"]
      }
    }

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Confirmation saved.", "records" => [record]})

    assert inspect(rendered) =~ "Automation confirmed"
    assert inspect(rendered) =~ proposal["title"]
    refute inspect(rendered) =~ "Enable automation"
    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
  end

  test "renders host-authorized typed mentions into native Slack controls" do
    authority = %{
      "broadcasts" => [],
      "channels" => ["slack:T123:C456"],
      "user_groups" => [],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Thanks [@Bruno](slack-user:U123). Raw <!everyone> stays inert.",
               "records" => [],
               "slack_mentions" => authority
             })

    assert rendered["text"] == "Thanks <@U123>. Raw &lt;!everyone&gt; stays inert."
    assert hd(rendered["blocks"])["text"] == rendered["text"]
  end

  test "renders channel setup from host-owned typed state" do
    session_ref = Ecto.UUID.generate()

    assert {:ok, rendered} =
             Renderer.render(%{
               "channel_setup" => %{
                 "draft" => %{
                   "alert_policy" => nil,
                   "customizing" => false,
                   "default_repository" => "infrastructure",
                   "invite_user_group_refs" => [],
                   "invite_user_refs" => [],
                   "participation" => nil,
                   "repository_options" => ["infrastructure"],
                   "repository_ref" => nil
                 },
                 "expires_at" => "2026-08-28T12:30:00.000000Z",
                 "revision" => 1,
                 "session_ref" => session_ref,
                 "status" => "asking",
                 "step" => "participation"
               }
             })

    assert rendered["text"] =~ "Nothing is saved"
    assert [_, actions, safety] = rendered["blocks"]

    assert Enum.map(actions["elements"], & &1["action_id"]) == [
             "responder_setup_safe_defaults",
             "responder_setup_be_proactive",
             "responder_setup_customize"
           ]

    assert Enum.all?(actions["elements"], &(&1["value"] == session_ref))
    assert safety["text"]["text"] =~ "never grants write"
  end

  test "renders an engineering task offer as host-owned Block Kit" do
    document = %{
      "message" => "I can prepare that repository change.",
      "records" => [
        %{
          "kind" => "task_offer",
          "payload" => %{
            "kind" => "engineering",
            "prompt" => "Change the parser and run focused tests.",
            "repository" => "responder",
            "title" => "Fix parser retries"
          },
          "ref" => "record:task_offer:abc123",
          "status" => "open"
        }
      ]
    }

    assert {:ok, rendered} = Renderer.render(document)
    assert rendered["text"] == "I can prepare that repository change."

    assert [reply, offer, controls] = rendered["blocks"]

    assert reply == %{
             "text" => "I can prepare that repository change.",
             "type" => "markdown"
           }

    assert offer["type"] == "section"
    assert offer["text"]["type"] == "mrkdwn"
    assert offer["text"]["text"] =~ "*Fix parser retries*"
    assert offer["text"]["text"] =~ "Repository: `responder`"

    assert %{
             "action_id" => "responder_start_engineering_task",
             "confirm" => %{
               "confirm" => %{"text" => "Start task"},
               "deny" => %{"text" => "Cancel"},
               "text" => %{"text" => confirmation},
               "title" => %{"text" => "Start engineering task"}
             },
             "style" => "primary",
             "text" => %{"text" => "Start task"},
             "type" => "button",
             "value" => "record:task_offer:abc123"
           } = hd(controls["elements"])

    assert confirmation =~ "isolated working copy"
    refute inspect(rendered) =~ "Change the parser"
  end

  test "renders a durable engineering task projection without model-owned controls" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "task_card" => %{
                 "action_needed" => nil,
                 "confirmed_at" => "2026-08-28T12:00:00.000000Z",
                 "confirmed_by" => "slack:user:U123",
                 "controls" => ["stop", "view_diff", "close", "timeline", "evidence", "handoff"],
                 "episode_state" => "working",
                 "publication" => nil,
                 "repository" => "responder",
                 "session_generation" => 1,
                 "status" => "working",
                 "summary" => "The parser fix is being validated.",
                 "task_ref" => "task-card:abc123",
                 "title" => "Fix parser retries",
                 "ui_revision" => 2,
                 "updated_at" => "2026-08-28T12:01:00.000000Z",
                 "work_state" => "pending"
               }
             })

    assert rendered["text"] =~ "Engineering task abc123"
    assert rendered["text"] =~ "The parser fix is being validated"

    assert Enum.any?(rendered["blocks"], fn block ->
             text = get_in(block, ["text", "text"])
             is_binary(text) and text =~ "Reply in this thread"
           end)

    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))

    assert Enum.map(controls["elements"], & &1["action_id"]) == [
             "responder_stop_work",
             "responder_view_diff",
             "responder_close_work",
             "responder_work_record"
           ]

    record = List.last(controls["elements"])

    assert Enum.map(record["options"], & &1["value"]) == [
             "task-card:abc123|timeline",
             "task-card:abc123|evidence",
             "task-card:abc123|handoff"
           ]
  end

  test "renders snapshot-bound workspace diff navigation" do
    digest = String.duplicate("a", 64)

    assert {:ok, rendered} =
             Renderer.render(%{
               "work_diff" => %{
                 "message" => "Workspace diff for task-card:abc123\nPatch page",
                 "patch_bytes" => 7_200,
                 "patch_digest" => digest,
                 "patch_has_more" => true,
                 "patch_next_offset" => 4_800,
                 "patch_offset" => 2_400,
                 "work_ref" => "task-card:abc123"
               }
             })

    assert rendered["text"] =~ "Workspace diff"
    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))

    assert Enum.map(controls["elements"], &{&1["text"]["text"], &1["value"]}) == [
             {"Previous", "task-card:abc123|#{digest}|0"},
             {"Refresh", "task-card:abc123|#{digest}|2400"},
             {"Next", "task-card:abc123|#{digest}|4800"}
           ]

    assert Enum.all?(controls["elements"], &(&1["action_id"] == "responder_diff_page"))
  end

  test "renders only publication actions valid for the durable task state" do
    task = %{
      "action_needed" => nil,
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => ["view_diff", "timeline", "evidence", "handoff"],
      "episode_state" => "complete",
      "publication" => %{
        "controls" => ["open", "check"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => 91,
        "pull_request_url" => "https://github.com/acme/responder/pull/91",
        "recovery_generation" => 1,
        "review_offer_ref" => nil,
        "status" => "published"
      },
      "repository" => "responder",
      "session_generation" => 1,
      "status" => "published",
      "summary" => "The reviewed change is available as a draft PR.",
      "task_ref" => "task-card:abc123",
      "title" => "Fix parser retries",
      "ui_revision" => 3,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => "settled"
    }

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    publication_controls =
      rendered["blocks"]
      |> Enum.filter(&(&1["type"] == "actions"))
      |> Enum.find(fn block ->
        Enum.any?(block["elements"], &(&1["action_id"] == "responder_task_check"))
      end)

    assert Enum.map(publication_controls["elements"], & &1["action_id"]) == [
             "responder_open_publication",
             "responder_task_check"
           ]

    assert hd(publication_controls["elements"])["url"] ==
             "https://github.com/acme/responder/pull/91"

    assert List.last(publication_controls["elements"])["value"] ==
             "task-card:abc123|publication:def456"

    reviewed =
      put_in(task, ["publication"], %{
        "controls" => ["publish"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 1,
        "review_offer_ref" => nil,
        "status" => "reviewed"
      })

    assert {:ok, reviewed_rendered} = Renderer.render(%{"task_card" => reviewed})

    assert reviewed_rendered["blocks"]
           |> Enum.flat_map(&Map.get(&1, "elements", []))
           |> Enum.any?(&(&1["action_id"] == "responder_task_publish"))

    recoverable =
      put_in(task, ["publication"], %{
        "controls" => ["update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 3,
        "review_offer_ref" => nil,
        "status" => "blocked"
      })

    assert {:ok, recovery_rendered} = Renderer.render(%{"task_card" => recoverable})
    assert Jason.encode!(recovery_rendered) =~ "PR creation is blocked"
    refute Jason.encode!(recovery_rendered) =~ "Publication:"

    recovery_buttons =
      recovery_rendered["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.filter(&String.starts_with?(&1["action_id"] || "", "responder_task_"))

    assert Enum.map(recovery_buttons, &{&1["action_id"], &1["value"]}) == [
             {"responder_task_update_publication", "task-card:abc123|publication:def456|3"},
             {"responder_task_discard_publication", "task-card:abc123|publication:def456|3"}
           ]

    stale =
      put_in(task, ["publication"], %{
        "controls" => ["open", "check", "update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => 91,
        "pull_request_url" => "https://github.com/acme/responder/pull/91",
        "recovery_generation" => 4,
        "review_offer_ref" => nil,
        "status" => "published"
      })

    assert {:ok, stale_rendered} = Renderer.render(%{"task_card" => stale})

    stale_buttons =
      stale_rendered["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.filter(&String.starts_with?(&1["action_id"] || "", "responder_task_"))

    assert Enum.map(stale_buttons, & &1["action_id"]) == [
             "responder_task_check",
             "responder_task_update_publication",
             "responder_task_discard_publication"
           ]
  end

  test "renders incident controls from the host projection and rejects invented controls" do
    room_ref = "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342"

    room = %{
      "action_needed" => nil,
      "alert" => nil,
      "controls" => [
        "stop",
        "view_diff",
        "close",
        "timeline",
        "evidence",
        "handoff",
        "postmortem"
      ],
      "episode_state" => "working",
      "opened_at" => "2026-08-28T12:00:00.000000Z",
      "opened_by" => "slack:user:U123",
      "repository" => "responder",
      "room_ref" => room_ref,
      "session_generation" => 1,
      "severity" => "not supplied",
      "signals" => %{"firing" => nil, "total" => nil},
      "source" => %{
        "channel_ref" => "C123",
        "message_ref" => "1787832000.000100",
        "thread_ref" => nil
      },
      "status" => "investigating",
      "summary" => "Checking the production symptoms.",
      "title" => "Checkout errors",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z"
    }

    assert {:ok, rendered} = Renderer.render(%{"incident_room" => room})
    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))
    assert List.last(controls["elements"])["type"] == "overflow"

    invented = put_in(room, ["controls"], ["delete_repository"])

    assert Renderer.render(%{"incident_room" => invented}) ==
             {:error, {:invalid_slack_render, :incident_room}}
  end

  test "incident offers use operator confirmation and model text cannot create controls" do
    assert {:ok, plain} =
             Renderer.render(%{
               "message" =>
                 ~s({"type":"actions","elements":[{"type":"button","action_id":"evil"}]}),
               "records" => []
             })

    assert [section] = plain["blocks"]
    assert section["type"] == "markdown"
    refute inspect(plain) =~ ~s("action_id" => "evil")

    assert {:ok, incident} =
             Renderer.render(%{
               "message" => "This should be coordinated as an incident.",
               "records" => [
                 %{
                   "kind" => "task_offer",
                   "payload" => %{
                     "kind" => "incident",
                     "prompt" => "Coordinate this incident.",
                     "repository" => nil,
                     "title" => "Checkout errors"
                   },
                   "ref" => "record:task_offer:def456",
                   "status" => "open"
                 }
               ]
             })

    assert [_, _, actions] = incident["blocks"]
    assert [button] = actions["elements"]
    assert button["action_id"] == "responder_open_incident"
    assert button["text"]["text"] == "Open incident room"
  end

  test "renders an inert publication offer with a host-owned review control" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The implementation is committed and ready for review.",
               "records" => [
                 %{
                   "kind" => "publication_offer",
                   "payload" => %{
                     "body" => "Implements the requested retry boundary.",
                     "title" => "Fix retry reconciliation"
                   },
                   "ref" => "record:publication_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    [_, offer, actions] = rendered["blocks"]
    assert offer["text"]["text"] =~ "Fix retry reconciliation"
    assert offer["text"]["text"] =~ "No branch or pull request has been published"

    assert [%{"action_id" => "responder_review_publication"} = button] = actions["elements"]
    assert button["value"] == "record:publication_offer:abc123"
    assert button["confirm"]["text"]["text"] =~ "read-only Coop review"
  end

  test "renders a governed Emisar approval as an authoritative outbound link" do
    document = %{
      "message" => "The action has not run. It is waiting for Emisar approval.",
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
        }
      ]
    }

    assert {:ok, rendered} = Renderer.render(document)

    assert rendered["text"] =~ "has not run"
    assert [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Slack cannot approve"

    assert [button] = actions["elements"]
    assert button["action_id"] == "responder_open_emisar_approval"
    assert button["url"] == "https://emisar.example/app/acme/approvals/apr-1"
    assert button["value"] == "apr-1"

    malformed = put_in(document, ["records", Access.at(0), "payload", "request_id"], "other")
    assert {:error, {:invalid_slack_render, :record}} = Renderer.render(malformed)
  end

  test "refreshes a governed run status without adding Slack approval authority" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "emisar_approval_status" => approval_status("validation_failed", "invalid target")
             })

    assert rendered["text"] =~ "Validation failed"
    assert rendered["text"] =~ "Approval and policy decisions remain authoritative in Emisar"

    [status, actions] = rendered["blocks"]
    assert status["text"]["text"] =~ "Error: invalid target"
    assert status["text"]["text"] =~ "Slack cannot approve"

    assert Enum.map(actions["elements"], & &1["action_id"]) == [
             "responder_open_emisar_approval",
             "responder_open_emisar_run"
           ]

    malformed = put_in(approval_status("success", nil), ["run_url"], "http://evil.example/run")

    assert Renderer.render(%{"emisar_approval_status" => malformed}) ==
             {:error, {:invalid_slack_render, :emisar_approval_status}}
  end

  test "renders an inert schedule offer with exact recurrence and operator confirmation" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I can check this every weekday morning.",
               "records" => [
                 %{
                   "kind" => "schedule_offer",
                   "payload" => %{
                     "authority" => "read_only",
                     "catch_up" => "latest",
                     "expires_at" => nil,
                     "recurrence" => %{
                       "kind" => "weekly",
                       "time" => "09:00:00",
                       "weekday" => "monday"
                     },
                     "repository" => nil,
                     "task" => "Inspect current service health and report material changes.",
                     "timezone" => "America/New_York",
                     "title" => "Weekly service health"
                   },
                   "ref" => "record:schedule_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Weekly service health"
    assert summary["text"]["text"] =~ "every monday at 09:00:00"
    assert summary["text"]["text"] =~ "America/New_York"
    assert summary["text"]["text"] =~ "only an offer"

    assert [%{"action_id" => "responder_confirm_schedule"} = button] = actions["elements"]
    assert button["value"] == "record:schedule_offer:abc123"
    assert button["confirm"]["text"]["text"] =~ "current policy"
    refute inspect(rendered) =~ "event_matcher"
  end

  test "renders an additional Slack post as an exact requester-owned confirmation" do
    destination_ref = "slack-source:v1:T123:C789:thread:1787832888.000300"

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I prepared the requested post for confirmation.",
               "records" => [
                 %{
                   "kind" => "slack_post_offer",
                   "payload" => %{
                     "conversation_ref" => "slack:T123:C789",
                     "destination_ref" => destination_ref,
                     "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
                     "message" => "The deployment is healthy.",
                     "requested_by_actor_ref" => "slack:user:U123",
                     "thread_ref" => "1787832888.000300",
                     "transport" => "slack"
                   },
                   "ref" => "record:slack_post_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    rendered_text = inspect(rendered)
    assert rendered_text =~ destination_ref
    assert rendered_text =~ "The deployment is healthy."
    assert rendered_text =~ "No message has been posted"

    assert [button] =
             rendered["blocks"]
             |> Enum.find(&(&1["type"] == "actions"))
             |> Map.fetch!("elements")

    assert button["action_id"] == "responder_confirm_slack_post"
    assert button["value"] == "record:slack_post_offer:abc123"
    assert button["confirm"]["text"]["text"] =~ destination_ref
  end

  test "renders a complete automation before and after with one host-owned confirmation" do
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

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I can pause that schedule.",
               "records" => [
                 %{
                   "kind" => "automation_change_offer",
                   "payload" => %{
                     "action" => "pause",
                     "after" => before |> Map.put("revision", 2) |> Map.put("status", "paused"),
                     "automation_id" => before["automation_id"],
                     "automation_kind" => "time",
                     "before" => before,
                     "patch" => %{},
                     "revision" => 1
                   },
                   "ref" => "record:automation_change_offer:pause",
                   "status" => "open"
                 }
               ]
             })

    text = Enum.map_join(rendered["blocks"], "\n", &inspect/1)
    assert text =~ "Before"
    assert text =~ "After"
    assert text =~ "Daily service health"
    assert text =~ "Inspect current service health."
    assert text =~ "paused"

    assert [%{"action_id" => "responder_confirm_automation"} = button] =
             rendered["blocks"]
             |> Enum.filter(&(&1["type"] == "actions"))
             |> List.last()
             |> Map.fetch!("elements")

    assert button["value"] == "record:automation_change_offer:pause"
    assert button["style"] == "danger"
  end

  test "renders a complete maximum-sized automation update for operator review" do
    before = %{
      "automation_id" => "schedule:large-health-review",
      "catch_up" => "latest",
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "next_occurrence_at" => "2026-08-30T13:00:00.000000Z",
      "prompt" => String.duplicate("a", 12_000),
      "repository" => nil,
      "revision" => 1,
      "status" => "active",
      "title" => "Large daily health review",
      "trigger" => %{
        "recurrence" => "daily",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    }

    after_document =
      before
      |> Map.put("prompt", String.duplicate("b", 12_000))
      |> Map.put("revision", 2)

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Review this full prompt replacement.",
               "records" => [
                 %{
                   "kind" => "automation_change_offer",
                   "payload" => %{
                     "action" => "update",
                     "after" => after_document,
                     "automation_id" => before["automation_id"],
                     "automation_kind" => "time",
                     "before" => before,
                     "patch" => %{"prompt" => after_document["prompt"]},
                     "revision" => 1
                   },
                   "ref" => "record:automation_change_offer:large",
                   "status" => "open"
                 }
               ]
             })

    rendered_text =
      Enum.map_join(rendered["blocks"], "", fn
        %{"text" => %{"text" => text}} -> text
        %{"text" => text} when is_binary(text) -> text
        _block -> ""
      end)

    assert rendered_text =~ before["prompt"]
    assert rendered_text =~ after_document["prompt"]
    assert length(rendered["blocks"]) <= 50
  end

  test "renders behavior offers as explicit operator-owned confirmations" do
    records = [
      %{
        "kind" => "preference_offer",
        "payload" => %{
          "expires_in" => "90d",
          "key" => "response_detail",
          "repository" => nil,
          "scope" => "operator",
          "value" => "concise"
        },
        "ref" => "record:preference_offer:abc123",
        "status" => "open"
      },
      %{
        "kind" => "guidance_offer",
        "payload" => %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "conversation",
          "subject" => "terraform-review",
          "summary" => "Lead with availability risk.",
          "text" => "Explain availability and drift before resource counts.",
          "visibility" => "conversation"
        },
        "ref" => "record:guidance_offer:def456",
        "status" => "open"
      },
      %{
        "kind" => "standing_assignment_offer",
        "payload" => %{
          "action" => "review_terraform_plan",
          "expires_in" => "30d",
          "repository" => "responder-infra",
          "source_filter" => "app",
          "task" => "Review every exact Terraform plan posted here.",
          "trigger" => "terraform_plan"
        },
        "ref" => "record:standing_assignment_offer:ghi789",
        "status" => "open"
      },
      %{
        "kind" => "standing_assignment_offer",
        "payload" => %{
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
        },
        "ref" => "record:standing_assignment_offer:jkl012",
        "status" => "open"
      }
    ]

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "I can remember these bounds.", "records" => records})

    assert inspect(rendered) =~ "behavior has not changed"
    assert inspect(rendered) =~ "Advisory only"
    assert inspect(rendered) =~ "Read-only initiative"
    rendered_text = Enum.map_join(rendered["blocks"], "\n", &inspect/1)
    assert rendered_text =~ "Source event: `github`"
    assert rendered_text =~ "Review pull request reviews"

    assert rendered["blocks"]
           |> Enum.filter(&(&1["type"] == "actions"))
           |> Enum.flat_map(& &1["elements"])
           |> Enum.map(& &1["action_id"]) ==
             List.duplicate("responder_confirm_behavior", 4)
  end

  test "renders operational memory as an explicit scoped stale-hint confirmation" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I can remember that mapping after confirmation.",
               "records" => [
                 %{
                   "kind" => "memory_offer",
                   "payload" => %{
                     "expires_in" => "90d",
                     "kind" => "repository_binding",
                     "repository" => nil,
                     "scope" => "conversation",
                     "subject" => "primary_repository",
                     "value" => "responder",
                     "visibility" => "conversation"
                   },
                   "ref" => "record:memory_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    assert inspect(rendered) =~ "Potentially stale hint only"
    assert inspect(rendered) =~ "live evidence"

    assert [button] =
             rendered["blocks"]
             |> Enum.find(&(&1["type"] == "actions"))
             |> Map.fetch!("elements")

    assert button["action_id"] == "responder_confirm_memory"
    assert button["value"] == "record:memory_offer:abc123"
  end

  test "renders only an exact publishable review as an operator publication control" do
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

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The exact committed candidate passed review.",
               "records" => [
                 %{
                   "kind" => "publication_review",
                   "payload" => review,
                   "ref" => "publication:abc123",
                   "status" => "open"
                 }
               ]
             })

    [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Gate: `passed`"
    assert summary["text"]["text"] =~ "Candidate tree: `#{String.duplicate("7", 40)}`"
    assert [%{"action_id" => "responder_publish_draft"} = button] = actions["elements"]
    assert button["value"] == "publication:abc123"

    blocked = %{review | "gate" => "failed", "publishable" => false, "reasons" => ["gate_failed"]}

    assert {:ok, blocked_rendered} =
             Renderer.render(%{
               "message" => "The review did not pass.",
               "records" => [
                 %{
                   "kind" => "publication_review",
                   "payload" => blocked,
                   "ref" => "publication:def456",
                   "status" => "open"
                 }
               ]
             })

    refute inspect(blocked_rendered) =~ "responder_publish_draft"
    assert inspect(blocked_rendered) =~ "gate_failed"
  end

  test "a published pull request has host-owned open and delivery-check controls" do
    url = "https://github.com/acme/responder/pull/42"

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The draft is published.",
               "records" => [
                 %{
                   "kind" => "publication_result",
                   "payload" => %{
                     "branch_ref" => "refs/heads/responder/fix-42",
                     "commit_sha" => String.duplicate("a", 40),
                     "pull_request_number" => 42,
                     "pull_request_url" => url,
                     "repository" => "responder",
                     "title" => "Fix lifecycle tracking"
                   },
                   "ref" => "publication:published42",
                   "status" => "confirmed"
                 }
               ]
             })

    [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Draft pull request published"

    assert [open, check] = actions["elements"]
    assert open["action_id"] == "responder_open_publication"
    assert open["url"] == url
    assert open["value"] == "publication:published42"
    assert check["action_id"] == "responder_check_publication"
    assert check["value"] == "publication:published42"
  end

  test "renders durable questions and event waits without accepting model-authored controls" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I need one decision before I continue.",
               "records" => [
                 %{
                   "kind" => "input_request",
                   "payload" => %{
                     "choices" => ["Roll out to 1%", "Stop the rollout"],
                     "question" => "Which rollout action should I take?"
                   },
                   "ref" => "record:input_request:abc123",
                   "status" => "open"
                 },
                 %{
                   "kind" => "event_wait",
                   "payload" => %{
                     "deadline_at" => "2026-08-29T12:00:00.000000Z",
                     "event_matcher" => %{"deployment" => "responder"},
                     "kind" => "deployment_health",
                     "verification" => "Verify the new allocation is healthy."
                   },
                   "ref" => "record:event_wait:def456",
                   "status" => "open"
                 }
               ]
             })

    [_, question, choices, wait] = rendered["blocks"]
    assert question["text"]["text"] == "Which rollout action should I take?"

    assert Enum.map(choices["elements"], &{&1["action_id"], &1["value"]}) == [
             {"responder_answer_input", "record:input_request:abc123|0"},
             {"responder_answer_input", "record:input_request:abc123|1"}
           ]

    assert wait["text"]["text"] =~ "Verify the new allocation is healthy."
    assert wait["text"]["text"] =~ "2026-08-29T12:00:00.000000Z"
    refute inspect(rendered) =~ ~s("deployment" => "responder")
  end

  test "refuses malformed or unsupported presentation records" do
    assert Renderer.render(%{"message" => "Done.", "records" => "records"}) ==
             {:error, {:invalid_slack_render, :records}}

    assert Renderer.render(%{
             "message" => "Done.",
             "records" => [%{"kind" => "unknown", "payload" => %{}, "ref" => "record:1"}]
           }) == {:error, {:invalid_slack_render, :record}}
  end

  test "renders a plain host message without requiring presentation records" do
    assert {:ok, rendered} = Renderer.render(%{"message" => "A plain reply."})
    assert rendered["text"] == "A plain reply."
    assert [%{"type" => "markdown"}] = rendered["blocks"]
  end

  test "renders model prose as standard Markdown without granting Slack control syntax" do
    message = """
    # Result

    [Read the evidence](https://example.com/evidence?a=1&b=2).

    | Check | State |
    | --- | --- |
    | API | healthy |

    ```elixir
    assert current < target
    ```

    <!channel> <@U123>
    """

    assert {:ok, rendered} = Renderer.render(%{"message" => message})
    assert [%{"type" => "markdown", "text" => markdown}] = rendered["blocks"]
    assert markdown =~ "# Result"
    assert markdown =~ "[Read the evidence](https://example.com/evidence?a=1&amp;b=2)"
    assert markdown =~ "| Check | State |"
    assert markdown =~ "```elixir"
    assert markdown =~ "assert current &lt; target"
    assert markdown =~ "&lt;!channel&gt; &lt;@U123&gt;"
    refute markdown =~ "<!channel>"
    refute markdown =~ "<@U123>"
  end

  test "preserves prose above Slack's cumulative Markdown limit as inert plain text" do
    message = "# Result\n\n" <> String.duplicate("evidence ", 1_500)

    assert String.length(message) > 12_000
    assert {:ok, rendered} = Renderer.render(%{"message" => message})
    assert Enum.all?(rendered["blocks"], &(&1["type"] == "section"))

    assert Enum.map_join(rendered["blocks"], "", &get_in(&1, ["text", "text"])) == message
  end

  test "renders investigation records as escaped inert status sections" do
    records = [
      record("evidence", %{
        "claim_id" => "api.health",
        "observation" => "The <API> probe is ready.",
        "relation" => nil,
        "source_name" => "production & probe",
        "source_type" => "monitoring"
      }),
      record("coverage", %{
        "claim_ids" => ["api.health"],
        "detail" => "The public path was sampled.",
        "layer" => "application",
        "observed_at" => "2026-08-28T12:00:00.000000Z",
        "source" => "production probe",
        "status" => "healthy"
      }),
      record("finding", %{
        "status" => "unexplained",
        "what" => "Worker health is not yet known."
      }),
      record("progress", %{
        "phase" => "verifying",
        "summary" => "The API is healthy; workers remain."
      }),
      record("goal", %{
        "authority" => "read_only",
        "completion_contract" => "A current worker observation exists.",
        "id" => "check-workers",
        "kind" => "check",
        "parent_goal_id" => "verify-service",
        "prerequisite_goal_ids" => ["check-api"],
        "read_only_repositories" => ["runbooks"],
        "requested_outcome" => "Check worker health",
        "required" => true
      }),
      record("goal_state", %{
        "goal_id" => "check-workers",
        "state" => "working"
      }),
      record("alert_assessment", %{
        "impact" => "API traffic is healthy; workers are not yet verified.",
        "immediate_action" => "Inspect a current worker signal.",
        "verdict" => "unverified"
      })
    ]

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Current investigation state.", "records" => records})

    assert length(rendered["blocks"]) == 8
    refute inspect(rendered) =~ "action_id"
    assert inspect(rendered) =~ "&lt;API&gt;"
    assert inspect(rendered) =~ "production &amp; probe"
    assert inspect(rendered) =~ "Alert assessment · unverified"
    assert inspect(rendered) =~ "Parent: verify-service"
    assert inspect(rendered) =~ "Prerequisites: check-api"
    assert inspect(rendered) =~ "Read-only repositories: runbooks"
  end

  test "renders every durable setup state without inventing configuration authority" do
    session_ref = Ecto.UUID.generate()
    base = setup_document(session_ref)

    documents = [
      put_in(base, ["channel_setup", "draft", "customizing"], true),
      base
      |> put_in(["channel_setup", "step"], "repository")
      |> put_in(
        ["channel_setup", "draft", "repository_options"],
        Enum.map(1..7, &"repository-#{&1}")
      ),
      put_in(base, ["channel_setup", "step"], "alerts"),
      put_in(base, ["channel_setup", "step"], "audience"),
      base
      |> put_in(["channel_setup", "status"], "confirming")
      |> put_in(["channel_setup", "step"], "confirm")
      |> put_in(["channel_setup", "draft", "participation"], "proactive")
      |> put_in(["channel_setup", "draft", "repository_ref"], "responder")
      |> put_in(["channel_setup", "draft", "alert_policy"], "offer")
      |> put_in(["channel_setup", "draft", "invite_user_refs"], ["U123"]),
      base
      |> put_in(["channel_setup", "status"], "saved")
      |> put_in(["channel_setup", "draft", "participation"], "mentions")
      |> put_in(["channel_setup", "draft", "repository_ref"], "responder")
      |> put_in(["channel_setup", "draft", "alert_policy"], "reply"),
      put_in(base, ["channel_setup", "status"], "cancelled"),
      put_in(base, ["channel_setup", "status"], "expired")
    ]

    Enum.each(documents, fn document ->
      assert {:ok, %{"blocks" => blocks, "text" => text}} = Renderer.render(document)
      assert blocks != []
      assert is_binary(text) and text != ""
    end)

    repository = Enum.at(documents, 1)
    assert {:ok, rendered} = Renderer.render(repository)
    assert length(Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))) == 2
  end

  test "renders every task and incident lifecycle label from host-owned state" do
    task_statuses =
      ~w(waiting_for_input waiting_for_event action_required stopping reviewing ready_for_review ready_to_publish completed cancelled)

    Enum.each(task_statuses, fn status ->
      task = task_document(status)
      assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
      assert rendered["text"] =~ "Engineering task"
      refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
    end)

    readiness =
      task_document("ready_for_review")
      |> put_in(["publication"], %{
        "controls" => ["readiness"],
        "publication_ref" => nil,
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => nil,
        "review_offer_ref" => "record:publication_offer:review123",
        "status" => "offered"
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => readiness})
    assert inspect(rendered) =~ "responder_task_readiness"

    incident_statuses =
      ~w(provisioning action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)

    Enum.each(incident_statuses, fn status ->
      room = incident_document(status)
      result = Renderer.render(%{"incident_room" => room})
      assert match?({:ok, _rendered}, result), inspect({status, result})
      {:ok, rendered} = result
      assert rendered["text"] =~ "Incident 82208f8f"
      assert inspect(rendered) =~ "Latest alert assessment"
      assert inspect(rendered) =~ "Action needed"
    end)
  end

  test "rejects malformed cards, diffs, controls, publication identities, and dates" do
    assert Renderer.render(:not_a_document) == {:error, {:invalid_slack_render, :document}}

    assert Renderer.render(%{"work_diff" => %{}}) ==
             {:error, {:invalid_slack_render, :work_diff}}

    assert Renderer.render(%{"incident_room" => %{}}) ==
             {:error, {:invalid_slack_render, :incident_room}}

    assert Renderer.render(%{"task_card" => %{}}) ==
             {:error, {:invalid_slack_render, :task_card}}

    assert Renderer.render(%{"channel_setup" => %{}}) ==
             {:error, {:invalid_slack_render, :channel_setup}}

    assert Renderer.render(%{"task_card" => %{task_document("working") | "controls" => "stop"}}) ==
             {:error, {:invalid_slack_render, :task_card}}

    malformed_publication =
      task_document("working")
      |> put_in(["publication"], %{
        "controls" => ["open"],
        "publication_ref" => nil,
        "pull_request_number" => 1,
        "pull_request_url" => "http://example.test/pr/1",
        "recovery_generation" => nil,
        "review_offer_ref" => nil,
        "status" => "published"
      })

    assert Renderer.render(%{"task_card" => malformed_publication}) ==
             {:error, {:invalid_slack_render, :task_card}}

    assert Renderer.render(%{
             "incident_room" => %{
               incident_document("investigating")
               | "updated_at" => "yesterday"
             }
           }) == {:error, {:invalid_slack_render, :incident_room}}
  end

  defp record(kind, payload) do
    %{
      "kind" => kind,
      "payload" => payload,
      "ref" => "record:#{kind}:abc123",
      "status" => "open"
    }
  end

  defp approval_status(status, error) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => error,
      "request_id" => "apr-1",
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end

  defp setup_document(session_ref) do
    %{
      "channel_setup" => %{
        "draft" => %{
          "alert_policy" => nil,
          "customizing" => false,
          "default_repository" => "responder",
          "invite_user_group_refs" => [],
          "invite_user_refs" => [],
          "participation" => nil,
          "repository_options" => ["responder"],
          "repository_ref" => nil
        },
        "expires_at" => "2026-08-28T12:30:00.000000Z",
        "revision" => 1,
        "session_ref" => session_ref,
        "status" => "asking",
        "step" => "participation"
      }
    }
  end

  defp task_document(status) do
    %{
      "action_needed" => nil,
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => [],
      "episode_state" => "working",
      "publication" => nil,
      "repository" => "responder",
      "session_generation" => nil,
      "status" => status,
      "summary" => "The durable task state is current.",
      "task_ref" => "task-card:abc123",
      "title" => "Verify the product",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => nil
    }
  end

  defp incident_document(status) do
    %{
      "action_needed" => "Review the current blocker.",
      "alert" => %{"impact" => "Checkout traffic is affected.", "verdict" => "firing"},
      "controls" => [],
      "episode_state" => "working",
      "opened_at" => "2026-08-28T12:00:00.000000Z",
      "opened_by" => "slack:user:U123",
      "repository" => "responder",
      "room_ref" => "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342",
      "session_generation" => nil,
      "severity" => "high",
      "signals" => %{"firing" => 2, "total" => 3},
      "source" => %{
        "channel_ref" => "C123",
        "message_ref" => "1787832000.000100",
        "thread_ref" => "1787832000.000100"
      },
      "status" => status,
      "summary" => "The investigation state is current.",
      "title" => "Checkout errors",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z"
    }
  end
end

defmodule Responder.StateTools.RouterTest do
  use Responder.DataCase, async: true
  import Plug.Conn
  import Plug.Test

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership
  alias Responder.State.{BehaviorChangeset, Record, Records, Schedule, ScheduleChangeset}
  alias Responder.StateTools.{FixedTools, Router, Tools, ToolVisibility}
  alias Responder.Work.{Custody, FinalPreflight}

  @options Router.init(token: "trusted-state-tools-token")
  @emisar_options Router.init(
                    token: "trusted-state-tools-token",
                    emisar_rpc_url: "https://emisar.example/api/mcp/rpc"
                  )
  @wait_only_options Router.init(
                       token: "trusted-state-tools-token",
                       capabilities: [:event_waits]
                     )
  @no_owner_options Router.init(token: "trusted-state-tools-token", capabilities: [])
  @policy_digest String.duplicate("a", 64)

  test "exposes exactly the fixed state tools without model-supplied host credentials" do
    claim = claim!("mcp-task")

    options = bound_options(claim)
    list = rpc("tools/list", %{}, options)
    assert list.status == 200
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(list.resp_body)

    assert Enum.map(tools, & &1["name"]) == [
             "get_work_state",
             "cite_source",
             "request_input",
             "wait_for",
             "list_automations",
             "get_automation",
             "propose_automation",
             "request_task",
             "search_memory",
             "propose_memory",
             "update_conversation_summary",
             "record_feedback",
             "validate_final"
           ]

    refute Enum.any?(tools, fn tool ->
             properties = tool["inputSchema"]["properties"]
             Map.has_key?(properties, "state_token") or Map.has_key?(properties, "operation_id")
           end)

    response =
      rpc(
        "tools/call",
        %{
          "arguments" => %{
            "authority_limits" => ["must not deploy"],
            "instruction_ref" => "input:trusted:1",
            "prompt" => "Implement the exact requested fix and run focused tests.",
            "repository" => "responder",
            "source_refs" => [],
            "success_checks" => ["focused tests pass"],
            "title" => "Fix the responder"
          },
          "name" => "request_task"
        },
        options
      )

    assert response.status == 200

    assert %{
             "result" => %{
               "isError" => false,
               "structuredContent" => %{
                 "kind" => "task_offer",
                 "record_ref" => record_ref
               }
             }
           } = Jason.decode!(response.resp_body)

    assert record_ref =~ "record:task_offer:"

    assert [%{"kind" => "task_offer", "payload" => payload}] =
             Records.model_records(claim.episode.id)

    assert payload["repository"] == "responder"
    assert payload["prompt"] =~ "must not deploy"
    assert payload["authority_limits"] == ["must not deploy"]
    assert payload["instruction_ref"] == "input:trusted:1"
    assert payload["source_refs"] == []
    assert payload["success_checks"] == ["focused tests pass"]
  end

  test "source citations accept a short human-readable subject" do
    claim = claim!("human-readable-citation-subject")

    assert {:ok, %{"kind" => "citation", "record_ref" => record_ref}} =
             Tools.call(
               "cite_source",
               %{
                 "observation" => "The current Conversation Lab contains two matching messages.",
                 "relation" => "supports",
                 "source_ref" => "admit_input:current-message",
                 "subject" => "Exact phrase search results for Emisar MCP",
                 "supersedes" => []
               },
               bound_options(claim)
             )

    assert String.starts_with?(record_ref, "record:evidence:")

    assert [%{"kind" => "evidence", "payload" => payload}] =
             Records.model_records(claim.episode.id)

    assert payload["target"] == "Exact phrase search results for Emisar MCP"
  end

  test "request_task can offer a locally emulated incident to Slack or Conversation Lab" do
    claim = claim!("incident-task-offer")
    options = bound_options(claim)

    assert {:ok, %{"kind" => "task_offer", "record_ref" => record_ref}} =
             Tools.call(
               "request_task",
               %{
                 "authority_limits" => ["observe and contain; do not deploy"],
                 "instruction_ref" => "input:incident:1",
                 "kind" => "incident",
                 "prompt" => "Investigate the current service alert and report verified status.",
                 "repository" => nil,
                 "source_refs" => ["input:incident:1"],
                 "success_checks" => ["current impact and evidence are reported"],
                 "title" => "Investigate service health"
               },
               options
             )

    assert String.starts_with?(record_ref, "record:task_offer:")

    assert [%{"kind" => "task_offer", "payload" => payload}] =
             Records.model_records(claim.episode.id)

    assert payload["kind"] == "incident"
    assert payload["repository"] == nil
    assert payload["prompt"] =~ "observe and contain; do not deploy"
    assert payload["instruction_ref"] == "input:incident:1"
  end

  test "the fixed protocol reads work and creates each durable proposal kind" do
    claim = claim!("fixed-product-surface")
    options = bound_options(claim)

    assert {:ok, %{"automations" => [], "cursor" => nil}} =
             Tools.call(
               "list_automations",
               %{
                 "channel_ref" => nil,
                 "cursor" => nil,
                 "enabled" => nil,
                 "limit" => 50,
                 "query" => nil,
                 "relationship" => "either",
                 "trigger_type" => nil
               },
               options
             )

    assert Tools.call(
             "get_automation",
             %{"automation_id" => "schedule:missing", "run_limit" => 10},
             options
           ) == {:error, "not_found"}

    assert {:ok, %{"proposals" => [%{"kind" => "automation_offer"}]}} =
             Tools.call(
               "propose_automation",
               %{
                 "proposals" => [
                   %{
                     "action" => "create",
                     "automation_id" => nil,
                     "catch_up" => "latest",
                     "context_channel" => nil,
                     "delivery_channel" => nil,
                     "expires_at" => nil,
                     "hold" => nil,
                     "patch" => %{},
                     "prompt" => "Inspect current service health.",
                     "repository" => nil,
                     "revision" => nil,
                     "title" => "Daily service health",
                     "trigger" => %{
                       "recurrence" => "daily",
                       "time" => "13:00:00",
                       "timezone" => "Etc/UTC",
                       "type" => "time"
                     }
                   }
                 ]
               },
               options
             )

    offer = Repo.get_by!(Record, episode_id: claim.episode.id, kind: "schedule_offer")
    schedule_id = Ecto.UUID.generate()
    now = ~U[2026-08-29 12:00:00.000000Z]

    schedule =
      %{
        authority: :read_only,
        catch_up: :latest,
        confirmation_ref: "confirmation:fixed-product-surface",
        confirmed_at: now,
        confirmed_by_actor_ref: "slack:user:U1",
        destination_conversation_ref: claim.episode.destination_conversation_ref,
        destination_thread_ref: claim.episode.destination_thread_ref,
        destination_transport: claim.episode.destination_transport,
        id: schedule_id,
        next_occurrence_at: DateTime.add(now, 86_400, :second),
        offer_record_id: offer.id,
        recurrence: %{"kind" => "daily", "time" => "13:00:00"},
        ref: "schedule:#{schedule_id}",
        repository: nil,
        source_episode_id: claim.episode.id,
        status: :active,
        task: "Inspect current service health.",
        timezone: "Etc/UTC",
        title: "Daily service health"
      }
      |> ScheduleChangeset.insert()
      |> Repo.insert!()

    assert {:ok, %{"automation" => automation}} =
             Tools.call(
               "get_automation",
               %{"automation_id" => schedule.ref, "run_limit" => 10},
               options
             )

    assert automation["automation_id"] == schedule.ref
    assert automation["status"] == "active"
    assert automation["recent_runs"] == []

    assert automation["trigger"] == %{
             "recurrence" => "daily",
             "time" => "13:00:00",
             "timezone" => "Etc/UTC",
             "type" => "time"
           }

    assert {:ok, %{"automations" => [listed]}} =
             Tools.call(
               "list_automations",
               %{
                 "channel_ref" => nil,
                 "cursor" => nil,
                 "enabled" => true,
                 "limit" => 10,
                 "query" => "SERVICE HEALTH",
                 "relationship" => "either",
                 "trigger_type" => "time"
               },
               options
             )

    assert listed["automation_id"] == schedule.ref

    assert {:ok, %{"kind" => "memory_offer"}} =
             Tools.call(
               "propose_memory",
               %{
                 "expires_at" => nil,
                 "kind" => "fact",
                 "scope" => "current_channel",
                 "source_refs" => ["source:health"],
                 "subject" => "service_owner",
                 "supersedes" => [],
                 "value" => "The Payments team owns this service."
               },
               options
             )

    assert {:ok, %{"kind" => "memory_offer"}} =
             Tools.call(
               "propose_memory",
               %{
                 "expires_at" => "2099-08-29T12:00:00.000000Z",
                 "kind" => "guidance",
                 "scope" => "repository",
                 "source_refs" => ["source:runbook"],
                 "subject" => "Deployment completion reporting",
                 "supersedes" => [],
                 "value" => "Verify the allocation before reporting completion."
               },
               options
             )

    assert {:ok, %{"kind" => "feedback"}} =
             Tools.call(
               "record_feedback",
               %{
                 "category" => "usefulness",
                 "details" => "The answer needed a source link.",
                 "needs_response" => true,
                 "response_question" => "Can you include the source?",
                 "sentiment" => "suggestion",
                 "summary" => "Add a source link.",
                 "target_message_ref" => "message:previous"
               },
               options
             )

    assert {:ok, %{"cursor" => nil, "memories" => []}} =
             Tools.call(
               "search_memory",
               %{
                 "cursor" => nil,
                 "kinds" => ["guidance", "fact"],
                 "limit" => 20,
                 "query" => "not-yet-confirmed",
                 "scope" => "current_channel"
               },
               options
             )

    assert {:ok, state} =
             Tools.call(
               "get_work_state",
               %{
                 "history" => "current",
                 "limit" => 100,
                 "since" => nil,
                 "types" => ["proposal"]
               },
               options
             )

    assert state["cursor"] =~ "episode:#{claim.episode.id}:v"
    assert state["episode"]["owner"] == "turn"
    assert state["episode"]["state"] == "working"
    assert Enum.any?(state["records"], &(&1["kind"] == "schedule_offer"))
    assert Enum.any?(state["records"], &(&1["kind"] == "memory_offer"))
    assert Enum.any?(state["records"], &(&1["kind"] == "progress"))
  end

  test "final preflight reports semantic failures and defers output artifact existence to Coop" do
    claim = claim!("fixed-final-rejections")
    options = bound_options(claim)

    silent_candidate = %{
      "decision_reason" => "There is nothing to send.",
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    }

    assert {:ok, %{"accepted" => false, "violations" => violations}} =
             Tools.call("validate_final", %{"candidate" => silent_candidate}, options)

    assert Enum.any?(violations, &String.contains?(&1, "Set delivery to reply"))

    missing_artifact_candidate = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The requested artifact is attached.",
      "outcome" => %{
        "artifact_refs" => ["artifact:missing"],
        "record_refs" => [],
        "state" => "complete"
      }
    }

    assert {:ok, %{"accepted" => true, "candidate" => ^missing_artifact_candidate}} =
             Tools.call(
               "validate_final",
               %{"candidate" => missing_artifact_candidate},
               options
             )

    # Coop assigns output artifact identities only when the provider turn ends.
    # Executor validates the terminal metadata and exact bytes before accepting
    # or delivering the candidate; preflight must not require those future bytes.
    assert {:ok, _turn} =
             Custody.verify_final_preflight(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               FinalPreflight.candidate_sha256(missing_artifact_candidate),
               ["artifact:missing"]
             )
  end

  test "automation proposals normalize every supported time trigger without executing it" do
    claim = claim!("fixed-automation-triggers")
    options = bound_options(claim)

    triggers = [
      %{
        "at" => "2099-08-29T12:00:00.000000Z",
        "recurrence" => "once",
        "type" => "time"
      },
      %{"recurrence" => "weekly", "time" => "13:00:00", "type" => "time", "weekday" => "friday"},
      %{"day" => 15, "recurrence" => "monthly", "time" => "13:00:00", "type" => "time"},
      %{"every_seconds" => 900, "recurrence" => "interval", "type" => "time"}
    ]

    proposals =
      triggers
      |> Enum.with_index(1)
      |> Enum.map(fn {trigger, index} ->
        %{
          "action" => "create",
          "catch_up" => "skip",
          "patch" => %{},
          "prompt" => "Verify occurrence #{index}.",
          "repository" => nil,
          "title" => "Verification #{index}",
          "trigger" => trigger
        }
      end)

    assert {:ok, %{"proposals" => records}} =
             Tools.call("propose_automation", %{"proposals" => proposals}, options)

    assert length(records) == 4

    recurrences =
      claim.episode.id
      |> Records.model_records()
      |> Enum.filter(&(&1["kind"] == "schedule_offer"))
      |> Enum.map(&get_in(&1, ["payload", "recurrence"]))

    assert Enum.map(recurrences, & &1["kind"]) ==
             ~w(once weekly monthly interval)
  end

  test "weekly automation accepts the minute precision operators naturally request" do
    claim = claim!("weekly-automation-minute-precision")
    options = bound_options(claim)

    assert {:ok, %{"proposals" => [%{"kind" => "automation_offer", "record_ref" => ref}]}} =
             Tools.call(
               "propose_automation",
               %{
                 "proposals" => [
                   %{
                     "action" => "create",
                     "automation_id" => nil,
                     "catch_up" => "skip",
                     "context_channel" => claim.episode.destination_conversation_ref,
                     "delivery_channel" => claim.episode.destination_conversation_ref,
                     "expires_at" => nil,
                     "hold" => nil,
                     "patch" => %{},
                     "prompt" => "Prepare an evidence-backed production health review.",
                     "repository" => nil,
                     "revision" => nil,
                     "title" => "Weekly production health review",
                     "trigger" => %{
                       "recurrence" => "weekly",
                       "time" => "09:00",
                       "timezone" => "UTC",
                       "type" => "time",
                       "weekday" => "monday"
                     }
                   }
                 ]
               },
               options
             )

    assert Repo.get_by!(Record, ref: ref).payload["recurrence"] == %{
             "kind" => "weekly",
             "time" => "09:00:00",
             "weekday" => "monday"
           }
  end

  test "an invalid automation time is reported as an argument error, not an outage" do
    claim = claim!("invalid-automation-time")

    assert Tools.call(
             "propose_automation",
             %{
               "proposals" => [
                 %{
                   "action" => "create",
                   "catch_up" => "skip",
                   "patch" => %{},
                   "prompt" => "Prepare the review.",
                   "repository" => nil,
                   "title" => "Invalid review time",
                   "trigger" => %{
                     "recurrence" => "weekly",
                     "time" => "25:99",
                     "type" => "time",
                     "weekday" => "monday"
                   }
                 }
               ]
             },
             bound_options(claim)
           ) == {:error, "invalid_arguments"}
  end

  test "automation proposal sets cannot exceed the destination-safe atomic bound" do
    claim = claim!("fixed-automation-proposal-bound")
    options = bound_options(claim)

    automation =
      Tools.list(options)
      |> Enum.find(&(&1["name"] == "propose_automation"))

    assert get_in(automation, ["inputSchema", "properties", "proposals", "maxItems"]) == 4

    proposals =
      for index <- 1..5 do
        %{
          "action" => "create",
          "catch_up" => "skip",
          "patch" => %{},
          "prompt" => "Verify bounded occurrence #{index}.",
          "repository" => nil,
          "title" => "Bounded verification #{index}",
          "trigger" => %{
            "every_seconds" => 900,
            "recurrence" => "interval",
            "type" => "time"
          }
        }
      end

    assert Tools.call("propose_automation", %{"proposals" => proposals}, options) ==
             {:error, "invalid_arguments"}

    assert Records.model_records(claim.episode.id) == []
  end

  test "automation mutations are inert, revision-fenced, scoped, and atomic as one proposal set" do
    claim = claim!("automation-mutation")
    options = bound_options(claim)

    assert {:ok, offer} =
             Records.create(
               Records.token(claim.turn),
               "existing-schedule",
               "schedule_offer",
               %{
                 "authority" => "read_only",
                 "catch_up" => "latest",
                 "expires_at" => nil,
                 "recurrence" => %{"kind" => "daily", "time" => "13:00:00"},
                 "repository" => nil,
                 "task" => "Inspect current service health.",
                 "timezone" => "Etc/UTC",
                 "title" => "Daily service health"
               }
             )

    schedule_id = Ecto.UUID.generate()

    schedule =
      %{
        authority: :read_only,
        catch_up: :latest,
        confirmation_ref: "confirmation:existing-schedule",
        confirmed_at: ~U[2026-08-29 12:00:00.000000Z],
        confirmed_by_actor_ref: "slack:user:U1",
        destination_conversation_ref: claim.episode.destination_conversation_ref,
        destination_thread_ref: claim.episode.destination_thread_ref,
        destination_transport: claim.episode.destination_transport,
        id: schedule_id,
        next_occurrence_at: ~U[2026-08-30 13:00:00.000000Z],
        offer_record_id: offer.id,
        recurrence: %{"kind" => "daily", "time" => "13:00:00"},
        ref: "schedule:#{schedule_id}",
        repository: nil,
        source_episode_id: claim.episode.id,
        status: :active,
        task: "Inspect current service health.",
        timezone: "Etc/UTC",
        title: "Daily service health"
      }
      |> ScheduleChangeset.insert()
      |> Repo.insert!()

    assert {:ok, %{"proposals" => [%{"record_ref" => change_ref}]}} =
             Tools.call(
               "propose_automation",
               %{
                 "proposals" => [
                   %{
                     "action" => "pause",
                     "automation_id" => schedule.ref,
                     "patch" => %{},
                     "revision" => 1
                   }
                 ]
               },
               options
             )

    assert %Record{kind: "automation_change_offer", payload: change} =
             Repo.get_by!(Record, ref: change_ref)

    assert change["before"]["status"] == "active"
    assert change["after"]["status"] == "paused"
    assert change["after"]["revision"] == 2
    assert Repo.get!(Schedule, schedule.id).status == :active

    assert Tools.call(
             "propose_automation",
             %{
               "proposals" => [
                 %{
                   "action" => "pause",
                   "automation_id" => schedule.ref,
                   "patch" => %{},
                   "revision" => 2
                 }
               ]
             },
             options
           ) == {:error, "operation_conflict"}

    atomic_claim = claim!("automation-atomic")
    record_count = Repo.aggregate(Record, :count, :id)

    assert Tools.call(
             "propose_automation",
             %{
               "proposals" => [
                 %{
                   "action" => "update",
                   "automation_id" => schedule.ref,
                   "patch" => %{"title" => "Changed only if every proposal is valid"},
                   "revision" => 1
                 },
                 %{
                   "action" => "delete",
                   "automation_id" => "schedule:missing",
                   "patch" => %{},
                   "revision" => 1
                 }
               ]
             },
             bound_options(atomic_claim)
           ) == {:error, "not_found"}

    assert Repo.aggregate(Record, :count, :id) == record_count
  end

  test "source-event automation creation preserves the exact inert assignment" do
    claim = claim!("fixed-source-event-automation")
    options = bound_options(claim)

    assert {:ok, %{"proposals" => [%{"kind" => "automation_offer", "record_ref" => ref}]}} =
             Tools.call(
               "propose_automation",
               %{
                 "proposals" => [
                   %{
                     "action" => "create",
                     "automation_id" => nil,
                     "catch_up" => "skip",
                     "context_channel" => nil,
                     "delivery_channel" => nil,
                     "expires_at" => "2027-08-29T12:00:00.000000Z",
                     "hold" => nil,
                     "patch" => %{},
                     "prompt" => "Review the exact pull request review and report material risk.",
                     "repository" => "responder",
                     "revision" => nil,
                     "title" => "Review every submitted pull request review",
                     "trigger" => %{
                       "filter" => %{
                         "action" => "submitted",
                         "review" => %{"state" => "changes_requested"}
                       },
                       "source_kind" => "github",
                       "type" => "source_event"
                     }
                   }
                 ]
               },
               options
             )

    assert %Record{kind: "standing_assignment_offer", payload: payload} =
             Repo.get_by!(Record, ref: ref)

    assert payload == %{
             "catch_up" => "skip",
             "context_channel" => claim.episode.destination_conversation_ref,
             "delivery_channel" => claim.episode.destination_conversation_ref,
             "expires_at" => "2027-08-29T12:00:00.000000Z",
             "filter" => %{
               "action" => "submitted",
               "review" => %{"state" => "changes_requested"}
             },
             "hold" => nil,
             "repository" => "responder",
             "source_kind" => "github",
             "task" => "Review the exact pull request review and report material risk.",
             "title" => "Review every submitted pull request review"
           }

    behavior_id = Ecto.UUID.generate()

    behavior =
      %{
        confirmation_ref: "confirmation:fixed-source-event-automation",
        confirmed_at: ~U[2026-08-29 12:00:00.000000Z],
        confirmed_by_actor_ref: "slack:user:U1",
        expires_at: nil,
        id: behavior_id,
        identity_key: "source-event:review-pull-request-reviews",
        kind: :standing_assignment,
        offer_record_id: Repo.get_by!(Record, ref: ref).id,
        payload: payload,
        ref: "behavior:#{behavior_id}",
        scope_kind: :conversation,
        scope_ref: claim.episode.destination_conversation_ref,
        source_conversation_ref: claim.episode.destination_conversation_ref,
        source_message_ref: "1787832001.000200",
        source_thread_ref: claim.episode.destination_thread_ref,
        source_transport: claim.episode.destination_transport,
        status: :active,
        workspace_ref: claim.episode.destination_conversation_ref
      }
      |> BehaviorChangeset.insert()
      |> Repo.insert!()

    assert {:ok, %{"automations" => [listed], "cursor" => nil}} =
             Tools.call(
               "list_automations",
               %{
                 "channel_ref" => nil,
                 "cursor" => nil,
                 "enabled" => true,
                 "limit" => 50,
                 "query" => "submitted pull request",
                 "relationship" => "either",
                 "trigger_type" => "source_event"
               },
               options
             )

    assert listed["automation_id"] == behavior.ref
    assert listed["status"] == "active"

    assert listed["trigger"] == %{
             "filter" => payload["filter"],
             "source_kind" => "github",
             "type" => "source_event"
           }

    assert {:ok, %{"automation" => exact}} =
             Tools.call(
               "get_automation",
               %{"automation_id" => behavior.ref, "run_limit" => 10},
               options
             )

    assert Map.drop(exact, ["recent_runs"]) == listed
    assert exact["recent_runs"] == []
  end

  test "automation listing cannot silently substitute the bound conversation" do
    claim = claim!("automation-list-scope")

    assert Tools.call(
             "list_automations",
             %{
               "channel_ref" => "slack:T123:C999",
               "cursor" => nil,
               "enabled" => nil,
               "limit" => 50,
               "query" => nil,
               "relationship" => "either",
               "trigger_type" => nil
             },
             bound_options(claim)
           ) == {:error, "unauthorized"}
  end

  test "memory proposals map every durable scope without widening repository authority" do
    joined_channel!("T123", "C456", false)

    claim =
      claim!("fixed-memory-scopes", %{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        }
      })

    options = bound_options(claim)

    proposals = [
      {"guidance", "mine", "operator-guidance"},
      {"guidance", "current_channel", "conversation-guidance"},
      {"guidance", "workspace", "workspace-guidance"},
      {"fact", "repository", "repository-fact"},
      {"fact", "workspace", "workspace-fact"}
    ]

    for {kind, scope, subject} <- proposals do
      assert {:ok, %{"record_ref" => record_ref}} =
               Tools.call(
                 "propose_memory",
                 %{
                   "expires_at" => "2026-09-03T12:00:00.000000Z",
                   "kind" => kind,
                   "scope" => scope,
                   "source_refs" => ["source:#{subject}"],
                   "subject" => subject,
                   "supersedes" => [],
                   "value" => "Bounded durable value for #{subject}."
                 },
                 options
               )

      assert String.starts_with?(record_ref, "record:")
    end

    records = Records.model_records(claim.episode.id)
    assert Enum.count(records, &(&1["kind"] == "guidance_offer")) == 3
    assert Enum.count(records, &(&1["kind"] == "memory_offer")) == 2

    assert Enum.any?(records, fn record ->
             record["payload"]["scope"] == "operator" and
               record["payload"]["visibility"] == "private"
           end)

    assert Enum.any?(records, fn record ->
             record["payload"]["scope"] == "repository" and
               record["payload"]["repository"] == "responder"
           end)
  end

  test "private, Slack Connect, and unknown Slack sources cannot propose cross-channel memory" do
    joined_channel!("T123", "G456", true)

    private =
      claim!("private-memory-scope", %{
        destination: %{
          conversation_ref: "slack:T123:G456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        }
      })

    for {kind, scope, subject} <- [
          {"guidance", "workspace", "private-guidance"},
          {"fact", "repository", "private-fact"}
        ] do
      assert {:ok, %{"record_ref" => _record_ref}} =
               Tools.call(
                 "propose_memory",
                 %{
                   "expires_at" => "2026-09-10T12:00:00.000000Z",
                   "kind" => kind,
                   "scope" => scope,
                   "source_refs" => ["source:#{subject}"],
                   "subject" => subject,
                   "supersedes" => [],
                   "value" => "Private channel content."
                 },
                 bound_options(private)
               )
    end

    assert Enum.all?(Records.model_records(private.episode.id), fn record ->
             record["payload"]["scope"] == "conversation" and
               record["payload"]["visibility"] == "conversation" and
               is_nil(record["payload"]["repository"])
           end)

    joined_channel!("T123", "C789", false, true)

    external =
      claim!("external-memory-scope", %{
        destination: %{
          conversation_ref: "slack:T123:C789",
          thread_ref: "1787832000.000101",
          transport: "slack"
        }
      })

    assert {:ok, %{"record_ref" => _record_ref}} =
             Tools.call(
               "propose_memory",
               %{
                 "expires_at" => "2026-09-10T12:00:00.000000Z",
                 "kind" => "guidance",
                 "scope" => "workspace",
                 "source_refs" => ["source:external-source"],
                 "subject" => "external-source",
                 "supersedes" => [],
                 "value" => "Slack Connect content."
               },
               bound_options(external)
             )

    assert [external_record] = Records.model_records(external.episode.id)
    assert external_record["payload"]["scope"] == "conversation"
    assert external_record["payload"]["visibility"] == "conversation"
    assert is_nil(external_record["payload"]["repository"])

    unknown =
      claim!("unknown-memory-scope", %{
        destination: %{
          conversation_ref: "slack:T123:C999",
          thread_ref: nil,
          transport: "slack"
        }
      })

    assert {:ok, %{"record_ref" => _record_ref}} =
             Tools.call(
               "propose_memory",
               %{
                 "expires_at" => "2026-09-10T12:00:00.000000Z",
                 "kind" => "fact",
                 "scope" => "workspace",
                 "source_refs" => ["source:unknown-source"],
                 "subject" => "unknown-source",
                 "supersedes" => [],
                 "value" => "Unknown source content."
               },
               bound_options(unknown)
             )

    assert [record] = Records.model_records(unknown.episode.id)
    assert record["payload"]["scope"] == "conversation"
    assert record["payload"]["visibility"] == "conversation"
  end

  test "implements the stateless MCP handshake and refuses unauthenticated calls" do
    initialize = rpc("initialize", %{"protocolVersion" => "2025-11-25"})

    assert %{
             "result" => %{
               "capabilities" => %{"tools" => %{"listChanged" => false}},
               "protocolVersion" => "2025-11-25",
               "serverInfo" => %{"name" => "responder-state", "version" => "1"}
             }
           } = Jason.decode!(initialize.resp_body)

    unauthorized =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", %{})))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert unauthorized.status == 401
    assert Jason.decode!(unauthorized.resp_body) == %{"error" => "unauthorized"}
  end

  test "keeps all state tools visible while disabled owners reject calls server-side" do
    list = rpc("tools/list", %{}, @wait_only_options)

    names =
      list.resp_body |> Jason.decode!() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    assert "wait_for" in names
    refute "offer_publication" in names
    refute "offer_schedule" in names
    assert length(names) == 13

    automation =
      list.resp_body
      |> Jason.decode!()
      |> get_in(["result", "tools"])
      |> Enum.find(&(&1["name"] == "propose_automation"))

    assert get_in(automation, [
             "inputSchema",
             "properties",
             "proposals",
             "items",
             "oneOf",
             Access.at(0),
             "properties",
             "trigger",
             "properties",
             "type",
             "enum"
           ]) == ["source_event"]
  end

  test "GitHub sessions expose offers backed by authenticated textual confirmations" do
    claim =
      claim!("github-capability-surface", %{
        actor_ref: "github-user:7",
        destination: %{
          conversation_ref: "github:main:repository:99",
          thread_ref: "github:main:pull:42",
          transport: "github"
        },
        native_input_id: "github-item:capability-surface"
      })

    names = Tools.list(bound_options(claim)) |> Enum.map(& &1["name"])

    assert "propose_automation" in names
    assert "propose_memory" in names
    assert "request_task" in names

    assert "request_input" in names
    assert "wait_for" in names
    assert "list_automations" in names
    assert "get_automation" in names
    assert "record_feedback" in names
    assert "validate_final" in names

    assert {:ok, %{"kind" => "task_offer", "record_ref" => "record:task_offer:" <> _}} =
             Tools.call(
               "request_task",
               %{
                 "authority_limits" => ["do not publish or merge"],
                 "instruction_ref" => "input:github-review:1",
                 "prompt" => "Apply the requested review changes.",
                 "repository" => "responder",
                 "source_refs" => [],
                 "success_checks" => ["focused tests pass"],
                 "title" => "Apply pull request review"
               },
               bound_options(claim)
             )
  end

  test "Conversation Lab sessions expose the same confirmable state offers as Slack" do
    slack_claim = claim!("slack-capability-surface")

    lab_claim =
      claim!("lab-capability-surface", %{
        actor_ref: "control_plane:user:local-operator",
        destination: %{
          conversation_ref: "control-plane:lab:9a51fa43-977f-4b27-93f6-0c2ad3652ddc",
          thread_ref: "control-plane:lab:9a51fa43-977f-4b27-93f6-0c2ad3652ddc",
          transport: "control_plane"
        },
        native_input_id: "control-plane-message:capability-surface"
      })

    slack_tools = Tools.list(bound_options(slack_claim))
    lab_tools = Tools.list(bound_options(lab_claim))

    assert lab_tools == slack_tools

    names = Enum.map(lab_tools, & &1["name"])

    assert "propose_automation" in names
    assert "propose_memory" in names
    assert "request_task" in names
    assert "request_input" in names
    assert "wait_for" in names
  end

  test "omits unowned wait tools and rejects their direct calls" do
    list = rpc("tools/list", %{}, @no_owner_options)

    names =
      list.resp_body |> Jason.decode!() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    refute "wait_for" in names
    assert "propose_automation" in names

    response =
      rpc(
        "tools/call",
        %{
          "arguments" => %{
            "deadline" => "2099-08-29T12:00:00.000000Z",
            "on_timeout" => "Report timeout.",
            "trigger" => %{"at" => "2099-08-29T12:00:00.000000Z", "type" => "at"},
            "verification" => "Verify completion."
          },
          "name" => "wait_for"
        },
        @no_owner_options
      )

    assert get_in(Jason.decode!(response.resp_body), ["result", "structuredContent", "error"]) ==
             "unknown_tool"
  end

  test "an evaluation cassette can extend the real state server without shadowing host tools" do
    source_tool = %{
      "description" => "Read a time-pinned fabricated monitoring result.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"],
        "type" => "object"
      },
      "name" => "monitoring.query"
    }

    options =
      Router.init(
        token: "trusted-state-tools-token",
        additional_tools: [source_tool],
        additional_call: fn "monitoring.query", %{"query" => "firing"} ->
          {:ok, %{"alerts" => []}}
        end
      )

    list = rpc("tools/list", %{}, options)
    tools = list.resp_body |> Jason.decode!() |> get_in(["result", "tools"])
    assert Enum.any?(tools, &(&1["name"] == "request_input"))
    assert Enum.any?(tools, &(&1["name"] == "monitoring.query"))

    response =
      rpc(
        "tools/call",
        %{"arguments" => %{"query" => "firing"}, "name" => "monitoring.query"},
        options
      )

    assert get_in(Jason.decode!(response.resp_body), ["result", "structuredContent"]) == %{
             "alerts" => []
           }

    assert_raise ArgumentError, ~r/collid/, fn ->
      Router.init(
        token: "trusted-state-tools-token",
        additional_tools: [%{source_tool | "name" => "request_input"}],
        additional_call: fn _, _ -> {:error, %{"code" => "unused"}} end
      )
    end

    bound = %{episode: :episode, session: :session, state_token: "state", turn: :turn}

    bound_options =
      Router.init(
        token: "trusted-state-tools-token",
        binding: bound,
        additional_tools: [source_tool],
        additional_call: fn "monitoring.query", %{"query" => "firing"}, received ->
          {:ok, %{"binding_received" => received == bound}}
        end
      )

    bound_response =
      rpc(
        "tools/call",
        %{"arguments" => %{"query" => "firing"}, "name" => "monitoring.query"},
        bound_options
      )

    assert get_in(Jason.decode!(bound_response.resp_body), [
             "result",
             "structuredContent",
             "binding_received"
           ]) == true
  end

  test "a Lab turn sees generic and Slack-compatible local tools but not GitHub authority" do
    refute ToolVisibility.visible?(nil, "control_plane")

    conversation_ref = "control-plane:lab:#{Ecto.UUID.generate()}"

    claim =
      claim!("lab-tool-visibility", %{
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: conversation_ref,
          transport: "control_plane"
        }
      })

    schema = %{
      "description" => "Test tool.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{},
        "type" => "object"
      }
    }

    options =
      Router.init(
        token: "trusted-state-tools-token",
        binding: %{
          episode: claim.episode,
          session: claim.session,
          state_token: Records.token(claim.turn),
          turn: claim.turn
        },
        additional_tools: [
          Map.put(schema, "name", "list_runners"),
          Map.put(schema, "name", "list_slack_channels"),
          Map.put(schema, "name", "set_github_reaction")
        ],
        additional_call: fn name, %{}, _binding -> {:ok, %{"called" => name}} end
      )

    names =
      rpc("tools/list", %{}, options).resp_body
      |> Jason.decode!()
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "list_runners" in names
    assert "list_slack_channels" in names
    refute "set_github_reaction" in names

    visible =
      rpc(
        "tools/call",
        %{"arguments" => %{}, "name" => "list_slack_channels"},
        options
      )

    assert get_in(Jason.decode!(visible.resp_body), ["result", "structuredContent", "called"]) ==
             "list_slack_channels"
  end

  test "tool validation errors stay inside the MCP result channel" do
    response =
      rpc("tools/call", %{
        "arguments" => %{"repository" => "missing-fields"},
        "name" => "request_task"
      })

    assert %{
             "result" => %{
               "isError" => true,
               "structuredContent" => %{"error" => error}
             }
           } = Jason.decode!(response.resp_body)

    assert error == "unauthorized"
  end

  test "state tools fail closed on malformed, unauthorized, conflicting, and invalid records" do
    claim = claim!("tool-errors")
    options = bound_options(claim)

    assert Tools.call("request_input", :invalid, options) == {:error, "unknown_tool"}
    assert Tools.call("wait_for", %{}, options) == {:error, "invalid_arguments"}
    assert Tools.call("request_input", %{}, []) == {:error, "unauthorized"}

    duplicate_choices = %{
      "context" => nil,
      "questions" => [%{"choices" => ["Same", "Same"], "text" => "Choose one"}]
    }

    assert Tools.call("request_input", duplicate_choices, options) ==
             {:error, "invalid_arguments"}
  end

  test "creates input and event waits through the same active-turn capability" do
    claim = claim!("mcp-waits")
    options = bound_options(claim)

    question =
      rpc(
        "tools/call",
        %{
          "arguments" => %{
            "context" => nil,
            "questions" => [
              %{
                "choices" => ["One percent", "Stop"],
                "text" => "Which rollout action should I take?"
              }
            ]
          },
          "name" => "request_input"
        },
        options
      )

    assert get_in(Jason.decode!(question.resp_body), ["result", "structuredContent", "kind"]) ==
             "input_request"

    wait =
      rpc(
        "tools/call",
        %{
          "arguments" => %{
            "deadline" => "2099-08-29T12:00:00.000000Z",
            "on_timeout" => "Report that deployment health could not be verified.",
            "trigger" => %{
              "match" => %{"deployment" => "responder"},
              "source_kind" => "deployment",
              "type" => "source_event"
            },
            "verification" => "Verify the allocation is healthy."
          },
          "name" => "wait_for"
        },
        options
      )

    assert get_in(Jason.decode!(wait.resp_body), ["result", "structuredContent", "kind"]) ==
             "event_wait"

    unknown = rpc("tools/call", %{"arguments" => %{}, "name" => "invented_tool"})

    assert get_in(Jason.decode!(unknown.resp_body), ["result", "structuredContent", "error"]) ==
             "unknown_tool"
  end

  test "an elapsed event wait is rejected before it can strand final validation" do
    claim = claim!("mcp-elapsed-wait")
    options = bound_options(claim)

    assert Tools.call(
             "wait_for",
             %{
               "deadline" => "2000-01-01T00:00:00.000000Z",
               "on_timeout" => "Report that verification could not complete.",
               "trigger" => %{
                 "match" => %{"deployment" => "responder"},
                 "source_kind" => "deployment",
                 "type" => "source_event"
               },
               "verification" => "Verify the allocation is healthy."
             },
             options
           ) == {:error, "deadline_elapsed"}

    assert Records.model_records(claim.episode.id) == []
  end

  test "host-derived slots reconcile exact retries and reject a conflicting model retry" do
    claim = claim!("host-derived-slots")
    options = bound_options(claim)

    call = fn text ->
      rpc(
        "tools/call",
        %{
          "arguments" => %{
            "context" => nil,
            "questions" => [%{"choices" => [], "text" => text}]
          },
          "name" => "request_input"
        },
        options
      )
      |> then(&Jason.decode!(&1.resp_body))
    end

    first = call.("Which repository owns this service?")
    retry = call.("Which repository owns this service?")
    conflict = call.("Which account owns this service?")

    assert get_in(first, ["result", "structuredContent", "record_ref"]) ==
             get_in(retry, ["result", "structuredContent", "record_ref"])

    assert get_in(conflict, ["result", "structuredContent", "error"]) ==
             "operation_conflict"
  end

  test "validate_final preflights the exact candidate without persisting model identifiers" do
    claim = claim!("validate-final")
    options = bound_options(claim)

    candidate = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The requested check is complete.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    }

    response =
      rpc(
        "tools/call",
        %{"arguments" => %{"candidate" => candidate}, "name" => "validate_final"},
        options
      )
      |> then(&Jason.decode!(&1.resp_body))

    assert get_in(response, ["result", "structuredContent", "accepted"]) == true
    assert get_in(response, ["result", "structuredContent", "candidate"]) == candidate

    digest = get_in(response, ["result", "structuredContent", "candidate_sha256"])
    assert digest =~ ~r/^[0-9a-f]{64}$/

    persisted = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted.final_preflight_candidate_sha256 == digest
    assert persisted.final_preflight_ledger_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert persisted.final_preflight_semantic_version == claim.episode.semantic_version

    assert {:ok, _turn} =
             Custody.verify_final_preflight(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               digest,
               []
             )

    cite =
      rpc(
        "tools/call",
        %{
          "arguments" => %{
            "observation" => "A newer source observation changes the final ledger.",
            "relation" => "supports",
            "source_ref" => "source:newer-observation",
            "subject" => "requested-check",
            "supersedes" => []
          },
          "name" => "cite_source"
        },
        options
      )

    assert get_in(Jason.decode!(cite.resp_body), ["result", "isError"]) == false

    assert {:error, :work_final_preflight_required} =
             Custody.verify_final_preflight(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               digest,
               []
             )
  end

  test "a configured Emisar receipt is advertised and registered through the active turn" do
    unconfigured = rpc("tools/list", %{})

    refute unconfigured.resp_body
           |> Jason.decode!()
           |> get_in(["result", "tools"])
           |> Enum.any?(&(&1["name"] == "record_emisar_approval"))

    configured = rpc("tools/list", %{}, @emisar_options)

    assert configured.resp_body
           |> Jason.decode!()
           |> get_in(["result", "tools"])
           |> Enum.any?(&(&1["name"] == "record_emisar_approval"))

    assert Tools.call("record_emisar_approval", %{}, []) == {:error, "not_configured"}

    assert Tools.call("record_emisar_approval", %{}, %{}) == {:error, "not_configured"}
    assert Tools.call("record_emisar_approval", %{}, :invalid) == {:error, "not_configured"}

    assert Tools.call(
             "record_emisar_approval",
             :invalid,
             emisar_rpc_url: "https://emisar.example/api/mcp/rpc"
           ) == {:error, "invalid_arguments"}

    assert Tools.call(
             "record_emisar_approval",
             %{},
             emisar_rpc_url: "https://emisar.example/api/mcp/rpc"
           ) == {:error, "invalid_arguments"}

    claim = claim!("mcp-emisar-approval")

    approval = %{
      "action_id" => "deploy",
      "approval_url" => "https://emisar.example/app/runs/run-1/approvals/request-1",
      "expires_at" => DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601(),
      "operation_id" => "operation-1",
      "pack_ref" => "pack:deploy",
      "request_id" => "request-1",
      "run_id" => "run-1",
      "runner_ref" => "runner-1",
      "status" => "pending_approval"
    }

    assert Tools.call(
             "record_emisar_approval",
             approval,
             emisar_rpc_url: "https://emisar.example/api/mcp/rpc"
           ) == {:error, "unauthorized"}

    assert Tools.call(
             "record_emisar_approval",
             approval,
             %{
               "binding" => %{"state_token" => "state:missing-turn"},
               emisar_rpc_url: "https://emisar.example/api/mcp/rpc"
             }
           ) == {:error, "unauthorized"}

    options =
      claim
      |> bound_options()
      |> Map.put(:emisar_rpc_url, "https://emisar.example/api/mcp/rpc")

    response =
      rpc(
        "tools/call",
        %{"arguments" => approval, "name" => "record_emisar_approval"},
        options
      )

    assert get_in(Jason.decode!(response.resp_body), ["result", "isError"]) == false

    assert %Record{kind: "emisar_approval", status: :open} =
             Repo.get_by!(Record, turn_id: claim.turn.id)

    assert Tools.call(
             "record_emisar_approval",
             %{approval | "status" => "approved"},
             emisar_rpc_url: "https://emisar.example/api/mcp/rpc"
           ) == {:error, "invalid_arguments"}

    assert Enum.map(Tools.list(), & &1["name"]) == FixedTools.names()
    assert FixedTools.known?("validate_final")
    refute FixedTools.known?("record_emisar_approval")
  end

  test "obsolete unadvertised investigation tools remain unavailable" do
    claim = claim!("mcp-investigation")
    options = bound_options(claim)

    for tool <-
          ~w(record_evidence record_coverage record_finding report_progress plan_goal update_goal record_alert_assessment) do
      assert Tools.call(tool, %{}, options) == {:error, "unknown_tool"}
    end
  end

  test "handles the remaining MCP and HTTP protocol boundaries" do
    initialize = rpc("initialize", %{})

    assert get_in(Jason.decode!(initialize.resp_body), ["result", "protocolVersion"]) ==
             "2025-11-25"

    assert rpc("ping", %{}).status == 200

    notification =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      )
      |> put_req_header("authorization", "Bearer trusted-state-tools-token")
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert notification.status == 202

    unknown = rpc("missing/method", %{})
    assert get_in(Jason.decode!(unknown.resp_body), ["error", "code"]) == -32_601

    invalid =
      conn(:post, "/mcp", "not-json")
      |> put_req_header("authorization", "Bearer trusted-state-tools-token")
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert get_in(Jason.decode!(invalid.resp_body), ["error", "code"]) == -32_600

    unsupported =
      conn(:post, "/mcp", "{}")
      |> put_req_header("authorization", "Bearer trusted-state-tools-token")
      |> put_req_header("content-type", "text/plain")
      |> Router.call(@options)

    assert unsupported.status == 415

    not_found = conn(:get, "/elsewhere") |> Router.call(@options)
    assert not_found.status == 404
  end

  defp rpc(method, params, options \\ @options) do
    conn(:post, "/mcp", Jason.encode!(request(method, params)))
    |> put_req_header("authorization", "Bearer trusted-state-tools-token")
    |> put_req_header("content-type", "application/json")
    |> Router.call(options)
  end

  defp request(method, params) do
    %{"id" => 1, "jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp bound_options(claim) do
    Router.init(
      token: "trusted-state-tools-token",
      binding: %{
        episode: claim.episode,
        session: claim.session,
        state_token: Records.token(claim.turn),
        turn: claim.turn
      }
    )
  end

  defp claim!(suffix, overrides \\ %{}) do
    command =
      EpisodeFixtures.admit_input(
        Map.merge(
          %{
            episode_id: Ecto.UUID.generate(),
            episode_key: "state-tools:#{suffix}",
            native_input_id: "source:#{suffix}",
            payload: %{"text" => "Please help."},
            turn_ref: "turn:#{suffix}"
          },
          overrides
        )
      )

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               transition.episode.id,
               "test-policy",
               @policy_digest,
               "responder"
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    claim
  end

  defp joined_channel!(workspace_ref, channel_ref, private, external_shared \\ false) do
    Repo.insert!(%ChannelMembership{
      channel_ref: channel_ref,
      external_shared: external_shared,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: DateTime.utc_now(),
      private: private,
      status: :joined,
      workspace_ref: workspace_ref
    })
  end
end

defmodule Responder.StateTools.RouterTest do
  use Responder.DataCase, async: true

  # A sandbox holds fixture inserts until the whole test rolls back. Reusing
  # T123 with channel-configuration tests formed a membership -> conversation
  # -> configuration -> membership deadlock across five unrelated tests.
  # Keep this suite's authority fixtures in its own workspace, not a shared row.
  import Plug.Conn
  import Plug.Test

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership

  alias Responder.State.{
    BehaviorChangeset,
    KnowledgeSnapshot,
    Record,
    Records,
    Schedule,
    ScheduleChangeset
  }

  alias Responder.StateTools.{FixedTools, Router, Tools, ToolVisibility}
  alias Responder.Work.{Custody, FinalPreflight, Prompt, SubmissionBuilder}

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
             "record_finding",
             "request_input",
             "wait_for",
             "list_automations",
             "get_automation",
             "propose_automation",
             "plan_goal",
             "update_goal",
             "request_task",
             "search_memory",
             "propose_memory",
             "remember_answer",
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
             Records.retained_records(claim.episode.id)

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
             Records.retained_records(claim.episode.id)

    assert payload["target"] == "Exact phrase search results for Emisar MCP"
    assert payload["source_name"] == payload["source_id"]
    assert payload["source_id"] == "admit_input:current-message"
  end

  test "an investigation can save a source-linked finding without sending a reply" do
    # The replay retained hundreds of observations but exposed no way for the
    # model to save an actual conclusion in the Findings page.
    claim = claim!("source-linked-finding", %{execution_mode: :shadow})
    options = bound_options(claim)

    assert {:ok, %{"record_ref" => evidence}} =
             Tools.call(
               "cite_source",
               %{
                 "subject" => "Configured service count",
                 "observation" =>
                   "The checked-out configuration deliberately sets the service count to zero.",
                 "source_ref" => "source:configured-count",
                 "relation" => "supports",
                 "supersedes" => []
               },
               options
             )

    args = %{
      "what" => "Zero instances are expected for this service.",
      "status" => "expected",
      "reason" =>
        "The checked-out configuration deliberately disables it; deployed configuration is unverified.",
      "scope" => "Repository intent, not a live health claim",
      "cause_evidence" => [evidence]
    }

    assert {:ok, %{"kind" => "finding", "record_ref" => ref} = saved} =
             Tools.call("record_finding", args, options)

    assert {:ok, ^saved} = Tools.call("record_finding", args, options)
    record = Repo.get_by!(Record, ref: ref)
    assert record.payload == args
    assert record.episode_id == claim.episode.id
    assert Repo.get!(Responder.Work.Turn, claim.turn.id).delivery_document == nil
    assert Repo.get!(Responder.Episodes.Episode, claim.episode.id).owner_kind == :turn

    assert {:error, "invalid_arguments"} =
             Tools.call("record_finding", %{args | "reason" => nil}, options)

    assert {:error, "invalid_arguments"} =
             Tools.call(
               "record_finding",
               %{args | "status" => "explained", "cause_evidence" => []},
               options
             )

    assert {:error, "invalid_arguments"} =
             Tools.call(
               "record_finding",
               %{args | "cause_evidence" => ["record:evidence:not-offered"]},
               options
             )

    assert {:error, "unauthorized"} = Tools.call("record_finding", args, [])
    assert Enum.count(Records.retained_records(claim.episode.id), &(&1["kind"] == "finding")) == 1
  end

  test "findings accept the advertised Unicode character limits" do
    # Byte limits rejected schema-valid non-English conclusions after a model
    # had already spent its investigation collecting the evidence.
    claim = claim!("unicode-finding")

    args = %{
      "what" => String.duplicate("é", 4_000),
      "status" => "expected",
      "reason" => String.duplicate("界", 2_000),
      "scope" => String.duplicate("é", 2_000),
      "cause_evidence" => []
    }

    assert {:ok, %{"record_ref" => ref}} =
             Tools.call("record_finding", args, bound_options(claim))

    assert Repo.get_by!(Record, ref: ref).payload == args

    assert {:error, "invalid_arguments"} =
             Tools.call(
               "record_finding",
               %{args | "what" => args["what"] <> "é"},
               bound_options(claim)
             )
  end

  test "a finding cannot borrow another episode's evidence" do
    first = claim!("finding-evidence-owner")

    assert {:ok, %{"record_ref" => evidence}} =
             Tools.call(
               "cite_source",
               %{
                 "subject" => "Owner-only evidence",
                 "observation" => "A retained observation.",
                 "source_ref" => "source:owner-only",
                 "relation" => "supports",
                 "supersedes" => []
               },
               bound_options(first)
             )

    second = claim!("finding-other-episode")

    assert {:error, "invalid_arguments"} =
             Tools.call(
               "record_finding",
               %{
                 "what" => "An unsupported cross-episode conclusion",
                 "status" => "explained",
                 "reason" => nil,
                 "scope" => nil,
                 "cause_evidence" => [evidence]
               },
               bound_options(second)
             )

    refute Enum.any?(Records.retained_records(second.episode.id), &(&1["kind"] == "finding"))
  end

  test "a read-only goal may inspect the pinned primary but never an unbound repository" do
    # Three health_check plans failed unauthorized on Sep 6 while reading their own emisar workspace.
    for context <- [nil, %{"read_only_repositories" => ["docs"]}] do
      claim = claim!("health-goal-#{Ecto.UUID.generate()}")
      claim = put_in(claim.session.repository_ref, "emisar")
      claim = put_in(claim.session.repository_context, context)

      arguments = %{
        "authority" => "read_only",
        "completion_contract" => "Check infrastructure health and flag issues",
        "id" => "health_check",
        "kind" => "check",
        "parent_goal_id" => nil,
        "prerequisite_goal_ids" => [],
        "read_only_repositories" => ["emisar"],
        "requested_outcome" => "Check infrastructure health and flag issues",
        "required" => true,
        "stage" => "implementation",
        "writable_repository" => nil
      }

      assert {:ok, %{"kind" => "goal"}} = Tools.call("plan_goal", arguments, bound_options(claim))
      assert Enum.any?(Records.retained_records(claim.episode.id), &(&1["kind"] == "goal"))

      assert {:error, "unauthorized"} =
               Tools.call(
                 "plan_goal",
                 %{arguments | "id" => "escape", "read_only_repositories" => ["unbound"]},
                 bound_options(claim)
               )
    end
  end

  test "plan_goal requires a lifecycle stage the model owns and never a host stage" do
    # Stage rows on the Slack task card come from typed membership. A goal
    # claiming CI or Draft PR would let the model paint a host-owned stage.
    claim = claim!("goal-stage-contract")
    options = bound_options(claim)

    arguments = %{
      "authority" => "read_only",
      "completion_contract" => "The drain path is covered by a focused test.",
      "id" => "drain-workers",
      "kind" => "engineering",
      "parent_goal_id" => nil,
      "prerequisite_goal_ids" => [],
      "read_only_repositories" => [],
      "requested_outcome" => "Drain and recycle workers safely",
      "required" => true,
      "successor_of" => nil,
      "writable_repository" => nil
    }

    assert {:error, "invalid_arguments"} = Tools.call("plan_goal", arguments, options)

    for stage <- ~w(workspace_setup draft_pr ci review_and_merge unknown) do
      assert {:error, "invalid_arguments"} =
               Tools.call("plan_goal", Map.put(arguments, "stage", stage), options)
    end

    assert {:ok, %{"kind" => "goal"}} =
             Tools.call("plan_goal", Map.put(arguments, "stage", "implementation"), options)

    assert [%{"kind" => "goal", "payload" => payload}] =
             Records.retained_records(claim.episode.id)

    assert payload["stage"] == "implementation"

    plan_goal = Enum.find(FixedTools.list(), &(&1["name"] == "plan_goal"))
    assert "stage" in plan_goal["inputSchema"]["required"]

    assert plan_goal["inputSchema"]["properties"]["stage"]["enum"] ==
             ~w(planning implementation self_review)

    update_goal = Enum.find(FixedTools.list(), &(&1["name"] == "update_goal"))
    assert Map.has_key?(update_goal["inputSchema"]["properties"], "evidence_refs")

    assert {:ok, evidence} =
             Records.create(Records.token(claim.turn), "evidence-drain", "evidence", %{
               "claim_id" => "drain.focused_test",
               "observation" => "The focused drain test passed.",
               "source_name" => "mix test",
               "source_type" => "repository"
             })

    assert {:ok, %{"kind" => "goal_state"}} =
             Tools.call(
               "update_goal",
               %{
                 "detail" => "Covered by the focused drain test.",
                 "evidence_refs" => [evidence.ref],
                 "goal_id" => "drain-workers",
                 "state" => "completed"
               },
               options
             )

    assert {:error, "invalid_arguments"} =
             Tools.call(
               "update_goal",
               %{
                 "detail" => nil,
                 "evidence_refs" => ["not a reference"],
                 "goal_id" => "drain-workers",
                 "state" => "completed"
               },
               options
             )
  end

  test "typed goal tools persist a dependency plan and preflight its live state" do
    claim = claim!("typed-goals")
    options = bound_options(claim)

    assert {:error, "unauthorized"} =
             Tools.call(
               "plan_goal",
               %{
                 "authority" => "repository_write",
                 "completion_contract" => "The unrelated repository changes.",
                 "id" => "escape-workspace",
                 "kind" => "engineering",
                 "parent_goal_id" => nil,
                 "prerequisite_goal_ids" => [],
                 "read_only_repositories" => [],
                 "requested_outcome" => "Change an unbound repository",
                 "required" => true,
                 "stage" => "implementation",
                 "writable_repository" => "unbound"
               },
               options
             )

    assert {:ok, %{"kind" => "goal", "record_ref" => parent_ref}} =
             Tools.call(
               "plan_goal",
               %{
                 "authority" => "read_only",
                 "completion_contract" => "Every required child has stopped successfully.",
                 "id" => "answer-request",
                 "kind" => "check",
                 "parent_goal_id" => nil,
                 "prerequisite_goal_ids" => [],
                 "read_only_repositories" => [],
                 "requested_outcome" => "Answer the complete request",
                 "required" => true,
                 "stage" => "implementation",
                 "writable_repository" => nil
               },
               options
             )

    assert {:ok, %{"kind" => "goal", "record_ref" => child_ref}} =
             Tools.call(
               "plan_goal",
               %{
                 "authority" => "read_only",
                 "completion_contract" => "The current state is established.",
                 "id" => "inspect-current-state",
                 "kind" => "check",
                 "parent_goal_id" => "answer-request",
                 "prerequisite_goal_ids" => [],
                 "read_only_repositories" => [],
                 "requested_outcome" => "Inspect current state",
                 "required" => true,
                 "stage" => "implementation",
                 "writable_repository" => nil
               },
               options
             )

    candidate = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Done.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [parent_ref, child_ref],
        "state" => "complete"
      }
    }

    assert {:ok, %{"accepted" => false, "violations" => [violation]}} =
             Tools.call("validate_final", %{"candidate" => candidate}, options)

    assert violation =~ "required goals remain open"

    assert {:ok, %{"kind" => "goal_state"}} =
             Tools.call(
               "update_goal",
               %{
                 "detail" => "Fresh evidence established the current state.",
                 "goal_id" => "inspect-current-state",
                 "state" => "completed"
               },
               options
             )

    assert {:ok, %{"kind" => "goal_state"}} =
             Tools.call(
               "update_goal",
               %{
                 "detail" => "All required child outcomes are complete.",
                 "goal_id" => "answer-request",
                 "state" => "completed"
               },
               options
             )

    assert {:ok, %{"accepted" => true}} =
             Tools.call("validate_final", %{"candidate" => candidate}, options)
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
             Records.retained_records(claim.episode.id)

    assert payload["kind"] == "incident"
    assert payload["repository"] == nil
    assert payload["prompt"] =~ "observe and contain; do not deploy"
    assert payload["instruction_ref"] == "input:incident:1"
  end

  test "request_task carries an exact repository source into the inert offer" do
    claim = claim!("source-task-offer")
    options = bound_options(claim)

    arguments = %{
      "authority_limits" => ["do not deploy"],
      "instruction_ref" => "input:review:1",
      "kind" => "engineering",
      "prompt" => "Review the payments branch and report findings.",
      "repository" => "responder",
      "repository_source" => %{"kind" => "branch", "name" => "feature/payments"},
      "source_refs" => ["input:review:1"],
      "success_checks" => ["findings are reported"],
      "title" => "Review the payments branch"
    }

    assert {:ok, %{"kind" => "task_offer"}} = Tools.call("request_task", arguments, options)

    assert [%{"kind" => "task_offer", "payload" => payload}] =
             Records.retained_records(claim.episode.id)

    assert payload["repository"] == "responder"
    assert payload["repository_source"] == %{"kind" => "branch", "name" => "feature/payments"}

    # The proposing session's own workspace is untouched: the selector belongs to
    # the new linked session that confirmation creates.
    assert Responder.Repo.get!(Responder.Work.Session, claim.session.id).repository_source ==
             claim.session.repository_source
  end

  test "request_task refuses a source outside the union or without a repository" do
    claim = claim!("source-task-offer-refused")
    options = bound_options(claim)

    base = %{
      "authority_limits" => ["do not deploy"],
      "instruction_ref" => "input:review:2",
      "kind" => "engineering",
      "prompt" => "Review the named source.",
      "repository" => "responder",
      "source_refs" => [],
      "success_checks" => ["findings are reported"],
      "title" => "Review a source"
    }

    for invalid <- [
          %{"kind" => "tag", "name" => "v1"},
          %{"kind" => "branch", "name" => "refs/heads/main"},
          %{"kind" => "commit", "sha" => String.duplicate("a", 12)},
          %{"kind" => "pull_request", "number" => 0},
          "feature/payments"
        ] do
      assert Tools.call("request_task", Map.put(base, "repository_source", invalid), options) ==
               {:error, "invalid_arguments"}
    end

    assert {:error, unscoped} =
             Tools.call(
               "request_task",
               base
               |> Map.put("kind", "incident")
               |> Map.put("repository", nil)
               |> Map.put("repository_source", %{"kind" => "default"}),
               options
             )

    assert String.starts_with?(unscoped, "invalid_arguments:")
    assert unscoped =~ "requires a non-null repository"
    assert Records.retained_records(claim.episode.id) == []
  end

  test "engineering task repository errors explain the blocker without creating work" do
    # One recorded GitHub turn spent six calls changing unrelated arguments
    # because missing repository and an incompatible slug both said invalid_arguments.
    fixture =
      "testdata/state_tools/github-task-repository-errors.json"
      |> File.read!()
      |> Jason.decode!()

    claim =
      claim!("task-repository-errors", %{
        destination: %{
          conversation_ref: "github:eval:repository:99",
          thread_ref: "github:eval:pull:42",
          transport: "github"
        }
      })

    options = bound_options(claim)
    assert length(fixture["calls"]) == 6

    errors =
      for call <- fixture["calls"] do
        response =
          rpc(
            "tools/call",
            %{"name" => "request_task", "arguments" => call["arguments"]},
            options
          )

        result = Jason.decode!(response.resp_body)["result"]
        assert result["isError"]
        assert Records.retained_records(claim.episode.id) == []
        result["structuredContent"]["error"]
      end

    assert Enum.map(errors, &hd(String.split(&1, ":", parts: 2))) == [
             "repository_required",
             "repository_required",
             "repository_required",
             "invalid_repository_reference",
             "repository_required",
             "repository_required"
           ]

    for error <- errors do
      assert error =~ "configured"
      refute error =~ "octo/example"
    end

    arguments = hd(fixture["calls"])["arguments"]

    assert {:error, default_error} =
             Tools.call("request_task", Map.delete(arguments, "kind"), options)

    assert String.starts_with?(default_error, "repository_required:")

    malformed = arguments |> Map.put("repository", "responder") |> Map.delete("title")
    assert Tools.call("request_task", malformed, options) == {:error, "invalid_arguments"}
    assert Records.retained_records(claim.episode.id) == []
  end

  test "task repository documentation distinguishes engineering and incident requirements" do
    claim = claim!("task-repository-documentation")
    task = Enum.find(Tools.list(bound_options(claim)), &(&1["name"] == "request_task"))
    description = get_in(task, ["inputSchema", "properties", "repository", "description"])
    assert is_binary(description)
    assert description =~ "engineering"
    assert description =~ "incident"
    assert String.downcase(description) =~ "configured"
  end

  test "task repository guidance names supplied companion targets before asking for configuration" do
    # The GitHub null-target clarification made a real Rivals turn ask three
    # unnecessary configuration questions despite its named read-only companion.
    fixture =
      "testdata/state_tools/recorded-rivals-repository-context.json"
      |> File.read!()
      |> Jason.decode!()

    # The captured fields are stored context. Assert the current provider-facing
    # projection, so documentation cannot accidentally name storage-only paths.
    prompt = fixture["context"] |> Prompt.build() |> Jason.decode!()
    assert prompt["work"]["repository_ref"] == nil
    assert prompt["work"]["workspace"]["primary"]["name"] == "primary"

    assert [%{"name" => "blitz-rivals-scraper", "read_only" => true}] =
             prompt["work"]["workspace"]["companions"]

    claim = claim!("task-companion-documentation")
    options = bound_options(claim)
    task = Enum.find(Tools.list(options), &(&1["name"] == "request_task"))
    description = get_in(task, ["inputSchema", "properties", "repository", "description"])

    for path <- ["work.repository_ref", "work.workspace.companions[].name"] do
      assert description =~ path
    end

    assert task["description"] =~ "inert proposal, not execution"
    assert description =~ "relevant"
    assert description =~ "generic primary"
    assert description =~ "unrelated companion"
    assert description =~ "unoffered"
    assert description =~ "only if no matching supplied target exists"

    github_fixture =
      "testdata/state_tools/github-task-repository-errors.json"
      |> File.read!()
      |> Jason.decode!()

    assert {:error, error} =
             Tools.call("request_task", hd(github_fixture["calls"])["arguments"], options)

    assert error =~ "work.repository_ref"
    assert error =~ "work.workspace.companions[].name"
    assert error =~ "only if no matching supplied target exists"
    assert Records.retained_records(claim.episode.id) == []
  end

  test "the fixed protocol reads work and creates each durable proposal kind" do
    claim = claim!("fixed-product-surface")
    assert {:ok, initial} = SubmissionBuilder.build(claim)

    assert :ok =
             KnowledgeSnapshot.expose_submission(%{
               claim
               | turn: %{claim.turn | submission: initial}
             })

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

    requested_expiry =
      DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()

    # The live memory card saved the supported seven-day bucket while the reply repeated the
    # requested one-day timestamp, so the model must receive the normalized proposal it created.
    assert {:ok,
            %{
              "kind" => "memory_offer",
              "proposal" => %{"expires_in" => "7d", "subject" => "service_owner"}
            }} =
             Tools.call(
               "propose_memory",
               %{
                 "expires_at" => requested_expiry,
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
                 "after" => nil,
                 "before" => nil,
                 "time_basis" => "changed",
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

  test "Lab images pass the same destination checks as final execution" do
    # A generated cat was discarded after preflight incorrectly told the model
    # that Conversation Lab could not deliver images; the final executor could.
    claim =
      claim!("lab-image-preflight", %{
        destination: %{
          conversation_ref: "control-plane:lab:images",
          thread_ref: "control-plane:lab:images",
          transport: "control_plane"
        }
      })

    candidate = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Here is the cat image.",
      "outcome" => %{
        "artifact_refs" => ["artifact_bd0541dddfe6910a3a3d8ff6"],
        "record_refs" => [],
        "state" => "complete"
      }
    }

    assert {:ok, %{"accepted" => true, "candidate" => ^candidate}} =
             Tools.call("validate_final", %{"candidate" => candidate}, bound_options(claim))
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
      |> Records.retained_records()
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

    assert Records.retained_records(claim.episode.id) == []

    assert Tools.call(
             "wait_for",
             %{
               "deadline" => "2099-01-01T00:00:00.000000Z",
               "on_timeout" => "Report that verification could not complete.",
               "trigger" => %{
                 "match" => %{"deployment" => "responder"},
                 "poll_after" => "2099-01-01T00:05:00.000000Z",
                 "source_kind" => "deployment",
                 "type" => "source_event"
               },
               "verification" => "Verify the allocation is healthy."
             },
             options
           ) == {:error, "invalid_arguments"}
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
               "channel_ref" => "slack:TSTATETOOLS:C999",
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
    joined_channel!("TSTATETOOLS", "C456", false)

    claim =
      claim!("fixed-memory-scopes", %{
        destination: %{
          conversation_ref: "slack:TSTATETOOLS:C456",
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

    records = Records.retained_records(claim.episode.id)
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
    joined_channel!("TSTATETOOLS", "G456", true)

    private =
      claim!("private-memory-scope", %{
        destination: %{
          conversation_ref: "slack:TSTATETOOLS:G456",
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

    assert Enum.all?(Records.retained_records(private.episode.id), fn record ->
             record["payload"]["scope"] == "conversation" and
               record["payload"]["visibility"] == "conversation" and
               is_nil(record["payload"]["repository"])
           end)

    joined_channel!("TSTATETOOLS", "C789", false, true)

    external =
      claim!("external-memory-scope", %{
        destination: %{
          conversation_ref: "slack:TSTATETOOLS:C789",
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

    assert [external_record] = Records.retained_records(external.episode.id)
    assert external_record["payload"]["scope"] == "conversation"
    assert external_record["payload"]["visibility"] == "conversation"
    assert is_nil(external_record["payload"]["repository"])

    unknown =
      claim!("unknown-memory-scope", %{
        destination: %{
          conversation_ref: "slack:TSTATETOOLS:C999",
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

    assert [record] = Records.retained_records(unknown.episode.id)
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
    assert length(names) == 17

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
    assert "plan_goal" in names
    assert "update_goal" in names
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

  test "a question is refused where no person has ever spoken" do
    # Production on 2026-09-12: every question asked in an episode a person had
    # spoken in was answered — 7 of 7 — and every question asked where no person
    # ever spoke is still open, 3 of 3, the oldest for days. The world matrix
    # charges the same behaviour as a hard authority failure on eight
    # observations, and it is what `one-outage-two-channels-joins-one-episode`
    # failed on every time: an alert-sourced turn that asks a question parks the
    # investigation behind a wait nobody is addressed to answer. `wait_for` is
    # that lane's instrument and it is offered alongside.
    alert = claim!("alert-only", %{actor_ref: "slack:app:alertmanager"})

    refused =
      rpc(
        "tools/call",
        %{"arguments" => question_arguments(), "name" => "request_input"},
        bound_options(alert)
      )

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             Jason.decode!(refused.resp_body)

    assert text =~ "no_addressee"

    # The same call in an episode a person started is untouched.
    operator = claim!("operator-present", %{actor_ref: "slack:user:U0BHTNFCW6S"})

    accepted =
      rpc(
        "tools/call",
        %{"arguments" => question_arguments(), "name" => "request_input"},
        bound_options(operator)
      )

    assert %{"result" => %{"structuredContent" => %{"kind" => "input_request"}}} =
             Jason.decode!(accepted.resp_body)
  end

  defp question_arguments do
    %{
      "context" => "The rollback needs an owner.",
      "questions" => [
        %{"choices" => ["roll back", "continue"], "text" => "Should we roll back?"}
      ],
      "remember" => nil
    }
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
        cursor_secret: "host-owned-source-cursor-secret",
        additional_tools: [source_tool],
        additional_call: fn "monitoring.query", %{"query" => "firing"}, received ->
          {:ok,
           %{
             "binding_received" =>
               Map.delete(received, :cursor_secret) == bound and
                 received[:cursor_secret] == "host-owned-source-cursor-secret"
           }}
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

    refute bound_response.resp_body =~ "host-owned-source-cursor-secret"
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
              "cursor" => %{"deployment_id" => "responder"},
              "match" => %{"deployment" => "responder"},
              "poll_after" => "2099-08-29T11:55:00.000000Z",
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

  test "a remembered answer belongs to one concrete question and frozen applicability" do
    claim = claim!("remembered-question")
    options = bound_options(claim)

    arguments = %{
      "context" => "The plan replaces the portal template and updates its fleet and monitors.",
      "questions" => [
        %{
          "choices" => [
            "project-prod",
            "project-stage",
            "project-dev",
            "project-data",
            "project-tools",
            "project-archive",
            "project-sandbox"
          ],
          "text" => "Which GCP project should I use for the health and backup checks?"
        }
      ],
      "remember" => %{
        "subject" => "GCP project",
        "applicability" => "Production portal in AndrewDryga/emisar"
      }
    }

    assert {:ok, result} = Tools.call("request_input", arguments, options)
    record = Repo.get_by!(Record, ref: result["record_ref"])
    assert record.payload["remember"] == arguments["remember"]
    assert record.payload["choices"] == hd(arguments["questions"])["choices"]
    assert record.payload["question"] =~ "plan replaces the portal template"

    ambiguous =
      Map.put(
        arguments,
        "questions",
        arguments["questions"] ++
          [
            %{
              "choices" => [],
              "text" => "Which region should I use?"
            }
          ]
      )

    assert Tools.call("request_input", ambiguous, options) == {:error, "invalid_arguments"}
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
                 "poll_after" => "1999-12-31T23:59:00.000000Z",
                 "source_kind" => "deployment",
                 "type" => "source_event"
               },
               "verification" => "Verify the allocation is healthy."
             },
             options
           ) == {:error, "deadline_elapsed"}

    assert Records.retained_records(claim.episode.id) == []
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

  test "recorded malformed final checks explain the complete call without accepting a partial answer" do
    # The live Terraform offer spent two tool calls guessing this shape because
    # both a missing candidate wrapper and a missing outcome said only invalid_arguments.
    captured = Jason.decode!(File.read!("testdata/work/terraform-automation-recovery.json"))
    claim = claim!("recorded-final-shape")

    for arguments <- captured["invalid_validation_calls"] do
      assert {:error, error} = Tools.call("validate_final", arguments, bound_options(claim))
      assert error =~ "invalid_arguments:"
      assert error =~ "candidate"
      assert error =~ "outcome"
      assert error =~ "record_refs"
      assert error =~ "artifact_refs"
      assert Repo.get!(Responder.Work.Turn, claim.turn.id).final_preflight_candidate_sha256 == nil
    end
  end

  test "an automation cannot name a vendor as an unregistered ingress source" do
    captured = Jason.decode!(File.read!("testdata/work/terraform-automation-recovery.json"))
    claim = claim!("recorded-automation-source")

    assert {:error, error} =
             Tools.call(
               "propose_automation",
               captured["automation_arguments"],
               bound_options(claim)
             )

    assert error =~ "source_kind"
    assert error =~ "slack"
    assert Records.model_records(claim.episode, claim.session.repository_ref) == []

    tools = Tools.list(bound_options(claim))
    schema = Enum.find(tools, &(&1["name"] == "propose_automation"))["inputSchema"]
    trigger = hd(schema["properties"]["proposals"]["items"]["oneOf"])["properties"]["trigger"]
    assert trigger["properties"]["source_kind"]["enum"] == ["github", "slack", "webhook"]
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
          ~w(record_evidence record_coverage report_progress record_alert_assessment) do
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

  test "a platform read runs its provider call outside the memory transaction" do
    # Enrichment opens a transaction with a five-second statement timeout. A
    # provider read that drifted inside it would hold a database connection for
    # a whole Slack round trip, so every other search waits on the network. The
    # order is structural today and nothing failed if a refactor moved it.
    claim =
      claim!("provider-transaction", %{
        destination: %{
          conversation_ref: "slack:TROUTER:CROUTER",
          thread_ref: "1789058307.523479",
          transport: "slack"
        }
      })

    assert :ok = KnowledgeSnapshot.expose(claim, [])
    test_pid = self()

    reader = %{
      "description" => "Search retained Slack conversation.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"],
        "type" => "object"
      },
      "name" => "search_slack"
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
        cursor_secret: "host-owned-source-cursor-secret",
        additional_tools: [reader],
        additional_call: fn "search_slack", _arguments, _binding ->
          send(test_pid, {:provider_transaction, Repo.in_transaction?()})
          {:ok, %{"complete" => true, "results" => %{"messages" => []}}}
        end
      )

    response =
      rpc(
        "tools/call",
        %{"arguments" => %{"query" => "readiness"}, "name" => "search_slack"},
        options
      )

    assert response.status == 200
    assert_received {:provider_transaction, false}

    assert get_in(Jason.decode!(response.resp_body), ["result", "structuredContent", "results"]) ==
             %{"messages" => []}
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

defmodule Responder.Work.TaskStagesTest do
  use ExUnit.Case, async: true

  alias Responder.Episodes.Episode
  alias Responder.Publication.{Followup, Publication}
  alias Responder.State.{Record, Records}
  alias Responder.Work.{Session, TaskStages, Turn}

  @stages ~w(workspace_setup planning implementation self_review draft_pr ci review_and_merge)

  test "all seven stages persist through waiting, failure, stop, skip and unknown" do
    # The old card was a tail of four progress notes plus one flat goal list:
    # a wait or a stop erased where the task stood. Every lifecycle state must
    # keep the same seven rows and only change their disposition.
    plan =
      plan([goal("choose", "planning", "completed"), goal("drain", "implementation", "working")])

    cases = [
      {"queued", facts(session: %Session{coop_session_id: nil}, plan: plan([])),
       ~w(waiting pending pending pending pending pending pending)},
      {"planning without a plan yet", facts(plan: plan([])),
       ~w(completed running pending pending pending pending pending)},
      {"implementing", facts(plan: plan),
       ~w(completed completed running pending pending pending pending)},
      {"waiting for a person",
       facts(
         episode: %Episode{state: :waiting_for_input, owner_kind: :input},
         turn: nil,
         plan:
           plan([
             goal("choose", "planning", "completed"),
             goal("drain", "implementation", "waiting")
           ])
       ), ~w(completed completed waiting pending pending pending pending)},
      {"waiting for an event",
       facts(
         episode: %Episode{state: :waiting_for_event, owner_kind: :event},
         turn: nil,
         plan: plan
       ), ~w(completed completed waiting pending pending pending pending)},
      {"blocked turn",
       facts(
         turn: %Turn{
           status: :blocked,
           coop_turn_id: "turn-1",
           last_error_detail: "The worker lost its workspace."
         },
         plan: plan
       ), ~w(completed completed failed pending pending pending pending)},
      {"blocked before a workspace existed",
       facts(
         session: %Session{coop_session_id: nil},
         turn: %Turn{
           status: :blocked,
           coop_turn_id: nil,
           last_error_detail: "No worker accepted the placement."
         },
         plan: plan([])
       ), ~w(failed pending pending pending pending pending pending)},
      {"stopped during implementation",
       facts(
         episode: %Episode{state: :cancelled, owner_kind: :turn},
         turn: %Turn{status: :superseded, coop_turn_id: "turn-1"},
         plan: plan
       ), ~w(completed completed stopped pending pending pending pending)},
      {"stop requested",
       facts(turn: %Turn{status: :cancel_pending, coop_turn_id: "turn-1"}, plan: plan),
       ~w(completed completed running pending pending pending pending)},
      {"checking the changes",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: %Publication{status: :review_pending},
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed running pending pending pending)},
      {"checks did not start",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication_offer: %{"status" => "open"},
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed failed pending pending pending)},
      {"reviewed, draft awaits the operator",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: %Publication{status: :reviewed},
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed waiting pending pending)},
      {"creating the draft",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: %Publication{status: :publish_pending},
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed running pending pending)},
      {"draft creation blocked",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: %Publication{
           status: :blocked,
           last_error_detail: "The branch already exists."
         },
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed failed pending pending)},
      {"published, checks pending",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: published(),
         followup: %Followup{
           pr_state: "open",
           checks_state: "pending",
           checks_total: 8,
           checks_passed: 3,
           checks_failed: 0
         },
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed completed running pending)},
      {"published, checks failing",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: published(),
         followup: %Followup{
           pr_state: "open",
           checks_state: "failing",
           checks_total: 8,
           checks_passed: 6,
           checks_failed: 2
         },
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed completed failed pending)},
      {"no checks configured",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: published(),
         followup: %Followup{pr_state: "open", checks_state: "none"},
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed completed skipped waiting)},
      {"merged",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: published(),
         followup: %Followup{
           pr_state: "merged",
           checks_state: "passing",
           checks_total: 8,
           checks_passed: 8,
           merge_sha: String.duplicate("b", 40)
         },
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed completed completed completed)},
      {"closed without merging",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: published(),
         followup: %Followup{
           pr_state: "closed",
           checks_state: "passing",
           checks_total: 8,
           checks_passed: 8
         },
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed completed completed stopped)},
      {"candidate discarded",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         publication: %Publication{status: :discarded},
         plan: plan([goal("drain", "implementation", "completed")])
       ), ~w(completed completed completed completed skipped pending pending)},
      {"completed before any telemetry existed",
       facts(
         episode: %Episode{state: :complete, owner_kind: :turn},
         turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
         plan: plan([])
       ), ~w(completed unknown unknown unknown unknown pending pending)}
    ]

    for {label, facts, expected} <- cases do
      rows = TaskStages.build(facts)
      assert Enum.map(rows, & &1["stage"]) == @stages, label
      assert Enum.map(rows, & &1["state"]) == expected, label
      assert Enum.count(rows, & &1["current"]) <= 1, label
    end
  end

  test "human handoffs are marked on their owning stage and never on a running worker" do
    waiting =
      TaskStages.build(
        facts(
          episode: %Episode{state: :waiting_for_input, owner_kind: :input},
          turn: nil,
          plan:
            plan([
              goal("choose", "planning", "completed"),
              goal("drain", "implementation", "waiting", %{
                "detail" => "waiting for the storage-location answer"
              })
            ])
        )
      )

    implementation = row(waiting, "implementation")
    assert implementation["your_turn"]
    assert implementation["current"]
    assert implementation["detail"] == "0/1 subtasks"

    assert [
             %{
               "id" => "drain",
               "state" => "waiting",
               "current" => true,
               "detail" => "waiting for the storage-location answer"
             }
           ] =
             implementation["subtasks"]

    refute Enum.any?(waiting, &(&1["your_turn"] and &1["stage"] != "implementation"))

    reviewed =
      TaskStages.build(
        facts(
          episode: %Episode{state: :complete, owner_kind: :turn},
          turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
          publication: published(),
          followup: %Followup{
            pr_state: "open",
            checks_state: "passing",
            checks_total: 8,
            checks_passed: 8
          },
          plan: plan([goal("drain", "implementation", "completed")])
        )
      )

    assert row(reviewed, "review_and_merge")["your_turn"]
    assert row(reviewed, "review_and_merge")["current"]
    assert row(reviewed, "ci")["detail"] == "8/8"
    assert row(reviewed, "draft_pr")["detail"] == "#91"
    assert row(reviewed, "draft_pr")["url"] == "https://github.com/acme/responder/pull/91"

    running = TaskStages.build(facts(plan: plan([goal("drain", "implementation", "working")])))
    refute Enum.any?(running, & &1["your_turn"])
  end

  test "implementation counts current leaves and a missing plan has no denominator" do
    rows =
      TaskStages.build(
        facts(
          plan:
            plan([
              goal("deliver", "implementation", "working"),
              goal("persist", "implementation", "completed", %{"parent_goal_id" => "deliver"}),
              goal("restore", "implementation", "working", %{"parent_goal_id" => "deliver"}),
              goal("partial", "implementation", "ready", %{"parent_goal_id" => "deliver"}),
              goal("tests", "implementation", "ready", %{"parent_goal_id" => "deliver"}),
              goal("review", "self_review", "ready")
            ])
        )
      )

    implementation = row(rows, "implementation")
    assert implementation["detail"] == "1/4 subtasks"
    assert Enum.map(implementation["subtasks"], & &1["id"]) == ~w(persist restore partial tests)
    assert implementation["subtasks_total"] == 4

    assert [%{"id" => "restore", "current" => true}] =
             Enum.filter(implementation["subtasks"], & &1["current"])

    assert row(rows, "self_review")["detail"] == nil

    [no_plan] =
      TaskStages.build(facts(plan: plan([]))) |> Enum.filter(&(&1["stage"] == "implementation"))

    assert no_plan["detail"] == nil
    assert no_plan["subtasks"] == []
    refute Enum.any?(TaskStages.build(facts(plan: plan([]))), &(&1["detail"] == "0/0 subtasks"))

    excluded =
      TaskStages.build(
        facts(
          plan:
            plan([
              goal("persist", "implementation", "completed"),
              goal("restore", "implementation", "excluded", %{
                "detail" => "Covered by the supervisor test."
              })
            ])
        )
      )

    assert row(excluded, "implementation")["detail"] == "1/1 subtasks · 1 excluded"
  end

  test "a large plan shows the active subset and names the hidden remainder" do
    goals =
      for index <- 1..9 do
        state =
          cond do
            index <= 6 -> "completed"
            index == 7 -> "working"
            true -> "ready"
          end

        goal("step-#{index}", "implementation", state)
      end

    rows = TaskStages.build(facts(plan: plan(goals)))
    implementation = row(rows, "implementation")
    assert implementation["detail"] == "6/9 subtasks"
    assert implementation["subtasks_total"] == 9
    assert length(implementation["subtasks"]) == 6
    assert hd(implementation["subtasks"])["id"] == "step-7"

    assert Enum.map(implementation["subtasks"], & &1["state"]) ==
             ~w(working ready ready completed completed completed)
  end

  test "newer implementation work marks the previous checks and draft as stale instead of green" do
    completed_review = [
      goal("drain", "implementation", "completed", %{}, 1),
      goal("review", "self_review", "completed", %{}, 3)
    ]

    settled =
      facts(
        episode: %Episode{state: :complete, owner_kind: :turn},
        turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
        publication: published(~U[2026-09-11 10:00:00.000000Z]),
        followup: %Followup{
          pr_state: "open",
          checks_state: "passing",
          checks_total: 6,
          checks_passed: 6
        },
        plan: plan(completed_review)
      )

    assert Enum.map(TaskStages.build(settled), & &1["state"]) ==
             ~w(completed completed completed completed completed completed waiting)

    follow_up =
      plan(
        completed_review ++
          [goal("labels", "implementation", "working", %{}, 10, ~U[2026-09-11 11:00:00.000000Z])]
      )

    rows =
      TaskStages.build(%{
        settled
        | episode: %Episode{state: :working, owner_kind: :turn},
          turn: %Turn{status: :pending, coop_turn_id: "turn-2"},
          plan: follow_up
      })

    assert Enum.map(rows, & &1["state"]) ==
             ~w(completed completed running stale stale stale pending)

    assert row(rows, "self_review")["detail"] == "previous version checked"
    assert row(rows, "draft_pr")["detail"] == "#91 · newer changes not published"
    assert row(rows, "ci")["detail"] == "6/6 on the published revision"
    assert row(rows, "implementation")["detail"] == "1/2 subtasks"
  end

  test "a held working copy fails its own stage without rolling back the work that ran" do
    # Marking the workspace stage failed is the point — "✓ Workspace setup" above
    # a working copy the host never snapshotted is the one claim that is false.
    # But the guard behind Planning read "no completed workspace, so nothing has
    # started yet", which turned every later row back to ○ on a task whose worker
    # had already finished.
    held =
      facts(
        episode: %Episode{state: :working, owner_kind: :turn},
        turn: %Turn{status: :blocked, coop_turn_id: "turn-1"},
        plan: plan([goal("drain", "implementation", "completed")]),
        workspace_hold: %{closed: true, held: :workspace, report: "Prepared the bump."}
      )

    rows = TaskStages.build(held)

    assert Enum.map(rows, & &1["state"]) ==
             ~w(failed completed completed pending pending pending pending)

    assert row(rows, "workspace_setup")["detail"] == "no saved snapshot · session closed"
    assert row(rows, "workspace_setup")["current"]

    # Without the hold the same bound session is an ordinary completed workspace.
    assert row(TaskStages.build(%{held | workspace_hold: nil}), "workspace_setup")["state"] ==
             "completed"

    still_open =
      TaskStages.build(%{
        held
        | workspace_hold: %{closed: false, held: :reply, report: nil}
      })

    assert row(still_open, "workspace_setup")["detail"] == "no saved snapshot"

    # An earlier pull request stays reachable, marked as the earlier snapshot.
    with_draft =
      TaskStages.build(%{
        held
        | publication: published(),
          followup: %Followup{pr_state: "open", checks_state: "passing"}
      })

    assert row(with_draft, "draft_pr")["state"] == "stale"
    assert row(with_draft, "draft_pr")["url"] == "https://github.com/acme/responder/pull/91"

    assert row(with_draft, "draft_pr")["detail"] ==
             "#91 · earlier snapshot, newer work not saved"
  end

  test "a draft whose gate never ran leaves the check stage open and the merge untouched" do
    # The check stage read ✓ and Review and merge read "← 🙋 your turn" for a
    # change no required check had run against, because "a publication exists"
    # was being read as "the checks finished".
    unrun =
      facts(
        episode: %Episode{state: :complete, owner_kind: :turn},
        turn: %Turn{status: :settled, coop_turn_id: "turn-1"},
        publication: %{
          published()
          | review_document: %{
              "gate" => "startup_error",
              "gate_error" => "docker: command not found",
              "patch_artifact_id" => "review-patch:1",
              "patch_bytes" => 64,
              "patch_digest" => String.duplicate("a", 64),
              "patch_truncated" => false,
              "policy_findings" => [],
              "publishable" => false,
              "rebase" => "clean"
            }
        },
        followup: %Followup{
          pr_state: "open",
          checks_state: "passing",
          checks_total: 6,
          checks_passed: 6
        },
        plan: plan([goal("drain", "implementation", "completed")])
      )

    rows = TaskStages.build(unrun)

    assert Enum.map(rows, & &1["state"]) ==
             ~w(completed completed completed failed completed completed pending)

    assert row(rows, "self_review")["detail"] == "docker: command not found"
    refute row(rows, "review_and_merge")["your_turn"]

    # The same ledger with a gate that actually passed still hands over.
    passed = put_in(unrun.publication.review_document["gate"], "passed")
    assert row(TaskStages.build(passed), "self_review")["state"] == "completed"
    assert row(TaskStages.build(passed), "review_and_merge")["your_turn"]
  end

  test "historical goals without a stage are listed as unassigned, never backfilled" do
    rows =
      TaskStages.build(
        facts(plan: plan([goal("goal-1", nil, "completed"), goal("goal-2", nil, "completed")]))
      )

    assert Enum.map(rows, & &1["stage"]) == @stages ++ ["unassigned"]
    unassigned = List.last(rows)
    assert unassigned["state"] == "unknown"
    assert unassigned["detail"] == "2 subtasks recorded without a stage"
    assert Enum.map(unassigned["subtasks"], & &1["id"]) == ~w(goal-1 goal-2)
    assert row(rows, "implementation")["detail"] == nil
  end

  defp row(rows, stage), do: Enum.find(rows, &(&1["stage"] == stage))

  defp facts(overrides) do
    Map.merge(
      %{
        episode: %Episode{state: :working, owner_kind: :turn},
        turn: %Turn{status: :pending, coop_turn_id: "turn-1"},
        session: %Session{coop_session_id: "coop-session-1"},
        publication: nil,
        followup: nil,
        publication_offer: nil,
        plan: plan([]),
        workspace_hold: nil
      },
      Map.new(overrides)
    )
  end

  defp published(published_at \\ ~U[2026-09-11 10:00:00.000000Z]) do
    %Publication{
      status: :published,
      github_repository: "acme/responder",
      pull_request_number: 91,
      pull_request_url: "https://github.com/acme/responder/pull/91",
      published_at: published_at
    }
  end

  # Records are sequenced in list order unless a test pins one explicitly.
  defp plan(goals) do
    goals
    |> List.flatten()
    |> Enum.with_index(1)
    |> Enum.map(fn {record, index} -> %{record | sequence: record.sequence || index} end)
    |> Records.plan_from_records()
  end

  # Goal records shaped like the retained rows: the goal record carries the
  # plan, one later goal_state record carries the current state and detail.
  defp goal(id, stage, state, overrides \\ %{}, sequence \\ nil, inserted_at \\ nil) do
    inserted_at = inserted_at || ~U[2026-09-11 09:00:00.000000Z]
    {detail, overrides} = Map.pop(overrides, "detail")

    payload =
      %{
        "authority" => "read_only",
        "completion_contract" => "Complete #{id}.",
        "id" => id,
        "kind" => "engineering",
        "requested_outcome" => "Complete #{id}",
        "required" => true
      }
      |> Map.merge(if(stage, do: %{"stage" => stage}, else: %{}))
      |> Map.merge(overrides)

    goal = %Record{
      kind: "goal",
      subject_ref: id,
      payload: payload,
      sequence: sequence,
      inserted_at: inserted_at
    }

    if state == "ready" do
      [goal]
    else
      [
        goal,
        %Record{
          kind: "goal_state",
          subject_ref: id,
          payload: %{"goal_id" => id, "state" => state, "detail" => detail},
          sequence: sequence && sequence + 1,
          inserted_at: inserted_at
        }
      ]
    end
  end
end

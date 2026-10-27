defmodule Ryker.ControlPlane.WorkPlanCardTest do
  @moduledoc """
  Plan changes retain their own place in the timeline; the latest checklist
  is a separate summary, never a later result backdated to the first plan.
  """
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, EpisodeTrace, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Work.Custody

  # Folding all changes into the first plan card made a completed result
  # appear before the work that produced it (reported 2026-10-26).
  test "plan changes keep their recorded times and the current checklist stays outside the timeline" do
    work = claimed!()
    goal = goal!(work, "check-health", "Check infrastructure health")
    other = goal!(work, "double-check", "Double-check the findings")
    {:ok, before} = EpisodeProjection.fetch(work.episode.key)
    evidence = evidence!(work, "nodes", %{"target" => "Nomad nodes"})
    working = state!(work, "check-health", "working")

    completed =
      state!(work, "check-health", "completed", %{
        "detail" => "Every node reports ready.",
        "evidence_refs" => [evidence.ref]
      })

    blocked =
      state!(work, "double-check", "blocked", %{
        "detail" => "The monitoring API refused the query."
      })

    {detail, html} = rendered(work.episode)

    changes = Enum.filter(detail.trace.steps, &(&1.stage == "Plan change"))

    assert Enum.map(changes, &{&1.record_ref, &1.at}) ==
             Enum.map([goal, other, working, completed, blocked], &{&1.ref, &1.inserted_at})

    assert Enum.map(changes, & &1.plan_change.status) ==
             ["Not started", "Not started", "In progress", "Done", "Blocked"]

    assert hd(changes) == Enum.find(before.trace.steps, &(&1.record_ref == goal.ref))
    refute Enum.any?(detail.trace.steps, &(&1.stage == "Work plan"))

    assert Enum.map(detail.trace.work_plan.steps, &{&1.title, &1.status}) == [
             {"Check infrastructure health", "Done"},
             {"Double-check the findings", "Blocked"}
           ]

    document = LazyHTML.from_document(html)
    assert document |> LazyHTML.query(".work-plan-summary") |> Enum.count() == 1
    assert Enum.count(LazyHTML.query(document, "#work-plan-summary ~ #execution-timeline")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#execution-timeline .work-plan-summary"))
    assert Enum.count(LazyHTML.query(document, "#execution-timeline .plan-change")) == 2

    [planned, updated] =
      Enum.to_list(LazyHTML.query(document, "#execution-timeline .plan-change"))

    assert Enum.count(LazyHTML.query(planned, ".plan-step")) == 2
    refute LazyHTML.text(planned) =~ "Every node reports ready."
    assert Enum.count(LazyHTML.query(updated, ".plan-step")) == 2
    assert LazyHTML.text(updated) =~ "In progress → Done"
    assert LazyHTML.text(updated) =~ "Not started → Blocked"
    refute html =~ "Plan history"
    steps = LazyHTML.query(document, ".work-plan-summary .plan-step")
    assert Enum.count(steps) == 2

    [done, blocked] = Enum.map(steps, &LazyHTML.text/1)
    assert done =~ "Every node reports ready."
    assert blocked =~ "The monitoring API refused the query."

    assert document
           |> LazyHTML.query(
             ".work-plan-summary .plan-step a[href='#event-record-#{evidence.id}']"
           )
           |> LazyHTML.text() == evidence.payload["observation"]

    assert Enum.count(
             LazyHTML.query(
               document,
               "#plan-summary-record-#{goal.id} a[href='#event-record-#{completed.id}']"
             )
           ) == 1

    ids = LazyHTML.query(document, "[id]") |> LazyHTML.attribute("id")
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "the summary is current while waiting and final only when the request has ended" do
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")
    {:ok, snapshot} = EpisodeProjection.fetch(work.episode.key)

    for {state, title} <- [
          {:working, "Current work plan"},
          {:waiting_for_input, "Current work plan"},
          {:waiting_for_event, "Current work plan"},
          {:complete, "Final work plan"},
          {:cancelled, "Final work plan"}
        ] do
      episode = %{snapshot.episode | state: state}

      html =
        render_component(&EpisodePage.render/1,
          snapshot: %{snapshot | episode: episode},
          params: %{}
        )

      summary = html |> LazyHTML.from_document() |> LazyHTML.query("#work-plan-summary")
      assert LazyHTML.text(summary) =~ title
      # A request ending does not manufacture completion for an unfinished goal.
      assert LazyHTML.text(summary) =~ "Not started"
    end
  end

  test "a plan batch keeps anchors for an attempt replaced within that same batch" do
    work = claimed!()
    first = goal!(work, "check-health", "Check infrastructure health")
    # The host requires the predecessor to have finished. Retain that history,
    # then isolate two consecutive plan entries to exercise the presentation.
    state!(work, "check-health", "completed")

    replacement =
      goal!(work, "check-again", "Check health again", %{"successor_of" => "check-health"})

    {:ok, detail} = EpisodeProjection.fetch(work.episode.key)
    steps = EpisodeTrace.Work.record_steps([first, replacement])

    html =
      render_component(&EpisodePage.render/1,
        snapshot: put_in(detail.trace.steps, steps),
        params: %{}
      )

    document = LazyHTML.from_document(html)

    for record <- [first, replacement] do
      assert Enum.count(LazyHTML.query(document, ".plan-change #event-record-#{record.id}")) == 1
    end

    assert LazyHTML.text(LazyHTML.query(document, ".plan-change")) =~ "Replaced"
    assert Enum.count(LazyHTML.query(document, ".work-plan-summary .plan-step")) == 1
  end

  test "an update snapshot includes unchanged steps and excludes later progress" do
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")
    goal!(work, "check-backups", "Check backups")
    state!(work, "check-health", "working")
    {_detail, before} = rendered(work.episode)
    evidence!(work, "split-events", %{})
    state!(work, "check-backups", "completed", %{"detail" => "The backup finished later."})
    {_detail, after_html} = rendered(work.episode)

    first_update = fn html ->
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".plan-change")
      |> Enum.at(1)
      |> LazyHTML.to_html()
    end

    assert first_update.(before) == first_update.(after_html)
    assert first_update.(before) =~ "Check backups"
    refute first_update.(before) =~ "The backup finished later."
  end

  test "a later run owns its plan update without moving the original plan into that run" do
    work = claimed!()
    goal = goal!(work, "check-health", "Check infrastructure health")
    update = state!(work, "check-health", "working")
    resumed_turn = Ecto.UUID.generate()
    update = %{update | turn_id: resumed_turn}

    [planned, changed] = EpisodeTrace.Work.record_steps([goal, update])
    assert planned.owner == {:turn, work.turn.id}
    assert changed.owner == {:turn, resumed_turn}
    assert planned.at == goal.inserted_at
    assert changed.at == update.inserted_at
  end

  test "progress contains the plan under its recorded stages before the next action" do
    work = claimed!()
    goal!(work, "plan", "Plan the investigation", %{"stage" => "planning"})
    state!(work, "plan", "completed")
    goal!(work, "check-health", "Check infrastructure health")
    goal!(work, "review", "Review the evidence", %{"stage" => "self_review"})
    state!(work, "check-health", "blocked", %{"detail" => "Waiting for approval."})
    state!(work, "review", "working", %{"detail" => "Comparing the recorded evidence."})
    {:ok, snapshot} = EpisodeProjection.fetch(work.episode.key)

    stopped = %{
      headline: "The task needs attention",
      reason: "The command failed.",
      action: "Resolve the command failure before retrying.",
      href: nil,
      attempted: []
    }

    snapshot =
      snapshot
      |> Map.put(:task, %{
        stages:
          Enum.map(~w(planning implementation self_review), fn stage ->
            %{
              "stage" => stage,
              "state" => if(stage == "planning", do: "completed", else: "pending"),
              "detail" => nil
            }
          end),
        repository_url: nil
      })
      |> put_in([:trace, :stopped], stopped)

    document =
      render_component(&EpisodePage.render/1, snapshot: snapshot, params: %{})
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, ".task-progress#work-plan-summary + .story-stop")) ==
             1

    summary = LazyHTML.query(document, "#work-plan-summary")
    assert LazyHTML.text(summary) =~ "Progress and plan"

    assert LazyHTML.text(LazyHTML.query(summary, "[data-stage='implementation']")) =~
             "Check infrastructure health"

    assert LazyHTML.text(LazyHTML.query(summary, "[data-stage='implementation']")) =~
             "Waiting for approval."

    refute LazyHTML.text(LazyHTML.query(summary, "[data-stage='implementation']")) =~
             "Review the evidence"

    assert LazyHTML.text(LazyHTML.query(summary, "[data-stage='self_review']")) =~
             "Review the evidence"

    assert Enum.count(LazyHTML.query(summary, ".plan-step")) == 2
    refute LazyHTML.text(summary) =~ "Plan the investigation"

    assert LazyHTML.text(LazyHTML.query(document, "#execution-timeline")) =~
             "Plan the investigation"

    assert Enum.empty?(LazyHTML.query(summary, ".plan-step-title strong"))

    assert summary |> LazyHTML.query("strong.plan-step-title") |> LazyHTML.text() |> String.trim() ==
             "Review the evidence"

    assert LazyHTML.text(summary) =~ "Comparing the recorded evidence."
    refute LazyHTML.text(summary) =~ "Done when"
    refute LazyHTML.text(summary) =~ "Current work plan"
  end

  test "the latest saved plan status follows record sequence even if the clock moves backwards" do
    work = claimed!()
    goal = goal!(work, "check-health", "Check infrastructure health")
    working = state!(work, "check-health", "working")
    completed = state!(work, "check-health", "completed", %{"detail" => "Every node is ready."})
    completed = %{completed | inserted_at: DateTime.add(working.inserted_at, -1, :second)}
    assert completed.sequence > working.sequence

    %{steps: [step]} = EpisodeTrace.Work.work_plan([goal, working, completed])
    assert step.status == "Done"
    assert step.detail == "Every node is ready."
    assert step.change_id == "record-#{completed.id}"
  end

  test "a historical goal without a stage stays explicitly unassigned in the combined summary" do
    work = claimed!()
    goal = goal!(work, "old-goal", "Inspect the retained evidence")
    old_goal = %{goal | payload: Map.delete(goal.payload, "stage")}
    {:ok, snapshot} = EpisodeProjection.fetch(work.episode.key)

    snapshot =
      snapshot
      |> put_in([:trace, :work_plan], EpisodeTrace.Work.work_plan([old_goal]))
      |> Map.put(:task, %{stages: [], repository_url: nil})

    html = render_component(&EpisodePage.render/1, snapshot: snapshot, params: %{})
    unassigned = html |> LazyHTML.from_document() |> LazyHTML.query(".task-stage-unassigned")
    assert LazyHTML.text(unassigned) =~ "Steps without a recorded stage"
    assert LazyHTML.text(unassigned) =~ "Inspect the retained evidence"
    assert Enum.count(LazyHTML.query(unassigned, ".plan-step")) == 1
  end

  test "plan titles and progress render as text in both the events and summary" do
    work = claimed!()
    goal!(work, "check-health", "Inspect <script>alert('title')</script>")

    state!(work, "check-health", "completed", %{"detail" => "<img src=x onerror=alert('result')>"})

    {_detail, html} = rendered(work.episode)
    document = LazyHTML.from_document(html)

    assert Enum.empty?(
             LazyHTML.query(
               document,
               ".plan-change script, .plan-change img, .work-plan-summary script, .work-plan-summary img"
             )
           )

    assert LazyHTML.text(LazyHTML.query(document, ".work-plan-summary")) =~
             "<img src=x onerror=alert('result')>"
  end

  test "a step not yet done says what finishes it as Done when, and only an optional step is marked" do
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")
    goal!(work, "tidy", "Tidy the dashboards", %{"required" => false})

    {_detail, html} = rendered(work.episode)
    [required, optional] = step_texts(html)

    assert required =~ "Not started"
    assert required =~ "Done when"
    assert required =~ "Current evidence supports a bounded conclusion."
    refute required =~ "Optional"
    refute required =~ "Required"
    assert optional =~ "Optional"
  end

  test "a large evidence set has a counted disclosure without losing any destination" do
    # Real rollout goals held eight long evidence titles as a comma wall.
    # A small set stays direct; a larger set is inspectable as its own list.
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")

    evidence =
      for number <- 1..4,
          do: evidence!(work, "source-#{number}", %{"target" => "Source #{number}"})

    state!(work, "check-health", "completed", %{"evidence_refs" => Enum.map(evidence, & &1.ref)})
    {_detail, html} = rendered(work.episode)
    document = LazyHTML.from_document(html)
    fold = LazyHTML.query(document, ".work-plan-summary .plan-steps .plan-evidence")
    assert fold |> LazyHTML.query("summary") |> LazyHTML.text() =~ "4 evidence records"
    assert Enum.count(LazyHTML.query(fold, "a")) == 4

    for record <- evidence do
      assert LazyHTML.query(fold, "a[href='#event-record-#{record.id}']") |> Enum.count() == 1
    end
  end

  test "plan events show criteria and progress without displaying bookkeeping IDs" do
    work = claimed!()
    goal = goal!(work, "check-health", "Check infrastructure health")
    update = state!(work, "check-health", "working")

    {_detail, html} = rendered(work.episode)
    document = LazyHTML.from_document(html)

    face = LazyHTML.query(document, ".work-plan-summary .plan-steps")
    refute LazyHTML.text(face) =~ ~r/read only/i
    assert face |> LazyHTML.query("[data-copy-value]") |> Enum.count() == 0

    changes = LazyHTML.query(document, ".plan-change")
    history = LazyHTML.text(changes)
    assert history =~ "Work plan created"
    assert history =~ "Work plan updated"
    assert history =~ "Done when"
    assert history =~ "Current evidence supports a bounded conclusion."
    assert history =~ "In progress"
    refute history =~ goal.ref
    refute history =~ goal.operation_id
    refute history =~ "Membership"
    refute history =~ "Goal ID"
    refute history =~ "Operation"
    assert Enum.count(LazyHTML.query(document, ".plan-change #event-record-#{goal.id}")) == 1
    assert Enum.count(LazyHTML.query(document, ".plan-change #event-record-#{update.id}")) == 1
    assert Enum.empty?(LazyHTML.query(changes, "button, .identifier"))
  end

  # A repeated check after changed work is a new attempt; the one it replaces
  # keeps its result but is never counted as the work's.
  test "a repeated attempt replaces the summary step without changing the earlier events" do
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")

    state!(work, "check-health", "completed", %{
      "detail" => "Every node was ready before the change."
    })

    goal!(work, "check-health-2", "Check infrastructure health again", %{
      "successor_of" => "check-health"
    })

    {detail, html} = rendered(work.episode)

    assert [%{title: "Check infrastructure health again", attempt: 2}] =
             detail.trace.work_plan.steps

    assert [step] = step_texts(html)
    assert step =~ "Attempt 2"
    refute step =~ "Every node was ready before the change."

    history =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#execution-timeline .plan-change")
      |> LazyHTML.text()

    assert history =~ "Check infrastructure health"
    assert history =~ "Check infrastructure health again"
    assert history =~ "Every node was ready before the change."
  end

  test "a bounded page does not claim an older goal or its evidence was deleted" do
    # The page keeps only a bounded record window. Its missing plan may still
    # be retained, so absence here must never read as expired or deleted.
    work = claimed!()
    original = goal!(work, "earlier-goal", "Inspect the earlier deployment")
    evidence = evidence!(work, "earlier-source", %{"target" => "Deployment health"})

    dependent =
      goal!(work, "later-goal", "Verify the later deployment", %{
        "prerequisite_goal_ids" => ["earlier-goal"]
      })

    update =
      state!(work, "earlier-goal", "completed", %{
        "detail" => "The earlier deployment is healthy.",
        "evidence_refs" => [evidence.ref]
      })

    assert {:ok, [retained]} = Records.fetch_for_episode(work.episode.id, [original.ref])
    assert retained.ref == original.ref

    # Supply exactly the bounded projection boundary: the newer dependent
    # plan and the old goal's latest update, not its older plan/evidence.
    trace = EpisodeTrace.project(work.episode, [], [dependent, update])
    missing = Enum.find(trace.work_plan.steps, &(&1.goal_id == "earlier-goal"))
    assert missing.title == "Goal details not on this page"
    assert missing.detail == "The earlier deployment is healthy."
    assert missing.evidence == [%{href: nil, title: "Evidence not on this page"}]

    later = Enum.find(trace.work_plan.steps, &(&1.goal_id == "later-goal"))
    assert Enum.find(later.facts, &(&1.label == "After")).value == "Goal details not on this page"
  end

  test "missing evidence is one counted note, not a disclosure of repeated placeholders" do
    work = claimed!()
    goal = goal!(work, "check-health", "Check infrastructure health")

    evidence =
      for number <- 1..4,
          do: evidence!(work, "source-#{number}", %{"target" => "Source #{number}"})

    update =
      state!(work, "check-health", "completed", %{"evidence_refs" => Enum.map(evidence, & &1.ref)})

    for {visible, missing} <- [{[], 4}, {[hd(evidence)], 3}] do
      {:ok, snapshot} = EpisodeProjection.fetch(work.episode.key)
      trace = EpisodeTrace.project(work.episode, [], [goal] ++ visible ++ [update])

      document =
        render_component(&EpisodePage.render/1,
          snapshot: %{snapshot | trace: trace},
          requests: nil,
          params: %{}
        )
        |> LazyHTML.from_document()

      face = LazyHTML.query(document, ".work-plan-summary .plan-steps")
      assert Enum.empty?(LazyHTML.query(face, ".plan-evidence, code"))

      assert LazyHTML.query(face, ".plan-evidence-unavailable")
             |> LazyHTML.text()
             |> String.trim() ==
               "#{missing} evidence records not on this page."

      assert Enum.count(LazyHTML.query(face, ".record-links a")) == length(visible)
    end
  end

  test "skipped and cancelled steps never read as done, and a waiting step says so" do
    work = claimed!()
    goal!(work, "skip", "Skip the optional cleanup", %{"required" => false})
    goal!(work, "cancel", "Restart the workers")
    goal!(work, "wait", "Wait for the rollout")
    state!(work, "skip", "excluded", %{"detail" => "Nothing to clean."})
    state!(work, "cancel", "cancelled")
    state!(work, "wait", "waiting", %{"detail" => "The rollout finishes at 10:00."})

    {detail, _html} = rendered(work.episode)

    assert Enum.map(detail.trace.work_plan.steps, & &1.status) == [
             "Skipped",
             "Cancelled",
             "Waiting"
           ]
  end

  test "a request with no goals has no Work plan card" do
    work = claimed!()
    evidence!(work, "nodes", %{})

    {detail, html} = rendered(work.episode)
    refute Enum.any?(detail.trace.steps, &(&1.stage == "Work plan"))
    assert detail.trace.work_plan == nil
    refute html =~ "Work plan"
  end

  defp claimed! do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _session} = WorkSessions.pin_episode(episode.id, "plan-test", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("plan-test", 60, :work)
    %{episode: episode, turn: claim.turn}
  end

  defp goal!(work, id, outcome, overrides \\ %{}) do
    {:ok, record} =
      Records.create(
        Records.token(work.turn),
        "goal-#{id}",
        "goal",
        Map.merge(
          %{
            "authority" => "read_only",
            "completion_contract" => "Current evidence supports a bounded conclusion.",
            "id" => id,
            "kind" => "check",
            "prerequisite_goal_ids" => [],
            "read_only_repositories" => [],
            "requested_outcome" => outcome,
            "required" => true,
            "stage" => "implementation",
            "writable_repository" => nil
          },
          overrides
        )
      )

    record
  end

  defp state!(work, goal_id, state, extra \\ %{}) do
    {:ok, record} =
      Records.create(
        Records.token(work.turn),
        "goal-state-#{goal_id}-#{state}",
        "goal_state",
        Map.merge(%{"goal_id" => goal_id, "state" => state}, extra)
      )

    record
  end

  defp evidence!(work, claim, extra) do
    {:ok, record} =
      Records.create(
        Records.token(work.turn),
        "evidence-#{claim}",
        "evidence",
        Map.merge(
          %{
            "claim_id" => claim,
            "observation" => "All three nodes report ready.",
            "source_name" => "Nomad",
            "source_type" => "monitoring"
          },
          extra
        )
      )

    record
  end

  defp step_texts(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".work-plan-summary .plan-step")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp rendered(episode) do
    {:ok, detail} = EpisodeProjection.fetch(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    html =
      render_component(&EpisodePage.render/1,
        snapshot: detail,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    {detail, html}
  end
end

defmodule Ryker.ControlPlane.WorkPlanCardTest do
  @moduledoc """
  The Work plan card: a request's goals as one card of compact steps.

  The timeline drew every planned goal and every goal update as a card of its
  own, so two related steps became a stack of large panels whose details
  explained record fields, and a goal's completion criteria read like a
  result already achieved. Andrew approved one Work plan card (2026-10-15):
  each step's outcome and status in words, what finishes it, its result and
  evidence once done. Plan history keeps criteria, progress and earlier attempts
  in bounded inner items, not the old database-field dump.
  """
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, EpisodeTrace, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Work.Custody

  test "a request's goals and their updates are one Work plan card with each step's latest status" do
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")
    goal!(work, "double-check", "Double-check the findings")
    evidence = evidence!(work, "nodes", %{"target" => "Nomad nodes"})
    state!(work, "check-health", "working")

    state!(work, "check-health", "completed", %{
      "detail" => "Every node reports ready.",
      "evidence_refs" => [evidence.ref]
    })

    state!(work, "double-check", "blocked", %{"detail" => "The monitoring API refused the query."})

    {detail, html} = rendered(work.episode)

    assert [plan] = Enum.filter(detail.trace.steps, &(&1.stage == "Work plan"))
    refute Enum.any?(detail.trace.steps, &(&1.stage == "Plan"))
    refute Enum.any?(detail.trace.steps, &String.starts_with?(&1.title || "", "Goal"))

    assert Enum.map(plan.plan.steps, &{&1.title, &1.status}) == [
             {"Check infrastructure health", "Done"},
             {"Double-check the findings", "Blocked"}
           ]

    document = LazyHTML.from_document(html)
    assert document |> LazyHTML.query(".work-plan") |> Enum.count() == 1
    steps = LazyHTML.query(document, ".work-plan .plan-step")
    assert Enum.count(steps) == 2

    [done, blocked] = Enum.map(steps, &LazyHTML.text/1)
    assert done =~ "Every node reports ready."
    assert blocked =~ "The monitoring API refused the query."

    assert document
           |> LazyHTML.query(".work-plan .plan-step a[href='#event-record-#{evidence.id}']")
           |> LazyHTML.text() == "Nomad nodes"
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
    fold = LazyHTML.query(document, ".plan-steps .plan-evidence")
    assert fold |> LazyHTML.query("summary") |> LazyHTML.text() =~ "4 evidence records"
    assert Enum.count(LazyHTML.query(fold, "a")) == 4

    for record <- evidence do
      assert LazyHTML.query(fold, "a[href='#event-record-#{record.id}']") |> Enum.count() == 1
    end
  end

  # The history was a database field dump: IDs and enums overwhelmed the
  # criteria and actual progress, even after opening its human-facing label.
  test "goal history separates criteria and progress without displaying bookkeeping IDs" do
    work = claimed!()
    goal = goal!(work, "check-health", "Check infrastructure health")
    state!(work, "check-health", "working")

    {_detail, html} = rendered(work.episode)
    document = LazyHTML.from_document(html)

    face = LazyHTML.query(document, ".work-plan .plan-steps")
    refute LazyHTML.text(face) =~ ~r/read only/i
    assert face |> LazyHTML.query("[data-copy-value]") |> Enum.count() == 0

    details = LazyHTML.query(document, ".work-plan details")
    history = LazyHTML.text(details)
    assert history =~ "Plan history"
    assert history =~ "Read-only check"
    assert history =~ "Done when"
    assert history =~ "Current evidence supports a bounded conclusion."
    assert history =~ "In progress"
    refute history =~ goal.ref
    refute history =~ goal.operation_id
    refute history =~ "Membership"
    refute history =~ "Goal ID"
    refute history =~ "Operation"
    assert Enum.count(LazyHTML.query(details, ".ui-knowledge-item")) == 1

    assert LazyHTML.attribute(LazyHTML.query(details, ".ui-knowledge-item"), "data-record-ref") ==
             [goal.ref]

    assert Enum.empty?(LazyHTML.query(details, "button, .identifier"))
  end

  # A repeated check after changed work is a new attempt; the one it replaces
  # keeps its result but is never counted as the work's.
  test "a repeated attempt takes its predecessor's place, and the earlier attempt stays in the history" do
    work = claimed!()
    goal!(work, "check-health", "Check infrastructure health")

    state!(work, "check-health", "completed", %{
      "detail" => "Every node was ready before the change."
    })

    goal!(work, "check-health-2", "Check infrastructure health again", %{
      "successor_of" => "check-health"
    })

    {detail, html} = rendered(work.episode)
    assert [plan] = Enum.filter(detail.trace.steps, &(&1.stage == "Work plan"))
    assert [%{title: "Check infrastructure health again", attempt: 2}] = plan.plan.steps

    assert [step] = step_texts(html)
    assert step =~ "Attempt 2"
    refute step =~ "Every node was ready before the change."

    history =
      html |> LazyHTML.from_document() |> LazyHTML.query(".work-plan details") |> LazyHTML.text()

    assert history =~ "Earlier attempt"
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
    [plan] = Enum.filter(trace.steps, &(&1.stage == "Work plan"))
    missing = Enum.find(plan.plan.steps, &(&1.goal_id == "earlier-goal"))
    assert missing.title == "Goal details not on this page"
    assert missing.detail == "The earlier deployment is healthy."
    assert missing.evidence == [%{href: nil, title: "Evidence not on this page"}]

    later = Enum.find(plan.plan.steps, &(&1.goal_id == "later-goal"))
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

      face = LazyHTML.query(document, ".work-plan .plan-steps")
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
    assert [plan] = Enum.filter(detail.trace.steps, &(&1.stage == "Work plan"))

    assert Enum.map(plan.plan.steps, & &1.status) == ["Skipped", "Cancelled", "Waiting"]
  end

  test "a request with no goals has no Work plan card" do
    work = claimed!()
    evidence!(work, "nodes", %{})

    {detail, html} = rendered(work.episode)
    refute Enum.any?(detail.trace.steps, &(&1.stage == "Work plan"))
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
    |> LazyHTML.query(".work-plan .plan-step")
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

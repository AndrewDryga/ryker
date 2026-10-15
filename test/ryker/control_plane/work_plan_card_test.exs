defmodule Ryker.ControlPlane.WorkPlanCardTest do
  @moduledoc """
  The Work plan card: a request's goals as one card of compact steps.

  The timeline drew every planned goal and every goal update as a card of its
  own, so two related steps became a stack of large panels whose details
  explained record fields, and a goal's completion criteria read like a
  result already achieved. Andrew approved one Work plan card (2026-10-15):
  each step's outcome and status in words, what finishes it, its result and
  evidence once done, and everything technical under Details and history,
  where Read only stays.
  """
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ModelRequests}
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

  # Andrew rejected promoting Read only into the card (2026-10-15).
  test "authority, kind and record IDs stay under Details and history, with every change" do
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
    assert history =~ "Details and history"
    assert history =~ "read only"
    assert history =~ "check"
    assert history =~ "In progress"
    assert details |> LazyHTML.query("[data-copy-value='#{goal.ref}']") |> Enum.count() == 1
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

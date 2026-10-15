defmodule Ryker.ControlPlane.ObservationsCardTest do
  @moduledoc """
  The Observations card: evidence a turn recorded, one compact row each.

  Every evidence record was a large "Evidence recorded" card with its own
  heading, time and Details panel, so a short batch of observations became a
  long stack of repeated framing and the facts, sources, measurement times and
  limits were hard to scan. Andrew approved one Observations card with
  compact rows that open (2026-10-15).
  """
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, EpisodeTrace, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Work.Custody

  test "evidence a turn wrote one after another is one Observations card, a row per record" do
    work = claimed!()
    first = evidence!(work, "ingress", %{"target" => "Ingress"})
    second = evidence!(work, "nodes", %{"target" => "Nomad nodes"})
    third = evidence!(work, "disk", %{"target" => "Disk usage"})

    {detail, html} = rendered(work.episode)

    assert [card] = Enum.filter(detail.trace.steps, &(&1.stage == "Observations"))
    assert Enum.map(card.observations, & &1.area) == ["Ingress", "Nomad nodes", "Disk usage"]
    refute Enum.any?(detail.trace.steps, &(&1.stage == "Evidence"))

    document = LazyHTML.from_document(html)
    refute html =~ "Evidence recorded"

    # Each row keeps its record's anchor, so links to the evidence still land.
    for record <- [first, second, third] do
      assert document
             |> LazyHTML.query(".observations #event-record-#{record.id}.observation-row")
             |> Enum.count() == 1
    end
  end

  test "a row shows when the evidence was measured, never when it was written down" do
    work = claimed!()

    evidence!(work, "measured", %{
      "target" => "Ingress",
      "observed_at" => "2026-10-15T09:14:00Z",
      "freshness" => "Last five minutes"
    })

    evidence!(work, "unmeasured", %{"target" => "Workers"})

    {_detail, html} = rendered(work.episode)
    [measured, unmeasured] = row_summaries(html)

    assert measured =~ "Nomad · Measured 15 Oct, 09:14 UTC · Last five minutes"
    refute unmeasured =~ "Measured"
    assert row_bodies(html) |> List.last() =~ "Not recorded"
  end

  test "a limit on what a check covers stays on the row before it is opened" do
    work = claimed!()

    evidence!(work, "ingress", %{
      "target" => "Ingress",
      "scope_note" => "Only the public ingress was checked, not internal services."
    })

    {_detail, html} = rendered(work.episode)
    assert [summary] = row_summaries(html)
    assert summary =~ "Only the public ingress was checked, not internal services."
  end

  # Zero errors, a responding endpoint or health_effect none prove nothing
  # about overall health, so none of them is shown as a verdict.
  test "a problem or an unknown is said in words, and health effect none says nothing" do
    work = claimed!()
    evidence!(work, "unhealthy", %{"target" => "Database", "health_effect" => "unhealthy"})
    evidence!(work, "unknown", %{"target" => "Queue", "health_effect" => "unknown"})
    evidence!(work, "none", %{"target" => "Ingress", "health_effect" => "none"})
    evidence!(work, "contradicts", %{"target" => "Alert", "relation" => "contradicts"})

    {_detail, html} = rendered(work.episode)
    [unhealthy, unknown, none, contradicts] = row_summaries(html)

    assert unhealthy =~ "Unhealthy"
    assert unknown =~ "Unknown"
    refute none =~ ~r/healthy|none/i
    assert contradicts =~ "Contradicts its claim"
    refute html =~ ~r/all healthy/i
  end

  test "an observation that replaces another keeps the earlier one reachable" do
    work = claimed!()
    earlier = evidence!(work, "earlier", %{"target" => "Ingress"})

    evidence!(work, "later", %{
      "target" => "Ingress, checked again",
      "supersedes" => [earlier.ref]
    })

    {_detail, html} = rendered(work.episode)

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(".observation-body a[href='#event-record-#{earlier.id}']")
           |> Enum.count() == 1
  end

  test "a request without evidence has no Observations card" do
    work = claimed!()
    {detail, html} = rendered(work.episode)

    refute Enum.any?(detail.trace.steps, &(&1.stage == "Observations"))
    refute html =~ "Observations"
  end

  # Grouping a whole request's evidence would read as a summary of work it
  # was not part of: other work between two pieces of evidence, or another
  # turn, starts a card of its own.
  test "evidence with other work between it, or from another turn, starts its own card" do
    steps = [
      evidence_step("a", {:turn, "one"}),
      evidence_step("b", {:turn, "one"}),
      %{id: "tool-1", stage: "Tool call", owner: {:turn, "one"}},
      evidence_step("c", {:turn, "one"}),
      evidence_step("d", {:turn, "two"})
    ]

    assert [
             %{stage: "Observations", observations: [%{area: "a"}, %{area: "b"}]},
             %{stage: "Tool call"},
             %{stage: "Observations", observations: [%{area: "c"}]},
             %{stage: "Observations", observations: [%{area: "d"}]}
           ] = EpisodeTrace.Work.observations(steps)
  end

  defp evidence_step(area, owner) do
    %{
      id: "record-#{area}",
      stage: "Evidence",
      owner: owner,
      band: :work,
      at: ~U[2026-10-15 09:00:00.000000Z],
      observation: %{id: "record-#{area}", area: area}
    }
  end

  defp claimed! do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, _session} =
      WorkSessions.pin_episode(episode.id, "observations-test", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("observations-test", 60, :work)
    %{episode: episode, turn: claim.turn}
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

  defp row_summaries(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".observation-row > summary")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp row_bodies(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".observation-row .observation-body")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
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

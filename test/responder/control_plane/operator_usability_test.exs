defmodule Responder.ControlPlane.OperatorUsabilityTest do
  alias Responder.ControlPlane.AuditHTML
  alias Responder.ControlPlane.UsageChart
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.HTML

  # Operators could not tell what recovery would do; internal queue terms were
  # exposed as the primary action on failed deliveries and workspace cleanup.
  test "failed operations explain recovery without exposing queue jargon" do
    html =
      HTML.failures([
        %{
          kind: "delivery",
          ref: "delivery:one",
          action: :rearm,
          status: "blocked",
          summary: "Slack rate limit",
          updated_at: nil
        }
      ])
      |> IO.iodata_to_binary()

    assert html =~ "Retry delivery"
    assert html =~ "Needs attention"
    refute html =~ ">Rearm"
    assert html =~ "/rearm"
    refute html =~ "<th>Reference</th>"
    assert html =~ "Inspect cause"
  end

  test "working copies do not present the repository name as a retention reason" do
    html =
      HTML.workspaces([
        %{
          action: nil,
          ref: "session:1",
          status: :discarded,
          state: :complete,
          summary: "emisar",
          repository: "emisar",
          updated_at: ~U[2026-09-05 12:00:00Z]
        }
      ])
      |> IO.iodata_to_binary()

    assert html =~ "Working copy removed"
    assert html =~ "05 Sep, 12:00 UTC"
    refute html =~ ">emisar</span>"
  end

  test "failure detail leads with the interrupted operation and keeps opaque IDs secondary" do
    html =
      HTML.failure(%{
        kind: "retention",
        ref: "session:one",
        episode_ref: "episode:one",
        status: "blocked",
        summary: "coop_error",
        destination: "control_plane:control-plane:lab:one / control-plane:lab:one",
        updated_at: ~U[2026-09-05 12:00:00Z]
      })
      |> IO.iodata_to_binary()

    assert html =~ "<h2>Working-copy cleanup stopped</h2>"
    assert html =~ "Open request"
    assert html =~ "Conversation Lab"
    assert html =~ "<details><summary>Technical record</summary>"
    refute html =~ ">Custody reference</dt>"
  end

  test "search has an accessible label without an extra visible column" do
    html = HTML.repositories([]) |> IO.iodata_to_binary()
    assert html =~ "class=\"sr-only\" for=\"operator-search\""
  end

  test "daily graph keeps missing days on the time axis and exposes exact values without hover" do
    days = [
      %{date: ~D[2026-09-01], tokens: 1000, attempts: 2, measured: 2},
      %{date: ~D[2026-09-03], tokens: 2000, attempts: 3, measured: 2}
    ]

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    assert html =~ "<svg"
    assert html =~ "2026-09-02"
    assert html =~ "1,000"
    assert html =~ "Daily values"
    assert html =~ "No executions"
  end

  # Four bars for 2-5 September were labelled 2, 4, 5: the operator read the
  # unlabelled third day as missing data, even though it had executions.
  test "short daily charts label every day without a standing disclaimer" do
    days =
      for day <- 2..5,
          do: %{date: Date.new!(2026, 9, day), tokens: 1000, attempts: 1, measured: 1}

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    labels = Regex.scan(~r/<text class="chart-axis"[^>]*>([^<]+)<\/text>/, html)
    assert Enum.any?(labels, fn [_, label] -> label == "03 Sep" end)
    refute html =~ "empty days remain on the axis"
  end

  test "sparse multi-year usage cannot expand into an unbounded daily chart" do
    days = [
      %{date: ~D[2000-01-01], tokens: 1000, attempts: 2, measured: 2},
      %{date: ~D[2026-09-05], tokens: 2000, attempts: 3, measured: 2}
    ]

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    assert length(Regex.scan(~r/<rect /, html)) <= 366
    assert html =~ "latest 366 calendar days"
  end

  test "different requests in one repository remain distinguishable before cleanup or audit inspection" do
    rows =
      for title <- ["Investigate portal errors", "Update runner version"] do
        %{
          kind: :input_admitted,
          source: :episode,
          actor: "Responder",
          ref: title,
          episode_ref: title,
          href: "/episodes/" <> URI.encode_www_form(title),
          request_title: title,
          repository: "emisar",
          summary: "emisar",
          status: :discarded,
          state: :complete,
          action: nil,
          updated_at: nil
        }
      end

    for html <- [HTML.workspaces(rows), AuditHTML.render(rows)] do
      html = IO.iodata_to_binary(html)
      assert html =~ ">Investigate portal errors</a>"
      assert html =~ ">Update runner version</a>"
    end
  end

  test "audit leads with the action and linked request rather than a dedupe key" do
    html =
      AuditHTML.render([
        %{
          kind: :delivery_confirmed,
          ref: "episode:one",
          summary: "dedupe-internal",
          updated_at: ~U[2026-09-05 12:00:00Z],
          source: :episode,
          actor: "Responder",
          target: "episode:one",
          href: "/episodes/episode%3Aone"
        }
      ])
      |> IO.iodata_to_binary()

    assert html =~ "Reply delivered"
    assert html =~ "Open request"
    assert html =~ "Technical record"
    refute html =~ "<h3>dedupe-internal"
  end

  test "routing decisions lead with the chosen response and link to the inspected input" do
    html =
      HTML.decisions([
        %{
          kind: "admission",
          ref: "opaque-decision",
          input_id: "one",
          state: :start_episode,
          status: :decided,
          summary: "slack",
          updated_at: ~U[2026-09-05 12:00:00Z]
        }
      ])
      |> IO.iodata_to_binary()

    assert html =~ "Start work"
    assert html =~ "/admission/one"
    assert html =~ "05 Sep, 12:00 UTC"
    refute html =~ "<dt>ref</dt>"
  end
end

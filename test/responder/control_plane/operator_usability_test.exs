defmodule Responder.ControlPlane.OperatorUsabilityTest do
  alias Responder.ControlPlane.UsageChart
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.HTML

  test "cleanup recovery explains the ownership blocker instead of sending people to a hash" do
    # The real September 2 failure was displayed as coop_error and a hash,
    # encouraging retries that cannot supply the missing ownership proof.
    html =
      HTML.failure(%{
        kind: "retention",
        ref: "session:one",
        episode_ref: "episode:one",
        status: "blocked",
        summary: "coop_error",
        updated_at: nil,
        request_title: "Hi",
        source: "responder",
        action: :rearm,
        attempt_count: 2,
        cleanup_phase: :plan_pending,
        closed_at: ~U[2026-09-02 13:56:40Z],
        discarded_at: nil,
        diagnosis: %{http_status: 409, code: "invalid_session_state", reason: :missing_ownership},
        detail: "stored diagnostic sha256:abc"
      })
      |> IO.iodata_to_binary()

    assert html =~ "Ownership proof is missing"
    assert html =~ "What happened"
    assert html =~ "What to do"
    assert html =~ "Preserve the working copy"
    assert html =~ "Retrying alone will not repair"
    assert html =~ "Check whether removal is safe"
    assert html =~ "HTTP 409"

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("a[href='/episodes/episode%3Aone']")
           |> LazyHTML.text()
           |> String.trim() == "Hi"

    refute html =~ "Inspect the saved error"
    refute html =~ "Resume cleanup…"
    [primary | _] = String.split(html, "<details")
    refute primary =~ "stored diagnostic sha256"
  end

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

    assert html =~ "Working-copy cleanup stopped"
    assert html =~ "Open request"
    assert html =~ "Conversation Lab"
    assert html =~ "<summary>Diagnostic reference</summary>"
    refute html =~ ">Custody reference</dt>"
  end

  test "search has a visible label grouped with its input instead of an extra column" do
    html = HTML.repositories([]) |> IO.iodata_to_binary()

    assert html =~
             "<div class=\"filter-field filter-search\"><label for=\"operator-search\">Search</label><input"
  end

  test "daily graph keeps calendar spacing and accessible values without an extra table" do
    days = [
      %{date: ~D[2026-09-01], tokens: 1000, attempts: 2, measured: 2},
      %{date: ~D[2026-09-03], tokens: 2000, attempts: 3, measured: 2}
    ]

    html = UsageChart.render(days) |> IO.iodata_to_binary()
    assert html =~ "<svg"
    assert html =~ "2026-09-02"
    assert html =~ "1,000"
    refute html =~ "Daily values"
    refute html =~ "<table"
    assert html =~ "02 Sep: 0 tokens"
    assert html =~ "tabindex=\"0\""
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

  test "different requests in one repository remain distinguishable before cleanup" do
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

    html = rows |> HTML.workspaces() |> IO.iodata_to_binary()
    assert html =~ ">Investigate portal errors</a>"
    assert html =~ ">Update runner version</a>"
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

defmodule Responder.ControlPlane.OperatorUsabilityTest do
  alias Responder.ControlPlane.UsageChart
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.HTML

  test "timer subscriptions show their scheduled wake without pretending to watch any source" do
    html =
      HTML.subscriptions([
        %{
          title: "Timed follow-up",
          condition: "Resume work at the scheduled time",
          context_label: "Source context unavailable",
          episode_title: "Follow up on the deployment",
          episode_href: "/episodes/episode%3Atimer",
          source_label: "Timer",
          target_url: nil,
          cursor_digest: nil,
          deadline_at: ~U[2026-09-07 12:15:00Z],
          episode_ref: "episode:timer",
          last_observed_at: nil,
          last_observation_digest: nil,
          matcher_digest: "matcher-digest",
          poll_after: ~U[2026-09-07 12:10:00Z],
          ref: "subscription:timer",
          revision: 1,
          resolution_kind: nil,
          source_kind: nil,
          status: :active,
          trigger_type: "after",
          updated_at: ~U[2026-09-07 12:00:00Z]
        }
      ])
      |> IO.iodata_to_binary()

    assert html =~ "Wait subscriptions"
    assert html =~ "Next wake-up"
    assert html =~ "Timed follow-up"
    assert html =~ "Resume work at the scheduled time"
    refute html =~ ">any<"
    refute html =~ "External event subscriptions"
  end

  test "findings explain their scope and supported creation workflow" do
    html = HTML.findings(%{items: [], total: 0, page: 1, pages: 1}) |> IO.iodata_to_binary()
    assert html =~ "What was found"
    assert html =~ "not a second list of episodes"
    assert html =~ "Ask Responder to investigate"
    refute html =~ "Create finding"
  end

  test "cleanup recovery explains the ownership blocker instead of sending people to a hash" do
    # The real September 2 failure was displayed as coop_error and a hash,
    # encouraging retries that cannot supply the missing ownership proof.
    row = %{
      kind: "retention",
      ref: "session:one",
      episode_ref: "episode:one",
      status: "blocked",
      summary: "coop_error",
      updated_at: nil,
      request_title: "Hi",
      request_state: :complete,
      source: "responder",
      action: :rearm,
      attempt_count: 2,
      cleanup_phase: :plan_pending,
      closed_at: ~U[2026-09-02 13:56:40Z],
      discarded_at: nil,
      diagnosis: %{http_status: 409, code: "invalid_session_state", reason: :missing_ownership},
      detail: "stored diagnostic sha256:abc"
    }

    html = row |> HTML.failure() |> IO.iodata_to_binary()

    assert html =~ "Temporary files could not be removed"
    assert html =~ "The request is complete. Only automatic cleanup failed."
    assert html =~ "Why it stopped"
    assert html =~ "Leave the folder in place for now. Do not retry cleanup."
    assert html =~ "There is no supported recovery command for this older session yet."
    refute html =~ "A developer needs to check the leftover folder"
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
    refute primary =~ "Ownership proof"
    refute primary =~ "HTTP 409"
    refute primary =~ "failure-progress"
    refute primary =~ "Resume cleanup"

    document = LazyHTML.from_document(html)
    assert Enum.count(LazyHTML.query(document, ".failure-diagnostics form button")) == 1

    pending = %{row | request_state: :working} |> HTML.failure() |> IO.iodata_to_binary()
    refute pending =~ "The request is complete"

    work = %{row | kind: "work"} |> HTML.failure() |> IO.iodata_to_binary()
    refute work =~ "Temporary files could not be removed"
    refute work =~ "Only automatic cleanup failed"

    list = [row] |> HTML.failures() |> IO.iodata_to_binary()
    assert list =~ "Cleanup paused"
    refute list =~ "Resume cleanup"

    one_attempt = %{row | kind: "work", attempt_count: 1}

    for rendered <- [HTML.failure(one_attempt), HTML.failures([one_attempt])] do
      text = rendered |> IO.iodata_to_binary() |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert text =~ "1 attempt"
      refute text =~ "1 attempts"
    end
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
    refute html =~ "Needs attention"
    refute html =~ ">Rearm"
    assert html =~ "/rearm"
    refute html =~ "<th>Reference</th>"
    assert html =~ "Inspect cause"
  end

  test "failure summary counts listed operations and distinct requests without nesting the cards" do
    # Two cleanup failures in one request were buried in a second large panel;
    # missing zero counts left it unclear whether other failure types were healthy.
    cleanup = %{
      kind: "retention",
      ref: "session:one",
      episode_ref: "episode:one",
      action: :rearm,
      status: "blocked",
      summary: "coop_error",
      updated_at: nil
    }

    rows = [
      cleanup,
      %{cleanup | ref: "session:two"},
      %{cleanup | kind: "delivery", ref: "delivery:one", episode_ref: "episode:two"},
      %{cleanup | kind: "admission", ref: "input:one", episode_ref: nil}
    ]

    document = rows |> HTML.failures() |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    summary =
      document
      |> LazyHTML.query(".failure-summary > div")
      |> Enum.map(fn stat ->
        {stat |> LazyHTML.query("dt") |> LazyHTML.text(),
         stat |> LazyHTML.query("dd") |> LazyHTML.text()}
      end)

    assert summary == [
             {"Failures", "4"},
             {"Affected requests", "2"}
           ]

    types =
      document
      |> LazyHTML.query(".failure-types > div")
      |> Enum.map(fn stat ->
        {stat |> LazyHTML.query("dt") |> LazyHTML.text(),
         stat |> LazyHTML.query("dd") |> LazyHTML.text()}
      end)

    assert types == [
             {"Model work", "0"},
             {"Routing", "1"},
             {"Delivery", "1"},
             {"Cleanup", "2"},
             {"Slack updates", "0"},
             {"Incident rooms", "0"},
             {"Approvals", "0"}
           ]

    assert Enum.count(LazyHTML.query(document, ".failure-types .has-failures")) == 3

    assert Enum.count(LazyHTML.query(document, ".failure-cards > article")) == 4
    assert Enum.empty?(LazyHTML.query(document, "section"))
    refute LazyHTML.text(document) =~ "These saved operations"
  end

  test "empty failures show zero for every type without a surrounding panel" do
    document = [] |> HTML.failures() |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
    counts = LazyHTML.query(document, ".failure-summary dd, .failure-types dd")
    assert Enum.count(counts) == 9
    assert Enum.all?(counts, &(LazyHTML.text(&1) == "0"))
    assert Enum.empty?(LazyHTML.query(document, ".has-failures"))
    assert LazyHTML.text(document) =~ "Nothing needs attention"
    assert Enum.empty?(LazyHTML.query(document, "section"))
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
    assert html =~ "<summary>Technical details</summary>"
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
end

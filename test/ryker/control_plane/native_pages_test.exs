defmodule Ryker.ControlPlane.NativePagesTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{ActivityPage, Assets, Components, EpisodePage, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  @now ~U[2026-09-05 12:00:00.000000Z]

  test "populated activity preserves filters, source labels, navigation, and scheduled context" do
    items =
      for {state, index} <- Enum.with_index(~w(pending working blocked complete cancelled), 1) do
        {"request-#{index}",
         %{
           kind: "episode",
           href: "/timeline/request-#{index}",
           title: "Investigate <unsafe> #{index}",
           source: if(index == 1, do: "Direct conversation", else: "GitHub"),
           repository: "ryker",
           target: "configured-target",
           state: state,
           bucket: if(state == "complete", do: "done", else: "running"),
           updated_at: @now,
           started_at: DateTime.add(@now, -120)
         }}
      end

    html =
      render_component(&ActivityPage.render/1,
        overview: %{counts: %{active: 2}, fleet: %{eligible_workers: 1, unavailable: true}},
        activity: %{total: 90, page: 2, pages: 3, mode: "all"},
        params: %{"q" => "trace", "repository" => "ryker", "mode" => "all"},
        path: "/activity",
        now: @now,
        stream: items,
        new_items: 2,
        schedules: [
          %{
            ref: "schedule:one",
            title: "Weekly review",
            next_occurrence_at: @now,
            timezone: "UTC"
          }
        ]
      )

    assert html =~ "Investigate &lt;unsafe&gt;"
    assert html =~ "GitHub"
    assert html =~ "2m since received"
    assert html =~ "Page 2 of 3"
    assert html =~ "page=1"
    assert html =~ "page=3"
    assert html =~ "repository=ryker"
    assert html =~ "2 new or reordered items"
    assert html =~ "Weekly review"
    assert html =~ "1 eligible"
    assert html =~ "Worker status is unavailable"
    refute html =~ "<unsafe>"
  end

  test "a filtered empty activity page does not imply the workspace has no conversations" do
    html =
      render_component(&ActivityPage.render/1,
        overview: %{counts: %{}, fleet: %{required: false}},
        activity: %{total: 0, page: 1, pages: 1, mode: "shadow"},
        params: %{"q" => "absent"},
        path: "/",
        now: @now,
        stream: [],
        new_items: 0,
        schedules: []
      )

    assert html =~ "No matching activity"
    assert html =~ "Clear filters"
    refute html =~ "activity-rail"
    refute html =~ "No activity yet"
  end

  test "worker problems remain actionable without filling an empty inbox with decorative widgets" do
    # The old rail hid worker status at tablet widths and showed invented account status.
    for fleet <- [%{required: true, eligible_workers: 0}, %{unavailable: true}] do
      html =
        render_component(&ActivityPage.render/1,
          overview: %{counts: %{}, fleet: fleet},
          activity: %{total: 0, page: 1, pages: 1, mode: "live"},
          params: %{},
          path: "/",
          now: @now,
          stream: [],
          new_items: 0,
          schedules: []
        )

      assert html =~ "Worker attention"
      assert html =~ "Inspect configuration"
      assert html =~ "href=\"/workspaces\""
      assert html =~ "No activity yet"
      refute html =~ "Coming up"
      refute html =~ "Test your ryker"
      refute html =~ "Local operator"
      refute html =~ "empty-orbit"
    end
  end

  test "the episode shows cost coverage, recovery evidence, and confirmed answers together" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    step = List.last(snapshot.trace.steps)

    message = %{
      id: "confirmed",
      actor: "Ryker",
      at: @now,
      status: "Delivery confirmed",
      available: true,
      text: "A retained answer <not markup>",
      href: "model-calls?kind=work&attempt=confirmed"
    }

    trace =
      snapshot.trace
      |> Map.put(:actions, [
        %{
          href: "/actions/episode/example/resolve",
          label: "Close as no longer needed",
          tone: :danger
        }
      ])
      |> Map.put(:source, %{href: "https://slack.com/archives/C123/p123", label: "Open source"})
      |> Map.put(:history, %{truncated: true})
      |> Map.put(:stopped, %{
        headline: "Delivery needs attention",
        reason: "The provider did not confirm delivery",
        action: "Review the retained request before retrying",
        href: "/failures/delivery/example",
        attempted: ["Reconciled the previous request"]
      })
      |> Map.put(:steps, [%{step | href: "/timeline/ingress-input%3Aexample"}])
      |> Map.update!(:case_file, fn file ->
        %{file | conversation: [message], repository: "ryker", reply: message.text}
      end)

    snapshot = %{
      snapshot
      | trace: trace,
        accounting: %{costed: 1, attempts: 2, cost_usd: Decimal.new("0.12")}
    }

    html = episode_html(snapshot)

    assert html =~ "$0.12"
    assert html =~ "1 reported · 0 estimated / 2 requests"
    assert html =~ "Delivery confirmed"
    assert html =~ "A retained answer &lt;not markup&gt;"
    refute html =~ "Inspect accepted answer"
    # A bounded window now names the bound instead of announcing that one exists.
    assert html =~ "Older model calls stay under"
    assert html =~ "Already attempted"
    assert html =~ "Reconciled the previous request"
    assert html =~ "Open recovery"
    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, "a[href^='/actions/']") |> LazyHTML.to_tree() == []

    assert LazyHTML.query(
             document,
             "form[action='/actions/episode/example/resolve'] button.danger[type='submit']"
           )
           |> LazyHTML.text() == "Close as no longer needed"

    assert html =~ "Inspect related record"
    # The split panes hid the processing behind tabs and a second scroll area.
    assert html =~ "Execution timeline"
    assert html =~ "trace-chapter"
    assert html =~ "Getting ready"
    assert LazyHTML.from_fragment(html) |> LazyHTML.text() =~ "The answer"
    refute html =~ "aria-label=\"Episode view\""
    refute html =~ "aria-label=\"Selected event\""
    refute html =~ "phx-click=\"inspect-step\""

    for {state, expected} <- [{:cancelled, "Stopped"}, {:complete, "No further reply was sent"}] do
      terminal = put_in(snapshot, [:episode, :state], state)
      assert episode_html(terminal) =~ expected
    end

    following = put_in(snapshot, [:trace, :stopped], nil)
    assert episode_html(following) =~ "Follow-up in progress"
  end

  # Episode-history retention deletes the kernel events, origins and closed
  # records and stamps the episode. The projection has carried that stamp
  # since 2026-09-13, and without reading it the page showed the pruned
  # episode as an empty timeline: indistinguishable from one that never ran.
  test "pruned episode history reads as retention, not as an empty timeline" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    refute episode_html(snapshot) =~ "history-pruned"

    pruned =
      snapshot
      |> put_in([:episode, :history_pruned_at], @now)
      |> put_in([:trace, :history, :pruned_at], @now)

    document = pruned |> episode_html() |> LazyHTML.from_document()
    notice = LazyHTML.query(document, "#execution-timeline .history-pruned")

    assert LazyHTML.text(notice) =~
             "Execution history was removed by retention on 05 Sep, 12:00 UTC"

    assert LazyHTML.text(notice) =~ "not a request that did nothing"

    assert LazyHTML.query(notice, "time[datetime='2026-09-05T12:00:00.000000Z']") |> Enum.count() ==
             1
  end

  test "elapsed labels remain meaningful across missing, naive, future, and long-lived timestamps" do
    assert Components.age(nil, @now) == "—"
    assert Components.age(DateTime.add(@now, 60), @now) == "0s"
    assert Components.age(DateTime.to_naive(DateTime.add(@now, -61)), @now) == "1m"
    assert Components.age(DateTime.add(@now, -3660), @now) == "1h 1m"
    assert Components.age(DateTime.add(@now, -172_800), @now) == "2d"
    assert Components.timestamp(DateTime.to_naive(@now)) == "05 Sep, 12:00 UTC"

    for {state, expected} <- [
          {"pending", "Queued"},
          {"waiting_for_input", "Needs your input"},
          {"waiting_for_event", "Waiting for an event"},
          {"delivery_pending", "Sending reply"},
          {"ignore", "No response needed"},
          {"react", "Reaction selected"},
          {"reply", "Reply selected"}
        ] do
      assert render_component(&Components.status/1, state: state) =~ expected
    end
  end

  test "timeline offsets include admission before the durable episode was created" do
    # Slow admission happens before episode creation; measuring from creation
    # made that whole wait appear as zero and understated every later offset.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    [step | _] = snapshot.trace.steps

    snapshot =
      snapshot
      |> put_in([:episode, :created_at], @now)
      |> put_in([:trace, :steps], [%{step | band: :ready, at: DateTime.add(@now, -30)}])
      |> put_in([:trace, :case_file, :conversation], [])
      |> Map.update!(:trace, &Map.put(&1, :received_at, DateTime.add(@now, -60)))

    assert episode_html(snapshot) =~ "+30s from start"
  end

  test "the packaged asset allowlist serves local modules but never arbitrary paths" do
    for file <-
          ~w(phoenix.mjs phoenix_live_view.esm.js control-plane.js reading-state.mjs composer.mjs conversation.mjs drafts.mjs filter-toolbar.mjs leave-guard.mjs control-plane.css workspace.css) do
      conn = Assets.call(Plug.Test.conn(:get, "/#{file}"), [])
      assert conn.status == 200
      assert conn.halted
      assert conn.resp_body != ""
    end

    for {method, path} <- [{:get, "/unknown"}, {:get, "/../mix.exs"}, {:post, "/workspace.css"}] do
      assert Assets.call(Plug.Test.conn(method, path), []).status == 404
    end
  end

  defp episode_html(snapshot),
    do:
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        selected_step: nil,
        requests: nil,
        params: %{}
      )
end

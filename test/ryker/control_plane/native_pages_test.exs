defmodule Ryker.ControlPlane.NativePagesTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{ActivityPage, Assets, Components, EpisodePage, EpisodeProjection}
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
           state: state,
           bucket: if(state == "complete", do: "done", else: "running"),
           updated_at: @now,
           started_at: DateTime.add(@now, -120)
         }}
      end

    html =
      render_component(&ActivityPage.render/1,
        overview: %{fleet: %{eligible_workers: 1, unavailable: true}},
        activity: %{total: 90, page: 2, pages: 3, mode: "all"},
        params: %{"q" => "trace", "repository" => "ryker", "mode" => "all"},
        path: "/activity",
        now: @now,
        # As the LiveView draws the list: each row carries its day.
        stream:
          Enum.zip(
            Enum.map(items, &elem(&1, 0)),
            ActivityPage.with_days(Enum.map(items, &elem(&1, 1)), @now)
          ),
        new_items: 2,
        schedules: [schedule("schedule:one", "Weekly review")]
      )

    document = LazyHTML.from_fragment(html)
    assert html =~ "Investigate &lt;unsafe&gt;"
    refute html =~ "<unsafe>"

    # Each request is one Kit row: its name opens the timeline in place, its
    # state is a dot and a word, then where it came from, when and where it ran.
    rows = LazyHTML.query(document, "#activity-stream > article.entity-row.entity-row-link")
    assert Enum.count(rows) == 5

    assert LazyHTML.query(
             rows,
             ".entity-name a[href='/timeline/request-1'][data-phx-link=redirect]"
           )
           |> LazyHTML.text() == "Investigate <unsafe> 1"

    assert Enum.map(LazyHTML.query(rows, ".entity-side .state-word"), fn state ->
             {LazyHTML.attribute(state, "data-tone"), LazyHTML.text(state)}
           end) == [
             {["busy"], "Queued"},
             {["busy"], "Working"},
             {["warn"], "Needs attention"},
             {["off"], "Completed"},
             {["off"], "Stopped"}
           ]

    assert LazyHTML.query(rows, ".entity-meta") |> Enum.at(0) |> LazyHTML.text() =~
             "Direct conversation"

    assert LazyHTML.query(rows, ".entity-meta") |> Enum.at(1) |> LazyHTML.text() =~ "GitHub"
    assert LazyHTML.query(rows, ".entity-meta") |> Enum.at(1) |> LazyHTML.text() =~ "ryker"
    # When is the row's edge, under its day's heading.
    assert LazyHTML.query(rows, ".entity-side time[datetime]") |> Enum.count() == 5
    assert LazyHTML.query(rows, ".entity-group") |> Enum.count() >= 1
    # A search and a repository narrow the list, so its size is what matches.
    assert first_count(document) == "90 matching"

    assert html =~ "Page 2 of 3"
    assert html =~ "page=1"
    assert html =~ "page=3"
    assert html =~ "repository=ryker"
    assert html =~ "2 new or reordered items"

    # Coming up is a section of Kit rows in the Schedules page's own words.
    assert LazyHTML.query(document, "#coming-up .section-head h2") |> LazyHTML.text() ==
             "Coming up"

    assert LazyHTML.query(document, "#coming-up .entity-name a[href='/schedules/schedule%3Aone']")
           |> LazyHTML.text() == "Weekly review"

    assert LazyHTML.query(document, "#coming-up .entity-meta") |> LazyHTML.text() =~
             "Every day at 09:00 UTC"

    # A worker problem is a warning count at the top and a section below.
    assert LazyHTML.query(document, ".kit-counts a.kit-count[href='#workers'][data-tone=warn]")
           |> LazyHTML.text() =~ "worker status"

    assert LazyHTML.query(document, "#workers .entity-name") |> LazyHTML.text() =~
             "Worker status is unknown"

    assert LazyHTML.query(document, "#workers .entity-meta") |> LazyHTML.text() =~
             "last check: 1 worker available"
  end

  test "a filtered empty activity page does not imply the workspace has no conversations" do
    html =
      render_component(&ActivityPage.render/1,
        overview: %{fleet: %{required: false}},
        activity: %{total: 0, page: 1, pages: 1, mode: "shadow", searchable: true},
        params: %{"q" => "absent"},
        path: "/",
        now: @now,
        stream: [],
        new_items: 0,
        schedules: []
      )

    assert html =~ "No matching activity"
    assert html =~ "Clear filters"
    refute html =~ ~r/id="activity-filters-search"[^>]*disabled/
    refute html =~ "id=\"workers\""
    refute html =~ "id=\"coming-up\""
    refute html =~ "No activity yet"
  end

  # Andrew, 2026-09-24, comparing Activity with Incident rooms, Failures,
  # Channels and Working copies: "Look how different all those pages are."
  # Activity had its own framed collection, tab strip, mint links and filled
  # status pills; it now leads with the same counts and toolbar row as every
  # other list page.
  test "activity leads with the counts and toolbar row every list page shares" do
    html =
      render_component(&ActivityPage.render/1,
        overview: %{fleet: %{required: false}},
        activity: %{
          total: 0,
          page: 1,
          pages: 1,
          mode: "live",
          searchable: false,
          views: %{"attention" => 2, "running" => 3, "done" => 0}
        },
        params: %{},
        path: "/",
        now: @now,
        stream: [],
        new_items: 0,
        schedules: []
      )
      |> LazyHTML.from_fragment()

    counts = LazyHTML.query(html, ".activity-page > .kit-counts > .kit-count")

    assert Enum.map(counts, fn count ->
             {count |> LazyHTML.query("b") |> LazyHTML.text(),
              count |> LazyHTML.text() |> String.split() |> tl() |> Enum.join(" "),
              count |> LazyHTML.attribute("href") |> List.first()}
           end) == [
             {"0", "requests", nil},
             {"3", "in progress", "/?filter=running"},
             {"2", "need you", "/?filter=attention"}
           ]

    assert LazyHTML.query(html, ".kit-count[data-tone=warn]") |> LazyHTML.text() =~ "need you"
    assert LazyHTML.query(html, ".kit-count[data-phx-link=patch]") |> Enum.count() == 2

    refute LazyHTML.query(html, ".activity-pulse, .collection-shell, .page-summary")
           |> Enum.any?()

    toolbar = LazyHTML.query(html, ".activity-page > .kit-toolbar")
    assert Enum.count(toolbar) == 1

    assert LazyHTML.query(toolbar, "#activity-filters-toolbar.filter-toolbar") |> Enum.count() ==
             1

    assert LazyHTML.query(toolbar, "nav.segmented a[data-phx-link=patch]")
           |> Enum.map(&LazyHTML.text/1) == ["All", "Needs you", "In progress", "Finished"]

    assert LazyHTML.query(toolbar, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
             "All"

    # The list's size is the first count, never a second number in the toolbar.
    refute LazyHTML.text(toolbar) =~ ~r/\d+ (items?|requests?)/

    assert LazyHTML.query(html, ".kit-empty .kit-empty-title") |> LazyHTML.text() ==
             "No activity yet"

    assert LazyHTML.query(html, "#activity-filters-search[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(html, "#activity-mode[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(html, "#filter-add[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(html, ".search-field.filter-control") |> Enum.count() == 1
    assert LazyHTML.query(html, "#activity-mode.filter-control") |> Enum.count() == 1
    assert LazyHTML.query(html, "#filter-add.filter-control") |> Enum.count() == 1
  end

  test "worker problems remain actionable without filling an empty inbox with decorative widgets" do
    # The old rail hid worker status at tablet widths and showed invented account status.
    for fleet <- [%{required: true, eligible_workers: 0}, %{unavailable: true}] do
      html =
        render_component(&ActivityPage.render/1,
          overview: %{fleet: fleet},
          activity: %{total: 0, page: 1, pages: 1, mode: "live", searchable: false},
          params: %{},
          path: "/",
          now: @now,
          stream: [],
          new_items: 0,
          schedules: []
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, ".kit-count[href='#workers'][data-tone=warn]")
             |> Enum.count() == 1

      # The row carries its two buttons, so its state sits beside its name.
      assert LazyHTML.query(document, "#workers h3.entity-name .state-word[data-tone=warn]")
             |> Enum.count() == 1

      assert LazyHTML.query(document, "#workers a[href='/settings/advanced']") |> Enum.count() ==
               1

      assert LazyHTML.query(document, "#workers a[href='/working-copies']") |> Enum.count() == 1
      assert html =~ "No activity yet"
      refute html =~ "Coming up"
      refute html =~ "Test your ryker"
      refute html =~ "Local operator"
      refute html =~ "empty-orbit"
    end
  end

  # Andrew, 2026-09-25: the toolbar's "18 items" said again what the counts
  # above it said. How many requests the list holds is now said once, as the
  # first count, and it says "matching" whenever a search, a filter or a view
  # narrows the list, so a narrowed list never reads as everything Ryker got.
  test "activity says how many requests it lists once, as its first count" do
    for {params, total, first} <- [
          {%{}, 18, "18 requests"},
          {%{}, 1, "1 request"},
          {%{"mode" => "all"}, 40, "40 requests"},
          {%{"q" => "deploy"}, 5, "5 matching"},
          {%{"repository" => "ryker"}, 3, "3 matching"},
          {%{"filter" => "attention"}, 2, "2 matching"},
          {%{"usage_model" => "gpt-5.6-sol", "usage_window" => "7d"}, 7, "7 matching"}
        ] do
      document = activity_document(params, total)
      assert first_count(document) == first, inspect(params)
      assert LazyHTML.query(document, ".kit-counts > .kit-count") |> Enum.count() == 3
      refute LazyHTML.query(document, ".kit-toolbar") |> LazyHTML.text() =~ ~r/\d+ (items?|req)/
    end
  end

  # Andrew, 2026-09-25: "+ Filter" sat between the work select and the views,
  # splitting the controls every visit uses with the one that adds a custom
  # filter. The row now reads search, work included, the four views, then the
  # custom filters: each applied chip and "+ Filter" with its menu.
  test "activity's custom filters come after the view switch, with their menu" do
    document = activity_document(%{"repository" => "ryker"}, 3, "fields")
    [toolbar] = LazyHTML.query(document, ".activity-page > .kit-toolbar") |> Enum.to_list()
    html = LazyHTML.to_html(toolbar)

    order =
      Enum.map(
        [
          ~s(id="activity-filters-search"),
          ~s(id="activity-mode"),
          ~s(class="segmented"),
          ~s(data-filter="repository"),
          ~s(id="filter-add")
        ],
        &(:binary.match(html, &1) |> elem(0))
      )

    assert order == Enum.sort(order)
    assert LazyHTML.query(toolbar, "#activity-filters-toolbar #request-filters") |> Enum.empty?()
    assert LazyHTML.query(toolbar, ".filter-add-wrap > #filter-popover") |> Enum.count() == 1

    assert LazyHTML.query(toolbar, "#filter-popover .filter-field[data-field=state]")
           |> LazyHTML.text() == "State"
  end

  # QA, 2026-09-25, at 390px: Learning's outcome views scrolled "Sources
  # changed" out of sight as "Sources c…", with nothing saying more was
  # there. On a phone a toolbar's views wrap onto another line instead.
  test "a toolbar's views wrap on a phone instead of scrolling out of sight" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    phone =
      ~r/@media\s*\(max-width:\s*(\d+)px\)\s*\{((?:[^{}]*\{[^{}]*\})*[^{}]*)\}/
      |> Regex.scan(css, capture: :all_but_first)
      |> Enum.filter(fn [width, _rules] -> String.to_integer(width) >= 390 end)
      |> Enum.map_join("\n", &List.last/1)

    assert phone =~
             ~r/\.kit-toolbar \.segmented\s*\{[^}]*flex-wrap:\s*wrap[^}]*overflow:\s*visible/,
           "no phone rule wraps a toolbar's views"
  end

  # Moving the custom filters after the view switch took them out of the
  # search form's `.filter-toolbar`, whose control finish every chip and
  # "+ Filter" wore: without it "+ Filter" turns bold on another ground and
  # border than the select beside it. Every rule that finishes a control in
  # the search form finishes the custom filters too.
  test "activity's custom filters keep the search form's control finish" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    selectors =
      ~r/([^{}]+)\{/
      |> Regex.scan(css, capture: :all_but_first)
      |> Enum.map(fn [selector] -> String.trim(selector) end)
      |> Enum.filter(
        &(&1 =~ ~r/\.filter-toolbar\s+\.filter-(control|clear)\b/ or
            &1 =~ ~r/:is\(\.filter-toolbar,/)
      )

    assert selectors != []

    for selector <- selectors,
        do:
          assert(selector =~ ".filter-toolbar-controls", "#{selector} misses the custom filters")
  end

  defp activity_document(params, total, menu \\ nil) do
    render_component(&ActivityPage.render/1,
      overview: %{fleet: %{required: false}},
      activity: %{
        total: total,
        page: 1,
        pages: 1,
        mode: params["mode"] || "live",
        views: %{"attention" => 0, "running" => 1, "done" => 0}
      },
      params: params,
      path: "/activity",
      now: @now,
      stream: [],
      new_items: 0,
      schedules: [],
      filter_menu: menu
    )
    |> LazyHTML.from_fragment()
  end

  defp first_count(document) do
    document
    |> LazyHTML.query(".kit-counts > .kit-count")
    |> Enum.at(0)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # One active schedule as the Schedules projection lists it.
  defp schedule(ref, title) do
    %{
      authority: :read_only,
      destination_conversation_ref: "slack:T123:C456",
      destination_thread_ref: nil,
      destination_transport: "slack",
      expires_at: nil,
      expires_local: nil,
      failures: 0,
      next_local: ~N[2026-09-06 09:00:00],
      next_occurrence_at: ~U[2026-09-06 09:00:00Z],
      now_local: ~N[2026-09-05 12:00:00],
      once_local: nil,
      recurrence: %{"kind" => "daily", "time" => "09:00:00"},
      ref: ref,
      repository: nil,
      status: :active,
      task: "Summarize the week.",
      timezone: "UTC",
      title: title,
      updated_at: @now
    }
  end

  test "the episode shows cost coverage, recovery evidence, and confirmed answers together" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
    step = List.last(snapshot.trace.steps)

    message = %{
      id: "confirmed",
      actor: "Ryker",
      at: @now,
      status: "Delivery confirmed",
      available: true,
      text: "A retained answer <not markup>",
      href: "#request-confirmed"
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
    # The cost is one figure; its coverage no longer hides behind a disclosure
    # larger than its one line.
    refute html =~ "1 reported · 0 estimated / 2 requests"
    assert html =~ "Delivery confirmed"
    assert html =~ "A retained answer &lt;not markup&gt;"
    refute html =~ "Inspect accepted answer"
    # A bounded window now names the bound instead of announcing that one exists.
    assert html =~ "Long artifacts are labeled when truncated"
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
    assert html =~ "Before the first message"
    assert LazyHTML.from_fragment(html) |> LazyHTML.text() =~ "Answer"
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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

  test "a naive timestamp and every episode state read in the page's words" do
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
          ~w(phoenix.mjs phoenix_live_view.esm.js control-plane.js copy-value.mjs reading-state.mjs composer.mjs conversation.mjs drafts.mjs elapsed-time.mjs filter-toolbar.mjs leave-guard.mjs control-plane.css workspace.css) do
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

defmodule Ryker.ControlPlane.SubscriptionsPageTest do
  @moduledoc """
  Automations › Follow-ups: work Ryker paused and will pick up again at a set
  time or when something happens. Each row says what it waits for, which
  request it continues and when, in words; the identifiers support needs stay
  in one closed Details disclosure.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Navigation, Pages, SubscriptionsPage}
  alias Ryker.Fixtures.ControlPlaneOptions

  @now ~U[2026-09-10 10:00:00Z]

  setup do
    # The live page once reduced exact Terraform-run follow-ups to nine
    # columns of IDs and digests. These fields come from the saved run
    # matcher, not a claim that the run was approved or has finished.
    %{item: item_fixture()}
  end

  test "a full list says it shows only the first 100 follow-ups" do
    # The list stopped at 100 rows without a word, so a follow-up past the
    # cut looked as if it did not exist.
    options = ControlPlaneOptions.options(self())
    [item] = options.projection.subscriptions.(%{})
    items = for index <- 1..100, do: %{item | ref: "event-subscription:#{index}"}
    options = put_in(options, [:projection, :subscriptions], fn _params -> items end)

    assert Pages.page(["follow-ups"], %{}, options).body =~ "Showing the first 100 follow-ups."
  end

  test "a row says what it waits for, which request it continues, when, and where", %{
    item: item
  } do
    row =
      row(%{item | poll_after: DateTime.add(@now, 2_400), deadline_at: ~U[2026-09-26 12:00:00Z]})

    assert LazyHTML.query(row, ".entity-name") |> LazyHTML.text() |> String.trim() =~
             "An update on Run run-t2W6yCNeLUU9xFso"

    assert LazyHTML.query(row, ".entity-side .state-word[data-tone=busy]") |> LazyHTML.text() ==
             "Waiting"

    text = LazyHTML.query(row, ".entity-text")
    assert words(text) == "Continues: Review the portal deployment"

    assert LazyHTML.query(text, "a[href='/timeline/episode%3Arun-monitor']") |> LazyHTML.text() ==
             "Review the portal deployment"

    assert words(LazyHTML.query(row, ".entity-meta")) ==
             "when a matching update arrives · next check in 40 minutes · stops waiting 26 Sep · in #infra · repository emisar"

    assert LazyHTML.query(row, ".entity-meta strong") |> Enum.map(&LazyHTML.text/1) == [
             "#infra",
             "emisar"
           ]
  end

  test "timing advances with the clock while the exact UTC time stays one hover away", %{
    item: item
  } do
    at = ~U[2026-09-10 10:00:00Z]

    item = %{
      item
      | title: "Timer",
        condition: nil,
        trigger_type: "at",
        poll_after: at,
        deadline_at: DateTime.add(at, 600)
    }

    future = row(item, DateTime.add(at, -300))
    due = row(item, at)
    late = row(item, DateTime.add(at, 300))

    for {document, text} <- [
          {future, "in 5 minutes"},
          {due, "due now"},
          {late, "overdue by 5 minutes"}
        ] do
      time = LazyHTML.query(document, ".entity-meta time[datetime='2026-09-10T10:00:00Z']")
      assert LazyHTML.text(time) == text
      assert LazyHTML.attribute(time, "title") == ["10 Sep 2026, 10:00 UTC"]
    end

    # A timer continues at its moment; its deadline is only a safety net.
    refute words(LazyHTML.query(future, ".entity-meta")) =~ "stops waiting"

    # The Details disclosure keeps its identity across a refresh, so an open
    # one stays open.
    assert LazyHTML.query(future, "details") |> LazyHTML.attribute("id") ==
             LazyHTML.query(due, "details") |> LazyHTML.attribute("id")
  end

  test "support references stay in one closed Details disclosure with copy buttons", %{
    item: item
  } do
    details = row(item) |> LazyHTML.query("details.follow-up-details:not([open])")

    assert LazyHTML.query(details, "summary") |> LazyHTML.text() |> String.trim() == "Details"

    assert LazyHTML.query(details, "summary") |> LazyHTML.attribute("aria-label") == [
             "Details for An update on Run run-t2W6yCNeLUU9xFso"
           ]

    assert details
           |> LazyHTML.query("button[data-copy-value]")
           |> LazyHTML.attribute("data-copy-value") ==
             [item.ref]

    assert LazyHTML.text(details) =~ "Follow-up ID"
    assert LazyHTML.text(details) =~ "Source revision"
    assert LazyHTML.text(details) =~ "attachment title: Run Planning"
    refute LazyHTML.text(details) =~ item.matcher_digest

    # A follow-up that gave up keeps the digests that explain why.
    timed_out = %{
      item
      | status: :timed_out,
        resolution_kind: :deadline,
        cursor_digest: String.duplicate("c", 64),
        last_observation_digest: String.duplicate("o", 64)
    }

    text = row(timed_out) |> LazyHTML.query("details") |> LazyHTML.text()
    assert text =~ "Matcher reference"
    assert text =~ "Cursor reference"
    assert text =~ "Observation reference"
  end

  test "each state reads as a word people use, and history says what happened", %{item: item} do
    at = DateTime.add(@now, -7_200)

    for {status, resolution, trigger, tone, word, meta, lead} <- [
          {:active, nil, "source_event", "busy", "Waiting", "when a matching update arrives",
           "Continues"},
          {:resolved, :input, "source_event", "off", "Resumed", "update arrived 2 hours ago",
           "Continued"},
          {:resolved, :poll_fallback, "source_event", "off", "Resumed",
           "checked again 2 hours ago", "Continued"},
          {:resolved, :timer, "after", "off", "Resumed", "timer fired 2 hours ago", "Continued"},
          {:timed_out, :deadline, "source_event", "warn", "Deadline passed",
           "gave up 2 hours ago", "Continued"},
          {:cancelled, :cancelled, "source_event", "off", "Cancelled", "cancelled 2 hours ago",
           "Part of"}
        ] do
      document =
        row(%{
          item
          | status: status,
            resolution_kind: resolution,
            trigger_type: trigger,
            last_observed_at: at
        })

      state = LazyHTML.query(document, ".entity-side .state-word")
      assert LazyHTML.text(state) == word, inspect(status)
      assert LazyHTML.attribute(state, "data-tone") == [tone], inspect(status)
      assert words(LazyHTML.query(document, ".entity-meta")) =~ meta, inspect(status)
      assert words(LazyHTML.query(document, ".entity-text")) =~ lead <> ":", inspect(status)
    end
  end

  test "nothing on the page calls a follow-up a wait", %{item: item} do
    # The page was "Waits" until 2026-09-24, and its rows, count, empty states
    # and disclosures named the thing a wait ("1 wait", "Wait details", "Wait
    # ID", "Wait cancelled"). Work may still have to wait; a follow-up is not
    # called one.
    items =
      for {status, resolution} <- [
            active: nil,
            resolved: :timer,
            timed_out: :deadline,
            cancelled: :cancelled
          ],
          do: %{
            item
            | status: status,
              resolution_kind: resolution,
              ref: "event-subscription:#{status}"
          }

    for params <- [%{}, %{"view" => "past"}, %{"q" => "absent"}],
        listed <- [items, []] do
      text =
        listed
        |> SubscriptionsPage.list(SubscriptionsPage.params(params), @now)
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      refute text =~ ~r/\bWaits?\b|\bwaits\b|\b(a|one|no|\d+) wait\b/, text
    end
  end

  test "long source text is escaped and a safe target gets its own link", %{item: item} do
    title = "<script>alert(1)</script> " <> String.duplicate("long request ", 30)
    item = %{item | title: title, episode_title: title, target_url: "https://example.test/run"}
    document = row(item)

    assert LazyHTML.query(document, "script") |> Enum.empty?()
    assert LazyHTML.query(document, ".entity-name") |> LazyHTML.text() =~ title

    target = LazyHTML.query(document, ".entity-meta a[href='https://example.test/run']")
    assert LazyHTML.attribute(target, "rel") == ["noreferrer"]
    assert LazyHTML.text(target) =~ "Open target"
    assert LazyHTML.attribute(target, "aria-label") == ["Open target for #{title}"]
  end

  test "the list offers Current and Past, keeps the search across both, and says Ryker adds them",
       %{item: item} do
    parent = self()

    options = %{
      projection: %{
        subscriptions: fn params ->
          send(parent, {:subscriptions, params})
          [item]
        end
      }
    }

    page = Pages.page(["follow-ups"], %{"q" => "portal", "status" => "active"}, options)
    assert_received {:subscriptions, %{"q" => "portal", "view" => "current"} = params}
    assert map_size(params) == 2

    assert page.title == "Follow-ups"

    assert page.description ==
             "Work Ryker paused and will pick up again at a set time or when something happens."

    document = LazyHTML.from_fragment(page.body)
    toolbar = LazyHTML.query(document, ".follow-ups-view > .kit-toolbar")

    assert LazyHTML.query(toolbar, "form.filter-toolbar[action='/follow-ups'] input[name=q]")
           |> LazyHTML.attribute("value") == ["portal"]

    assert LazyHTML.query(toolbar, "a.filter-clear") |> LazyHTML.attribute("href") == [
             "/follow-ups"
           ]

    segments = LazyHTML.query(toolbar, "nav.segmented a")
    assert Enum.map(segments, &LazyHTML.text/1) == ["Current", "Past"]

    assert LazyHTML.attribute(segments, "href") == [
             "/follow-ups?q=portal",
             "/follow-ups?q=portal&view=past"
           ]

    assert LazyHTML.query(toolbar, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
             "Current"

    hint = LazyHTML.query(document, "p.ask-hint")

    assert LazyHTML.text(hint) =~
             "Ryker adds follow-ups on its own when work has to wait. You can also ask:"

    assert LazyHTML.query(hint, "q") |> LazyHTML.text() == "Check again tomorrow morning."

    # Read-only: Ryker owns these, so the page offers no controls.
    assert Enum.empty?(
             LazyHTML.query(document, "details.page-help, select, form.action-control, table")
           )
  end

  test "an empty list says what would put a follow-up there, and a search miss says it missed" do
    for {params, title, text} <- [
          {%{}, "Nothing is waiting",
           "When Ryker has to pause a request until a set time or an update, it shows here."},
          {%{"view" => "past"}, "No past follow-ups",
           "Follow-ups move here once the work continues, the deadline passes or they are cancelled."},
          {%{"q" => "absent"}, "No follow-ups match “absent”",
           "Try other words, or look under Past."}
        ] do
      page = Pages.page(["follow-ups"], params, %{projection: %{subscriptions: fn _ -> [] end}})
      empty = page.body |> LazyHTML.from_fragment() |> LazyHTML.query(".entity-empty")
      assert LazyHTML.query(empty, ".entity-empty-title") |> LazyHTML.text() == title
      assert LazyHTML.text(empty) =~ text
    end
  end

  test "follow-up page titles and navigation use the same name", %{item: item} do
    page =
      Pages.page(["follow-ups"], %{}, %{projection: %{subscriptions: fn _ -> [item] end}})

    assert page.title == "Follow-ups"
    assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(page.body), "h1, .page-description"))

    sidebar =
      render_component(&Navigation.sidebar/1, path: "/follow-ups", live: false)
      |> LazyHTML.from_document()

    assert LazyHTML.query(sidebar, "a[href='/follow-ups']") |> LazyHTML.text() == "Follow-ups"
  end

  defp row(item, now \\ @now) do
    [item]
    |> SubscriptionsPage.list(%{"q" => "", "view" => "current"}, now)
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".entity-list .entity-row")
  end

  defp item_fixture do
    %{
      ref: "event-subscription:9751a3c9-bc54-4d81-8b2d-173ed92fb54c",
      episode_ref: "episode:run-monitor",
      episode_title: "Review the portal deployment",
      episode_href: "/timeline/episode%3Arun-monitor",
      place: "#infra",
      repository: "emisar",
      title: "An update on Run run-t2W6yCNeLUU9xFso",
      condition: "attachment title: Run Planning",
      target_url: nil,
      source_label: "Slack",
      matcher_digest: String.duplicate("a", 64),
      cursor_digest: nil,
      last_observation_digest: nil,
      last_observed_at: nil,
      poll_after: nil,
      deadline_at: nil,
      resolution_kind: nil,
      revision: 1,
      source_kind: "slack",
      status: :active,
      trigger_type: "source_event",
      updated_at: ~U[2026-09-10 09:00:00Z]
    }
  end

  # Text as a reader sees it: markup whitespace collapsed to single spaces.
  defp words(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
end

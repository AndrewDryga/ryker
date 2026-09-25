defmodule Ryker.ControlPlane.ConfigurationShellTest do
  @moduledoc """
  The shared shell every secondary page renders into: the title once, its
  description directly beneath, then whatever the page owns. Pages.page
  produces the title, description and body the live shell shows, and
  HTML.page wraps them in the static shell used by confirmed HTTP actions.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Components, HTML, Pages}

  @pages [
    {"/rules", "Rules"},
    {"/schedules", "Schedules"},
    {"/follow-ups", "Follow-ups"},
    {"/channels", "Channels"},
    {"/repositories", "Repositories"},
    {"/memory", "Facts"},
    {"/incident-rooms", "Incident rooms"},
    {"/failures", "Failures"}
  ]

  test "a secondary page carries its title once with the description directly beneath it" do
    # Before 2026-09-13 the shell printed the title and every list page then
    # opened its body with a second intro heading of its own ("Recurring and
    # one-shot work" under "Schedules", "Waits" under "Waits"), followed by a
    # rule and a 26px gap. Andrew asked for one heading, one description 8px
    # under it, and one left edge on every Configuration page.
    for {path, title} <- @pages do
      page = Pages.page(String.split(path, "/", trim: true), %{}, options())
      assert page.status == 200, path
      assert page.title == title
      document = HTML.page(page.title, page.description, page.body) |> LazyHTML.from_document()

      headings = LazyHTML.query(document, "main h1")
      assert Enum.count(headings) == 1, path
      assert LazyHTML.text(headings) == title

      assert Enum.count(LazyHTML.query(document, "main header.page-header > .page-heading > h1")) ==
               1

      description =
        LazyHTML.query(document, "main header.page-header > .page-heading + p.page-description")

      assert Enum.count(description) == 1, path
      words = description |> LazyHTML.text() |> String.split() |> length()
      assert words in 4..32, path

      assert Enum.empty?(
               LazyHTML.query(
                 document,
                 "main section.page-description, main .page-description h2, main .secondary-page-title"
               )
             ),
             path
    end
  end

  test "list pages filter through one compact toolbar with no apply button and no second description" do
    # The old search_form printed visible Search/Status labels in their own
    # columns and an "Apply filters" button; dropdowns now apply on change and
    # search submits on Enter, so a shareable URL is the only state.
    for path <- ["/schedules", "/follow-ups", "/channels", "/repositories", "/incident-rooms"] do
      page = Pages.page(String.split(path, "/", trim: true), %{"q" => "emisar"}, options())
      document = LazyHTML.from_fragment(page.body)
      toolbar = LazyHTML.query(document, "form.filter-toolbar")
      assert Enum.count(toolbar) == 1, path
      assert LazyHTML.attribute(toolbar, "action") == [path]
      assert LazyHTML.attribute(toolbar, "method") == ["get"]

      assert LazyHTML.query(toolbar, "input[type=search][name=q]") |> LazyHTML.attribute("value") ==
               ["emisar"]

      assert Enum.count(LazyHTML.query(toolbar, "label[for=operator-search]")) == 1
      assert Enum.empty?(LazyHTML.query(toolbar, "button:not(noscript button)")), path
      assert LazyHTML.query(toolbar, "a.filter-clear") |> LazyHTML.attribute("href") == [path]

      assert Enum.empty?(
               LazyHTML.query(document, "p.page-description, section.page-description")
             ),
             path
    end

    # Schedules and Follow-ups narrow by Current and Past beside the search,
    # not by a status dropdown, and the search keeps the view it searches in.
    for path <- ["/schedules", "/follow-ups"] do
      past =
        Pages.page(String.split(path, "/", trim: true), %{"view" => "past"}, options()).body
        |> LazyHTML.from_fragment()

      assert Enum.empty?(LazyHTML.query(past, "select")), path

      assert LazyHTML.query(past, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
               "Past"

      assert LazyHTML.query(past, "form.filter-toolbar input[type=hidden][name=view]")
             |> LazyHTML.attribute("value") == ["past"]
    end
  end

  test "Schedules and Follow-ups say in one line how each comes to exist, not in a help disclosure" do
    for {path, description, hint} <- [
          {"/schedules", "Tasks Ryker runs at a set time, once or on repeat.",
           "To add a schedule, tell Ryker where the results should go: Every Monday at 09:00 Berlin time, summarize unresolved incidents in this channel."},
          {"/follow-ups",
           "Work Ryker paused and will pick up again at a set time or when something happens.",
           "Ryker adds follow-ups on its own when work has to wait. You can also ask: Check again tomorrow morning."}
        ] do
      page = Pages.page(String.split(path, "/", trim: true), %{}, options())
      document = HTML.page(page.title, page.description, page.body) |> LazyHTML.from_document()

      assert LazyHTML.query(document, "main header.page-header p.page-description")
             |> LazyHTML.text() == description

      assert LazyHTML.query(document, "main p.ask-hint") |> LazyHTML.text() == hint
      assert Enum.empty?(LazyHTML.query(document, "main details.page-help")), path
    end
  end

  test "the page header keeps a real action opposite the title and renders nothing for an absent one" do
    with_action =
      render_component(&Components.page_header/1,
        title: "Settings",
        description: "What this installation decided.",
        action: [%{inner_block: fn _, _ -> "Create settings" end, __slot__: :action}]
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(with_action, "header.page-header > .page-heading > h1")
           |> LazyHTML.text() == "Settings"

    assert LazyHTML.query(with_action, ".page-heading > .page-action") |> LazyHTML.text() =~
             "Create settings"

    assert LazyHTML.query(with_action, ".page-heading + p.page-description") |> LazyHTML.text() ==
             "What this installation decided."

    bare =
      render_component(&Components.page_header/1, title: "Retry delivery")
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(bare, "h1") |> LazyHTML.text() == "Retry delivery"
    assert Enum.empty?(LazyHTML.query(bare, ".page-action, .page-description"))
  end

  test "Memory pages carry one plain sentence under their title and no help disclosure" do
    # Until 2026-09-24 Memory and Findings opened with "How memory works" and
    # "How findings work" disclosures of three paragraphs each; what a person
    # needs now sits in the sentence under the title and the page itself.
    for {path, title, description} <- [
          {"/memory", "Facts",
           "Things people told Ryker to remember. Ryker uses them as context, never as permission."},
          {"/memory/learned", "Learned",
           "What Ryker learned by reading conversations, with the messages it learned from."},
          {"/memory/learning", "Learning",
           "Ryker reads conversations in the background and keeps what it learned up to date. Learning never sends a reply."},
          {"/memory/findings", "Findings",
           "Conclusions Ryker reached in investigations, with the evidence behind them."}
        ] do
      page = Pages.page(String.split(path, "/", trim: true), %{}, options())
      document = HTML.page(page.title, page.description, page.body) |> LazyHTML.from_document()

      assert LazyHTML.query(document, "main header.page-header h1") |> LazyHTML.text() == title,
             path

      assert LazyHTML.query(document, "main header.page-header p.page-description")
             |> LazyHTML.text() == description,
             path

      assert Enum.empty?(LazyHTML.query(document, "main details.page-help")), path
    end
  end

  defp options do
    %{
      csrf_secret: String.duplicate("s", 32),
      actions: %{},
      projection: %{
        behaviors: fn kind, params ->
          %{
            kind: kind,
            items: [],
            counts: %{},
            total: 0,
            page: 1,
            pages: 1,
            runs: [],
            params: %{"q" => params["q"] || "", "scope" => "", "status" => "current"}
          }
        end,
        schedules: fn _params -> [] end,
        subscriptions: fn _params -> [] end,
        channels: fn _params -> [] end,
        repositories: fn _params -> [] end,
        incidents: fn _params -> [] end,
        failures: fn _params -> {:ok, []} end,
        memory: fn _params -> %{memories: [], reviews: []} end,
        learned: fn _params ->
          %{
            counts: %{context: 0, knowledge: 0},
            kind: "knowledge",
            q: "",
            page: 1,
            pages: 1,
            total: 0,
            related_to: nil,
            source_parent: nil,
            selected: nil,
            rebuild: nil,
            history: [],
            history_page: 1,
            history_pages: 1,
            learning: nil,
            items: []
          }
        end,
        learning: fn _params ->
          %{
            state: :off,
            enabled: false,
            worker_running: false,
            counts: %{queued: 0, running: 0, applied: 0, no_change: 0, deferred: 0, superseded: 0},
            waiting_inputs: 0,
            oldest_waiting_at: nil,
            attention: %{items: [], page: 1, pages: 1, total: 0},
            recent: %{items: [], page: 1, pages: 1, total: 0, outcome: ""},
            handover_failures: %{total: 0, items: [], page: 1, pages: 1},
            selected: nil,
            receipt: nil
          }
        end,
        workspaces: fn _params -> [] end,
        findings: fn _params -> %{items: [], page: 1, pages: 1, total: 0} end
      }
    }
  end
end

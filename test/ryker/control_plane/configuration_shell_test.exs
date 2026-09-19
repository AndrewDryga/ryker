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
    {"/rules", "Standing rules"},
    {"/preferences", "Preferences"},
    {"/guidance", "Guidance"},
    {"/schedules", "Schedules"},
    {"/subscriptions", "Waits"},
    {"/channels", "Channels"},
    {"/repositories", "Repositories"},
    {"/memory", "Memory"},
    {"/incident-rooms", "Incident rooms"}
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
    for path <- ["/schedules", "/subscriptions", "/channels", "/repositories", "/incident-rooms"] do
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

    with_status =
      Pages.page(["schedules"], %{"status" => "paused"}, options()).body
      |> LazyHTML.from_fragment()

    assert Enum.count(
             LazyHTML.query(with_status, "form.filter-toolbar label[for=operator-status]")
           ) == 1

    assert LazyHTML.query(with_status, "select#operator-status[name=status] option[selected]")
           |> LazyHTML.attribute("value") == ["paused"]
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

  test "Automation and Memory pages render the approved subtitle and help copy in reading order" do
    pages = [
      {"/rules",
       "Standing rules let Ryker watch for specific events and use your instructions to decide what to do when one happens.",
       "How to create a standing rule",
       [
         "In the Slack channel where the rule should apply, tell Ryker what event to watch for, any conditions that must match, and how it should respond.",
         "For example: “When someone posts a Terraform plan in this channel, review it for risky changes.”",
         "Ryker shows the exact rule for confirmation before saving it. Later, ask Ryker to update, pause, resume, or delete it—or manage it here."
       ]},
      {"/schedules",
       "Schedules let Ryker run a task once at a future time or repeat it on a regular schedule.",
       "How to create a schedule",
       [
         "In the Slack conversation where the results should appear, tell Ryker what to do and when. Include the time zone and whether the task should run once or repeat.",
         "For example: “Every weekday at 09:00 Berlin time, summarize unresolved incidents in this channel.”",
         "Ryker shows the schedule for confirmation before saving it. Later, ask Ryker to update, pause, resume, or delete it—or manage it here. Run now starts an extra occurrence without changing the saved schedule."
       ]},
      {"/subscriptions",
       "Waits are work Ryker has paused until a timer fires or a specific update arrives.",
       "How waits work",
       [
         "Ryker creates a wait when active work cannot continue yet. You can also tell it to continue at a particular time or after a particular event.",
         "For example: “Continue when this pull request is merged” or “Check again tomorrow morning.”",
         "Each wait shows what can resume the work. This page is read-only: waits resume the original work when their condition is met, or end when their deadline is reached."
       ]},
      {"/memory",
       "Memory shows what Ryker learned from conversations and the reusable facts people explicitly asked it to remember.",
       "How memory works",
       [
         "Ryker learns useful decisions, explanations, intentions, and changes from conversations, even when it does not reply. Related updates become current knowledge that can help with later work.",
         "For a specific reusable fact, ask Ryker to remember it and confirm the proposal it shows you.",
         "To correct learned knowledge, explain the change in its source conversation. You can ask Ryker to forget a confirmed fact or remove it here. Memory provides context; it does not grant permission or prove that something is still true."
       ]},
      {"/preferences",
       "Preferences are saved choices about Ryker’s response detail, health-check depth, and reply location.",
       "How to save a preference",
       [
         "Tell Ryker what you prefer and where it should apply: to you, this conversation, a repository, or the workspace.",
         "For example: “Keep replies concise for me” or “Use deep health checks in this repository.” Reply-location preferences cannot be limited to a repository.",
         "Ryker shows the normalized preference for confirmation before saving it. Use this page to pause, resume, or delete it."
       ]},
      {"/guidance",
       "Guidance gives Ryker advice and checklists to use in the conversations and repositories where they apply.",
       "How to add guidance",
       [
         "Ask Ryker to save an instruction, checklist, or working convention. Include where it should apply and, when useful, how long it should be retained.",
         "For example: “When reviewing this repository, always check that database migrations can be rolled back.”",
         "Ryker shows the guidance for confirmation before saving it. To replace it, continue its source conversation and explain what should change. You can pause, resume, or delete it here."
       ]},
      {"/findings",
       "Findings are conclusions Ryker saves from investigations, together with the evidence behind them.",
       "How findings work",
       [
         "During a substantive investigation, Ryker saves useful conclusions automatically—what caused a problem, why behavior is expected, or what important question remains unanswered.",
         "Routine lookups, raw alerts, and unchanged repeated conclusions are not saved as findings.",
         "Findings make investigations easier to review and become part of the completed cases Ryker can recall when similar work appears later. Open a finding to inspect its evidence or continue the source investigation if its conclusion is incomplete or wrong."
       ]}
    ]

    for {path, description, label, paragraphs} <- pages do
      page = Pages.page(String.split(path, "/", trim: true), %{}, options())
      document = HTML.page(page.title, page.description, page.body) |> LazyHTML.from_document()
      header = LazyHTML.query(document, "main header.page-header")
      help = LazyHTML.query(document, "main details.page-help.configuration-help:not([open])")

      assert LazyHTML.query(header, "p.page-description") |> LazyHTML.text() == description, path
      assert LazyHTML.query(help, "summary") |> LazyHTML.text() == label, path

      assert help |> LazyHTML.query(".page-help-body p") |> Enum.map(&LazyHTML.text/1) ==
               paragraphs,
             path

      html = HTML.page(page.title, page.description, page.body) |> IO.iodata_to_binary()
      assert :binary.match(html, description) < :binary.match(html, label), path
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
        memory: fn _params -> %{memories: [], reviews: []} end,
        findings: fn _params -> %{items: [], page: 1, pages: 1, total: 0} end
      }
    }
  end
end

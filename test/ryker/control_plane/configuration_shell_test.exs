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
        memory: fn _params -> %{memories: [], reviews: []} end
      }
    }
  end
end

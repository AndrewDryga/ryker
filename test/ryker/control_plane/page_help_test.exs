defmodule Ryker.ControlPlane.PageHelpTest do
  @moduledoc """
  Andrew, 2026-09-25, reading the Incident rooms list: "'To open one, ask
  Ryker in the alert's Slack thread: Open an incident room for this. Ryker
  offers the room and creates it once you confirm.' — this should be replaced
  with a collapsible on top of the page or a help column on the right ... On
  all pages. Now it's small text everywhere, but we need to educate users how
  to use it without distracting from the main content, and I want the docs to
  be a bit longer than you can put in a hint, to be more useful."

  How to use a page was one line of small print under seven lists and nothing
  at all on the other twenty-seven pages. Every page the route map serves now
  carries "How this page works", written for someone who has never seen Ryker.
  These tests hold that shut: a new page without help, help left behind for a
  removed page, and help that slips into Ryker's own vocabulary all fail here.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Assets, Layouts, PageHelp, WebRouter}

  # Words that name Ryker's machinery rather than anything a reader sees. A
  # reader who meets "episode" or "custody" in help has learned nothing.
  # ("Payload" stays allowed: the Webhooks page's own controls say it.)
  @internal ~w(episode custody digest admission ingress projection coop co:op lease janitor
               manifest ledger subscription placement fleet liveview)

  test "every page the route map serves explains itself, and no help outlives its page" do
    routed = live_routes()
    assert length(routed) > 30

    assert Enum.sort(PageHelp.routes()) == Enum.sort(routed),
           """
           Help and the route map disagree.
           Pages without help: #{inspect(routed -- PageHelp.routes())}
           Help for pages that do not exist: #{inspect(PageHelp.routes() -- routed)}
           """

    for route <- routed do
      assert %{title: title, sections: sections} = PageHelp.for_path(sample(route)), route
      assert title =~ ~r/^How .+ works?$/, "#{route} is titled #{inspect(title)}"
      assert length(sections) in 2..5, "#{route} has #{length(sections)} sections"

      for %{heading: heading, paragraphs: paragraphs} <- sections do
        assert heading =~ ~r/^\S/ and length(String.split(heading)) <= 6, "#{route}: #{heading}"
        assert length(paragraphs) in 1..2, "#{route}: #{heading}"
      end
    end
  end

  test "help is written in short plain sentences, without Ryker's internal words" do
    for route <- PageHelp.routes(), text <- texts(PageHelp.for_path(sample(route))) do
      for word <- @internal do
        refute String.downcase(text) =~ ~r/\b#{Regex.escape(word)}/,
               "#{route} says #{inspect(word)}: #{text}"
      end

      refute text =~ ~r/\bLab\b/, "#{route} calls Chat the Lab: #{text}"

      for sentence <- String.split(text, ~r/(?<=[.?!]|[.?!]”)\s+/u) do
        words = length(String.split(sentence))
        assert words <= 32, "#{route} has a #{words}-word sentence: #{sentence}"
      end
    end
  end

  test "a page is found by its address, with or without a trailing slash or a query" do
    assert PageHelp.for_path("/").title == "How Activity works"
    assert PageHelp.for_path("/activity") == PageHelp.for_path("/")
    assert PageHelp.for_path("/incident-rooms/").title == "How incident rooms work"

    assert PageHelp.for_path("/incident-rooms/incident%3Aone").title ==
             "How an incident room works"

    assert PageHelp.for_path("/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6") ==
             PageHelp.for_path("/conversations")

    assert PageHelp.for_path("/channels/T1/C1") != PageHelp.for_path("/channels")

    for unknown <- ["/actions/delivery/ref/retry", "/channels/T1", "/memory/unknown", "/nope"],
        do: assert(PageHelp.for_path(unknown) == nil, unknown)
  end

  test "asking Ryker in Slack for an incident room is explained where rooms are listed" do
    # The hint Andrew quoted, moved into the help and kept whole.
    text = "/incident-rooms" |> PageHelp.for_path() |> texts() |> Enum.join(" ")
    assert text =~ "Open an incident room for this."
    assert text =~ "creates it once you confirm"
  end

  # Andrew, 2026-09-26: "side docs are nice but they should not be
  # collapsible like that. Instead we need a button that will open/hide that
  # side bar completely." The help was a <details> headed "How this page
  # works" above every page. It is now the page's help as it is, and one
  # quiet button that shows or hides all of it.
  test "one button shows or hides the page's help, which has no collapsible heading" do
    document =
      render_component(&PageHelp.panel/1, path: "/incident-rooms") |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "details, summary"))
    refute LazyHTML.text(document) =~ "How this page works"

    [toggle] = LazyHTML.query(document, "button#page-help-toggle") |> Enum.to_list()
    assert LazyHTML.attribute(toggle, "type") == ["button"]
    assert LazyHTML.attribute(toggle, "aria-controls") == ["page-help"]
    assert LazyHTML.attribute(toggle, "phx-hook") == ["PageHelp"]
    assert LazyHTML.attribute(toggle, "data-page-help-toggle") == [""]
    # The server cannot know what this browser chose, so it renders the
    # button closed; the page's <head> shows the remembered state before the
    # first paint and page-help.mjs sets the button to match.
    assert LazyHTML.attribute(toggle, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(toggle, "aria-label") == ["Show help"]
    # No hover hint: a hint is built when the pointer arrives, so a tap left
    # "Show help" on a phone's screen over help that had just opened.
    assert LazyHTML.attribute(toggle, "data-tooltip") == []
    assert LazyHTML.attribute(toggle, "title") == []
    assert LazyHTML.query(toggle, "svg.ui-icon") |> Enum.count() == 2

    [aside] = LazyHTML.query(document, "aside#page-help.page-help") |> Enum.to_list()
    assert LazyHTML.attribute(aside, "aria-label") == ["How incident rooms work"]

    assert LazyHTML.query(aside, "h2.page-help-title") |> LazyHTML.text() ==
             "How incident rooms work"

    help = PageHelp.for_path("/incident-rooms")

    assert LazyHTML.query(aside, "section.page-help-section h3")
           |> Enum.map(&LazyHTML.text/1) == Enum.map(help.sections, & &1.heading)

    assert LazyHTML.query(aside, "section.page-help-section p") |> Enum.count() ==
             help.sections |> Enum.flat_map(& &1.paragraphs) |> length()
  end

  # Whether help shows is this browser's choice, kept in localStorage. A
  # module script runs after the page has been parsed and can paint, so the
  # page would flash the other layout first; a classic script in <head> sets
  # the state before anything renders.
  test "the page's head decides whether help shows before the first paint" do
    document =
      render_component(&Layouts.root/1, page_title: "Activity", inner_content: "")
      |> LazyHTML.from_document()

    [early] =
      LazyHTML.query(document, "head script[src='/assets/page-help-early.js']") |> Enum.to_list()

    for attribute <- ["type", "defer", "async"],
        do: assert(LazyHTML.attribute(early, attribute) == [], "the early script is #{attribute}")

    conn = Assets.call(Plug.Test.conn(:get, "/page-help-early.js"), [])
    assert conn.status == 200
    assert conn.resp_body =~ "data-page-help"
  end

  test "a path without help renders no panel and no button" do
    assert render_component(&PageHelp.panel/1, path: "/actions/delivery/ref/retry")
           |> String.trim() == ""
  end

  defp live_routes do
    for %{plug: Phoenix.LiveView.Plug, verb: :get, path: path} <-
          Phoenix.Router.routes(WebRouter),
        uniq: true,
        do: path
  end

  defp sample(route) do
    "/" <>
      (route
       |> String.split("/", trim: true)
       |> Enum.map_join("/", fn
         ":" <> _param -> "ref%3Aone"
         segment -> segment
       end))
  end

  defp texts(%{title: title, sections: sections}),
    do: [title | Enum.flat_map(sections, &[&1.heading | &1.paragraphs])]
end

defmodule Ryker.ControlPlane.SubscriptionsPageTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.HTML
  alias Ryker.ControlPlane.Navigation
  alias Ryker.ControlPlane.Pages
  alias Ryker.ControlPlane.SubscriptionsPage
  import Phoenix.LiveViewTest

  setup do
    # The live page reduced exact Terraform-run waits to nine columns of IDs and
    # digests. These presentation fields come from the saved run matcher, not a
    # claim that the run has been approved or has finished.
    %{item: item_fixture()}
  end

  test "waits lead with their purpose and keep internal identities in collapsed details", %{
    item: item
  } do
    document =
      item
      |> List.wrap()
      |> HTML.subscriptions()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    assert LazyHTML.query(document, ".subscription-title") |> LazyHTML.text() == item.title

    assert LazyHTML.query(document, ".subscription-condition") |> LazyHTML.text() ==
             item.condition

    assert LazyHTML.query(document, "a[href='/timeline/episode%3Arun-monitor']")
           |> LazyHTML.text() == item.episode_title

    assert LazyHTML.text(document) =~ "When a matching update arrives"
    assert LazyHTML.text(document) =~ "No deadline"
    assert LazyHTML.query(document, "details:not([open])") |> LazyHTML.text() =~ item.ref

    assert LazyHTML.query(document, "details:not([open])") |> LazyHTML.text() =~
             item.matcher_digest

    assert LazyHTML.query(document, "table") |> Enum.empty?()
  end

  test "unchanged wait rows advance relative labels while exposing exact UTC times on focus", %{
    item: item
  } do
    at = ~U[2026-09-10 10:00:00Z]
    item = %{item | trigger_type: "at", poll_after: at, deadline_at: DateTime.add(at, 600)}

    render = fn now ->
      render_component(&SubscriptionsPage.render/1, items: [item], now: now)
      |> LazyHTML.from_document()
    end

    future = render.(DateTime.add(at, -300))
    due = render.(at)

    assert LazyHTML.query(future, "time[tabindex='0'][datetime='2026-09-10T10:00:00Z']")
           |> LazyHTML.text() == "in 5 minutes"

    assert LazyHTML.query(due, "time[tabindex='0'][datetime='2026-09-10T10:00:00Z']")
           |> LazyHTML.text() == "due now"

    assert LazyHTML.query(
             due,
             "time[aria-label='due now · 10 Sep, 10:00 UTC'][title='2026-09-10T10:00:00Z']"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(future, "details") |> LazyHTML.attribute("id") ==
             LazyHTML.query(due, "details") |> LazyHTML.attribute("id")
  end

  test "long source text is escaped and empty filtered lists explain their search window", %{
    item: item
  } do
    title = "<script>alert(1)</script> " <> String.duplicate("long request ", 30)
    item = %{item | title: title, episode_title: title, target_url: "https://example.test/run"}
    document = HTML.subscriptions([item]) |> IO.iodata_to_binary() |> LazyHTML.from_document()
    assert LazyHTML.query(document, "script") |> Enum.empty?()
    assert LazyHTML.query(document, ".subscription-title") |> LazyHTML.text() == title

    assert LazyHTML.query(document, "a.subscription-target[rel=noreferrer]") |> LazyHTML.text() =~
             "Open target"

    assert LazyHTML.query(document, ".subscription-target") |> LazyHTML.attribute("aria-label") ==
             ["Open target for #{title}"]

    assert LazyHTML.query(document, "summary") |> LazyHTML.attribute("aria-label") ==
             ["Technical details for #{title}"]

    html = HTML.subscriptions([], %{"q" => "absent"}) |> IO.iodata_to_binary()
    assert html =~ "No waits match these filters"
    assert LazyHTML.from_document(html) |> LazyHTML.query(".subscription-list") |> Enum.empty?()
  end

  test "the waits page is help, one toolbar, one quiet count and the rows in that order, without a panel",
       %{item: item} do
    # Before 2026-09-13 the body repeated "Waits" as an intro heading under the
    # shell's own, the window explanation sat as a loose paragraph above the
    # rows, and the whole list was boxed twice: the secondary-page section rule
    # drew a bordered panel around a list that draws its own border.
    document = HTML.subscriptions([item]) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    assert outline(document, "div.subscriptions-page > *") == [
             "details.page-help",
             "form.filter-toolbar",
             "p.result-count",
             "div.subscriptions-view"
           ]

    assert LazyHTML.query(document, "p.result-count") |> LazyHTML.text() == "1 wait"

    assert Enum.empty?(
             LazyHTML.query(document, "section, h1, .page-description, .subscription-window")
           )

    help = LazyHTML.query(document, "details.page-help#waits-help:not([open])")

    assert LazyHTML.query(help, "summary") |> LazyHTML.text() == "How waits work"
    assert LazyHTML.text(help) =~ "when active work cannot continue yet"
    assert LazyHTML.text(help) =~ "Continue when this pull request is merged"
    assert LazyHTML.text(help) =~ "This page is read-only"

    assert LazyHTML.query(document, "div.subscriptions-view[aria-label=Waits]") |> Enum.count() ==
             1
  end

  test "an empty waits list tells a filtered miss from an installation with nothing waiting" do
    filtered = HTML.subscriptions([], %{"status" => "timed_out"}) |> IO.iodata_to_binary()
    assert filtered =~ "No waits match these filters"
    refute filtered =~ "result-count"

    bare = HTML.subscriptions([]) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
    text = LazyHTML.query(bare, "p.empty-state") |> LazyHTML.text()
    assert text =~ "No waits right now"
    assert text =~ "timer or an external event"
    refute text =~ "match these filters"
    assert Enum.empty?(LazyHTML.query(bare, "p.result-count"))
  end

  test "wait page titles and navigation use the same name", %{item: item} do
    # The page title is the shell's one heading; the body carries no second
    # intro heading of its own, so the name can only come from the route.
    page =
      Pages.page(["subscriptions"], %{}, %{projection: %{subscriptions: fn _ -> [item] end}})

    assert page.title == "Waits"
    content = LazyHTML.from_fragment(page.body)
    assert Enum.empty?(LazyHTML.query(content, "h1, .page-description"))

    sidebar =
      render_component(&Navigation.sidebar/1,
        path: "/subscriptions",
        live: false
      )
      |> LazyHTML.from_document()

    assert LazyHTML.query(sidebar, "a[href='/subscriptions']") |> LazyHTML.text() == "Waits"
  end

  test "wait status filters use the same words as the rows they select", %{item: item} do
    # The filter said Active/Resolved/Stopped while the rows said
    # Waiting/Resumed/Cancelled, leaving operators to guess the correspondence.
    for {status, label} <- [
          active: "Waiting",
          resolved: "Resumed",
          timed_out: "Timed out",
          cancelled: "Cancelled"
        ] do
      document =
        HTML.subscriptions([%{item | status: status}], %{"status" => Atom.to_string(status)})
        |> IO.iodata_to_binary()
        |> LazyHTML.from_document()

      assert LazyHTML.query(document, "select[name=status] option[selected]") |> LazyHTML.text() ==
               label

      assert LazyHTML.query(document, ".subscription-timing .ui-status") |> LazyHTML.text() ==
               label
    end
  end

  defp item_fixture do
    %{
      ref: "event-subscription:9751a3c9-bc54-4d81-8b2d-173ed92fb54c",
      episode_ref: "episode:run-monitor",
      episode_title: "Review the portal deployment",
      episode_href: "/timeline/episode%3Arun-monitor",
      context_label: "Slack · #infra",
      title: "Run run-t2W6yCNeLUU9xFso",
      condition: "Next matching Slack update",
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

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end

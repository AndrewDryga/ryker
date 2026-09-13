defmodule Responder.ControlPlane.SchedulesPageTest do
  @moduledoc """
  The Schedules list inside the shared Configuration shell: toolbar, quiet
  count, one comparison table whose rows read as words and readable times, and
  a stacking pattern for narrow screens that never hides a schedule's identity.
  """
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.{HTML, Router}

  @schedule %{
    authority: :read_only,
    destination_conversation_ref: "slack:T123:C456",
    destination_transport: "slack",
    failures: 0,
    next_occurrence_at: ~U[2026-08-29 09:00:00Z],
    ref: "schedule:one",
    repository: "responder",
    status: :active,
    timezone: "Europe/Kyiv",
    title: "Daily health",
    updated_at: ~U[2026-08-28 12:00:00Z]
  }

  test "the schedules page is one toolbar, one quiet count and one comparison table in that order" do
    # Before 2026-09-13 the body opened with its own "Recurring and one-shot
    # work" heading under the shell's "Schedules", and the list was a bare
    # table-wrap with no count: an operator could not tell nine rows from ninety
    # without scrolling. The approved shell keeps the title and description in
    # the header and composes the body down one left edge.
    document = render([@schedule, %{@schedule | ref: "schedule:two", title: "Weekly review"}])

    assert outline(document, "div.schedules-page > *") == [
             "form.filter-toolbar",
             "p.result-count",
             "table.data-table"
           ]

    assert LazyHTML.query(document, "p.result-count") |> LazyHTML.text() == "2 schedules"
    assert Enum.empty?(LazyHTML.query(document, "h1, h2, .page-description, .table-wrap"))

    assert LazyHTML.query(document, "table.data-table thead th") |> LazyHTML.text() ==
             "ScheduleStatusNext occurrenceRepositoryFailures"
  end

  test "a schedule row reads as status words and readable times with its exact reference kept secondary" do
    # The old row printed the raw atom "active", an ISO-8601 next occurrence and
    # the reference in the same weight as the title.
    document = render([%{@schedule | failures: 2}])
    row = LazyHTML.query(document, "table.data-table tbody tr")

    assert LazyHTML.query(row, "td.row-identity a[href='/schedules/schedule%3Aone']")
           |> LazyHTML.text() == "Daily health"

    secondary = LazyHTML.query(row, "td.row-identity .row-secondary")
    assert LazyHTML.text(secondary) =~ "Slack channel C456"
    assert LazyHTML.query(secondary, "code") |> LazyHTML.text() == "schedule:one"

    status = LazyHTML.query(row, "td[data-label='Status'] .ui-status")
    assert LazyHTML.text(status) == "Active"
    assert LazyHTML.attribute(status, "class") == ["ui-status status-active"]

    assert LazyHTML.query(row, "td[data-label='Status']") |> LazyHTML.text() |> String.trim() ==
             "Active"

    next = LazyHTML.query(row, "td[data-label='Next occurrence']")
    assert LazyHTML.query(next, "time") |> LazyHTML.text() == "29 Aug, 09:00 UTC"

    assert LazyHTML.query(next, "time") |> LazyHTML.attribute("datetime") == [
             "2026-08-29T09:00:00Z"
           ]

    assert LazyHTML.query(next, ".row-secondary") |> LazyHTML.text() == "Europe/Kyiv"
    refute LazyHTML.text(next) =~ "2026-08-29T09"

    assert LazyHTML.query(row, "td[data-label='Repository']") |> LazyHTML.text() == "responder"
    assert LazyHTML.query(row, "td[data-label='Failures']") |> LazyHTML.text() == "2"
  end

  test "every schedule status keeps its own word and tone, and a paused schedule has no next occurrence" do
    for {status, label, tone} <- [
          {:active, "Active", "active"},
          {:paused, "Paused", "quiet"},
          {:completed, "Completed", "done"},
          {:expired, "Expired", "quiet"},
          {:deleted, "Deleted", "quiet"}
        ] do
      document = render([%{@schedule | status: status, next_occurrence_at: nil}])
      badge = LazyHTML.query(document, "tbody .ui-status")
      assert LazyHTML.text(badge) == label, inspect(status)
      assert LazyHTML.attribute(badge, "class") == ["ui-status status-#{tone}"], inspect(status)

      assert LazyHTML.query(document, "td[data-label='Next occurrence']") |> LazyHTML.text() ==
               "None scheduled"
    end
  end

  test "an empty schedules list tells a filtered miss from an installation with no schedules" do
    # "No durable records." was the same sentence for both, and neither said
    # how a schedule comes to exist.
    filtered = render([], %{"q" => "absent"})
    assert LazyHTML.query(filtered, "p.empty-state") |> LazyHTML.text() =~ "No schedules match"
    assert Enum.empty?(LazyHTML.query(filtered, "p.result-count, table"))

    bare = render([])
    text = LazyHTML.query(bare, "p.empty-state") |> LazyHTML.text()
    assert text =~ "No schedules yet"
    assert text =~ "confirmed in a conversation"
    refute text =~ "durable records"
    assert Enum.empty?(LazyHTML.query(bare, "p.result-count, table"))
  end

  test "every cell carries its column label so narrow screens can stack a row without hiding the identity" do
    # Wide data must not overflow the whole page; the mobile pattern turns each
    # row into label/value pairs, which only works when the cells know their
    # column. The identity cell stays label-free because it is the row's name.
    document = render([@schedule, %{@schedule | ref: "schedule:two", title: "Weekly review"}])
    cells = LazyHTML.query(document, "table.data-table tbody td")
    assert Enum.count(cells) == 10

    labels = LazyHTML.attribute(cells, "data-label")

    assert Enum.take(labels, 5) == [
             "Schedule",
             "Status",
             "Next occurrence",
             "Repository",
             "Failures"
           ]

    assert Enum.count(LazyHTML.query(document, "tbody tr > td:first-child.row-identity")) == 2
  end

  test "the route keeps the shell's title and description and carries the filter into the toolbar" do
    page =
      Router.snapshot("/schedules", "q=health&status=paused", %{
        projection: %{schedules: fn _params -> [%{@schedule | status: :paused}] end}
      })

    assert page.title == "Schedules"
    assert page.description =~ "Recurring and one-shot work"
    document = LazyHTML.from_fragment(page.body)

    assert LazyHTML.query(document, "form.filter-toolbar input[name=q]")
           |> LazyHTML.attribute("value") == ["health"]

    assert LazyHTML.query(document, "select[name=status] option[selected]") |> LazyHTML.text() ==
             "Paused"

    assert LazyHTML.query(document, "form.filter-toolbar a.filter-clear")
           |> LazyHTML.attribute("href") ==
             ["/schedules"]
  end

  defp render(items, params \\ %{}) do
    items |> HTML.schedules(params) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
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

defmodule Ryker.ControlPlane.ComponentsTest do
  @moduledoc """
  The shared vocabulary every page composes: one status markup, one pager,
  one comparison table. Pages that hand-rolled these drifted apart (a pager
  with no touch targets beside one with them, "Active" in the in-progress tone
  on one page and the settled tone on another), so the contract lives here.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Components, HTML}
  alias Ryker.Fixtures.ControlPlaneOptions

  test "a status reads the same whether its state arrives as a string or an atom" do
    # Episode states are strings in the projections and atoms in the schemas;
    # an atom used to fall through every clause and render the quiet tone
    # under a bare word, so the channel page had to stringify by hand.
    for state <- ["blocked", :blocked] do
      assert Components.label(state) == "Needs attention"
      assert Components.tone(state) == "attention"
    end

    assert Components.tone(:working) == "active"
    assert Components.label(:complete) == "Completed"

    html = render_component(&Components.status/1, state: :working)
    assert html =~ ~s(class="ui-status status-active")
    assert html =~ "Working"
  end

  test "rules, schedules and memories share one lifecycle vocabulary" do
    assert Components.lifecycle(:active) == {"Active", "done"}
    assert Components.lifecycle("active") == {"Active", "done"}
    assert Components.lifecycle(:paused) == {"Paused", "quiet"}
    assert Components.lifecycle("disabled") == {"Paused", "quiet"}
    assert Components.lifecycle(:completed) == {"Completed", "done"}
    assert Components.lifecycle(:expired) == {"Expired", "quiet"}

    component = render_component(&Components.status/1, lifecycle: "disabled")
    assert component =~ ~s(class="ui-status status-quiet")
    assert component =~ "Paused"

    explicit = render_component(&Components.status/1, label: "Ready", tone: "done")

    assert explicit =~
             ~s(<span class="ui-status status-done"><i aria-hidden="true"></i>Ready</span>)

    # The string pages render through the same function, so the markup cannot drift.
    assert IO.iodata_to_binary(Components.status("Ready", "done")) == String.trim(explicit)
  end

  test "the pager renders nothing for one page and only the links that lead somewhere" do
    assigns = %{path: fn page -> "/findings?page=#{page}" end}

    assert render_component(&Components.pager/1,
             page: 1,
             pages: 1,
             path: assigns.path,
             label: "Finding pages"
           ) == ""

    first =
      render_component(&Components.pager/1,
        page: 1,
        pages: 3,
        path: assigns.path,
        label: "Finding pages"
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(first, "nav.pagination[aria-label='Finding pages']") |> Enum.count() ==
             1

    assert LazyHTML.query(first, "a") |> LazyHTML.attribute("href") == ["/findings?page=2"]
    assert LazyHTML.query(first, "a") |> LazyHTML.text() == "Next →"
    assert LazyHTML.query(first, "span") |> LazyHTML.text() =~ "Page 1 of 3"

    middle =
      render_component(&Components.pager/1,
        page: 2,
        pages: 3,
        path: assigns.path,
        label: "Memory pages",
        earlier: "← Newer updates",
        later: "Older updates →",
        summary: "12 entries"
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(middle, "a") |> LazyHTML.attribute("href") == [
             "/findings?page=1",
             "/findings?page=3"
           ]

    assert LazyHTML.query(middle, "a") |> LazyHTML.text() == "← Newer updatesOlder updates →"
    assert LazyHTML.text(middle) =~ "Page 2 of 3 · 12 entries"
  end

  test "the page summary keeps facts, a message, a breakdown and related navigation in one vocabulary" do
    html =
      render_component(&Components.page_summary/1,
        label: "Current workload",
        facts: [
          %{value: 2, label: "active"},
          %{value: 1, label: "blocked", tone: :attention, href: "/failures"}
        ],
        message: "Nothing else needs attention",
        secondary: [%{value: 1, label: "Routing"}, %{value: 2, label: "Delivery"}],
        related: %{href: "/usage", label: "View usage and cost"}
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, ".page-summary[aria-label='Current workload']") |> Enum.count() ==
             1

    assert LazyHTML.query(html, ".page-summary-facts > div") |> Enum.count() == 2

    assert LazyHTML.query(html, ".page-summary-fact-attention a[href='/failures']")
           |> Enum.count() == 1

    assert LazyHTML.query(html, ".page-summary-message") |> LazyHTML.text() ==
             "Nothing else needs attention"

    assert LazyHTML.query(html, ".page-summary-secondary") |> LazyHTML.text() =~ "By area"

    assert LazyHTML.query(html, ".page-summary-link[href='/usage']") |> LazyHTML.text() ==
             "View usage and cost"
  end

  test "the table marks every cell with its column so a narrow screen can stack it" do
    rows = [%{name: "Daily health", count: 2}, %{name: "Weekly digest", count: 0}]

    html =
      render_component(
        fn assigns ->
          ~H"""
          <Components.table rows={@rows}>
            <:col :let={row} label="Schedule">{row.name}</:col>
            <:col :let={row} label="Failures" class="row-number">{row.count}</:col>
          </Components.table>
          """
        end,
        rows: rows
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "table.data-table thead th[scope='col']") |> LazyHTML.text() ==
             "ScheduleFailures"

    assert LazyHTML.query(document, "th.row-number") |> LazyHTML.text() == "Failures"
    assert LazyHTML.query(document, "tbody tr") |> Enum.count() == 2

    assert LazyHTML.query(document, "td[data-label='Schedule'].row-identity .cell-value")
           |> LazyHTML.text() == "Daily healthWeekly digest"

    assert LazyHTML.query(document, "td[data-label='Failures'].row-number .cell-value")
           |> LazyHTML.text() == "20"

    refute html =~ ~s(class="")

    # The string pages build the same shape, so one stylesheet rule covers both.
    string_table =
      ControlPlaneOptions.options(self()).projection.channels.(%{})
      |> HTML.channels(%{})
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    for contract <- [
          "table.data-table thead th[scope='col']",
          "tbody tr td.row-identity[data-label] .cell-value",
          "th.row-number"
        ] do
      assert LazyHTML.query(document, contract) |> Enum.count() > 0, contract
      assert LazyHTML.query(string_table, contract) |> Enum.count() > 0, contract
    end
  end
end

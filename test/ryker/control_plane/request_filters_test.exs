defmodule Ryker.ControlPlane.RequestFiltersTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{RequestFilters, UsageProjection}

  defp render_filters(assigns) do
    render_component(
      &RequestFilters.render/1,
      Map.merge(%{params: %{}, values: [], path: "/activity", menu: nil}, assigns)
    )
  end

  test "every supported usage dimension can be added from the filter menu" do
    assert UsageProjection.filter_keys() -- RequestFilters.keys() == []
    html = render_filters(%{menu: "fields"})

    for key <- RequestFilters.keys(),
        do: assert(html =~ ~s(data-field="#{key}"), key)
  end

  test "choosing a value applies it at once and keeps search, mode and the other filters" do
    # Andrew, 2026-09-19: a criterion used to wait for a separate Apply button,
    # and adding one from the leading dropdown reset the dropdown under him.
    params = %{"q" => "health", "mode" => "all", "page" => "4", "state" => "complete"}

    assert RequestFilters.set(params, "transport", "slack") ==
             %{"q" => "health", "mode" => "all", "state" => "complete", "transport" => "slack"}

    # A usage filter is always bounded by a visible usage period.
    assert RequestFilters.set(params, "usage_profile", "emisar")["usage_window"] == "7d"

    assert RequestFilters.set(%{"usage_window" => "30d"}, "usage_profile", "emisar") ==
             %{"usage_window" => "30d", "usage_profile" => "emisar"}
  end

  test "selecting a user does not also select a bot with the same account name" do
    # GitHub users and bots can retain the same actor string in separate inputs.
    assert RequestFilters.set(%{}, "usage_actor", "andrew") ==
             %{"usage_actor" => "andrew", "usage_actor_kind" => "user", "usage_window" => "7d"}
  end

  test "removing a filter, or saving an empty value, keeps every other filter" do
    params = %{"q" => "health", "usage_profile" => "emisar", "usage_window" => "30d"}

    assert RequestFilters.remove(params, "usage_profile") ==
             %{"q" => "health", "usage_window" => "30d"}

    assert RequestFilters.set(params, "usage_profile", "") ==
             %{"q" => "health", "usage_window" => "30d"}
  end

  test "a filter has no operator: no Any, no Not recorded and no Apply button" do
    # Andrew, 2026-09-19: "Any" was a disabled filter that could just be
    # removed, and new work records every field, so "Not recorded" only
    # matched leftovers from testing.
    html = render_filters(%{params: %{"usage_profile" => "emisar", "state" => "complete"}})

    refute html =~ "Not recorded"
    refute html =~ ">Any<"
    refute html =~ "Apply filters"
    refute html =~ "criteria["
    refute html =~ "Add filter…"
  end

  test "each applied filter reads as a chip with its value in words and its own remove button" do
    params = %{
      "state" => "complete",
      "transport" => "github",
      "usage_window" => "7d",
      "usage_measurement" => "measured",
      "usage_actor_kind" => "user",
      "usage_profile" => "emisar"
    }

    html = render_filters(%{params: params})
    document = LazyHTML.from_fragment(html)
    chips = LazyHTML.query(document, ".filter-chip")

    assert Enum.map(chips, fn chip ->
             {LazyHTML.attribute(chip, "data-filter") |> hd(),
              LazyHTML.query(chip, ".filter-chip-value") |> LazyHTML.text()}
           end) == [
             {"state", "Completed"},
             {"transport", "GitHub"},
             {"usage_profile", "emisar"},
             {"usage_actor_kind", "User"},
             {"usage_measurement", "Recorded"},
             {"usage_window", "Last 7 days"}
           ]

    assert LazyHTML.query(
             document,
             ".filter-chip button.filter-chip-remove[phx-click=remove-filter]"
           )
           |> LazyHTML.attribute("phx-value-key") ==
             ~w(state transport usage_profile usage_actor_kind usage_measurement usage_window)

    # The add control comes after every chip, not before them.
    {last_chip, _} = :binary.matches(html, ~s(data-filter=)) |> List.last()
    {add, _} = :binary.match(html, ~s(id="filter-add"))
    assert add > last_chip
  end

  test "the menu offers only fields not already filtered, in request and usage groups" do
    document =
      render_filters(%{params: %{"state" => "complete"}, menu: "fields"})
      |> LazyHTML.from_fragment()

    fields = LazyHTML.query(document, "#filter-popover .filter-fields")
    assert LazyHTML.query(fields, "h3") |> Enum.map(&LazyHTML.text/1) == ["Request", "Usage"]
    keys = LazyHTML.query(fields, "button.filter-field") |> LazyHTML.attribute("data-field")
    refute "state" in keys
    assert "transport" in keys and "usage_actor" in keys
  end

  test "a field's values open beside the field list in a submenu, never in its place" do
    # Andrew, 2026-09-19: choosing a field replaced the menu with its values and
    # left no way back. Every field now owns a submenu next to the list, which
    # the FilterMenu hook shows on hover, focus or click.
    document = render_filters(%{menu: "fields"}) |> LazyHTML.from_fragment()
    menu = LazyHTML.query(document, "#filter-popover[phx-hook=FilterMenu]")
    assert Enum.count(menu) == 1

    field = LazyHTML.query(menu, ".filter-fields button.filter-field[data-field=transport]")
    assert LazyHTML.attribute(field, "aria-controls") == ["filter-values-transport"]
    assert LazyHTML.attribute(field, "aria-expanded") == ["false"]

    transport = LazyHTML.query(menu, "#filter-values-transport.filter-values[hidden]")
    choices = LazyHTML.query(transport, "button[phx-click=set-filter]")
    assert LazyHTML.attribute(choices, "phx-value-choice") == ~w(slack github control_plane)

    assert Enum.map(choices, &String.trim(LazyHTML.text(&1))) == [
             "Slack",
             "GitHub",
             "Direct conversation"
           ]

    assert Enum.count(LazyHTML.query(transport, "button[data-back]")) == 1

    repository = LazyHTML.query(menu, "#filter-values-repository[hidden]")

    assert LazyHTML.query(
             repository,
             "form[phx-submit=set-filter] input[name=key][value=repository]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(repository, "input#filter-value-repository[name=choice]")
           |> Enum.count() == 1

    # The field list stays in the same popover as every submenu.
    assert Enum.count(LazyHTML.query(menu, ".filter-fields")) == 1
    assert Enum.count(LazyHTML.query(menu, ".filter-values")) == length(RequestFilters.keys())
  end

  test "editing a chip opens that filter's values with the current one marked" do
    text =
      render_filters(%{params: %{"repository" => "emisar"}, menu: "repository"})
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(text, "#filter-popover input#filter-value-repository[value=emisar]")
           |> Enum.count() == 1

    choices =
      render_filters(%{params: %{"transport" => "github"}, menu: "transport"})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-popover button[aria-pressed=true]")

    assert LazyHTML.attribute(choices, "phx-value-choice") == ["github"]
  end

  test "a value button carries its value where the browser cannot overwrite it" do
    # Release 7d760b5d sent phx-value-value. LiveView's client then replaces a
    # clicked element's "value" with the button's own empty value, so choosing
    # Slack in a real browser applied "" and cleared the filter instead. The
    # server-side tests passed; only the live browser check caught it.
    html = render_filters(%{menu: "fields"})
    refute html =~ "phx-value-value"

    assert LazyHTML.from_fragment(html)
           |> LazyHTML.query("#filter-values-transport button[phx-click=set-filter]")
           |> LazyHTML.attribute("phx-value-choice") == ~w(slack github control_plane)
  end

  test "malformed and oversized filter input cannot become a query or executable markup" do
    params = %{"usage_profile" => "emisar"}

    for {key, value} <- [
          {"usage_profile", String.duplicate("x", 513)},
          {"unknown", "x"},
          {"usage_profile", %{}}
        ],
        do: assert(RequestFilters.set(params, key, value) == params)

    assert RequestFilters.remove(%{"usage_profile" => %{"bad" => "nested"}}, "usage_profile") ==
             %{}

    html =
      render_filters(%{params: %{"usage_profile" => "<script>", "mode" => %{"bad" => "nested"}}})

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end
end

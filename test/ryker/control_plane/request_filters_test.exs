defmodule Ryker.ControlPlane.RequestFiltersTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{RequestFilters, UsageProjection}

  defp render_filters(assigns) do
    render_component(
      &RequestFilters.render/1,
      Map.merge(%{params: %{}, values: [], path: "/activity", menu: nil, search: %{}}, assigns)
    )
  end

  test "the menu offers only the filters a person uses, each in plain words" do
    # QA, 2026-09-25: "+ Filter" listed 21 fields, most of them Ryker's own
    # machinery: Execution target, Thread, Conversation platform beside
    # Delivery platform, Profile, Provider, Usage repository beside Repository,
    # Sender type, Source workspace, Token report, Exact usage target and Usage
    # period.
    document = render_filters(%{menu: "fields"}) |> LazyHTML.from_fragment()
    fields = LazyHTML.query(document, "#filter-popover .filter-fields")

    groups =
      for section <- LazyHTML.query(fields, "section") do
        {LazyHTML.query(section, "h3") |> LazyHTML.text(),
         LazyHTML.query(section, "button.filter-field") |> Enum.map(&LazyHTML.text/1)}
      end

    assert groups == [
             {"Request", ["Conversation", "Source", "Repository", "State"]},
             {"Usage", ["Model", "Reasoning effort", "Work type", "User"]}
           ]

    # A filter another page links with still reads as a chip that can be
    # removed, even when the menu does not offer it.
    assert UsageProjection.filter_keys() -- RequestFilters.keys() == []
  end

  test "choosing a value applies it at once and keeps search, mode and the other filters" do
    # Andrew, 2026-09-19: a criterion used to wait for a separate Apply button,
    # and adding one from the leading dropdown reset the dropdown under him.
    params = %{"q" => "health", "mode" => "all", "page" => "4", "state" => "complete"}

    assert RequestFilters.set(params, "transport", "slack") ==
             %{"q" => "health", "mode" => "all", "state" => "complete", "transport" => "slack"}

    # QA, 2026-09-25: choosing a model also added "Usage period Last 7 days",
    # a filter nobody chose. A usage filter adds no period of its own; one a
    # Usage link carried stays.
    assert RequestFilters.set(%{}, "usage_model", "gpt-5.6-sol") == %{
             "usage_model" => "gpt-5.6-sol"
           }

    assert RequestFilters.set(%{"usage_window" => "30d"}, "usage_profile", "emisar") ==
             %{"usage_window" => "30d", "usage_profile" => "emisar"}
  end

  test "selecting a user does not also select a bot with the same account name" do
    # GitHub users and bots can retain the same actor string in separate inputs.
    assert RequestFilters.set(%{}, "usage_actor", "andrew") ==
             %{"usage_actor" => "andrew", "usage_actor_kind" => "user"}
  end

  test "a filter that narrows another reads as one chip and leaves with it" do
    # A Usage link to one person carries who, what kind of sender, and which
    # workspace and source: four chips for one choice ("Sender type User",
    # "Source workspace T123"). They are one filter, removed together.
    params = %{
      "usage_actor" => "U123",
      "usage_actor_kind" => "user",
      "usage_workspace" => "T123",
      "usage_source" => "slack",
      "usage_model" => "gpt-5.6-sol",
      "usage_provider" => "codex"
    }

    document = render_filters(%{params: params}) |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".filter-chip") |> LazyHTML.attribute("data-filter") ==
             ~w(usage_model usage_actor)

    assert RequestFilters.remove(params, "usage_actor") == %{
             "usage_model" => "gpt-5.6-sol",
             "usage_provider" => "codex"
           }

    assert RequestFilters.remove(params, "usage_model") |> Map.keys() |> Enum.sort() ==
             ~w(usage_actor usage_actor_kind usage_source usage_workspace)
  end

  # "Slack user U0BHTNFCW6S" is not readable (Andrew, 2026-09-26). A chip for
  # a person the loaded choices no longer list read as their bare Slack ID.
  test "a user chip names the person, never their Slack ID" do
    for params <- [
          %{"usage_actor" => "U0BHTNFCW6S", "usage_actor_kind" => "user"},
          %{
            "usage_actor" => "U0BHTNFCW6S",
            "usage_actor_kind" => "user",
            "usage_source" => "slack",
            "usage_workspace" => "T123"
          }
        ] do
      chip =
        render_filters(%{params: params})
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".filter-chip[data-filter=usage_actor] .filter-chip-value")
        |> LazyHTML.text()

      assert chip == "Slack user", inspect(params)
    end
  end

  test "reasoning effort reads in the words Settings uses" do
    # QA, 2026-09-25: the filter offered "Xhigh" where Settings says "Extra high".
    document = render_filters(%{menu: "fields"}) |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "#filter-values-usage_effort button[phx-click=set-filter]")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["No reasoning", "Minimal", "Low", "Medium", "High", "Extra high", "Max"]

    assert render_filters(%{params: %{"usage_effort" => "xhigh"}})
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".filter-chip-value")
           |> LazyHTML.text() == "Extra high"
  end

  test "a conversation chip names the conversation, not only where it happened" do
    # QA, 2026-09-25: filtering by a chat read only "Direct conversation", the
    # same words for every chat.
    ref = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    values = [
      %{
        conversation_ref: ref,
        conversation_label: "Direct conversation · Weekday incident status"
      }
    ]

    assert render_filters(%{params: %{"conversation" => ref}, values: values})
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".filter-chip-value")
           |> LazyHTML.text() == "Direct conversation · Weekday incident status"
  end

  # QA, 2026-09-26: hovering a conversation in the filter showed its stored
  # reference, "control-plane:lab:018f…", as a tooltip over the words that name it.
  test "a filter value shows its words, never its stored reference, even on hover" do
    ref = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    values = [
      %{
        conversation_ref: ref,
        conversation_label: "Direct conversation · Weekday incident status"
      }
    ]

    choices =
      render_filters(%{menu: "fields", values: values})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-values-conversation button[phx-click=set-filter]")

    assert LazyHTML.attribute(choices, "phx-value-choice") == [ref]
    refute Enum.any?(LazyHTML.attribute(choices, "title"), &(&1 =~ "control-plane:"))
  end

  # Andrew, 2026-10-03, of "+ Filter" › Conversation, which listed every conversation as a button
  # several lines tall: "are you crazy showing all options of such long list as dropdown option
  # in filters?!" A long list opens as a search over its most recent few, one line each, and
  # typing searches all of them.
  test "a long value list opens as a search over its most recent few, one line each" do
    values =
      for n <- 1..30 do
        %{
          conversation_ref: "slack:T1:C#{n}",
          conversation_label: "#channel-#{n}",
          conversation_name: "#channel-#{n}",
          conversation_source: "Slack"
        }
      end

    panel = fn search ->
      render_filters(%{menu: "fields", values: values, search: search})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-values-conversation")
    end

    first = panel.(%{})

    assert LazyHTML.query(
             first,
             "form[phx-change=filter-values-search] input[type=hidden][name=key][value=conversation]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(first, "input[type=search][name=q]")
           |> LazyHTML.attribute("placeholder") ==
             ["Find a conversation"]

    shown = LazyHTML.query(first, "button[phx-click=set-filter]")
    assert LazyHTML.attribute(shown, "phx-value-choice") == for(n <- 1..8, do: "slack:T1:C#{n}")
    assert LazyHTML.query(first, ".filter-more") |> LazyHTML.text() =~ "22 more"

    # One line each: the name, and where the conversation is as a quiet word beside it.
    [row | _rest] = Enum.to_list(shown)
    assert LazyHTML.query(row, ".filter-choice-name") |> LazyHTML.text() == "#channel-1"
    assert LazyHTML.query(row, ".filter-choice-tag") |> LazyHTML.text() == "Slack"

    # Typing searches every conversation, not only the few shown.
    found = panel.(%{"conversation" => "NEL-27"})

    assert LazyHTML.query(found, "button[phx-click=set-filter]")
           |> LazyHTML.attribute("phx-value-choice") == ["slack:T1:C27"]

    assert LazyHTML.query(found, ".filter-more") |> Enum.empty?()

    assert panel.(%{"conversation" => "nothing like it"})
           |> LazyHTML.query(".filter-empty")
           |> LazyHTML.text() =~ "Nothing matches"

    # A short list stays a list: three sources need no search.
    transport =
      render_filters(%{menu: "fields"})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-values-transport")

    assert LazyHTML.query(transport, "input[type=search]") |> Enum.empty?()
  end

  test "the value a chip holds stays in its list even when it is not among the most recent" do
    values =
      for n <- 1..30,
          do: %{conversation_ref: "slack:T1:C#{n}", conversation_label: "#channel-#{n}"}

    pressed =
      render_filters(%{
        params: %{"conversation" => "slack:T1:C30"},
        menu: "conversation",
        values: values
      })
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-popover button[aria-pressed=true]")

    assert LazyHTML.attribute(pressed, "phx-value-choice") == ["slack:T1:C30"]
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
      "usage_profile" => "emisar"
    }

    html = render_filters(%{params: params})
    document = LazyHTML.from_fragment(html)
    chips = LazyHTML.query(document, ".filter-chip")

    assert Enum.map(chips, fn chip ->
             {LazyHTML.attribute(chip, "data-filter") |> hd(),
              LazyHTML.query(chip, ".filter-chip-key") |> LazyHTML.text(),
              LazyHTML.query(chip, ".filter-chip-value") |> LazyHTML.text()}
           end) == [
             {"transport", "Source", "GitHub"},
             {"state", "State", "Completed"},
             {"usage_profile", "Account", "emisar"},
             {"usage_window", "Usage period", "Last 7 days"}
           ]

    assert LazyHTML.query(
             document,
             ".filter-chip button.filter-chip-remove[phx-click=remove-filter]"
           )
           |> LazyHTML.attribute("phx-value-key") ==
             ~w(transport state usage_profile usage_window)

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
    assert Enum.count(LazyHTML.query(menu, ".filter-values")) == 8
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

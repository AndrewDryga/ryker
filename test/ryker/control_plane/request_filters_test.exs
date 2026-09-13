defmodule Ryker.ControlPlane.RequestFiltersTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{RequestFilters, UsageProjection}

  test "every supported usage dimension has an editable control and missing remains distinct from any" do
    assert UsageProjection.filter_keys() -- RequestFilters.keys() == []

    draft =
      RequestFilters.draft(%{
        "usage_profile" => "emisar",
        "usage_model" => "",
        "usage_window" => "30d"
      })

    assert draft["usage_model"]["match"] == "missing"
    assert draft["usage_profile"]["value"] == "emisar"
    assert RequestFilters.draft(%{"usage_profile" => "emisar"})["usage_window"]["value"] == "7d"

    submitted = %{
      "criteria" => Map.put(draft, "usage_profile", %{"match" => "any", "value" => "emisar"})
    }

    assert RequestFilters.apply(
             %{"mode" => "all", "page" => "4", "state" => "complete"},
             submitted
           ) ==
             %{"mode" => "all", "usage_model" => "", "usage_window" => "30d"}
  end

  test "adding a criterion does not apply it or erase typed drafts on live refresh" do
    draft = RequestFilters.edit(%{}, %{"add_filter" => "usage_profile"})
    assert draft["usage_profile"] == %{"match" => "equals", "value" => ""}
    assert RequestFilters.apply(%{}, %{"criteria" => draft}) == %{}

    typed = %{
      "criteria" => %{"usage_profile" => %{"match" => "equals", "value" => "emisar"}},
      "add_filter" => "state"
    }

    updated = RequestFilters.edit(draft, typed)
    assert updated["usage_profile"]["value"] == "emisar"
    assert Map.has_key?(updated, "state")
    assert RequestFilters.edit(updated, %{"criteria" => [], "add_filter" => "unknown"}) == updated
  end

  test "selecting a person does not also select a bot with the same account name" do
    # GitHub users and bots can retain the same actor string in separate inputs.
    assert RequestFilters.apply(%{}, %{
             "criteria" => %{"usage_actor" => %{"match" => "equals", "value" => "andrew"}}
           }) == %{"usage_actor" => "andrew", "usage_actor_kind" => "user"}
  end

  test "disabled criteria can return to an editable equality match" do
    # Disabled value controls are omitted by the browser when the match changes.
    for match <- ~w(missing any) do
      draft = %{"usage_profile" => %{"match" => match, "value" => "emisar"}}

      edited =
        RequestFilters.edit(draft, %{"criteria" => %{"usage_profile" => %{"match" => "equals"}}})

      assert edited["usage_profile"] == %{"match" => "equals", "value" => "emisar"}
    end
  end

  test "not recorded criteria use each dimension's actual missing representation" do
    params =
      RequestFilters.apply(%{}, %{
        "criteria" => %{
          "usage_provider" => %{"match" => "missing"},
          "usage_work_kind" => %{"match" => "missing"}
        }
      })

    assert params == %{"usage_provider" => "unrecorded", "usage_work_kind" => "unclassified"}
    draft = RequestFilters.draft(params)
    assert draft["usage_provider"]["match"] == "missing"
    assert draft["usage_work_kind"]["match"] == "missing"
  end

  test "malformed and oversized filter input cannot become a query or executable markup" do
    draft = %{"usage_profile" => %{"match" => "equals", "value" => "emisar"}}

    for value <- [%{}, String.duplicate("x", 513), nil] do
      assert RequestFilters.edit(draft, %{
               "criteria" => %{"usage_profile" => %{"match" => "equals", "value" => value}}
             }) == draft
    end

    assert RequestFilters.apply(%{}, %{"criteria" => %{"state" => %{"match" => "missing"}}}) ==
             %{}

    assert RequestFilters.draft(%{"usage_profile" => %{"bad" => "nested"}}) == %{}

    html =
      render_component(&RequestFilters.render/1, %{
        draft: RequestFilters.draft(%{"usage_profile" => "<script>"}),
        values: [],
        params: %{"usage_profile" => "<script>", "mode" => %{"bad" => "nested"}},
        path: "/activity"
      })

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end

  test "all criterion types render selected values including preserved values outside the suggestions" do
    params = Map.new(RequestFilters.keys(), &{&1, "retained-value"})
    draft = RequestFilters.draft(params)

    html =
      render_component(&RequestFilters.render/1, %{
        draft: draft,
        values: [],
        params: params,
        path: "/activity"
      })

    for key <- RequestFilters.keys(), do: assert(html =~ "criteria[#{key}][value]")

    for label <- [
          "GitHub",
          "Person",
          "Recorded",
          "Missing",
          "All time",
          "Last 24 hours",
          "Last 7 days",
          "Last 30 days"
        ],
        do: assert(html =~ label)

    assert RequestFilters.clear_usage("/activity", %{
             "q" => "health",
             "mode" => "all",
             "state" => "complete",
             "usage_profile" => "emisar"
           }) == "/activity?mode=all&q=health&state=complete"
  end
end

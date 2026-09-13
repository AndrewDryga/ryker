defmodule Ryker.Slack.AppHomeEditorTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.AppHomeEditor

  test "builds a bounded native editor only for one stale visible entry" do
    review = %{
      "entries" => [
        %{
          "subject" => "checkout-api",
          "value" => "Verify production before changing it."
        }
      ],
      "kind" => "stale"
    }

    assert {:ok, view} = AppHomeEditor.memory_review_view("memory-review:one", review)
    assert view["type"] == "modal"
    assert view["callback_id"] == "ryker_home_edit_memory_review"
    assert Jason.decode!(view["private_metadata"]) == %{"review_ref" => "memory-review:one"}
    assert get_in(view, ["blocks", Access.at(0), "element", "initial_value"]) == "checkout-api"

    assert get_in(view, ["blocks", Access.at(1), "element", "initial_value"]) ==
             "Verify production before changing it."

    assert AppHomeEditor.memory_review_view("memory-review:one", %{
             review
             | "kind" => "duplicate"
           }) == {:error, :memory_review_cannot_edit}

    assert AppHomeEditor.memory_review_view("memory-review:one", %{
             review
             | "entries" => [%{"subject" => "checkout-api", "value" => ""}]
           }) == {:error, :memory_review_cannot_edit}

    assert AppHomeEditor.memory_review_view("memory-review:one", %{
             review
             | "entries" => [%{"subject" => nil, "value" => "valid"}]
           }) == {:error, :memory_review_cannot_edit}

    assert AppHomeEditor.open_memory_review(
             :not_a_slack_api,
             :client,
             "memory-review:one",
             "trigger.1",
             "slack:user:U123",
             "slack:T123"
           ) == {:error, {:invalid_app_home_editor, :api}}
  end
end

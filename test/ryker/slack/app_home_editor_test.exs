defmodule Ryker.Slack.AppHomeEditorTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.AppHomeEditor

  test "editing correction words explains that required checks will be removed" do
    entry = %{
      "subject" => "Deployment review",
      "value" => "Report before and after versions.",
      "requirements" => ["Report both versions."]
    }

    assert {:ok, view} =
             AppHomeEditor.memory_review_view(
               "memory-review:correction",
               %{"kind" => "stale", "entries" => [entry]}
             )

    hint = get_in(view, ["blocks", Access.at(1), "hint", "text"])
    assert hint =~ "removes its required checks"
    assert hint =~ "only the subject keeps"
  end

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
    # Slack rejects the entire editor above its native 3,000-character limit.
    assert get_in(view, ["blocks", Access.at(1), "element", "max_length"]) == 3_000
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

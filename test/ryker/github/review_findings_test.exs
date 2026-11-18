defmodule Ryker.GitHub.ReviewFindingsTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.ReviewFindings

  test "changing reactions does not change the approved comment version" do
    review = review()
    snapshot = ReviewFindings.snapshot(review)
    selected = put_in(review.findings, Enum.map(review.findings, &Map.put(&1, "selected", true)))
    assert ReviewFindings.snapshot(selected) == snapshot
    assert {:ok, [finding]} = ReviewFindings.select(selected, snapshot, ["thread-one"])
    refute Map.has_key?(finding, "selected")
  end

  test "empty, unknown and changed findings never become a fix request" do
    review = review()
    snapshot = ReviewFindings.snapshot(review)
    assert ReviewFindings.select(review, snapshot, []) == {:error, :empty_selection}

    assert ReviewFindings.select(review, snapshot, ["another-thread"]) ==
             {:error, :invalid_selection}

    changed = put_in(review.pull["headRefOid"], String.duplicate("b", 40))
    assert ReviewFindings.select(changed, snapshot, ["thread-one"]) == {:error, :review_changed}
    changed = %{review | findings: [Map.put(hd(review.findings), "body", "Edited finding")]}
    assert ReviewFindings.select(changed, snapshot, ["thread-one"]) == {:error, :review_changed}
    changed = put_in(review.pull["headRefName"], "another-branch")
    assert ReviewFindings.select(changed, snapshot, ["thread-one"]) == {:error, :review_changed}
  end

  defp review do
    %{
      binding: "widget-app",
      app_actor_id: 4321,
      installation_id: 41,
      number: 42,
      pull: %{"headRefOid" => String.duplicate("a", 40)},
      findings: [
        %{
          "thread_id" => "thread-one",
          "body" => "The empty value is not handled.",
          "updated_at" => "2026-11-17T12:00:00Z",
          "selected" => false
        }
      ]
    }
  end
end

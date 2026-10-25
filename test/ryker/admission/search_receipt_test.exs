defmodule Ryker.Admission.SearchReceiptTest do
  use ExUnit.Case, async: true
  alias Ryker.Admission.Context
  alias Ryker.Admission.Ranking

  test "a source eligibility rejection replaces the earlier selection reason" do
    # Ranking offered this request, but source custody later refused it. Keeping
    # 'offered' here would make the search card contradict the actual prompt.
    receipt = %{
      "examined" => 2,
      "offered" => 2,
      "omitted" => 0,
      "selection" => %{
        "version" => 1,
        "items" => [
          %{"episode_id" => "kept", "offered" => true, "reason" => "ranked"},
          %{"episode_id" => "removed", "offered" => true, "reason" => "source_owner"}
        ]
      }
    }

    actual = Ranking.finish_receipt(receipt, ["kept"])
    assert actual["offered"] == 1
    assert actual["omitted"] == 1

    assert List.last(actual["selection"]["items"]) == %{
             "episode_id" => "removed",
             "offered" => false,
             "reason" => "source_unavailable"
           }

    assert hd(actual["selection"]["items"]) == hd(receipt["selection"]["items"])
  end

  test "historical counts stay truthful without inventing missing item reasons" do
    receipt = %{"examined" => 3, "offered" => 2, "omitted" => 1}

    assert Ranking.finish_receipt(receipt, ["kept"]) == %{
             "examined" => 3,
             "offered" => 1,
             "omitted" => 2
           }
  end

  test "inspection metadata has a separate finite budget and cannot enlarge ordinary context" do
    selection = %{"items" => [%{"reason" => String.duplicate("x", 50_000)}]}

    assert Context.validate_snapshot(%{
             "routing_receipt" => %{"selection" => selection},
             "text" => String.duplicate("x", 90_000)
           }) == :ok

    assert {:error, _} = Context.validate_snapshot(%{"text" => String.duplicate("x", 99_000)})

    assert {:error, _} =
             Context.validate_snapshot(%{
               "routing_receipt" => %{"selection" => String.duplicate("x", 66_000)}
             })

    assert {:error, _} = Context.validate_snapshot("not a snapshot")
  end

  test "an unstructured historical search receipt remains ordinary bounded JSON" do
    # Inspection metadata must not make an otherwise valid frozen context raise
    # on admission. Older or malformed receipts are still evidence, not maps.
    for receipt <- [nil, "unstructured", [], false] do
      assert Context.validate_snapshot(%{"routing_receipt" => receipt}) == :ok
    end
  end

  test "eligible results outside the combined pool keep their real pool-limit reason" do
    # Five 50-result lanes can exceed the 200-result pool. Omitting these IDs
    # would leave a method claiming findings that could never be inspected.
    overflow = [%{episode: %{id: "bounded-out"}, lanes: [:text, :meaning]}]
    result = Ranking.select([], %{candidate_limit: 20}, overflow)
    assert result.selected == []

    assert result.selection["items"] == [
             %{
               "episode_id" => "bounded-out",
               "lanes" => ["text", "meaning"],
               "offered" => false,
               "reason" => "pool_limit"
             }
           ]
  end
end

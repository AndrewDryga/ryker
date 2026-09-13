defmodule Ryker.State.KnowledgeUpdateTest do
  use ExUnit.Case, async: true
  alias Ryker.Admission.Decision
  alias Ryker.State.KnowledgeUpdate

  test "knowledge schema rejects every proposal the host cannot accept" do
    # Schema/host drift causes repeated routing repair instead of useful passive learning.
    proposal = %{
      "topic_key" => "draft-ai-suggestions",
      "title" => "Keep draft-ai-suggestions",
      "summary" =>
        "U03EPT4RP5M wants to keep `draft-ai-suggestions` and plans to look into it at an unspecified future time.",
      "topics" => ["draft-ai-suggestions"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    schema = JSV.build!(KnowledgeUpdate.json_schema())
    assert {:ok, ^proposal} = JSV.validate(proposal, schema, cast: false)

    for change <- [
          %{"title" => " \n\t"},
          %{"summary" => <<0>>},
          %{"topics" => [" "]},
          %{"anchors" => [" "]},
          %{"anchors" => ["same", "same"]},
          %{"anchors" => Enum.map(1..9, &to_string/1)},
          %{
            "target_ref" => "knowledge:------------------------------------",
            "expected_version" => 1
          },
          %{"target_ref" => "knowledge:00000000-0000-0000-0000-000000000000"},
          %{"expected_version" => 1}
        ] do
      invalid = Map.merge(proposal, change)
      assert {:error, _} = KnowledgeUpdate.prepare(invalid)
      assert {:error, _} = JSV.validate(invalid, schema, cast: false)
    end

    decision = %{
      "action" => "ignore",
      "episode_ref" => nil,
      "relation" => "unrelated",
      "repository_source" => nil,
      "reason" => "Learn without responding.",
      "reaction" => nil,
      "work_class" => nil,
      "knowledge" => proposal
    }

    schema = JSV.build!(Decision.json_schema())

    for invalid <- [decision, Map.put(decision, "observation", nil)] do
      assert {:error, _} = Decision.parse(invalid)
      assert {:error, _} = JSV.validate(invalid, schema, cast: false)
    end

    with_note = Map.put(decision, "observation", Map.take(proposal, ~w(summary topics)))
    assert {:error, _} = Decision.parse(with_note)
    assert {:error, _} = JSV.validate(with_note, schema, cast: false)
    valid = Map.delete(decision, "knowledge")
    assert {:ok, _} = Decision.parse(valid)
    assert {:ok, ^valid} = JSV.validate(valid, schema, cast: false)
  end
end

defmodule Responder.Slack.Admission.DecisionTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Admission.Decision

  test "parses each supported generic admission action" do
    cases = [
      {%{"action" => "start_episode", "episode_ref" => nil, "relation" => "unrelated"},
       :start_episode},
      {%{
         "action" => "continue_episode",
         "episode_ref" => "candidate-1",
         "relation" => "same_work"
       }, :continue_episode},
      {%{"action" => "reply", "episode_ref" => nil, "relation" => "unrelated"}, :reply},
      {%{
         "action" => "react",
         "episode_ref" => nil,
         "reaction" => %{"emoji_name" => "eyes"},
         "relation" => "unrelated"
       }, :react},
      {%{"action" => "ignore", "episode_ref" => nil, "relation" => "unrelated"}, :ignore}
    ]

    for {fields, expected_action} <- cases do
      assert {:ok, decision} =
               fields
               |> Map.put_new("reaction", nil)
               |> Map.put("reason", "A short factual reason.")
               |> Decision.parse()

      assert decision.action == expected_action
    end
  end

  test "permits a new episode to carry history without reusing its destination" do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => "candidate-older-cycle",
               "reaction" => nil,
               "relation" => "history_only",
               "reason" => "This is a new lifecycle related to the older work."
             })

    assert decision.relation == :history_only
    assert decision.episode_ref == "candidate-older-cycle"
  end

  test "rejects unknown fields and inconsistent action shapes" do
    assert {:error, {:invalid_decision, :fields}} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "Duplicate event.",
               "thread_ts" => "the model cannot route"
             })

    assert {:error, {:invalid_decision, :episode_ref}} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Continue it."
             })

    assert {:error, {:invalid_decision, :relation}} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => "candidate-1",
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Ignore it."
             })
  end

  test "publishes an exact JSON schema for model self-validation" do
    schema = Decision.json_schema()

    assert schema["additionalProperties"] == false
    assert schema["required"] == ["action", "episode_ref", "reaction", "relation", "reason"]

    assert schema["properties"]["action"]["enum"] ==
             ~w(start_episode continue_episode reply react ignore)

    assert schema["properties"]["relation"]["enum"] ==
             ~w(same_work history_only unrelated)

    assert length(schema["oneOf"]) == 8
  end

  test "schema-valid Unicode and text boundaries are accepted by the host parser" do
    schema = JSV.build!(Decision.json_schema())

    valid = decision_document(reason: String.duplicate("🙂", 512))
    assert {:ok, ^valid} = JSV.validate(valid, schema, cast: false)
    assert {:ok, _decision} = Decision.parse(valid)

    for reason <- ["", " \n\t", <<0>>, String.duplicate("x", 513)] do
      document = decision_document(reason: reason)
      assert {:error, _validation_error} = JSV.validate(document, schema, cast: false)
      assert {:error, {:invalid_decision, :reason}} = Decision.parse(document)
    end
  end

  test "a reaction is complete enough for the Slack gateway to execute" do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "white_check_mark"},
               "relation" => "unrelated",
               "reason" => "Acknowledge the update without adding another message."
             })

    assert decision.reaction == %{emoji_name: "white_check_mark"}

    assert {:error, {:invalid_decision, :reaction}} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "This cannot be delivered without an emoji name."
             })
  end

  test "retry identity ignores prose but retains every executable choice" do
    assert {:ok, first} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "reason" => "Acknowledge this update."
             })

    paraphrased = %{first | reason: "The update only needs an acknowledgement."}
    different = %{first | reaction: %{emoji_name: "thumbsup"}}

    assert Decision.fingerprint(first) == Decision.fingerprint(paraphrased)
    refute Decision.fingerprint(first) == Decision.fingerprint(different)
  end

  defp decision_document(overrides) do
    defaults = %{
      "action" => "reply",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "Answer directly."
    }

    Enum.reduce(overrides, defaults, fn {key, value}, document ->
      Map.put(document, Atom.to_string(key), value)
    end)
  end
end

defmodule Ryker.Continuity.ConversationSummaryStateTest do
  use ExUnit.Case, async: true
  alias Ryker.Continuity.ConversationSummaryState

  # The schema promises each text 2,000 characters, as JSON Schema counts
  # them, and the host held it to 2,000 bytes: a summary in Ukrainian, two
  # bytes a letter, was refused at half the length the model was told
  # (2026-10-08). References stay ASCII and are held in bytes.
  test "a summary is held to the characters its schema promises, in any language" do
    ukrainian = String.duplicate("ї", 1_500)

    assert {:ok, _state} = ConversationSummaryState.prepare(state(%{"goal" => ukrainian}))
    assert {:ok, _state} = ConversationSummaryState.prepare(state(%{"decisions" => [ukrainian]}))

    assert ConversationSummaryState.prepare(
             state(%{"decisions" => [String.duplicate("ї", 2_001)]})
           ) == {:error, {:invalid_conversation_summary, "decisions"}}

    assert ConversationSummaryState.prepare(
             state(%{"evidence_refs" => [String.duplicate("ї", 600)]})
           ) == {:error, {:invalid_conversation_summary, "evidence_refs"}}
  end

  defp state(fields) do
    ConversationSummaryState.fields()
    |> Map.new(&{&1, if(&1 in ConversationSummaryState.list_fields(), do: [], else: nil)})
    |> Map.merge(fields)
  end
end

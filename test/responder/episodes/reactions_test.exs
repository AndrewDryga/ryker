defmodule Responder.Episodes.ReactionsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes.Reactions

  @now ~U[2026-09-03 09:00:00.000000Z]

  test "passive feedback rejects malformed authority before resolving a target" do
    valid = %{
      action: :add,
      actor_ref: "U123",
      emoji_name: "eyes",
      event_ref: "Ev-reaction",
      occurred_at: @now,
      source: %{kind: "slack", ref: "T123"},
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: "1787832000.000100",
        transport: "slack"
      }
    }

    cases = [
      {:fields, Map.put(valid, :authority, "approve")},
      {:action, %{valid | action: :approve}},
      {:actor_ref, %{valid | actor_ref: ""}},
      {:emoji_name, %{valid | emoji_name: "eyes:ship"}},
      {:event_ref, %{valid | event_ref: ""}},
      {:occurred_at, %{valid | occurred_at: DateTime.to_iso8601(@now)}},
      {:source, %{valid | source: %{kind: "slack", ref: "T123", role: "admin"}}},
      {:target, %{valid | target: Map.put(valid.target, :repository, "other/repo")}},
      {:transport, put_in(valid, [:target, :transport], "control_plane")}
    ]

    Enum.each(cases, fn {field, attributes} ->
      assert Reactions.record(attributes) ==
               {:error, {:invalid_conversation_reaction, field}}
    end)

    assert Reactions.record(%{}) == {:error, {:invalid_conversation_reaction, :fields}}
    assert Reactions.record(:reaction) == {:error, {:invalid_conversation_reaction, :fields}}
    assert Reactions.record(valid) == {:error, :conversation_reaction_target_not_found}
  end

  test "empty and invalid projections remain bounded empty documents" do
    assert Reactions.current_for_episodes([]) == %{}
    assert Reactions.current_for_episodes(:all) == %{}

    assert Reactions.model_context(nil, 0) == %{
             "current" => [],
             "events" => []
           }
  end
end

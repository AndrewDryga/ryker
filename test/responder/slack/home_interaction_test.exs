defmodule Responder.Slack.HomeInteractionTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.HomeInteraction

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "accepts only host-issued App Home lifecycle actions" do
    assert {:ok, interaction} =
             HomeInteraction.from_socket(
               envelope("responder_home_forget_memory", "memory:abc-123"),
               "T123",
               @now
             )

    assert interaction.action == :forget_memory
    assert interaction.actor_ref == "U123"
    assert interaction.event_ref == "interaction:env-home-control"
    assert interaction.resource_ref == "memory:abc-123"

    assert {:ok, review} =
             HomeInteraction.from_socket(
               envelope("responder_home_merge_memory_review", "memory-review:abc-123"),
               "T123",
               @now
             )

    assert review.action == :merge_memory_review

    assert HomeInteraction.from_socket(
             envelope("responder_home_forget_memory", "schedule:abc-123"),
             "T123",
             @now
           ) == :ignore

    assert HomeInteraction.from_socket(
             envelope("model_chosen_action", "memory:abc-123"),
             "T123",
             @now
           ) == :ignore
  end

  test "rejects copied, foreign-workspace, and message controls" do
    assert envelope("responder_home_pause_schedule", "schedule:abc")
           |> put_in(["payload", "team", "id"], "T999")
           |> HomeInteraction.from_socket("T123", @now) == :ignore

    assert envelope("responder_home_pause_schedule", "schedule:abc")
           |> put_in(["payload", "container", "type"], "message")
           |> HomeInteraction.from_socket("T123", @now) == :ignore
  end

  defp envelope(action_id, value) do
    %{
      "envelope_id" => "env-home-control",
      "payload" => %{
        "actions" => [%{"action_id" => action_id, "type" => "button", "value" => value}],
        "container" => %{"type" => "view", "view_id" => "V123"},
        "team" => %{"id" => "T123"},
        "type" => "block_actions",
        "user" => %{"id" => "U123"},
        "view" => %{"id" => "V123", "type" => "home"}
      },
      "type" => "interactive"
    }
  end
end

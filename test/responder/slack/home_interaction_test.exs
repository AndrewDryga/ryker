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
    assert interaction.trigger_ref == "trigger.123"

    assert {:ok, review} =
             HomeInteraction.from_socket(
               envelope("responder_home_merge_memory_review", "memory-review:abc-123"),
               "T123",
               @now
             )

    assert review.action == :merge_memory_review

    assert {:ok, repeated} =
             HomeInteraction.from_socket(
               envelope("responder_home_merge_memory_review__i2", "memory-review:abc-123"),
               "T123",
               @now
             )

    assert repeated.action == :merge_memory_review

    for {action_id, value, action} <- [
          {"responder_home_edit_memory_review", "memory-review:abc-123", :edit_memory_review},
          {"responder_home_pause_schedule", "schedule-control:schedule:abc-123:4",
           :pause_schedule},
          {"responder_home_pause_schedule", "schedule:legacy", :pause_schedule},
          {"responder_home_disable_behavior", "behavior:legacy", :disable_behavior},
          {"responder_home_run_schedule", "schedule:abc-123", :run_schedule},
          {"responder_home_retry_publication", "publication-recovery:abc-123:4",
           :retry_publication},
          {"responder_home_update_publication", "publication-recovery:abc-123:4",
           :update_publication},
          {"responder_home_discard_publication", "publication-recovery:abc-123:4",
           :discard_publication},
          {"responder_home_discard_workspace",
           "responder-work-control:responder-work:abc:session:1:#{String.duplicate("a", 64)}",
           :discard_workspace},
          {"responder_home_open", "task-card:abc-123", :open_resource},
          {"responder_home_show_collection", "home-collection:schedules:0", :show_collection},
          {"responder_home_show_collection", "home-collection:knowledge:20", :show_collection},
          {"responder_home_show_dashboard", "home-collection:dashboard", :show_dashboard}
        ] do
      assert {:ok, parsed} = HomeInteraction.from_socket(envelope(action_id, value), "T123", @now)
      assert parsed.action == action
      assert parsed.resource_ref == value
    end

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

    assert HomeInteraction.from_socket(
             envelope("responder_home_show_collection", "schedule:abc-123"),
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

    assert envelope(nil, "schedule:abc")
           |> HomeInteraction.from_socket("T123", @now) == :ignore

    assert envelope("responder_home_pause_schedule__i1", "schedule:abc")
           |> HomeInteraction.from_socket("T123", @now) == :ignore
  end

  defp envelope(action_id, value) do
    %{
      "envelope_id" => "env-home-control",
      "payload" => %{
        "actions" => [%{"action_id" => action_id, "type" => "button", "value" => value}],
        "container" => %{"type" => "view", "view_id" => "V123"},
        "team" => %{"id" => "T123"},
        "trigger_id" => "trigger.123",
        "type" => "block_actions",
        "user" => %{"id" => "U123"},
        "view" => %{"id" => "V123", "type" => "home"}
      },
      "type" => "interactive"
    }
  end
end

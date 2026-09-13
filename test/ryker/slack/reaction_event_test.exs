defmodule Ryker.Slack.ReactionEventTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.ReactionEvent

  @identity %{bot_ref: "B-BOT", bot_user_ref: "U-BOT", workspace_ref: "T123"}

  test "normalizes authenticated feedback on an exact Ryker message" do
    assert {:ok, reaction} =
             ReactionEvent.from_socket(envelope("reaction_added", "+1"), @identity)

    assert reaction == %{
             action: :add,
             actor_ref: "U123",
             emoji_name: "+1",
             event_ref: "Ev-reaction-1",
             occurred_at: DateTime.from_unix!(1_787_832_001_000_200, :microsecond),
             source: %{kind: "slack", ref: "T123"},
             target: %{
               conversation_ref: "slack:T123:C456",
               message_ref: "1787832000.000100",
               transport: "slack"
             }
           }

    assert {:ok, removed} =
             ReactionEvent.from_socket(envelope("reaction_removed", "eyes"), @identity)

    assert removed.action == :remove
    assert removed.emoji_name == "eyes"
  end

  test "ignores reactions that are not user feedback on this bot's own message" do
    other_author = put_in(envelope(), ["payload", "event", "item_user"], "U-OTHER")
    assert ReactionEvent.from_socket(other_author, @identity) == :ignore

    self_reaction = put_in(envelope(), ["payload", "event", "user"], "U-BOT")
    assert ReactionEvent.from_socket(self_reaction, @identity) == :ignore

    assert ReactionEvent.from_socket(%{"type" => "events_api"}, @identity) == :ignore
  end

  test "rejects malformed feedback instead of widening its authority" do
    cases = [
      put_in(envelope(), ["payload", "event", "reaction"], "eyes:ship"),
      put_in(envelope(), ["payload", "event", "item", "type"], "file"),
      put_in(envelope(), ["payload", "event", "user"], ""),
      put_in(envelope(), ["payload", "event", "event_ts"], "tomorrow")
    ]

    Enum.each(cases, fn invalid ->
      assert {:error, {:invalid_slack_reaction_event, _field}} =
               ReactionEvent.from_socket(invalid, @identity)
    end)

    wrong_workspace = put_in(envelope(), ["payload", "team_id"], "T-OTHER")
    assert ReactionEvent.from_socket(wrong_workspace, @identity) == :ignore
  end

  defp envelope(type \\ "reaction_added", emoji \\ "eyes") do
    %{
      "envelope_id" => "env-reaction-1",
      "payload" => %{
        "event" => %{
          "event_ts" => "1787832001.000200",
          "item" => %{
            "channel" => "C456",
            "ts" => "1787832000.000100",
            "type" => "message"
          },
          "item_user" => "U-BOT",
          "reaction" => emoji,
          "type" => type,
          "user" => "U123"
        },
        "event_id" => "Ev-reaction-1",
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end
end

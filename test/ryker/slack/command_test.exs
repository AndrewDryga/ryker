defmodule Ryker.Slack.CommandTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.Command

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "normalizes only the configured ryker slash command" do
    assert {:ok, command} = Command.from_socket(envelope("proactive global on"), "T123", @now)

    assert command.actor_ref == "U123"
    assert command.channel_ref == "C456"
    assert command.event_ref == "slash:env-command"
    assert command.text == "proactive global on"
    assert command.workspace_ref == "T123"

    assert Command.from_socket(envelope("status"), "T999", @now) == :ignore

    assert Command.from_socket(
             put_in(envelope("status"), ["payload", "command"], "/foreign"),
             "T123",
             @now
           ) == :ignore

    assert Command.from_socket(%{}, "T123", @now) == :ignore
  end

  defp envelope(text) do
    %{
      "accepts_response_payload" => true,
      "envelope_id" => "env-command",
      "payload" => %{
        "channel_id" => "C456",
        "command" => "/ryker",
        "response_url" => "https://hooks.slack.com/commands/secret",
        "team_id" => "T123",
        "text" => text,
        "trigger_id" => "trigger-1",
        "user_id" => "U123"
      },
      "type" => "slash_commands"
    }
  end
end

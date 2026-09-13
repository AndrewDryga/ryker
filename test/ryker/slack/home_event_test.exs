defmodule Ryker.Slack.HomeEventTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.HomeEvent

  @identity %{bot_ref: "B999", bot_user_ref: "U999", workspace_ref: "T123"}

  test "accepts only the bound workspace Home tab event" do
    assert {:ok, event} = HomeEvent.from_socket(envelope("home"), @identity)
    assert event.actor_ref == "U123"
    assert event.event_ref == "Ev-home-1"
    assert event.workspace_ref == "T123"

    assert HomeEvent.from_socket(envelope("messages"), @identity) == :ignore

    assert envelope("home")
           |> put_in(["payload", "team_id"], "T999")
           |> HomeEvent.from_socket(@identity) == :ignore
  end

  test "ignores malformed and unsupported event callbacks" do
    assert envelope("home")
           |> put_in(["payload", "event", "user"], nil)
           |> HomeEvent.from_socket(@identity) == :ignore

    assert envelope("home")
           |> put_in(["payload", "event", "type"], "message")
           |> HomeEvent.from_socket(@identity) == :ignore

    assert HomeEvent.from_socket(%{}, @identity) == :ignore
  end

  defp envelope(tab) do
    %{
      "envelope_id" => "env-home-1",
      "payload" => %{
        "event" => %{
          "event_ts" => "1787832001.000200",
          "tab" => tab,
          "type" => "app_home_opened",
          "user" => "U123"
        },
        "event_id" => "Ev-home-1",
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end
end

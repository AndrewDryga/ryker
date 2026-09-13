defmodule Ryker.Slack.MembershipTransitionTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.MembershipTransition

  test "normalizes only this bot's join leave and channel deletion events" do
    assert {:ok, joined} =
             MembershipTransition.from_socket(
               envelope(%{
                 "channel" => "C456",
                 "event_ts" => "1787832001.000200",
                 "inviter" => "U123",
                 "type" => "member_joined_channel",
                 "user" => "U-BOT"
               }),
               identity()
             )

    assert joined.kind == :joined
    assert joined.actor_ref == "U123"
    assert joined.channel_ref == "C456"
    assert joined.event_ref == "Ev-membership"

    assert {:ok, left} =
             MembershipTransition.from_socket(
               envelope(%{
                 "channel" => "C456",
                 "event_ts" => "1787832002.000200",
                 "type" => "member_left_channel",
                 "user" => "U-BOT"
               }),
               identity()
             )

    assert left.kind == :left
    assert left.actor_ref == nil

    assert {:ok, deleted} =
             MembershipTransition.from_socket(
               envelope(%{
                 "channel" => "C456",
                 "event_ts" => "1787832003.000200",
                 "type" => "channel_deleted"
               }),
               identity()
             )

    assert deleted.kind == :deleted

    assert {:ok, archived} =
             MembershipTransition.from_socket(
               envelope(%{
                 "channel" => "C456",
                 "event_ts" => "1787832004.000200",
                 "type" => "channel_archive",
                 "user" => "U123"
               }),
               identity()
             )

    assert archived.kind == :archived
    assert archived.actor_ref == "U123"

    assert {:ok, unarchived} =
             MembershipTransition.from_socket(
               envelope(%{
                 "channel" => "G456",
                 "event_ts" => "1787832005.000200",
                 "type" => "group_unarchive",
                 "user" => "U123"
               }),
               identity()
             )

    assert unarchived.kind == :unarchived
    assert unarchived.channel_ref == "G456"

    assert {:ok, group_deleted} =
             MembershipTransition.from_socket(
               envelope(%{"channel" => "G789", "type" => "group_deleted"}),
               identity()
             )

    assert group_deleted.kind == :deleted
    assert group_deleted.occurred_at == ~U[2026-08-27 12:00:01Z]

    assert {:ok, group_archived} =
             MembershipTransition.from_socket(
               envelope(%{
                 "channel" => "G789",
                 "type" => "group_archive",
                 "user" => "U123"
               }),
               identity()
             )

    assert group_archived.kind == :archived

    foreign_bot =
      envelope(%{
        "channel" => "C456",
        "event_ts" => "1787832001.000200",
        "type" => "member_joined_channel",
        "user" => "U-OTHER"
      })

    assert MembershipTransition.from_socket(foreign_bot, identity()) == :ignore

    assert MembershipTransition.from_socket(envelope(%{"type" => "message"}), identity()) ==
             :ignore

    assert MembershipTransition.from_socket(
             envelope(%{
               "channel" => "invalid-channel",
               "event_ts" => "invalid",
               "type" => "channel_deleted"
             }),
             identity()
           ) == {:error, {:invalid_slack_membership, :channel_ref}}

    assert MembershipTransition.from_socket(
             envelope(%{
               "channel" => "C456",
               "event_ts" => "invalid",
               "type" => "channel_deleted"
             }),
             identity()
           ) == {:error, {:invalid_slack_membership, :occurred_at}}

    assert MembershipTransition.from_socket(
             envelope(%{
               "channel" => "C456",
               "event_ts" => "1787832001.1",
               "inviter" => "invalid-actor",
               "type" => "member_joined_channel",
               "user" => "U-BOT"
             }),
             identity()
           ) == {:error, {:invalid_slack_membership, :actor_ref}}
  end

  defp envelope(event) do
    %{
      "payload" => %{
        "event" => event,
        "event_id" => "Ev-membership",
        "event_time" => 1_787_832_001,
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp identity,
    do: %{bot_ref: "B-BOT", bot_user_ref: "U-BOT", workspace_ref: "T123"}
end

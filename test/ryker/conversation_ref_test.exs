defmodule Ryker.ConversationRefTest do
  # Forty modules wrote these refs out by hand, and about twenty-five read
  # them back with splits of their own, until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.ConversationRef

  test "a Slack channel's ref, its workspace's scope and the prefix of its channels" do
    assert ConversationRef.slack("T123", "C456") == "slack:T123:C456"

    assert ConversationRef.slack(%{workspace_ref: "T123", channel_ref: "C456"}) ==
             "slack:T123:C456"

    assert ConversationRef.slack_workspace("T123") == "slack:T123"
    assert ConversationRef.slack_prefix("T123") == "slack:T123:"
  end

  test "a ref reads back to its workspace and channel, and nothing else does" do
    assert ConversationRef.parse_slack("slack:T123:C456") == {:ok, "T123", "C456"}
    assert ConversationRef.parse_slack("slack:T123") == :error
    assert ConversationRef.parse_slack("slack:T123:") == :error
    assert ConversationRef.parse_slack("slack::C456") == :error
    assert ConversationRef.parse_slack("slack:T123:C456:extra") == :error
    assert ConversationRef.slack_channel("slack:T123:C456") == "C456"
    assert ConversationRef.slack_channel("slack:T123") == nil
    assert ConversationRef.parse_slack("control-plane:lab:one") == :error
    assert ConversationRef.parse_slack(nil) == :error
  end
end

defmodule Ryker.Slack.ChannelFenceTest do
  use Ryker.DataCase, async: true

  alias Ryker.Repo
  alias Ryker.Slack.ChannelFence

  # A Slack conversation the fence could not read passed it as if it named no
  # channel, so a write naming a deleted channel under a mangled ref was never
  # refused (2026-10-04 review).
  test "a Slack conversation the fence cannot read is refused, not let through" do
    for conversation <- ["slack:T1", "slack:T1:", "slack::C1", "slack:T1:C1:extra", "C1"] do
      assert Repo.transaction(fn ->
               ChannelFence.authorize_in_transaction("slack", conversation)
             end) == {:ok, {:error, :invalid_slack_conversation}},
             conversation
    end

    assert Repo.transaction(fn ->
             ChannelFence.authorize_in_transaction("slack", "slack:T1:C1")
           end) == {:ok, :ok}

    assert Repo.transaction(fn ->
             ChannelFence.authorize_in_transaction("slack", "slack:T1:D1")
           end) == {:ok, :ok}

    assert Repo.transaction(fn ->
             ChannelFence.authorize_in_transaction("control_plane", "control-plane:chat:1")
           end) == {:ok, :ok}
  end
end

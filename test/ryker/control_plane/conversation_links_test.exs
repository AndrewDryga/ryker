defmodule Ryker.ControlPlane.ConversationLinksTest do
  use ExUnit.Case, async: false
  alias Ryker.ControlPlane.{Activity, ConversationMemory}
  alias Ryker.Slack.Names

  test "a remembered source reply keeps its own message and parent thread" do
    start_supervised!(
      {Names,
       workspace: "T123",
       workspace_url: "https://example-team.slack.com",
       fetch: fn _ -> {:error, :unavailable} end}
    )

    assert ConversationMemory.source_message(%{
             transport: "slack",
             conversation_ref: "slack:T123:C456",
             source_message_ref: "1787832001.000200",
             thread_ref: "1787832000.000100"
           }) ==
             "https://example-team.slack.com/archives/C456/p1787832001000200?cid=C456&thread_ts=1787832000.000100"
  end

  # The surface was renamed from /lab to /conversations on 2026-09-13. The
  # stored conversation ref stayed control-plane:lab:<uuid>, so every link the
  # control plane derives from it is a place the rename could quietly orphan a
  # retained conversation: memory notes, usage rows and activity sources all
  # resolve their links from the ref, not from the page that rendered them.
  test "links derived from a retained control-plane conversation ref use the renamed route" do
    id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    assert ConversationMemory.source_message(%{
             transport: "control_plane",
             conversation_ref: "control-plane:lab:" <> id
           }) == "/conversations/" <> id

    assert ConversationMemory.source_message(%{
             transport: "slack",
             conversation_ref: "slack:T123:C456"
           }) == nil

    assert Activity.conversation_path("control_plane", "control-plane:lab:" <> id) =~
             "conversation=control-plane:lab:" <> id
  end

  test "the direct-conversation transport is named without Lab phrasing" do
    assert Names.destination("control-plane:lab:uuid") == "Direct conversation"
    refute Names.destination("control-plane:lab:uuid") =~ "Lab"
  end
end

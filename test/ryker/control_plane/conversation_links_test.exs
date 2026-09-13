defmodule Ryker.ControlPlane.ConversationLinksTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{Activity, ConversationMemory, SlackNames}

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
             "conversation=control-plane%3Alab%3A" <> id
  end

  test "the direct-conversation transport is named without Lab phrasing" do
    assert SlackNames.destination("control-plane:lab:uuid") == "Direct conversation"
    assert SlackNames.destination("control_plane:control-plane:lab:uuid") == "Direct conversation"
    refute SlackNames.destination("control-plane:lab:uuid") =~ "Lab"
  end
end

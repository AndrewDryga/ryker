defmodule Ryker.ControlPlane.ChannelScopeTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{ChannelScope, PagedRelation}

  test "raw Slack refs derive the canonical refs every context table stores" do
    assert {:ok, scope} = ChannelScope.new("T0BHXKZJVDX", "C0BLU1GACKC")

    assert scope == %ChannelScope{
             workspace_ref: "T0BHXKZJVDX",
             channel_ref: "C0BLU1GACKC",
             canonical_workspace_ref: "slack:T0BHXKZJVDX",
             conversation_ref: "slack:T0BHXKZJVDX:C0BLU1GACKC",
             repository_ref: nil
           }

    assert ChannelScope.with_repository(scope, "ryker").repository_ref == "ryker"
    assert ChannelScope.with_repository(scope, nil).repository_ref == nil
    assert ChannelScope.with_repository(scope, "").repository_ref == nil
    refute ChannelScope.direct_message?(scope)
    assert {:ok, direct} = ChannelScope.new("T123", "D456")
    assert ChannelScope.direct_message?(direct)
  end

  test "a ref that cannot be told apart from a canonical ref is refused, not guessed" do
    # "slack:T123" as a workspace would join as "slack:slack:T123:C456" on one
    # table and match nothing on another; the page would then say "No durable
    # records" about a channel that has them.
    for {workspace, channel} <- [
          {"slack:T123", "C456"},
          {"T123", "T123:C456"},
          {"", "C456"},
          {"T123", ""},
          {" T123", "C456"},
          {"T123", "C456\n"},
          {"../T", "C"},
          {nil, "C456"},
          {"T123", 456},
          {String.duplicate("T", 257), "C456"}
        ] do
      assert ChannelScope.new(workspace, channel) == :error, inspect({workspace, channel})
    end
  end

  test "page parameters normalize to a bounded page number" do
    assert PagedRelation.requested(%{"episode_page" => "3"}, "episode_page") == 3
    assert PagedRelation.requested(%{}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => ""}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => "0"}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => "-4"}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => "two"}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => "2.5"}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => ["2"]}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => %{"a" => "2"}}, "episode_page") == 1
    assert PagedRelation.requested(%{"episode_page" => "99999999999"}, "episode_page") == 10_000
    assert PagedRelation.requested(:invalid, "episode_page") == 1
    assert PagedRelation.page_size() == 25
  end
end

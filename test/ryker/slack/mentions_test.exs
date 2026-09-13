defmodule Ryker.Slack.MentionsTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.Mentions

  test "renders only authorized typed Slack entities and keeps raw control syntax inert" do
    authority = %{
      "broadcasts" => ["here"],
      "channels" => ["slack:T123:C456"],
      "user_groups" => ["slack-usergroup:S123"],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    message =
      "Could [@Bruno](slack-user:U123) check [#backend](slack-channel:slack:T123:C456) with [@on-call](slack-usergroup:S123) [@here](slack-broadcast:here)? Raw <!channel> <@U999>."

    assert {:ok, rendered} = Mentions.render(message, authority)
    assert rendered =~ "<@U123>"
    assert rendered =~ "<#C456>"
    assert rendered =~ "<!subteam^S123>"
    assert rendered =~ "<!here>"
    assert rendered =~ "Raw &lt;!channel&gt; &lt;@U999&gt;."
  end

  test "rejects unauthorized, malformed, and overlong typed mentions" do
    authority = %{
      "broadcasts" => [],
      "channels" => ["slack:T123:C456"],
      "user_groups" => [],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    assert [violation] =
             Mentions.violations("Ping [@Mallory](slack-user:U999).", authority)

    assert violation =~ "not authorized"

    assert Mentions.violations("Ping [@Bruno](slack-user:U123", authority) == [
             "Fix the malformed typed Slack entity link before replying."
           ]

    message =
      String.duplicate("a", 12_001) <> " [@Bruno](slack-user:U123)"

    assert Enum.any?(Mentions.violations(message, authority), &String.contains?(&1, "12,000"))
  end

  test "plain messages need no Slack authority and remain safely escaped" do
    assert Mentions.typed?("Hello [@Bruno](slack-user:U123)")
    refute Mentions.typed?("Hello @Bruno")

    assert Mentions.render("Hello <!everyone> & goodbye", nil) ==
             {:ok, "Hello &lt;!everyone&gt; &amp; goodbye"}

    assert Mentions.violations("Hello [@Bruno](slack-user:U123)", nil) == [
             "Remove typed Slack entities from this non-Slack reply."
           ]
  end

  test "malformed mention messages and authority snapshots fail closed" do
    refute Mentions.typed?(:invalid)

    assert Mentions.render(:invalid, nil) ==
             {:error, {:invalid_slack_mentions, :message}}

    assert Mentions.violations(:invalid, nil) == [
             "Remove malformed typed Slack entities from this reply."
           ]

    assert Mentions.prepare_authority(:invalid) ==
             {:error, {:invalid_slack_mention_authority, :fields}}

    valid = %{
      "broadcasts" => [],
      "channels" => ["slack:T123:C456"],
      "user_groups" => [],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    for malformed <- [
          Map.put(valid, "workspace_ref", "not a workspace"),
          Map.put(valid, "users", :invalid),
          Map.put(valid, "users", ["slack-user:U123", "slack-user:U123"]),
          Map.put(valid, "users", [:invalid]),
          Map.put(valid, "channels", :invalid),
          Map.put(valid, "channels", ["slack:T999:C456"]),
          Map.put(valid, "user_groups", :invalid),
          Map.put(valid, "broadcasts", :invalid),
          Map.put(valid, "broadcasts", ["here", "here"]),
          Map.put(valid, "broadcasts", ["all"]),
          Map.put(valid, "unexpected", true)
        ] do
      assert Mentions.prepare_authority(malformed) ==
               {:error, {:invalid_slack_mention_authority, :fields}}
    end
  end
end

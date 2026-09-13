defmodule Ryker.Slack.PostGrantTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.{PostGrant, SourceRef}

  test "a permalink grant honors the explicit root thread timestamp" do
    text =
      "post to <https://example.slack.com/archives/G789/p1787832000000100?thread_ts=1787831000.000099&cid=G789|this thread>: publish the update"

    assert PostGrant.destination_refs(text, "T123", "U-BOT") == [
             SourceRef.thread("T123", "G789", "1787831000.000099")
           ]
  end

  test "foreign, malformed, and untyped destinations never become posting authority" do
    for text <- [
          "post to <https://attacker.example/archives/G789/p1787832000000100>: publish it",
          "post to <https://example.slack.com/not-a-permalink>: publish it",
          "post to <https://example.slack.com/archives/G789/p1787832000000100?thread_ts=invalid>: publish it"
        ] do
      assert PostGrant.destination_refs(text, "T123", "U-BOT") == []
    end

    assert PostGrant.destination_refs(nil, "T123", "U-BOT") == []
    assert PostGrant.destination_refs("post to <#G789>: publish it", nil, "U-BOT") == []
    assert PostGrant.destination_refs(<<255>>, "T123", "U-BOT") == []
  end
end

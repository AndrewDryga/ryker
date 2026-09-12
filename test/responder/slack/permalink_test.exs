defmodule Responder.Slack.PermalinkTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Permalink

  # The 2026-09-12 coverage measurement found two card states that could name a
  # message but not link to it, because the workspace origin was the one part of
  # a Slack permalink the host never stored.
  test "a link is built only from parts that are all exactly what they claim to be" do
    assert Permalink.message_url(
             "https://emisar.slack.com",
             "slack:T0BHXKZJVDX:C0BLU1GACKC",
             "1789161922.548889"
           ) == "https://emisar.slack.com/archives/C0BLU1GACKC/p1789161922548889"

    assert Permalink.message_url(
             "https://emisar.slack.com/",
             "slack:T0BHXKZJVDX:C0BLU1GACKC",
             "1789161922.548889"
           ) == "https://emisar.slack.com/archives/C0BLU1GACKC/p1789161922548889"
  end

  test "anything the host cannot vouch for yields no link at all" do
    for {origin, conversation, message} <- [
          {nil, "slack:T1:C1", "1789161922.548889"},
          {"https://emisar.slack.com", nil, "1789161922.548889"},
          {"https://emisar.slack.com", "slack:T0BHXKZJVDX:C0BLU1GACKC", nil},
          {"http://emisar.slack.com", "slack:T0BHXKZJVDX:C0BLU1GACKC", "1789161922.548889"},
          {"https://evil.example", "slack:T0BHXKZJVDX:C0BLU1GACKC", "1789161922.548889"},
          {"https://emisar.slack.com/archives", "slack:T0BHXKZJVDX:C0BLU1GACKC",
           "1789161922.548889"},
          {"https://emisar.slack.com", "control-plane:lab:abc", "1789161922.548889"},
          {"https://emisar.slack.com", "slack:T0BHXKZJVDX:C0BLU1GACKC", "not-a-timestamp"}
        ] do
      assert Permalink.message_url(origin, conversation, message) == nil
    end
  end
end

defmodule Ryker.Slack.PermalinkTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.Permalink

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

  # Only public channels' ids matched, so a question asked in a private
  # channel or a direct message never got a link (2026-10-04 review).
  test "a private channel's or a direct message's message links like any other" do
    for channel <- ["G0BLU1GACKC", "D0BLU1GACKC"] do
      assert Permalink.message_url(
               "https://emisar.slack.com",
               "slack:T0BHXKZJVDX:#{channel}",
               "1789161922.548889"
             ) == "https://emisar.slack.com/archives/#{channel}/p1789161922548889"
    end
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

  # Six modules built this link by hand until 2026-10-08, one with its query in
  # a different order and one accepting any digits as a message.
  test "Slack's redirect opens a channel or a message, and only from Slack's own ids" do
    assert Permalink.app_redirect("T123", "C456") ==
             "https://slack.com/app_redirect?team=T123&channel=C456"

    assert Permalink.app_redirect("T123", "C456", "1787832000.000100") ==
             "https://slack.com/app_redirect?team=T123&channel=C456&message_ts=1787832000.000100"

    assert Permalink.app_redirect("T123", "c456") == nil
    assert Permalink.app_redirect(nil, "C456") == nil
    assert Permalink.app_redirect("T123", "C456", "12.3") == nil
    assert Permalink.app_redirect("T123", "C456", nil) == nil
  end

  # The Memory page and the timeline each built this link by hand until
  # 2026-10-08, one checking the channel's kind and the other any Slack id.
  test "a message's archive link needs a channel or direct message and Slack's timestamps" do
    assert Permalink.archive_url("C0BLU1GACKC", "1789161922.548889") ==
             "https://slack.com/archives/C0BLU1GACKC/p1789161922548889"

    assert Permalink.archive_url("D0BLU1GACKC", "1789161922.548889", "1789161900.000100") ==
             "https://slack.com/archives/D0BLU1GACKC/p1789161922548889?cid=D0BLU1GACKC&thread_ts=1789161900.000100"

    assert Permalink.archive_url("C0BLU1GACKC", "1789161922.548889", "1789161922.548889") ==
             "https://slack.com/archives/C0BLU1GACKC/p1789161922548889"

    assert Permalink.archive_url("U0123456789", "1789161922.548889") == nil
    assert Permalink.archive_url("C0BLU1GACKC", "12.5") == nil
    assert Permalink.archive_url(nil, "1789161922.548889") == nil
  end
end

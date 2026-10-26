defmodule Ryker.Slack.PermalinkTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.Permalink

  # The 2026-09-12 coverage measurement found two card states that could name a
  # message but not link to it, because the workspace origin was the one part of
  # a Slack permalink the host never stored.
  test "a link is built only from parts that are all exactly what they claim to be" do
    assert Permalink.archive_url(
             "https://emisar.slack.com",
             "C0BLU1GACKC",
             "1789161922.548889"
           ) == "https://emisar.slack.com/archives/C0BLU1GACKC/p1789161922548889"

    assert Permalink.archive_url(
             "https://emisar.slack.com/",
             "C0BLU1GACKC",
             "1789161922.548889"
           ) == "https://emisar.slack.com/archives/C0BLU1GACKC/p1789161922548889"
  end

  # Only public channels' ids matched, so a question asked in a private
  # channel or a direct message never got a link (2026-10-04 review).
  test "a private channel's or a direct message's message links like any other" do
    for channel <- ["G0BLU1GACKC", "D0BLU1GACKC"] do
      assert Permalink.archive_url(
               "https://emisar.slack.com",
               channel,
               "1789161922.548889"
             ) == "https://emisar.slack.com/archives/#{channel}/p1789161922548889"
    end
  end

  test "anything the host cannot vouch for yields no link at all" do
    for {origin, conversation, message} <- [
          {nil, "C1", "1789161922.548889"},
          {"https://emisar.slack.com", nil, "1789161922.548889"},
          {"https://emisar.slack.com", "C0BLU1GACKC", nil},
          {"http://emisar.slack.com", "C0BLU1GACKC", "1789161922.548889"},
          {"https://evil.example", "C0BLU1GACKC", "1789161922.548889"},
          {"https://emisar.slack.com/archives", "C0BLU1GACKC", "1789161922.548889"},
          {"https://emisar.slack.com", "control-plane:lab:abc", "1789161922.548889"},
          {"https://emisar.slack.com", "C0BLU1GACKC", "not-a-timestamp"}
        ] do
      assert Permalink.archive_url(origin, conversation, message) == nil
    end
  end

  # Six modules built this link by hand until 2026-10-08, one with its query in
  # a different order and one accepting any digits as a message.
  test "Slack's redirect opens a channel or person, and only from Slack's own ids" do
    assert Permalink.app_redirect("T123", "C456") ==
             "https://slack.com/app_redirect?team=T123&channel=C456"

    assert Permalink.app_redirect("T123", "c456") == nil
    assert Permalink.app_redirect(nil, "C456") == nil
  end

  # The Memory page and the timeline each built this link by hand until
  # 2026-10-08, one checking the channel's kind and the other any Slack id.
  test "a message's archive link needs its workspace origin and preserves its reply and parent" do
    # A tenant's timeline opened the operator's default workspace instead of
    # the source workspace, so an existing message appeared broken (2026-10-26).
    assert Permalink.archive_url("https://example-team.slack.com", "C456", "1789161922.548889") ==
             "https://example-team.slack.com/archives/C456/p1789161922548889"

    assert Permalink.archive_url(
             "https://example-team.slack.com/",
             "D456",
             "1789161922.548889",
             "1789161900.000100"
           ) ==
             "https://example-team.slack.com/archives/D456/p1789161922548889?cid=D456&thread_ts=1789161900.000100"

    assert Permalink.archive_url(
             "https://example-team.slack.com",
             "C456",
             "1789161922.548889",
             "1789161922.548889"
           ) ==
             "https://example-team.slack.com/archives/C456/p1789161922548889"

    for origin <- [
          nil,
          "https://slack.com",
          "https://app.slack.com",
          "https://evil.example",
          "http://example-team.slack.com"
        ] do
      assert Permalink.archive_url(origin, "C456", "1789161922.548889") == nil
    end

    assert Permalink.archive_url("https://example-team.slack.com", "U123", "1789161922.548889") ==
             nil

    assert Permalink.archive_url("https://example-team.slack.com", "C456", "12.5") == nil

    assert Permalink.archive_url(
             "https://example-team.slack.com",
             "C456",
             "1789161922.548889",
             "invalid"
           ) == "https://example-team.slack.com/archives/C456/p1789161922548889"

    assert Permalink.archive_url("https://example-team.slack.com", nil, "1789161922.548889") ==
             nil
  end

  test "Home accepts only exact generated workspace message URLs" do
    url =
      Permalink.archive_url(
        "https://example-team.slack.com",
        "C456",
        "1789161922.548889",
        "1789161900.000100"
      )

    assert Permalink.archive_url?(url)

    assert Permalink.archive_url?(
             Permalink.archive_url("https://example-team.slack.com", "D456", "1789161922.548889")
           )

    for invalid <- [
          nil,
          "https://evil.example/archives/C456/p1789161922548889",
          "https://app.slack.com/archives/C456/p1789161922548889",
          url <> "&next=https://evil.example",
          url <> "#extra",
          String.replace(url, "https://", "http://"),
          String.replace(url, "cid=C456", "cid=C789")
        ] do
      refute Permalink.archive_url?(invalid)
    end
  end
end

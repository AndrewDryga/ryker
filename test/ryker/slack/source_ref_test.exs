defmodule Ryker.Slack.SourceRefTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.SourceRef

  # Every capability tool re-encodes the source it parsed to name it in
  # audits, results and continuations; a ref that changed on the way through
  # would let a reader cite a different original than the one it read.
  test "a parsed source encodes back to the exact ref it was parsed from" do
    refs = [
      SourceRef.channel("T123", "C123"),
      SourceRef.message("T123", "C123", "1787832000.000100"),
      SourceRef.thread("T123", "C123", "1787832000.000100"),
      SourceRef.bookmark("T123", "C123", "Bk123"),
      SourceRef.canvas("T123", "C123", "F123CANVAS"),
      SourceRef.file("T123", "C123", "F123")
    ]

    for ref <- refs do
      assert {:ok, source} = SourceRef.parse(ref, "T123")
      assert SourceRef.encode(source) == ref
    end
  end

  test "a source from another workspace or with a malformed part does not parse" do
    assert SourceRef.parse(SourceRef.channel("T999", "C123"), "T123") ==
             {:error, :invalid_slack_source_ref}

    assert SourceRef.parse("slack-source:v1:T123:C123:message:not-a-timestamp", "T123") ==
             {:error, :invalid_slack_source_ref}

    assert SourceRef.parse("slack-source:v2:T123:C123:channel", "T123") ==
             {:error, :invalid_slack_source_ref}

    assert SourceRef.parse(nil, "T123") == {:error, :invalid_slack_source_ref}
  end

  test "slack ids are upper-case alphanumerics only" do
    assert SourceRef.slack_id?("C0BL6UCCBGR")
    refute SourceRef.slack_id?("c0bl6uccbgr")
    refute SourceRef.slack_id?("C0BL 6UC")
    refute SourceRef.slack_id?("")
    refute SourceRef.slack_id?(nil)
  end
end

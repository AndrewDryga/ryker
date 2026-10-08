defmodule Ryker.WordingTest do
  # Fifteen copies of these words lived in the console, the Slack cards, the
  # weekly report and the model's tool errors until 2026-10-08, each with its
  # own idea of a plural: the ones that added "s" would have written "entrys",
  # and one list joiner put " and " before a single item.
  use ExUnit.Case, async: true
  alias Ryker.Wording

  test "a count is singular only for exactly one, and regular plurals are spelled" do
    assert Wording.count(1, "message") == "1 message"
    assert Wording.count(0, "message") == "0 messages"
    assert Wording.count(3, "entry") == "3 entries"
    assert Wording.count(2, "day") == "2 days"
    assert Wording.count(2, "box") == "2 boxes"
    assert Wording.count(2, "match") == "2 matches"
    assert Wording.count(2, "worker is", "workers are") == "2 workers are"
    assert Wording.count(1, "worker is", "workers are") == "1 worker is"
  end

  test "the word alone agrees with its count" do
    assert Wording.word(1, "request") == "request"
    assert Wording.word(5, "request") == "requests"
    assert Wording.word(5, "was", "were") == "were"
  end

  test "a number carries thousands separators" do
    assert Wording.number(0) == "0"
    assert Wording.number(999) == "999"
    assert Wording.number(1_000) == "1,000"
    assert Wording.number(12_345_678) == "12,345,678"
    assert Wording.number(-1_234) == "-1,234"
  end

  test "a list reads as a sentence however many items it has" do
    assert Wording.list(["Production"]) == "Production"
    assert Wording.list(["Production", "Staging"]) == "Production and Staging"
    assert Wording.list(["a", "b", "c"]) == "a, b and c"
  end

  # String.capitalize/1 lowered every invitee's Slack id, which Slack then
  # could not resolve; only the first letter changes.
  test "a capital first letter leaves the rest as written" do
    assert Wording.capitalize("invite <@U0ABC> and #ops") == "Invite <@U0ABC> and #ops"
    assert Wording.capitalize("étape") == "Étape"
    assert Wording.capitalize("") == ""
  end

  test "a sentence gets a capital and a full stop, and empty text stays empty" do
    assert Wording.sentence("the recording was too long") == "The recording was too long."
    assert Wording.sentence("") == ""
  end

  # Thirteen pages and cards turned a stored name into words by hand, nine of
  # them capitalized, until 2026-10-08.
  test "a stored name reads as words, or as a label" do
    assert Wording.words(:host_bug) == "host bug"
    assert Wording.words("response_detail") == "response detail"
    assert Wording.label(:host_bug) == "Host bug"
    assert Wording.label("response_detail") == "Response detail"
  end

  test "a label continues a sentence with its first letter lowered and the rest as written" do
    assert Wording.lowercase_first("Title") == "title"
    assert Wording.lowercase_first("Slack ID") == "slack ID"
    assert Wording.lowercase_first("") == ""
  end
end

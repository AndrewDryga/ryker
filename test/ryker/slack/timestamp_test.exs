defmodule Ryker.Slack.TimestampTest do
  # Fourteen modules each held this pattern until 2026-10-08, and the delivery
  # target's copy alone required all six digits of the second.
  use ExUnit.Case, async: true
  alias Ryker.Slack.Timestamp

  test "a timestamp is ten or more digits of seconds and up to six of the second" do
    assert Timestamp.valid?("1712345678.123456")
    assert Timestamp.valid?("1712345678.5")
    refute Timestamp.valid?("1712345678")
    refute Timestamp.valid?("171234567.123456")
    refute Timestamp.valid?("1712345678.1234567")
    refute Timestamp.valid?(" 1712345678.123456")
    refute Timestamp.valid?(nil)
    refute Timestamp.valid?(1_712_345_678)
  end

  test "a timestamp names its moment to the microsecond, short fractions padded" do
    assert Timestamp.to_datetime("1712345678.123456") ==
             {:ok, DateTime.from_unix!(1_712_345_678_123_456, :microsecond)}

    assert Timestamp.to_datetime("1712345678.5") ==
             {:ok, DateTime.from_unix!(1_712_345_678_500_000, :microsecond)}
  end

  # The tool arguments and the source window each turned a timestamp into
  # microseconds with their own copy until 2026-10-08.
  test "two timestamps compare as numbers in the order Slack posted them" do
    assert Timestamp.microseconds("1712345678.123456") == 1_712_345_678_123_456
    assert Timestamp.microseconds("1712345678.5") == 1_712_345_678_500_000

    assert Timestamp.microseconds("1712345678.000099") <
             Timestamp.microseconds("1712345678.0001")
  end

  test "anything else, or a moment past the year 9999, names no time" do
    assert Timestamp.to_datetime("yesterday") == :error
    assert Timestamp.to_datetime(nil) == :error
    assert Timestamp.to_datetime("99999999999999999.000001") == :error
  end
end

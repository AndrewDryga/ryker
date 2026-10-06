defmodule Ryker.ControlPlane.ShortTimeTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.ShortTime

  @now ~U[2026-09-26 12:00:00Z]

  test "past times read as how long ago, with no clock to misread" do
    assert ShortTime.text(~U[2026-09-26 11:59:30Z], @now) == "just now"
    assert ShortTime.text(~U[2026-09-26 11:40:00Z], @now) == "20 min ago"
    assert ShortTime.text(~U[2026-09-26 09:00:00Z], @now) == "3 h ago"
    assert ShortTime.text(~U[2026-09-25 09:00:00Z], @now) == "yesterday"
    assert ShortTime.text(~U[2026-09-20 09:00:00Z], @now) == "20 Sep"
  end

  # QA, 2026-09-26: Working copies said "removed after tomorrow 09:00" and a
  # channel page "expires tomorrow 09:00" while every other time on the
  # workspace names UTC, so a reader in Berlin read the wrong hour.
  test "a future clock time names its zone" do
    assert ShortTime.text(~U[2026-09-26 12:00:30Z], @now) == "in a moment"
    assert ShortTime.text(~U[2026-09-26 12:20:00Z], @now) == "in 20 min"
    assert ShortTime.text(~U[2026-09-26 18:00:00Z], @now) == "today 18:00 UTC"
    assert ShortTime.text(~U[2026-09-27 09:00:00Z], @now) == "tomorrow 09:00 UTC"
    assert ShortTime.text(~U[2026-10-03 09:00:00Z], @now) == "3 Oct 09:00 UTC"
  end

  # Chat's list, every "Saved at" stamp and the conversation filter wrote
  # "05 Oct, 09:30 UTC" for any year, while five other pages each worked out
  # the year their own way (2026-10-04 review). One day and one stamp, with the
  # year once it is not this one.
  test "a day and a moment carry the year only when it is not this one" do
    assert ShortTime.day(~D[2026-10-05], ~D[2026-12-31]) == "5 Oct"
    assert ShortTime.day(~U[2025-10-05 09:30:00Z], @now) == "5 Oct 2025"
    assert ShortTime.day(~N[2027-01-02 00:00:00], @now) == "2 Jan 2027"

    assert ShortTime.stamp(~U[2026-10-05 09:30:00Z], @now) == "5 Oct, 09:30 UTC"
    assert ShortTime.stamp(~U[2025-10-05 09:30:00Z], @now) == "5 Oct 2025, 09:30 UTC"
  end
end

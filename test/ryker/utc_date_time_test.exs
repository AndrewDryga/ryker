defmodule Ryker.UTCDateTimeTest do
  use ExUnit.Case, async: true
  alias Ryker.UTCDateTime

  # Found live 2026-09-27 14:13 UTC: a due-time query mixed an aggregate the
  # database returned without a zone with a typed one, earliest/1 compared them
  # with DateTime.compare, and every Work and delivery lane crashed on each
  # poll while a row was due, so replies stopped going out.
  test "the earliest of database times reads a zone-less one as UTC" do
    typed = ~U[2026-09-27 14:13:27.965671Z]
    zoneless = ~N[2026-09-27 14:13:24.011453]

    assert UTCDateTime.earliest([typed, nil, zoneless]) == ~U[2026-09-27 14:13:24.011453Z]
    assert UTCDateTime.earliest([zoneless]) == ~U[2026-09-27 14:13:24.011453Z]
    assert UTCDateTime.earliest([nil, nil]) == nil
  end

  # Moved from the observability reads on 2026-10-08, where the console's
  # workspace page kept a copy of its own.
  test "an age is whole seconds, never negative, and nothing to age is zero" do
    now = ~U[2026-10-08 12:00:10.000000Z]

    assert UTCDateTime.age_seconds(now, ~U[2026-10-08 12:00:00.000000Z]) == 10
    assert UTCDateTime.age_seconds(now, ~U[2026-10-08 12:01:00.000000Z]) == 0
    assert UTCDateTime.age_seconds(now, nil) == 0

    # A zone-less time counts the whole-second boundaries between the readings.
    assert UTCDateTime.age_seconds(
             ~U[2026-10-08 12:00:11.100000Z],
             ~N[2026-10-08 12:00:10.900000]
           ) ==
             1
  end
end

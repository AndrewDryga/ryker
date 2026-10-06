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
end

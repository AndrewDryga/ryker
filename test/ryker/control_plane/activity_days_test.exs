defmodule Ryker.ControlPlane.ActivityDaysTest do
  @moduledoc """
  Activity opens each day with a heading (2026-09-25: "no vertical rhythm").
  Its rows are a live stream that never moves a row under the reader, so the
  headings have to survive a refresh the same way the rows do.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{ActivityPage, Kit}

  @now ~U[2026-09-25 09:00:00Z]

  test "the first row of each day carries that day's heading" do
    items = [
      row("a", ~U[2026-09-25 08:33:00Z]),
      row("b", ~U[2026-09-25 06:05:00Z]),
      row("c", ~U[2026-09-24 22:58:00Z]),
      row("d", ~U[2026-09-20 21:15:00Z]),
      row("e", ~U[2025-12-31 23:59:00Z])
    ]

    assert Enum.map(ActivityPage.with_days(items, @now), & &1.group) ==
             ["Today", nil, "Yesterday", "Sunday", "31 December 2025"]
  end

  test "a live refresh keeps every row under its day, and each day keeps its heading" do
    # The first row of today goes away, and a row listed under yesterday
    # changes today. Rows never move under the reader, so the change stays
    # under yesterday until the reader shows the latest, and today's heading
    # moves to the next row of today instead of disappearing with the first.
    drawn =
      ActivityPage.with_days(
        [
          row("a", ~U[2026-09-25 08:33:00Z]),
          row("b", ~U[2026-09-25 06:05:00Z]),
          row("c", ~U[2026-09-24 22:58:00Z])
        ],
        @now
      )

    days = Map.new(drawn, &{&1.id, &1.day})

    refreshed = [
      {"b", row("b", ~U[2026-09-25 06:05:00Z])},
      {"c", row("c", ~U[2026-09-25 08:50:00Z])}
    ]

    assert [%{id: "b", group: "Today"}, %{id: "c", group: "Yesterday", day: ~D[2026-09-24]}] =
             ActivityPage.kept_days(refreshed, days, @now)
  end

  test "day names follow the week, then the date" do
    today = ~D[2026-09-25]
    assert Kit.day_label(~D[2026-09-19], today) == "Saturday"
    assert Kit.day_label(~D[2026-09-18], today) == "18 September"
    assert Kit.day_label(~D[2026-09-18], ~D[2027-01-02]) == "18 September 2026"
    assert Kit.clock(~U[2026-09-25 08:03:59Z]) == "08:03"
  end

  defp row(id, at), do: %{id: id, updated_at: at}
end

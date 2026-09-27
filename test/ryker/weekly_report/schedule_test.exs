defmodule Ryker.WeeklyReport.ScheduleTest do
  # The report is sent at a local time a person picked, in their zone. A send
  # computed in UTC arrives hours off for everyone east or west of it, and
  # one that ignores the clock changes arrives an hour off for half the year.
  use ExUnit.Case, async: true

  alias Ryker.TestSupport.TimeZones
  alias Ryker.WeeklyReport.Schedule

  @monday_nine %{weekday: 1, local_time: ~T[09:00:00], timezone: "Test/Plus2"}

  test "the send falls on the chosen day at the chosen local time in the chosen zone" do
    # Monday 09:00 two hours ahead of UTC is Monday 07:00 UTC.
    assert {:ok, latest} = Schedule.latest(@monday_nine, ~U[2026-10-07 12:00:00Z], TimeZones)
    assert latest.at == ~U[2026-10-05 07:00:00.000000Z]
    assert latest.date == ~D[2026-10-05]
    assert latest.week == ~D[2026-10-05]

    assert {:ok, next} = Schedule.next(@monday_nine, ~U[2026-10-07 12:00:00Z], TimeZones)
    assert next.at == ~U[2026-10-12 07:00:00.000000Z]

    # The week it covers starts at the same local time a week before.
    assert {:ok, previous} = Schedule.previous(latest, @monday_nine, TimeZones)
    assert previous.at == ~U[2026-09-28 07:00:00.000000Z]
  end

  test "the send time itself is the latest send, not the next one" do
    at = ~U[2026-10-05 07:00:00.000000Z]

    assert {:ok, %{at: ^at}} = Schedule.latest(@monday_nine, at, TimeZones)

    assert {:ok, %{at: ~U[2026-10-12 07:00:00.000000Z]}} =
             Schedule.next(@monday_nine, at, TimeZones)

    # A second before it, the latest is last week's.
    assert {:ok, %{at: ~U[2026-09-28 07:00:00.000000Z]}} =
             Schedule.latest(@monday_nine, DateTime.add(at, -1, :second), TimeZones)
  end

  test "the day is read in the chosen zone, not in UTC" do
    # Sunday 23:30 UTC is already Monday 01:30 two hours ahead: that calendar
    # week's Monday send is still ahead, and last week's is the latest.
    sunday_night = ~U[2026-10-04 23:30:00Z]

    assert {:ok, %{at: ~U[2026-09-28 07:00:00.000000Z], week: ~D[2026-09-28]}} =
             Schedule.latest(@monday_nine, sunday_night, TimeZones)

    sunday = %{@monday_nine | weekday: 7, local_time: ~T[00:30:00]}

    # Sunday 00:30 two hours ahead is Saturday 22:30 UTC.
    assert {:ok, %{at: ~U[2026-10-03 22:30:00.000000Z], week: ~D[2026-09-28]}} =
             Schedule.latest(sunday, sunday_night, TimeZones)
  end

  test "a send keeps its local time across the clock changes" do
    mountain = %{weekday: 7, local_time: ~T[09:00:00], timezone: "Test/Mountain"}

    # Before the spring change 09:00 is 16:00 UTC, after it 15:00 UTC.
    assert {:ok, %{at: ~U[2026-03-01 16:00:00.000000Z]}} =
             Schedule.latest(mountain, ~U[2026-03-02 00:00:00Z], TimeZones)

    assert {:ok, %{at: ~U[2026-03-08 15:00:00.000000Z]} = after_change} =
             Schedule.latest(mountain, ~U[2026-03-09 00:00:00Z], TimeZones)

    # So the week that holds the change is an hour short in UTC, and still
    # starts where the last report ended.
    assert {:ok, %{at: ~U[2026-03-01 16:00:00.000000Z]}} =
             Schedule.previous(after_change, mountain, TimeZones)
  end

  test "a send in the hour the spring change skips goes the moment the clock jumps" do
    skipped = %{weekday: 7, local_time: ~T[02:30:00], timezone: "Test/Mountain"}

    # 02:30 does not exist on 8 March; the clock goes from 02:00 to 03:00,
    # which is 09:00 UTC. The send is not moved a whole hour later.
    assert {:ok, %{at: ~U[2026-03-08 09:00:00.000000Z], date: ~D[2026-03-08]}} =
             Schedule.latest(skipped, ~U[2026-03-09 00:00:00Z], TimeZones)
  end

  test "a send in the hour the autumn change repeats goes the first time it comes round" do
    repeated = %{weekday: 7, local_time: ~T[01:30:00], timezone: "Test/Mountain"}

    # 01:30 happens twice on 1 November: at 07:30 UTC in summer time, and at
    # 08:30 UTC in winter time. The first is the send; the second sends
    # nothing more, being the same week.
    assert {:ok, %{at: ~U[2026-11-01 07:30:00.000000Z], week: ~D[2026-10-26]}} =
             Schedule.latest(repeated, ~U[2026-11-01 09:00:00Z], TimeZones)
  end

  test "a zone the database cannot resolve is an error, not a send in UTC" do
    unknown = %{@monday_nine | timezone: "Mars/Olympus"}

    assert {:error, :time_zone_not_found} =
             Schedule.latest(unknown, ~U[2026-10-07 12:00:00Z], TimeZones)

    assert {:error, :time_zone_not_found} =
             Schedule.next(unknown, ~U[2026-10-07 12:00:00Z], TimeZones)
  end
end

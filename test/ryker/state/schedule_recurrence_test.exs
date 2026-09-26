defmodule Ryker.State.ScheduleRecurrenceTest do
  use Ryker.DataCase, async: false

  alias Ryker.State.ScheduleRecurrence

  test "calendar recurrences retain their local wall-clock time across daylight saving changes" do
    daily = %{"kind" => "daily", "time" => "09:00:00"}

    assert {:ok, spring} =
             ScheduleRecurrence.next_after(
               daily,
               "America/New_York",
               ~U[2026-03-07 14:00:00.000000Z]
             )

    assert spring == ~U[2026-03-08 13:00:00.000000Z]

    assert {:ok, autumn} =
             ScheduleRecurrence.next_after(
               daily,
               "America/New_York",
               ~U[2026-10-31 13:00:00.000000Z]
             )

    assert autumn == ~U[2026-11-01 14:00:00.000000Z]
  end

  # QA, 2026-09-25: "every weekday at 9:00" had no recurrence to land in. The
  # tool refused the model's weekday bundle, the model fell back to Monday
  # alone, and confirming the card created "Every Monday at 09:00 UTC" under a
  # title that still said weekday. Monday to Friday is its own recurrence.
  test "a weekdays schedule runs Monday to Friday and skips the weekend in its own time zone" do
    weekdays = %{"kind" => "weekdays", "time" => "09:00:00"}

    # Friday's run is followed by Monday's, not Saturday's.
    assert ScheduleRecurrence.next_after(weekdays, "Etc/UTC", ~U[2026-09-25 09:00:00.000000Z]) ==
             {:ok, ~U[2026-09-28 09:00:00.000000Z]}

    assert ScheduleRecurrence.next_after(weekdays, "Etc/UTC", ~U[2026-09-26 12:00:00.000000Z]) ==
             {:ok, ~U[2026-09-28 09:00:00.000000Z]}

    assert ScheduleRecurrence.next_after(weekdays, "Etc/UTC", ~U[2026-09-29 08:00:00.000000Z]) ==
             {:ok, ~U[2026-09-29 09:00:00.000000Z]}

    # The weekend is the schedule's own: 10:00 on Saturday in Auckland is
    # Friday evening in UTC, and 09:00 on Monday there is Sunday in UTC.
    assert ScheduleRecurrence.next_after(
             weekdays,
             "Pacific/Auckland",
             ~U[2026-01-09 21:00:00.000000Z]
           ) == {:ok, ~U[2026-01-11 20:00:00.000000Z]}

    assert ScheduleRecurrence.next_after(
             weekdays,
             "Pacific/Auckland",
             ~U[2026-01-08 19:00:00.000000Z]
           ) == {:ok, ~U[2026-01-08 20:00:00.000000Z]}
  end

  test "a weekdays schedule keeps its local time across daylight saving changes" do
    weekdays = %{"kind" => "weekdays", "time" => "09:00:00"}

    # New York springs forward on Sunday 8 March: Friday's run is 14:00 UTC,
    # Monday's 13:00 UTC, both 09:00 in New York.
    assert ScheduleRecurrence.next_after(
             weekdays,
             "America/New_York",
             ~U[2026-03-06 14:00:00.000000Z]
           ) == {:ok, ~U[2026-03-09 13:00:00.000000Z]}

    # And falls back on Sunday 1 November.
    assert ScheduleRecurrence.next_after(
             weekdays,
             "America/New_York",
             ~U[2026-10-30 13:00:00.000000Z]
           ) == {:ok, ~U[2026-11-02 14:00:00.000000Z]}
  end

  test "monthly recurrence skips months that do not contain its requested day" do
    recurrence = %{"day" => 31, "kind" => "monthly", "time" => "09:30:00"}

    assert {:ok, next} =
             ScheduleRecurrence.next_after(
               recurrence,
               "Etc/UTC",
               ~U[2026-01-31 09:30:00.000000Z]
             )

    assert next == ~U[2026-03-31 09:30:00.000000Z]
  end

  test "once and interval recurrences are strict, bounded, and deterministic" do
    assert {:ok, ~U[2026-08-28 13:00:00.000000Z]} =
             ScheduleRecurrence.next_after(
               %{"at" => "2026-08-28T13:00:00.000000Z", "kind" => "once"},
               "Etc/UTC",
               ~U[2026-08-28 12:00:00.000000Z]
             )

    assert {:ok, nil} =
             ScheduleRecurrence.next_after(
               %{"at" => "2026-08-28T13:00:00.000000Z", "kind" => "once"},
               "Etc/UTC",
               ~U[2026-08-28 13:00:00.000000Z]
             )

    interval = %{
      "every_seconds" => 300,
      "kind" => "interval",
      "starts_at" => "2026-08-28T12:05:00.000000Z"
    }

    assert {:ok, ~U[2026-08-28 12:15:00.000000Z]} =
             ScheduleRecurrence.next_after(
               interval,
               "Etc/UTC",
               ~U[2026-08-28 12:14:59.000000Z]
             )

    assert ScheduleRecurrence.normalize(
             %{"kind" => "daily", "time" => "09:00:00"},
             "Not/A-Timezone",
             ~U[2026-08-28 12:00:00.000000Z]
           ) == {:error, {:invalid_schedule, :timezone}}
  end

  test "every supported shape is normalized before it enters durable schedule custody" do
    now = ~U[2026-08-28 12:00:00.000000Z]

    assert {:ok, %{"kind" => "interval", "starts_at" => starts_at}} =
             ScheduleRecurrence.normalize(
               %{"every_seconds" => 300, "kind" => "interval", "starts_at" => nil},
               "Etc/UTC",
               now
             )

    assert starts_at == "2026-08-28T12:05:00.000000Z"

    assert {:ok, %{"kind" => "weekly", "time" => "09:15:00", "weekday" => "monday"}} =
             ScheduleRecurrence.normalize(
               %{"kind" => "weekly", "time" => "09:15:00", "weekday" => "monday"},
               "Etc/UTC",
               now
             )

    assert {:ok, %{"kind" => "weekdays", "time" => "09:15:00"}} =
             ScheduleRecurrence.normalize(
               %{"kind" => "weekdays", "time" => "09:15"},
               "Etc/UTC",
               now
             )

    assert {:ok, %{"day" => 1, "kind" => "monthly", "time" => "00:00:00"}} =
             ScheduleRecurrence.normalize(
               %{"day" => 1, "kind" => "monthly", "time" => "00:00:00"},
               "Etc/UTC",
               now
             )

    assert {:ok, ~U[2026-08-31 09:15:00.000000Z]} =
             ScheduleRecurrence.next_after(
               %{"kind" => "weekly", "time" => "09:15:00", "weekday" => "monday"},
               "Etc/UTC",
               now
             )
  end

  test "invalid recurrence values fail at the public boundary" do
    now = ~U[2026-08-28 12:00:00.000000Z]

    invalid = [
      nil,
      %{},
      %{"at" => "not-a-date", "kind" => "once"},
      %{"every_seconds" => 299, "kind" => "interval", "starts_at" => nil},
      %{"every_seconds" => 300, "kind" => "interval", "starts_at" => "not-a-date"},
      %{"kind" => "daily", "time" => "25:00:00"},
      %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "funday"},
      %{"kind" => "weekdays", "time" => "09:00:00", "weekday" => "monday"},
      %{"kind" => "weekdays", "time" => "9 o'clock"},
      %{"day" => 32, "kind" => "monthly", "time" => "09:00:00"}
    ]

    Enum.each(invalid, fn recurrence ->
      assert ScheduleRecurrence.normalize(recurrence, "Etc/UTC", now) ==
               {:error, {:invalid_schedule, :recurrence}}
    end)

    assert ScheduleRecurrence.next_after(%{}, "Etc/UTC", now) ==
             {:error, {:invalid_schedule, :recurrence}}

    assert ScheduleRecurrence.normalize(%{"kind" => "daily", "time" => "09:00:00"}, nil, now) ==
             {:error, {:invalid_schedule, :timezone}}
  end
end

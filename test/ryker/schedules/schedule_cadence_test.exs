defmodule Ryker.Schedules.ScheduleCadenceTest do
  @moduledoc """
  How often a schedule runs, in the words every surface uses: the schedules
  page, the Chat card, the Slack offer and saved schedule, and the GitHub
  comment all read the stored recurrence through this one function.
  """
  use ExUnit.Case, async: true

  alias Ryker.Schedules.ScheduleCadence

  test "a recurrence reads as words in the schedule's own time zone" do
    for {recurrence, zone, once_local, expected} <- [
          {%{"kind" => "daily", "time" => "09:00:00"}, "Europe/Berlin", nil,
           "Every day at 09:00 Berlin time"},
          {%{"kind" => "weekdays", "time" => "09:00:00"}, "Etc/UTC", nil,
           "Every weekday at 09:00 UTC"},
          {%{"kind" => "weekdays", "time" => "08:30:00"}, "America/New_York", nil,
           "Every weekday at 08:30 New York time"},
          {%{"kind" => "weekly", "time" => "17:30:00", "weekday" => "friday"}, "America/New_York",
           nil, "Every Friday at 17:30 New York time"},
          {%{"day" => 1, "kind" => "monthly", "time" => "08:00:00"}, "Etc/UTC", nil,
           "Every month on the 1st at 08:00 UTC"},
          {%{"day" => 22, "kind" => "monthly", "time" => "08:00:00"}, "UTC", nil,
           "Every month on the 22nd at 08:00 UTC"},
          {%{"day" => 13, "kind" => "monthly", "time" => "08:00:00"}, "UTC", nil,
           "Every month on the 13th at 08:00 UTC"},
          {%{"day" => 3, "kind" => "monthly", "time" => "08:00:30"},
           "America/Argentina/Buenos_Aires", nil,
           "Every month on the 3rd at 08:00:30 Buenos Aires time"},
          {interval(900), "UTC", nil, "Every 15 minutes"},
          {interval(5_400), "UTC", nil, "Every 90 minutes"},
          {interval(3_600), "UTC", nil, "Every hour"},
          {interval(7_200), "UTC", nil, "Every 2 hours"},
          {interval(86_400), "UTC", nil, "Every day"},
          {interval(259_200), "UTC", nil, "Every 3 days"},
          {interval(604_800), "UTC", nil, "Every week"},
          {interval(1_209_600), "UTC", nil, "Every 2 weeks"},
          {%{"at" => "2026-09-25T07:00:00Z", "kind" => "once"}, "Europe/Berlin",
           ~N[2026-09-25 09:00:00], "Once on 25 Sep at 09:00 Berlin time"},
          # POSIX names count hours west of Greenwich: Etc/GMT+5 is five hours
          # behind UTC, and read "GMT+5" it said the opposite (2026-10-04 review).
          {%{"at" => "2027-01-05T08:00:00Z", "kind" => "once"}, "Etc/GMT+5",
           ~N[2027-01-05 03:00:00], "Once on 5 Jan 2027 at 03:00 UTC-5"},
          {%{"kind" => "daily", "time" => "09:00:00"}, "Etc/GMT-3", nil,
           "Every day at 09:00 UTC+3"},
          {%{"kind" => "a future kind"}, "UTC", nil, "On a custom timing"}
        ] do
      assert ScheduleCadence.describe(recurrence, zone,
               once_local: once_local,
               now_local: ~N[2026-09-24 12:00:00]
             ) == expected,
             inspect(recurrence)
    end
  end

  test "an offer with no local clock names a single run in UTC" do
    # An offer card renders from its payload alone, where no database has
    # turned the run's UTC instant into the schedule's zone yet.
    assert ScheduleCadence.describe(
             %{"at" => "2026-09-26T07:00:00Z", "kind" => "once"},
             "Europe/Berlin"
           ) == "Once on 26 Sep 2026 at 07:00 UTC"
  end

  defp interval(seconds),
    do: %{"every_seconds" => seconds, "kind" => "interval", "starts_at" => nil}
end

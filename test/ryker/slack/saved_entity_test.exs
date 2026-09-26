defmodule Ryker.Slack.SavedEntityTest do
  use ExUnit.Case, async: true

  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.SavedEntity

  # QA, 2026-09-25: the saved schedule in Slack said "Every monday at 09:00:00
  # · Etc/UTC" in words of its own, and had none for a weekday schedule. It
  # reads the recurrence through the one wording every surface shares.
  test "a saved schedule says how often it runs in the words every surface uses" do
    schedule = %Schedule{
      authority: :read_only,
      confirmed_at: ~U[2026-09-25 21:31:00.000000Z],
      confirmed_by_actor_ref: "slack:user:U123",
      destination_conversation_ref: "slack:T123:C456",
      expires_at: nil,
      next_occurrence_at: ~U[2026-09-28 09:00:00.000000Z],
      recurrence: %{"kind" => "weekdays", "time" => "09:00:00"},
      ref: "schedule:weekday-status",
      repository: nil,
      revision: 1,
      status: :active,
      task: "Post a one-line status of open incidents here.",
      timezone: "Etc/UTC",
      title: "Weekday open incident status"
    }

    assert ["When", "Every weekday at 09:00 UTC"] in SavedEntity.document(schedule, :saved)[
             "facts"
           ]

    weekly = %{
      schedule
      | recurrence: %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "monday"}
    }

    assert ["When", "Every Monday at 09:00 UTC"] in SavedEntity.document(weekly, :saved)["facts"]
  end
end

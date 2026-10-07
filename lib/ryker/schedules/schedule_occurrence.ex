defmodule Ryker.Schedules.ScheduleOccurrence do
  @moduledoc false
  use Ryker, :schema

  schema "episode_schedule_occurrences" do
    belongs_to(:schedule, Ryker.Schedules.Schedule)
    belongs_to(:child_episode, Ryker.Episodes.Episode)

    field(:ref, :string)
    field(:scheduled_for, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:dispatched, :missed])
    field(:trigger, Ecto.Enum, values: [:scheduled, :manual], default: :scheduled)
    field(:event_ref, :string)
    field(:missed_reason, :string)

    timestamps()
  end
end

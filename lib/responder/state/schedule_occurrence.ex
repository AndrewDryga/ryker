defmodule Responder.State.ScheduleOccurrence do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_schedule_occurrences" do
    belongs_to(:schedule, Responder.State.Schedule)
    belongs_to(:child_episode, Responder.Episodes.Episode)

    field(:ref, :string)
    field(:scheduled_for, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:dispatched, :missed])
    field(:event_ref, :string)
    field(:missed_reason, :string)

    timestamps(type: :utc_datetime_usec)
  end
end

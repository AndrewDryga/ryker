defmodule Ryker.State.StandingAssignmentRun do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "standing_assignment_runs" do
    belongs_to(:assignment, Ryker.State.Behavior)
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:ref, :string)
    field(:source_input_ref, :string)
    field(:source_event_ref, :string)
    field(:outcome, Ecto.Enum, values: [:pending, :decided, :superseded])

    field(
      :decision_action,
      Ecto.Enum,
      values: [:start_episode, :continue_episode, :reply, :react, :ignore]
    )

    field(:decision_ref, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

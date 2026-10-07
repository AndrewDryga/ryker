defmodule Ryker.Behaviors.StandingAssignmentRun do
  @moduledoc false
  use Ryker, :schema

  schema "standing_assignment_runs" do
    belongs_to(:assignment, Ryker.Behaviors.Behavior)
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:ref, :string)
    field(:source_input_ref, :string)
    field(:source_event_ref, :string)
    field(:outcome, Ecto.Enum, values: [:pending, :decided, :superseded])

    field(
      :decision_action,
      Ecto.Enum,
      values: [:start_episode, :continue_episode, :reply, :quick_reply, :react, :ignore]
    )

    field(:decision_ref, :string)
    timestamps(updated_at: false)
  end
end

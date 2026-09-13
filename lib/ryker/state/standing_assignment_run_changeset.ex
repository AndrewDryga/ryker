defmodule Ryker.State.StandingAssignmentRunChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.State.StandingAssignmentRun

  @fields [
    :assignment_id,
    :decision_action,
    :decision_ref,
    :episode_id,
    :id,
    :outcome,
    :ref,
    :source_event_ref,
    :source_input_ref
  ]

  def insert(attributes) do
    %StandingAssignmentRun{}
    |> cast(attributes, @fields)
    |> validate_required([
      :assignment_id,
      :id,
      :outcome,
      :ref,
      :source_event_ref,
      :source_input_ref
    ])
    |> unique_constraint(:ref)
    |> unique_constraint(:source_input_ref,
      name: :standing_assignment_runs_assignment_id_source_input_ref_index
    )
    |> foreign_key_constraint(:assignment_id)
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:outcome, name: :standing_assignment_run_valid)
  end

  def finalize(%StandingAssignmentRun{} = run, attributes) do
    run
    |> cast(attributes, [:decision_action, :decision_ref, :episode_id, :outcome])
    |> validate_required([:decision_action, :decision_ref, :outcome])
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:outcome, name: :standing_assignment_run_valid)
  end
end

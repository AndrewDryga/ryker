defmodule Responder.State.ScheduleOccurrenceChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.State.ScheduleOccurrence

  @fields [
    :child_episode_id,
    :event_ref,
    :id,
    :missed_reason,
    :ref,
    :schedule_id,
    :scheduled_for,
    :status,
    :trigger
  ]

  def insert(attributes) do
    %ScheduleOccurrence{}
    |> cast(attributes, @fields)
    |> validate_required([:id, :ref, :schedule_id, :scheduled_for, :status, :trigger])
    |> unique_constraint(:ref)
    |> unique_constraint(:scheduled_for,
      name: :episode_schedule_occurrences_schedule_id_scheduled_for_index
    )
    |> unique_constraint(:child_episode_id)
    |> foreign_key_constraint(:schedule_id)
    |> foreign_key_constraint(:child_episode_id)
    |> check_constraint(:status, name: :episode_schedule_occurrence_valid)
    |> check_constraint(:trigger, name: :episode_schedule_occurrence_trigger_valid)
  end
end

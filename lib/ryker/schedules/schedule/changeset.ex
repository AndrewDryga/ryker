defmodule Ryker.Schedules.Schedule.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Schedules.Schedule

  @fields [
    :authority,
    :confirmation_ref,
    :confirmed_at,
    :confirmed_by_actor_ref,
    :destination_conversation_ref,
    :destination_thread_ref,
    :destination_transport,
    :environment_ref,
    :expires_at,
    :failure_count,
    :id,
    :last_error,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :next_occurrence_at,
    :offer_record_id,
    :recurrence,
    :ref,
    :repository,
    :revision,
    :source_episode_id,
    :status,
    :task,
    :timezone,
    :title
  ]

  @insert_required @fields --
                     [
                       :destination_thread_ref,
                       :environment_ref,
                       :expires_at,
                       :failure_count,
                       :last_error,
                       :lease_expires_at,
                       :lease_owner,
                       :lease_ref,
                       :next_attempt_at,
                       :repository
                     ]

  def insert(attributes) do
    %Schedule{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> unique_constraint(:ref)
    |> unique_constraint(:offer_record_id)
    |> foreign_key_constraint(:offer_record_id)
    |> foreign_key_constraint(:source_episode_id)
    |> check_constraint(:environment_ref, name: :episode_schedules_environment_valid)
    |> check_constraint(:lease_ref, name: :episode_schedule_lease_valid)
    |> check_constraint(:revision, name: :episode_schedule_revision_valid)
  end

  def update(%Schedule{} = schedule, attributes) do
    schedule
    |> cast(attributes, @fields)
    |> check_constraint(:environment_ref, name: :episode_schedules_environment_valid)
    |> check_constraint(:lease_ref, name: :episode_schedule_lease_valid)
    |> check_constraint(:revision, name: :episode_schedule_revision_valid)
  end
end

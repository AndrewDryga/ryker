defmodule Responder.State.ScheduleChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.State.Schedule

  @fields [
    :authority,
    :catch_up,
    :confirmation_ref,
    :confirmed_at,
    :confirmed_by_actor_ref,
    :cutover_item_id,
    :destination_conversation_ref,
    :destination_thread_ref,
    :destination_transport,
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
                       :cutover_item_id,
                       :destination_thread_ref,
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
    |> foreign_key_constraint(:cutover_item_id)
    |> check_constraint(:offer_record_id, name: :episode_schedule_provenance_valid)
    |> check_constraint(:status, name: :episode_schedule_valid)
    |> check_constraint(:lease_ref, name: :episode_schedule_lease_valid)
    |> check_constraint(:revision, name: :episode_schedule_revision_valid)
  end

  def update(%Schedule{} = schedule, attributes) do
    schedule
    |> cast(attributes, @fields)
    |> check_constraint(:status, name: :episode_schedule_valid)
    |> check_constraint(:lease_ref, name: :episode_schedule_lease_valid)
    |> check_constraint(:revision, name: :episode_schedule_revision_valid)
  end
end

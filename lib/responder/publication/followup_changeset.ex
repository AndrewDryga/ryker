defmodule Responder.Publication.FollowupChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Publication.Followup

  @fields [
    :checks_failed,
    :checks_passed,
    :checks_state,
    :checks_total,
    :checks_url,
    :deadline_at,
    :episode_id,
    :failure_count,
    :id,
    :last_error,
    :last_event_key,
    :manual_check_ref,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :merge_sha,
    :merged_at,
    :next_poll_at,
    :pr_state,
    :publication_id,
    :verification_event_ref,
    :verification_sequence,
    :verification_turn_ref,
    :verified_at
  ]

  @insert_required [:deadline_at, :episode_id, :id, :next_poll_at, :publication_id]

  def insert(attributes) do
    %Followup{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> common()
    |> unique_constraint(:publication_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:publication_id,
      name: :episode_publication_followup_publication_episode_fkey
    )
  end

  def update(%Followup{} = followup, attributes) do
    followup
    |> cast(attributes, @fields)
    |> common()
  end

  defp common(changeset) do
    changeset
    |> validate_inclusion(:pr_state, ~w(open closed merged stale expired))
    |> validate_inclusion(:checks_state, ~w(unknown none pending passing failing))
    |> validate_number(:checks_total, greater_than_or_equal_to: 0)
    |> validate_number(:checks_passed, greater_than_or_equal_to: 0)
    |> validate_number(:checks_failed, greater_than_or_equal_to: 0)
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> validate_length(:checks_url, max: 2_048, count: :bytes)
    |> validate_length(:last_error, max: 4_096, count: :bytes)
    |> validate_length(:last_event_key, max: 128)
    |> validate_length(:manual_check_ref, max: 1_024)
    |> check_constraint(:pr_state, name: :episode_publication_followup_state_valid)
    |> check_constraint(:lease_ref, name: :episode_publication_followup_lease_valid)
  end
end

defmodule Ryker.Publication.LifecycleEventChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Publication.LifecycleEvent

  @fields [
    :attempt_count,
    :delivery_receipt,
    :delivery_receipt_fingerprint,
    :delivery_ref,
    :delivery_state,
    :episode_id,
    :id,
    :kind,
    :last_error,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :observation,
    :occurred_at,
    :publication_id,
    :ref,
    :source_conversation_ref,
    :source_item_ref,
    :source_transport,
    :state,
    :summary,
    :wakeup_state
  ]

  @insert_required [
    :delivery_ref,
    :episode_id,
    :id,
    :kind,
    :observation,
    :occurred_at,
    :publication_id,
    :ref,
    :state,
    :summary
  ]

  def insert(attributes) do
    %LifecycleEvent{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> common()
    |> unique_constraint(:id, name: :episode_publication_lifecycle_events_pkey)
    |> unique_constraint(:ref)
    |> unique_constraint(:delivery_ref)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:publication_id,
      name: :episode_publication_lifecycle_publication_episode_fkey
    )
  end

  def update(%LifecycleEvent{} = event, attributes) do
    event
    |> cast(attributes, @fields)
    |> common()
  end

  defp common(changeset) do
    changeset
    |> validate_inclusion(
      :kind,
      ~w(checks merged closed status deployment terraform verification deadline review_feedback)
    )
    |> validate_inclusion(:state, ~w(pending succeeded failed stopped))
    |> validate_inclusion(:wakeup_state, [:none, :pending, :admitted])
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:delivery_ref, min: 1, max: 256)
    |> validate_length(:summary, min: 1, max: 2_048, count: :bytes)
    |> validate_length(:last_error, max: 4_096, count: :bytes)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :episode_publication_lifecycle_valid)
    |> check_constraint(:lease_ref, name: :episode_publication_lifecycle_lease_valid)
  end
end

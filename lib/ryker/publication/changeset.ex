defmodule Ryker.Publication.Changeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Publication.Publication

  @fields [
    :approval_ref,
    :approved_at,
    :approved_by_actor_ref,
    :attempt_count,
    :body,
    :branch_ref,
    :commit_sha,
    :destination_conversation_ref,
    :destination_thread_ref,
    :destination_transport,
    :discarded_reason,
    :episode_id,
    :expected_remote_head_sha,
    :id,
    :last_error_code,
    :last_error_detail,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :offer_message_ref,
    :publication_receipt,
    :publication_receipt_fingerprint,
    :pull_request_number,
    :pull_request_url,
    :github_repository,
    :published_at,
    :published_delivery_receipt,
    :published_delivery_receipt_fingerprint,
    :record_id,
    :recovery_generation,
    :ref,
    :repository,
    :review_document,
    :review_expected_revision,
    :review_fingerprint,
    :review_generation,
    :review_patch,
    :review_request_ref,
    :review_requested_at,
    :review_requested_by_actor_ref,
    :review_delivery_receipt,
    :review_delivery_receipt_fingerprint,
    :reviewed_at,
    :session_id,
    :status,
    :title
  ]

  @insert_required [
    :body,
    :destination_conversation_ref,
    :destination_transport,
    :episode_id,
    :id,
    :offer_message_ref,
    :record_id,
    :ref,
    :repository,
    :review_request_ref,
    :review_requested_at,
    :review_requested_by_actor_ref,
    :session_id,
    :status,
    :title
  ]

  def insert(attributes) do
    %Publication{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> common()
    |> unique_constraint(:ref)
    |> unique_constraint(:record_id)
    |> unique_constraint(:review_request_ref)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:record_id)
    |> foreign_key_constraint(:session_id, name: :episode_publication_session_episode_fkey)
  end

  def update(%Publication{} = publication, attributes) do
    publication
    |> cast(attributes, @fields)
    |> common()
    |> unique_constraint(:approval_ref)
  end

  defp common(changeset) do
    changeset
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:repository, min: 1, max: 256)
    |> validate_length(:title, min: 1, max: 120)
    |> validate_length(:body, min: 1, max: 8_000, count: :bytes)
    |> validate_number(:review_generation, greater_than: 0)
    |> validate_number(:recovery_generation, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: :episode_publication_identity_valid)
    |> check_constraint(:status, name: :episode_publication_review_valid)
    |> check_constraint(:status, name: :episode_publication_approval_valid)
    |> check_constraint(:status, name: :episode_publication_publish_valid)
    |> check_constraint(:status, name: :episode_publication_lease_valid)
    |> check_constraint(:status, name: :episode_publication_remote_identity_valid)
    |> check_constraint(:discarded_reason, name: :episode_publication_discarded_reason_valid)
  end
end

defmodule Responder.Publication.Publication do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_publications" do
    belongs_to(:episode, Responder.Episodes.Episode)
    belongs_to(:record, Responder.State.Record)
    belongs_to(:session, Responder.Work.Session)

    field(:ref, :string)
    field(:repository, :string)
    field(:title, :string)
    field(:body, :string)

    field(:status, Ecto.Enum,
      values: [
        :review_pending,
        :review_ready,
        :reviewed,
        :publish_pending,
        :published_ready,
        :published,
        :blocked,
        :discarded
      ]
    )

    field(:destination_transport, :string)
    field(:destination_conversation_ref, :string)
    field(:destination_thread_ref, :string)
    field(:offer_message_ref, :string)
    field(:review_request_ref, :string)
    field(:review_requested_by_actor_ref, :string)
    field(:review_requested_at, :utc_datetime_usec)

    field(:review_generation, :integer, default: 1)
    field(:recovery_generation, :integer, default: 1)
    field(:review_expected_revision, :integer)
    field(:review_document, Responder.CanonicalJSON.Type)
    field(:review_fingerprint, :string)
    field(:review_patch, :binary)
    field(:reviewed_at, :utc_datetime_usec)
    field(:review_delivery_receipt, Responder.CanonicalJSON.Type)
    field(:review_delivery_receipt_fingerprint, :string)

    field(:approval_ref, :string)
    field(:approved_by_actor_ref, :string)
    field(:approved_at, :utc_datetime_usec)

    field(:publication_receipt, Responder.CanonicalJSON.Type)
    field(:publication_receipt_fingerprint, :string)
    field(:github_repository, :string)
    field(:branch_ref, :string)
    field(:commit_sha, :string)
    field(:expected_remote_head_sha, :string)
    field(:pull_request_number, :integer)
    field(:pull_request_url, :string)
    field(:published_at, :utc_datetime_usec)
    field(:published_delivery_receipt, Responder.CanonicalJSON.Type)
    field(:published_delivery_receipt_fingerprint, :string)

    field(:attempt_count, :integer, default: 0)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)

    timestamps(type: :utc_datetime_usec)
  end
end

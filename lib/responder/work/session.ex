defmodule Responder.Work.Session do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_work_sessions" do
    belongs_to(:episode, Responder.Episodes.Episode)
    field(:execution_kind, Ecto.Enum, values: [:work, :admission], default: :work)
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:repository_ref, :string)
    field(:external_ref, :string)
    field(:generation, :integer, default: 1)
    field(:create_generation, :integer, default: 1)
    field(:coop_session_id, :string)
    field(:workspace_task, Responder.CanonicalJSON.Type)

    field(:cleanup_status, Ecto.Enum,
      values: [
        :active,
        :close_pending,
        :grace,
        :plan_pending,
        :discard_pending,
        :retained,
        :discarded,
        :blocked
      ],
      default: :active
    )

    field(:cleanup_attempt_count, :integer, default: 0)
    field(:cleanup_lease_ref, :string)
    field(:cleanup_lease_owner, :string)
    field(:cleanup_lease_expires_at, :utc_datetime_usec)
    field(:cleanup_next_attempt_at, :utc_datetime_usec)
    field(:cleanup_last_error_code, :string)
    field(:cleanup_last_error_detail, :string)

    field(:cleanup_blocked_from, Ecto.Enum,
      values: [:close_pending, :plan_pending, :discard_pending]
    )

    field(:close_generation, :integer, default: 1)
    field(:close_expected_revision, :integer)
    field(:closed_at, :utc_datetime_usec)
    field(:discard_after, :utc_datetime_usec)
    field(:discard_plan_generation, :integer, default: 1)
    field(:discard_plan_expected_revision, :integer)
    field(:discard_plan_accept_unmerged, :boolean, default: false)
    field(:discard_plan_operation_id, :string)
    field(:discard_plan, Responder.CanonicalJSON.Type)
    field(:discard_plan_fingerprint, :string)
    field(:discard_generation, :integer, default: 1)
    field(:cleanup_receipt, Responder.CanonicalJSON.Type)
    field(:cleanup_receipt_fingerprint, :string)
    field(:retained_reason, :string)
    field(:discarded_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          episode_id: Ecto.UUID.t() | nil,
          execution_kind: :work | :admission,
          policy: String.t() | nil,
          policy_digest: String.t() | nil,
          repository_ref: String.t() | nil,
          external_ref: String.t() | nil,
          generation: pos_integer(),
          create_generation: pos_integer(),
          coop_session_id: String.t() | nil,
          workspace_task: map() | nil,
          cleanup_status:
            :active
            | :close_pending
            | :grace
            | :plan_pending
            | :discard_pending
            | :retained
            | :discarded
            | :blocked,
          cleanup_attempt_count: non_neg_integer(),
          cleanup_lease_ref: String.t() | nil,
          cleanup_lease_owner: String.t() | nil,
          cleanup_lease_expires_at: DateTime.t() | nil,
          cleanup_next_attempt_at: DateTime.t() | nil,
          cleanup_last_error_code: String.t() | nil,
          cleanup_last_error_detail: String.t() | nil,
          cleanup_blocked_from: :close_pending | :plan_pending | :discard_pending | nil,
          close_generation: pos_integer(),
          close_expected_revision: pos_integer() | nil,
          closed_at: DateTime.t() | nil,
          discard_after: DateTime.t() | nil,
          discard_plan_generation: pos_integer(),
          discard_plan_expected_revision: pos_integer() | nil,
          discard_plan_accept_unmerged: boolean(),
          discard_plan_operation_id: String.t() | nil,
          discard_plan: map() | nil,
          discard_plan_fingerprint: String.t() | nil,
          discard_generation: pos_integer(),
          cleanup_receipt: map() | nil,
          cleanup_receipt_fingerprint: String.t() | nil,
          retained_reason: String.t() | nil,
          discarded_at: DateTime.t() | nil
        }
end

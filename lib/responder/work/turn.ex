defmodule Responder.Work.Turn do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_work_turns" do
    belongs_to(:episode, Responder.Episodes.Episode)
    belongs_to(:session, Responder.Work.Session)
    field(:turn_ref, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :cancel_pending, :delivery_pending, :settled, :blocked, :superseded]
    )

    field(:submit_generation, :integer, default: 1)
    field(:validation_generation, :integer, default: 1)
    field(:cancel_generation, :integer, default: 1)
    field(:cancel_expected_revision, :integer)
    field(:close_expected_revision, :integer)
    field(:submission, Responder.CanonicalJSON.Type)
    field(:submission_fingerprint, :string)
    field(:state_tools_endpoint, :string)
    field(:state_tools_token_sha256, :string)
    field(:coop_turn_id, :string)
    field(:candidate, :string)
    field(:candidate_sha256, :string)
    field(:candidate_attempt, :integer)
    field(:validation_intent, Responder.CanonicalJSON.Type)
    field(:validation_intent_fingerprint, :string)
    field(:validation_history, Responder.CanonicalJSON.Type, default: [])
    field(:validation_receipt, :string)
    field(:completion_receipt, Responder.CanonicalJSON.Type)
    field(:final_preflight_candidate_sha256, :string)
    field(:final_preflight_continuity_sha256, :string)
    field(:final_preflight_ledger_sha256, :string)
    field(:final_preflight_semantic_version, :integer)
    field(:execution_target, :string)
    field(:usage_recorded, :boolean, default: false)
    field(:usage_input_tokens, :integer)
    field(:usage_cached_input_tokens, :integer)
    field(:usage_output_tokens, :integer)
    field(:usage_reasoning_tokens, :integer)
    field(:usage_cost_usd, :decimal)
    field(:usage_cost_recorded, :boolean)
    field(:timing_recorded, :boolean, default: false)
    field(:remote_queued_at, :utc_datetime_usec)
    field(:remote_started_at, :utc_datetime_usec)
    field(:remote_finished_at, :utc_datetime_usec)
    field(:usage_queued_ms, :integer)
    field(:usage_provider_ms, :integer)
    field(:usage_host_ms, :integer)
    field(:measurement_error_code, :string)
    field(:summary_error_code, :string)
    field(:cancellation_intent, Responder.CanonicalJSON.Type)
    field(:cancellation_intent_fingerprint, :string)
    field(:cancellation_receipt, Responder.CanonicalJSON.Type)
    field(:cancellation_receipt_fingerprint, :string)
    field(:remote_operation_kind, :string)
    field(:remote_operation_key, :string)
    field(:remote_operation_revision, :integer)
    field(:result_ref, :string)
    field(:delivery_ref, :string)
    field(:delivery_document, Responder.CanonicalJSON.Type)
    field(:delivery_fingerprint, :string)
    field(:continuation, Responder.CanonicalJSON.Type)
    field(:external_receipt, Responder.CanonicalJSON.Type)
    field(:external_receipt_fingerprint, :string)
    field(:work_attempt_count, :integer, default: 0)
    field(:cancel_attempt_count, :integer, default: 0)
    field(:delivery_attempt_count, :integer, default: 0)
    field(:delivery_retry_generation, :integer, default: 0)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    field(:accepted_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    field(:delivered_at, :utc_datetime_usec)
    field(:operational_pruned_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          episode_id: Ecto.UUID.t() | nil,
          session_id: Ecto.UUID.t() | nil,
          turn_ref: String.t() | nil,
          status:
            :pending
            | :cancel_pending
            | :delivery_pending
            | :settled
            | :blocked
            | :superseded
            | nil,
          submit_generation: pos_integer(),
          validation_generation: pos_integer(),
          cancel_generation: pos_integer(),
          cancel_expected_revision: pos_integer() | nil,
          close_expected_revision: pos_integer() | nil,
          submission: Responder.Work.Submission.t() | nil,
          submission_fingerprint: String.t() | nil,
          state_tools_endpoint: String.t() | nil,
          state_tools_token_sha256: String.t() | nil,
          coop_turn_id: String.t() | nil,
          candidate: String.t() | nil,
          candidate_sha256: String.t() | nil,
          candidate_attempt: pos_integer() | nil,
          validation_intent: Responder.Work.ValidationIntent.t() | nil,
          validation_intent_fingerprint: String.t() | nil,
          validation_history: [map()],
          validation_receipt: String.t() | nil,
          completion_receipt: map() | nil,
          final_preflight_candidate_sha256: String.t() | nil,
          final_preflight_continuity_sha256: String.t() | nil,
          final_preflight_ledger_sha256: String.t() | nil,
          final_preflight_semantic_version: non_neg_integer() | nil,
          execution_target: String.t() | nil,
          usage_recorded: boolean(),
          usage_input_tokens: non_neg_integer() | nil,
          usage_cached_input_tokens: non_neg_integer() | nil,
          usage_output_tokens: non_neg_integer() | nil,
          usage_reasoning_tokens: non_neg_integer() | nil,
          usage_cost_usd: Decimal.t() | nil,
          usage_cost_recorded: boolean() | nil,
          timing_recorded: boolean(),
          remote_queued_at: DateTime.t() | nil,
          remote_started_at: DateTime.t() | nil,
          remote_finished_at: DateTime.t() | nil,
          usage_queued_ms: non_neg_integer() | nil,
          usage_provider_ms: non_neg_integer() | nil,
          usage_host_ms: non_neg_integer() | nil,
          measurement_error_code: String.t() | nil,
          cancellation_intent: Responder.Work.Cancellation.intent() | nil,
          cancellation_intent_fingerprint: String.t() | nil,
          cancellation_receipt: Responder.Work.Cancellation.receipt() | nil,
          cancellation_receipt_fingerprint: String.t() | nil,
          remote_operation_kind: String.t() | nil,
          remote_operation_key: String.t() | nil,
          remote_operation_revision: pos_integer() | nil,
          result_ref: String.t() | nil,
          delivery_ref: String.t() | nil,
          delivery_document: map() | nil,
          delivery_fingerprint: String.t() | nil,
          continuation: map() | nil,
          external_receipt: map() | nil,
          external_receipt_fingerprint: String.t() | nil,
          work_attempt_count: non_neg_integer(),
          cancel_attempt_count: non_neg_integer(),
          delivery_attempt_count: non_neg_integer(),
          delivery_retry_generation: non_neg_integer(),
          lease_ref: String.t() | nil,
          lease_owner: String.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          next_attempt_at: DateTime.t() | nil,
          last_error_code: String.t() | nil,
          last_error_detail: String.t() | nil,
          accepted_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          operational_pruned_at: DateTime.t() | nil
        }
end

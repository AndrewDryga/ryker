defmodule Ryker.WeeklyReport.Review do
  @moduledoc """
  One advisory operational review of a frozen weekly interval. The row owns
  both the queue lease and its single model turn. It never starts a replacement
  turn, and a late result cannot change the report already queued for delivery.
  """
  use Ryker, :schema

  schema "weekly_report_reviews" do
    field(:identity, :string)
    field(:conversation_ref, :string)
    field(:settings_saved_at, :utc_datetime_usec)
    field(:period_start, :utc_datetime_usec)
    field(:period_end, :utc_datetime_usec)
    field(:timezone, :string)
    field(:deadline_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:prepared, :responded, :applied, :rejected, :stale])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:prompt, :string)
    field(:prompt_sha256, :string)
    field(:output_schema, Ryker.CanonicalJSON.Type)
    field(:manifest, Ryker.CanonicalJSON.Type)
    field(:recommendations, {:array, :map}, default: [])
    field(:source_identities, {:array, :string}, default: [])
    field(:message_keys, {:array, :string}, default: [])
    field(:source_turn_ids, {:array, :binary_id}, default: [])
    field(:source_conversation_refs, {:array, :string}, default: [])
    field(:started_at, :utc_datetime_usec)
    field(:submit_revision, :integer)
    field(:coop_turn_id, :string)
    field(:candidate_attempt, :integer)
    field(:result, :string)
    field(:result_sha256, :string)
    field(:producer, Ryker.CanonicalJSON.Type)
    field(:validation_receipt, Ryker.CanonicalJSON.Type)
    field(:stop_receipt, Ryker.CanonicalJSON.Type)
    field(:remote_stopped_at, :utc_datetime_usec)
    field(:error_code, :string)
    field(:forgotten_at, :utc_datetime_usec)
    field(:pruned_at, :utc_datetime_usec)
    field(:lease_ref, :binary_id)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:reconcile_attempt_count, :integer, default: 0)
    timestamps()
  end

  @type t :: %__MODULE__{}
end

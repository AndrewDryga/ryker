defmodule Ryker.Work.CompletionReview.Run do
  @moduledoc "Historical completion-review receipts, retained for inspection, accounting and cleanup. No new reviews are created."
  use Ryker, :schema

  schema "work_completion_reviews" do
    belongs_to(:turn, Ryker.Work.Turn)
    field(:generation, :integer)
    field(:candidate_sha256, :string)
    field(:ledger_sha256, :string)
    field(:progress_sha256, :string)
    field(:status, Ecto.Enum, values: [:prepared, :responded, :applied, :rejected, :stale])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:prompt, :string)
    field(:prompt_sha256, :string)
    field(:output_schema, Ryker.CanonicalJSON.Type)
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
    field(:pruned_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end

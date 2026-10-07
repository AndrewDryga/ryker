defmodule Ryker.Improvement.AnalysisRun do
  @moduledoc """
  One model turn that analyzed a candidate (`improvement_analysis_runs`),
  frozen like a learning run: the exact prompt and output schema it was
  given, what evidence went in (`manifest`), the worker session and turn it
  ran as, the answer, and the proof it stopped (`remote_stopped_at`), which is
  when cleanup may close its session.

  `status` is `prepared` until the turn's answer is saved, `responded` once it
  is, `applied` once the diagnosis reached the candidate, `rejected` when the
  answer or the turn failed, and `stale` when it never started.
  """
  use Ryker, :schema

  schema "improvement_analysis_runs" do
    belongs_to(:candidate, Ryker.Improvement.Candidate)
    field(:generation, :integer)
    field(:status, Ecto.Enum, values: [:prepared, :responded, :applied, :rejected, :stale])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:prompt, :string)
    field(:prompt_sha256, :string)
    field(:output_schema, Ryker.CanonicalJSON.Type)
    field(:manifest, Ryker.CanonicalJSON.Type)
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
    field(:reconcile_attempt_count, :integer, default: 0)
    field(:pruned_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end

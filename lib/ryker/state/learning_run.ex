defmodule Ryker.State.LearningRun do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "conversation_learning_runs" do
    field(:batch_key, :string)
    field(:batch_id, :binary_id)
    field(:batch_budget_version, :integer, default: 0)
    field(:rebuild, Ryker.CanonicalJSON.Type)
    field(:started_at, :utc_datetime_usec)
    field(:submit_revision, :integer)
    field(:coop_turn_id, :string)
    field(:candidate_attempt, :integer)
    field(:validation_receipt, Ryker.CanonicalJSON.Type)
    field(:stop_receipt, Ryker.CanonicalJSON.Type)
    field(:remote_stopped_at, :utc_datetime_usec)
    field(:reconcile_attempt_count, :integer, default: 0)
    field(:generation, :integer)
    field(:status, Ecto.Enum, values: [:prepared, :responded, :applied, :stale, :rejected])
    field(:inputs, Ryker.CanonicalJSON.Type)
    field(:source_dependencies, Ryker.CanonicalJSON.Type)
    field(:knowledge, Ryker.CanonicalJSON.Type)
    field(:omissions, Ryker.CanonicalJSON.Type)
    field(:match_refs, Ryker.CanonicalJSON.Type, default: [])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:prompt, :string)
    field(:prompt_sha256, :string)
    field(:output_schema, Ryker.CanonicalJSON.Type)
    field(:result, :string)
    field(:result_sha256, :string)
    field(:producer, Ryker.CanonicalJSON.Type, default: %{})
    field(:error_code, :string)
    field(:applied_at, :utc_datetime_usec)
    field(:pruned_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

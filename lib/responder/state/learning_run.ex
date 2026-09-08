defmodule Responder.State.LearningRun do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "conversation_learning_runs" do
    field(:batch_key, :string)
    field(:batch_id, :binary_id)
    field(:batch_budget_version, :integer, default: 0)
    field(:rebuild, Responder.CanonicalJSON.Type)
    field(:started_at, :utc_datetime_usec)
    field(:submit_revision, :integer)
    field(:coop_turn_id, :string)
    field(:candidate_attempt, :integer)
    field(:validation_receipt, Responder.CanonicalJSON.Type)
    field(:stop_receipt, Responder.CanonicalJSON.Type)
    field(:remote_stopped_at, :utc_datetime_usec)
    field(:reconcile_attempt_count, :integer, default: 0)
    field(:generation, :integer)
    field(:status, Ecto.Enum, values: [:prepared, :responded, :applied, :stale, :rejected])
    field(:inputs, Responder.CanonicalJSON.Type)
    field(:source_dependencies, Responder.CanonicalJSON.Type)
    field(:knowledge, Responder.CanonicalJSON.Type)
    field(:omissions, Responder.CanonicalJSON.Type)
    field(:match_refs, Responder.CanonicalJSON.Type, default: [])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:prompt, :string)
    field(:prompt_sha256, :string)
    field(:output_schema, Responder.CanonicalJSON.Type)
    field(:result, :string)
    field(:result_sha256, :string)
    field(:producer, Responder.CanonicalJSON.Type, default: %{})
    field(:error_code, :string)
    field(:applied_at, :utc_datetime_usec)
    field(:pruned_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

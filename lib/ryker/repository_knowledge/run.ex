defmodule Ryker.RepositoryKnowledge.Run do
  @moduledoc """
  One model turn that read a repository (`repository_knowledge_runs`),
  frozen like a self-analysis run: the commit it read, the exact prompt and
  output schema it was given, what went into the prompt (`manifest`), the
  worker session and turn it ran as, the answer, the document written from
  it, and the proof it stopped (`remote_stopped_at`), which is when cleanup
  may close its session.

  `status` is `prepared` until the turn's answer is saved, `responded` once it
  is, `applied` once its checked document is written, `rejected` when the
  answer or the turn failed, and `stale` when it never started.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "repository_knowledge_runs" do
    field(:repository_ref, :string)
    field(:generation, :integer)
    field(:status, Ecto.Enum, values: [:prepared, :responded, :applied, :rejected, :stale])
    field(:source_commit, :string)
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
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
    field(:document, :string)
    field(:dropped_count, :integer)
    field(:error_code, :string)
    field(:reconcile_attempt_count, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end

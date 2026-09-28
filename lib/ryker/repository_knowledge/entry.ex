defmodule Ryker.RepositoryKnowledge.Entry do
  @moduledoc """
  One repository's RYKER.md custody (`repository_knowledge`).

  `phase` is what is wanted next: `idle` waits for the daily check at
  `next_check_at`; `write` has a model read the repository (or, when no
  model can finish and none ever wrote it, the outline). `reason` says why
  the last write was wanted, `requested_by` who asked for it on the
  Repositories page.

  The last document Ryker wrote is the repository's knowledge, which Work is
  briefed with (`Ryker.Work.SubmissionBuilder`): kept with the default branch
  commit it read (`document_commit`), when (`document_at`) and who wrote it
  (`document_by`: a model, or the outline). Nothing of it is written to the
  repository. `error` says in plain words why the last step failed.
  """

  use Ecto.Schema

  @primary_key {:repository_ref, :string, autogenerate: false}

  schema "repository_knowledge" do
    field(:phase, Ecto.Enum, values: [:idle, :write], default: :idle)
    field(:reason, :string)
    field(:requested_by, :string)
    field(:start_count, :integer, default: 0)
    field(:start_limit, :integer, default: 2)
    field(:lease_ref, :binary_id)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:next_check_at, :utc_datetime_usec)
    field(:checked_at, :utc_datetime_usec)
    field(:document, :string)
    field(:document_sha256, :string)
    field(:document_commit, :string)
    field(:document_by, Ecto.Enum, values: [:model, :outline])
    field(:document_at, :utc_datetime_usec)
    field(:document_run_id, :binary_id)
    field(:dropped_count, :integer)
    field(:error_code, :string)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end

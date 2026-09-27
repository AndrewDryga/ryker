defmodule Ryker.RepositoryKnowledge.Entry do
  @moduledoc """
  One repository's RYKER.md custody (`repository_knowledge`).

  `phase` is what is wanted next: `idle` waits for the daily check at
  `next_check_at`; `write` has a model read the repository (or, when no
  model can finish and none ever wrote it, the outline); `publish` proposes
  the written document on GitHub. `reason` says why the last write was
  wanted, `requested_by` who asked for it on the Repositories page.

  The last document Ryker wrote is kept with the default branch commit it
  read (`document_commit`), when (`document_at`) and who wrote it
  (`document_by`: a model, or the outline). `published_at` and
  `publication` say how it reached GitHub: a pull request `opened`, an open
  one `updated`, or nothing, because the default branch already said the
  same (`unchanged`). `pull_request_url` is Ryker's latest knowledge pull
  request, and `pull_request_state` where it stood when last read. `error`
  says in plain words why the last step failed.
  """

  use Ecto.Schema

  @primary_key {:repository_ref, :string, autogenerate: false}

  schema "repository_knowledge" do
    field(:phase, Ecto.Enum, values: [:idle, :write, :publish], default: :idle)
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
    field(:published_at, :utc_datetime_usec)
    field(:publication, Ecto.Enum, values: [:opened, :updated, :unchanged])
    field(:pull_request_url, :string)
    field(:pull_request_number, :integer)
    field(:pull_request_state, Ecto.Enum, values: [:open, :merged, :closed])
    field(:error_code, :string)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end

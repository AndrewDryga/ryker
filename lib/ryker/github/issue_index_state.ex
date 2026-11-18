defmodule Ryker.GitHub.IssueIndexState do
  @moduledoc "One repository identity's bounded backfill and refresh lease."
  use Ryker, :schema

  schema "github_issue_indexes" do
    field(:identity, :string)
    field(:binding_ref, :string)
    field(:repository_ref, :string)
    field(:repository_id, :integer)
    field(:installation_id, :integer)
    field(:page, :integer, default: 1)
    field(:backfill_complete, :boolean, default: false)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end

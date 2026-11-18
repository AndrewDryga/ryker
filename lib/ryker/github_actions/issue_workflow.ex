defmodule Ryker.GitHubActions.IssueWorkflow do
  @moduledoc "One issue's current plan and its single GitHub progress comment. Earlier plans stay separate."
  use Ryker, :schema

  schema "github_issue_workflows" do
    field(:identity, :string)
    field(:binding_ref, :string)
    field(:repository_ref, :string)
    field(:repository_id, :integer)
    field(:installation_id, :integer)
    field(:number, :integer)
    field(:revision, :integer, default: 0)
    field(:current_plan_id, :binary_id)
    field(:current_request_id, :binary_id)
    field(:issue_snapshot, Ryker.CanonicalJSON.Type)
    field(:external_receipt, Ryker.CanonicalJSON.Type)
    field(:rendered_fingerprint, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error, :string)
    timestamps()
  end

  @type t :: %__MODULE__{}
end

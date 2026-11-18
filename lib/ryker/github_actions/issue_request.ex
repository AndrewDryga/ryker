defmodule Ryker.GitHubActions.IssueRequest do
  @moduledoc "One accepted planning or build request, frozen independently of later plan edits."
  use Ryker, :schema

  schema "github_issue_requests" do
    belongs_to(:workflow, Ryker.GitHubActions.IssueWorkflow)
    field(:plan_id, :binary_id)
    field(:kind, Ecto.Enum, values: [:make_plan, :build_issue, :implement_plan, :triage_issue])
    field(:request_key, :string)
    field(:base_revision, :integer)
    field(:source_snapshot, Ryker.CanonicalJSON.Type)
    field(:actor_id, :integer)
    field(:entry_id, :binary_id)
    field(:outcome, Ryker.CanonicalJSON.Type)
    field(:finished_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end

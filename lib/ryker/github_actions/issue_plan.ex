defmodule Ryker.GitHubActions.IssuePlan do
  @moduledoc "One immutable plan revision, including its inspected commit and original issue snapshot."
  use Ryker, :schema

  schema "github_issue_plans" do
    belongs_to(:workflow, Ryker.GitHubActions.IssueWorkflow)
    field(:revision, :integer)
    field(:parent_plan_id, :binary_id)
    field(:source_key, :string)
    field(:body, :string)
    field(:source_commit, :string)
    field(:issue_snapshot, Ryker.CanonicalJSON.Type)
    field(:author_ref, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end

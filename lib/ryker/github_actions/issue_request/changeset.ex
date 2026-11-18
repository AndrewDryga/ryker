defmodule Ryker.GitHubActions.IssueRequest.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHubActions.IssueRequest

  @fields ~w(workflow_id plan_id kind request_key base_revision source_snapshot actor_id entry_id inserted_at)a

  def insert(attributes) do
    %IssueRequest{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:plan_id])
    |> unique_constraint([:workflow_id, :request_key])
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:plan_id, name: :github_issue_request_plan_owned)
    |> check_constraint(:kind, name: :github_issue_request_valid)
  end

  def finish(%IssueRequest{finished_at: nil} = request, outcome, now) do
    request
    |> change(outcome: outcome, finished_at: now)
    |> check_constraint(:outcome, name: :github_issue_request_outcome_valid)
  end
end

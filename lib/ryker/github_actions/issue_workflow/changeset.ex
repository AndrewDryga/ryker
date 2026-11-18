defmodule Ryker.GitHubActions.IssueWorkflow.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHubActions.IssueWorkflow

  @identity ~w(identity binding_ref repository_ref repository_id installation_id number)a
  @mutable ~w(revision current_plan_id current_request_id issue_snapshot external_receipt rendered_fingerprint next_attempt_at attempt_count lease_ref lease_expires_at last_error)a

  def insert(attributes) do
    %IssueWorkflow{}
    |> cast(attributes, @identity ++ [:issue_snapshot, :next_attempt_at])
    |> validate_required(@identity ++ [:issue_snapshot])
    |> workflow_constraints()
  end

  def update(%IssueWorkflow{} = workflow, attributes),
    do: workflow |> cast(attributes, @mutable) |> workflow_constraints()

  defp workflow_constraints(changeset) do
    changeset
    |> unique_constraint(:identity)
    |> check_constraint(:identity, name: :github_issue_workflow_valid)
    |> foreign_key_constraint(:current_plan_id, name: :github_issue_workflow_plan_owned)
    |> foreign_key_constraint(:current_request_id, name: :github_issue_workflow_request_owned)
  end
end

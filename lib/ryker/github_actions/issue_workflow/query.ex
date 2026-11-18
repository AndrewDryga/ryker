defmodule Ryker.GitHubActions.IssueWorkflow.Query do
  @moduledoc "Bounded reads of issue plans and their comment delivery custody."
  use Ryker, :query
  alias Ryker.GitHubActions.IssueWorkflow

  def all, do: from(workflows in IssueWorkflow, as: :github_issue_workflows)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [github_issue_workflows: w], w.id == ^id)

  def by_identity(queryable \\ all(), identity),
    do: where(queryable, [github_issue_workflows: w], w.identity == ^identity)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def next_claimable(now, bindings) do
    from(w in all(),
      where: w.binding_ref in ^bindings,
      where: not is_nil(w.next_attempt_at) and w.next_attempt_at <= ^now,
      where: is_nil(w.lease_expires_at) or w.lease_expires_at <= ^now,
      order_by: [asc: w.next_attempt_at, asc: w.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end
end

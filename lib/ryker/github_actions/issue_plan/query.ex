defmodule Ryker.GitHubActions.IssuePlan.Query do
  @moduledoc "Exact plan revisions and a bounded issue history."
  use Ryker, :query
  alias Ryker.GitHubActions.IssuePlan

  def all, do: from(plans in IssuePlan, as: :github_issue_plans)
  def by_id(queryable \\ all(), id), do: where(queryable, [github_issue_plans: p], p.id == ^id)

  def by_workflow_id(queryable \\ all(), id),
    do: where(queryable, [github_issue_plans: p], p.workflow_id == ^id)

  def by_source_key(queryable \\ all(), key),
    do: where(queryable, [github_issue_plans: p], p.source_key == ^key)

  def before_revision(queryable, nil), do: queryable

  def before_revision(queryable, revision),
    do: where(queryable, [github_issue_plans: p], p.revision < ^revision)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [github_issue_plans: p], desc: p.revision)

  def limit_to(queryable, count), do: limit(queryable, ^count)
end

defmodule Ryker.GitHubActions.IssueRequest.Query do
  @moduledoc "Exact immutable issue starts; each saved request has one ingress input."
  use Ryker, :query
  alias Ryker.GitHubActions.IssueRequest

  def all, do: from(requests in IssueRequest, as: :github_issue_requests)
  def by_id(queryable \\ all(), id), do: where(queryable, [github_issue_requests: r], r.id == ^id)

  def by_workflow_id(queryable \\ all(), id),
    do: where(queryable, [github_issue_requests: r], r.workflow_id == ^id)

  def by_request_key(queryable \\ all(), key),
    do: where(queryable, [github_issue_requests: r], r.request_key == ^key)

  def by_entry_id(queryable \\ all(), id),
    do: where(queryable, [github_issue_requests: r], r.entry_id == ^id)
end

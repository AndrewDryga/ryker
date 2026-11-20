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

  @doc "An approval survives later page revisions, including requests recorded by earlier releases."
  def approved_work(query, :implement_plan, %{"plan_id" => id}, _issue, _key)
      when is_binary(id) do
    plan_implementation(query, id)
  end

  def approved_work(query, :build_issue, _expected, issue, _key) do
    report = Map.take(issue, ~w(id number title body url))

    query
    |> where(
      [github_issue_requests: r],
      r.kind == :build_issue and
        fragment("(?::jsonb->'issue') @> ?::jsonb", r.source_snapshot, ^report)
    )
    |> oldest()
  end

  def approved_work(query, _kind, _expected, _issue, key), do: by_request_key(query, key)

  def plan_implementation(query, id) do
    query
    |> where([github_issue_requests: r], r.kind == :implement_plan and r.plan_id == ^id)
    |> oldest()
  end

  defp oldest(query) do
    query |> order_by([github_issue_requests: r], asc: r.inserted_at, asc: r.id) |> limit(1)
  end

  def by_entry_id(queryable \\ all(), id),
    do: where(queryable, [github_issue_requests: r], r.entry_id == ^id)
end

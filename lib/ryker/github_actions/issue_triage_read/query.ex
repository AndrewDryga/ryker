defmodule Ryker.GitHubActions.IssueTriageRead.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.GitHubActions.IssueTriageRead
  def all, do: from(reads in IssueTriageRead, as: :github_issue_triage_reads)

  def by_request_id(queryable \\ all(), id),
    do: where(queryable, [github_issue_triage_reads: r], r.request_id == ^id)

  def by_fingerprint(queryable, digest),
    do: where(queryable, [github_issue_triage_reads: r], r.fingerprint == ^digest)
end

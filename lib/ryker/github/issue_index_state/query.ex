defmodule Ryker.GitHub.IssueIndexState.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.GitHub.IssueIndexState

  def all, do: from(indexes in IssueIndexState, as: :github_issue_indexes)
  def by_id(queryable \\ all(), id), do: where(queryable, [github_issue_indexes: i], i.id == ^id)

  def by_identity(queryable \\ all(), identity),
    do: where(queryable, [github_issue_indexes: i], i.identity == ^identity)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def next_claimable(now, bindings) do
    from(i in all(),
      where: i.binding_ref in ^bindings,
      where: not is_nil(i.next_attempt_at) and i.next_attempt_at <= ^now,
      where: is_nil(i.lease_expires_at) or i.lease_expires_at <= ^now,
      order_by: [asc: i.next_attempt_at, asc: i.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end
end

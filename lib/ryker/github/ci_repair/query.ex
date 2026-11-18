defmodule Ryker.GitHub.CIRepair.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.GitHub.CIRepair

  def all, do: from(repairs in CIRepair, as: :github_ci_repairs)
  def by_id(queryable \\ all(), id), do: where(queryable, [github_ci_repairs: r], r.id == ^id)

  def by_identity(queryable \\ all(), identity),
    do: where(queryable, [github_ci_repairs: r], r.identity == ^identity)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def active_pulls(binding_ref, repository_id) do
    from(r in all(),
      where: r.binding_ref == ^binding_ref and r.repository_id == ^repository_id and r.allowed,
      select: r.number
    )
  end

  def next_claimable(now, bindings) do
    from(r in all(),
      where: r.binding_ref in ^bindings,
      where: not is_nil(r.next_attempt_at) and r.next_attempt_at <= ^now,
      where: is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now,
      order_by: [asc: r.next_attempt_at, asc: r.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end
end

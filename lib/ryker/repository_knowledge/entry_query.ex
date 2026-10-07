defmodule Ryker.RepositoryKnowledge.EntryQuery do
  @moduledoc "What Ryker knows about each repository, for every read of `repository_knowledge`."
  import Ecto.Query
  alias Ryker.RepositoryKnowledge.{Entry, RunQuery}

  def all, do: from(entries in Entry, as: :repository_knowledge)

  def by_repository(queryable \\ all(), ref),
    do: where(queryable, [repository_knowledge: e], e.repository_ref == ^ref)

  def by_repositories(queryable \\ all(), refs),
    do: where(queryable, [repository_knowledge: e], e.repository_ref in ^refs)

  def select_refs(queryable), do: select(queryable, [repository_knowledge: e], e.repository_ref)

  def select_by_ref(queryable),
    do: select(queryable, [repository_knowledge: e], {e.repository_ref, e})

  @doc """
  The entry due first at `now` among repositories `refs` still sets up: a
  worker stopped renewing its lease; or, unleased, a write is due for a
  repository still set up or with a run out at Coop; or the daily check is
  due. Taken by one worker at a time.
  """
  def next_claimable(now, refs) do
    all()
    |> where(^claimable(now, refs))
    |> order_by([repository_knowledge: e],
      asc: coalesce(e.next_attempt_at, e.next_check_at),
      asc: e.repository_ref
    )
    |> limit(1)
    |> lock("FOR UPDATE SKIP LOCKED")
  end

  @doc """
  The next retry, daily check and lease expiry after `since`: what wakes the
  lane by the clock alone.
  """
  def next_due_after(since, refs) do
    select(all(), [repository_knowledge: e], [
      filter(
        min(e.next_attempt_at),
        is_nil(e.lease_ref) and e.phase == :write and e.next_attempt_at > ^since and
          (e.repository_ref in ^refs or exists(RunQuery.outstanding_for_parent()))
      ),
      filter(
        min(e.next_check_at),
        is_nil(e.lease_ref) and e.phase == :idle and e.next_check_at > ^since and
          e.repository_ref in ^refs
      ),
      filter(min(e.lease_expires_at), not is_nil(e.lease_ref) and e.lease_expires_at > ^since)
    ])
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  defp claimable(now, refs) do
    dynamic(
      [repository_knowledge: e],
      (not is_nil(e.lease_ref) and e.lease_expires_at <= ^now) or
        (is_nil(e.lease_ref) and (^step_due(now, refs) or ^check_due(now, refs)))
    )
  end

  defp step_due(now, refs) do
    dynamic(
      [repository_knowledge: e],
      e.phase == :write and
        (is_nil(e.next_attempt_at) or e.next_attempt_at <= ^now) and
        (e.repository_ref in ^refs or exists(RunQuery.outstanding_for_parent()))
    )
  end

  defp check_due(now, refs) do
    dynamic(
      [repository_knowledge: e],
      e.phase == :idle and (is_nil(e.next_check_at) or e.next_check_at <= ^now) and
        e.repository_ref in ^refs
    )
  end
end

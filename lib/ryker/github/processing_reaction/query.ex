defmodule Ryker.GitHub.ProcessingReaction.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.GitHub.ProcessingReaction

  def all, do: from(reactions in ProcessingReaction, as: :github_processing_reactions)

  def by_binding(queryable \\ all(), name, repository_id, actor_id) do
    where(
      queryable,
      [github_processing_reactions: r],
      r.binding == ^name and r.repository_id == ^repository_id and r.actor_id == ^actor_id
    )
  end

  def by_id(queryable \\ all(), id),
    do: where(queryable, [github_processing_reactions: r], r.id == ^id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def oldest_due_first(queryable, now) do
    from(r in queryable,
      where:
        not r.blocked and
          (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now) and
          (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now),
      order_by: [asc: r.updated_at, asc: r.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> requiring_write()
  end

  defp requiring_write(queryable) do
    where(
      queryable,
      [github_processing_reactions: r],
      (r.desired and (is_nil(r.reaction_id) or r.uncertain)) or
        (not r.desired and (not is_nil(r.reaction_id) or r.uncertain))
    )
  end
end

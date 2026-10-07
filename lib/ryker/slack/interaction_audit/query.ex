defmodule Ryker.Slack.InteractionAudit.Query do
  @moduledoc "Slack button presses Ryker answered, for every read of `slack_interaction_audit`."
  import Ecto.Query
  alias Ryker.Slack.InteractionAudit

  def all, do: from(audits in InteractionAudit, as: :slack_interaction_audit)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [slack_interaction_audit: a], a.id == ^id)

  def by_event_ref(queryable \\ all(), event_ref),
    do: where(queryable, [slack_interaction_audit: a], a.event_ref == ^event_ref)

  @doc "When pending repaints fall due after `since`, as `[next_attempt_at, lease_expires_at]`."
  def next_due_after(since) do
    from(audit in all(),
      where: audit.repaint_status == :pending,
      select: [
        filter(min(audit.next_attempt_at), audit.next_attempt_at > ^since),
        filter(min(audit.lease_expires_at), audit.lease_expires_at > ^since)
      ]
    )
  end

  @doc """
  The pending repaint a worker takes next at `now`: due and unleased, the
  earliest press first, skipping any another holds.
  """
  def next_claimable(now) do
    from(audit in all(),
      where:
        audit.repaint_status == :pending and
          (is_nil(audit.next_attempt_at) or audit.next_attempt_at <= ^now) and
          (is_nil(audit.lease_expires_at) or audit.lease_expires_at <= ^now),
      order_by: [asc: audit.occurred_at, asc: audit.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  def repaint_blocked(queryable \\ all()),
    do: where(queryable, [slack_interaction_audit: a], a.repaint_status == :blocked)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [slack_interaction_audit: a], desc: a.updated_at, desc: a.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end

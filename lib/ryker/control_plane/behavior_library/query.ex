defmodule Ryker.ControlPlane.BehaviorLibrary.Query do
  @moduledoc """
  What the Rules and saved-instruction pages read (`Ryker.ControlPlane.BehaviorLibrary`):
  each confirmed behavior with the status a reader sees, its counts, view
  and search, and the latest runs of standing rules.
  """
  use Ryker, :query
  alias Ryker.Behaviors
  alias Ryker.ControlPlane.Search
  alias Ryker.Episodes
  require Ryker.ControlPlane.Search

  @doc """
  Every confirmed behavior as the library shows it at `now`. Expiry is
  effective even before a maintenance pass updates the stored status.
  """
  def entries(now) do
    from([operator_behaviors: b] in Behaviors.Behavior.Query.all(),
      select: %{
        id: b.id,
        ref: b.ref,
        kind: b.kind,
        payload: b.payload,
        status:
          fragment(
            "CASE WHEN ? IN ('active', 'disabled') AND ? <= ? THEN 'expired' ELSE ? END",
            b.status,
            b.expires_at,
            ^now,
            b.status
          ),
        workspace_ref: b.workspace_ref,
        scope_kind: b.scope_kind,
        scope_ref: b.scope_ref,
        use_count: b.use_count,
        last_used_at: b.last_used_at,
        expires_at: b.expires_at,
        confirmed_at: b.confirmed_at,
        source_conversation_ref: b.source_conversation_ref,
        source_message_ref: b.source_message_ref,
        updated_at: b.updated_at
      }
    )
  end

  @doc "How many `entries` are in each status, as `{status, count}`."
  def status_counts(entries),
    do: from(b in subquery(entries), group_by: b.status, select: {b.status, count(b.id)})

  @doc "The `entries` a list pages through, by the status a reader sees."
  def listed(entries), do: from(b in subquery(entries), as: :library_entries)

  @doc "Listed entries in the past view (expired, deleted, superseded) or the current one."
  def in_view(listed, "past"),
    do: where(listed, [library_entries: b], b.status in ["expired", "deleted", "superseded"])

  def in_view(listed, _current),
    do: where(listed, [library_entries: b], b.status in ["active", "disabled"])

  @doc "Listed entries whose stored text or scope contains `pattern`."
  def matching(listed, pattern) do
    where(
      listed,
      [library_entries: b],
      Search.json_text_matches(b.payload, ^pattern) or ilike(b.scope_ref, ^pattern)
    )
  end

  @doc "The `limit` latest runs of the standing rules `rule_ids`."
  def rule_runs(rule_ids, limit) do
    from(r in Behaviors.StandingAssignmentRun,
      left_join: e in Episodes.Episode,
      on: e.id == r.episode_id,
      join: b in Behaviors.Behavior,
      on: b.id == r.assignment_id,
      where: r.assignment_id in ^rule_ids,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit,
      select: %{
        rule_ref: b.ref,
        at: r.inserted_at,
        outcome: r.outcome,
        action: r.decision_action,
        episode_id: e.id
      }
    )
  end
end

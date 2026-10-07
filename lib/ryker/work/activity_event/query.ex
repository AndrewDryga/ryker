defmodule Ryker.Work.ActivityEvent.Query do
  @moduledoc "What a Work worker reported doing, for every read of `episode_work_activity`."
  use Ryker, :query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.{ActivityEvent, Session, Turn}

  def all, do: from(events in ActivityEvent, as: :episode_work_activity)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_work_activity: a], a.id == ^id)

  @doc "A Coop turn's events of `kinds` that keep their bodies, oldest first, as training reads them."
  def trajectory(episode_id, coop_turn_id, kinds) do
    all()
    |> where(
      [episode_work_activity: a],
      a.episode_id == ^episode_id and a.coop_turn_id == ^coop_turn_id and a.kind in ^kinds and
        is_nil(a.operational_pruned_at)
    )
    |> order_by([episode_work_activity: a], asc: a.sequence, asc: a.occurred_at)
    |> select([episode_work_activity: a], %{
      "kind" => a.kind,
      "at" => a.occurred_at,
      "payload" => a.payload
    })
  end

  @doc "Episode `episode_id`'s events, and those of the messages it was routed from."
  def by_episode_id(episode_id) do
    inputs = episode_id |> Entry.Query.by_episode_id() |> Entry.Query.select_ids()

    where(
      all(),
      [episode_work_activity: a],
      a.episode_id == ^episode_id or a.admission_input_id in subquery(inputs)
    )
  end

  @doc "The event a session recorded at Coop sequence `sequence` of remote session `remote_session_id`."
  def by_sequence(session_id, remote_session_id, sequence) do
    where(
      all(),
      [episode_work_activity: a],
      a.session_id == ^session_id and a.remote_session_id == ^remote_session_id and
        a.sequence == ^sequence
    )
  end

  @doc "Events still shown: not pruned, and whose owner has not expired."
  def visible(queryable) do
    expired = expired_ids()

    where(
      queryable,
      [episode_work_activity: a],
      is_nil(a.operational_pruned_at) and a.id not in subquery(expired)
    )
  end

  @doc "Up to `limit` events whose owner expired, oldest first, skipping any another pass holds."
  def prunable(limit) do
    expired = expired_ids()

    from(a in all(),
      where: is_nil(a.operational_pruned_at) and a.id in subquery(expired),
      order_by: [asc: a.inserted_at, asc: a.id],
      limit: ^limit,
      select: a.id,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc "The events whose ids `ids`, a query of ids, selects."
  def among(ids), do: where(all(), [episode_work_activity: a], a.id in subquery(ids))

  # Events retire with their owner: a pruned routed message or Work turn.
  # Events without a turn binding retire when every turn in the discarded
  # session has expired.
  defp expired_ids do
    unexpired_turns =
      from(t in Turn, where: is_nil(t.operational_pruned_at), select: t.session_id)

    expired_turns =
      from(t in Turn, where: not is_nil(t.operational_pruned_at), select: t.session_id)

    from(a in ActivityEvent,
      left_join: i in Entry,
      on: i.id == a.admission_input_id,
      join: s in Session,
      on: s.id == a.session_id,
      left_join: t in Turn,
      on: t.session_id == a.session_id and t.coop_turn_id == a.coop_turn_id,
      where:
        not is_nil(i.operational_pruned_at) or not is_nil(t.operational_pruned_at) or
          (s.cleanup_status == :discarded and s.id in subquery(expired_turns) and
             s.id not in subquery(unexpired_turns)),
      select: a.id
    )
  end

  @doc """
  The Emisar runs among `references` that episode `episode_id`'s completed
  `run_action` calls returned, as one list of `{run_id, run_url}` maps per
  call. Only receipt identities are read, never a call's output.
  """
  def emisar_run_receipts(episode_id, references) do
    from(a in all(),
      where: a.episode_id == ^episode_id and a.kind == "tool.completed",
      where: fragment("?::jsonb #>> '{input,server}' = 'emisar'", a.payload),
      where: fragment("?::jsonb #>> '{input,tool}' = 'run_action'", a.payload),
      where: fragment("?::jsonb #>> '{status}' = 'completed'", a.payload),
      select:
        fragment(
          "(SELECT coalesce(jsonb_agg(jsonb_build_object('run_id', r->>'run_id', 'run_url', r->>'run_url')), '[]'::jsonb) FROM jsonb_path_query(?::jsonb, '$.output.result.structuredContent.runs[*]') AS r WHERE r->>'run_id' = ANY(?))",
          a.payload,
          type(^references, {:array, :string})
        )
    )
    |> visible()
  end

  @doc """
  The values among `urls` that a completed tool call of episode `episode_id`
  returned whole, as one list per call. Ryker's own state and controller
  tools are left out: they hand back the records the model just wrote.
  """
  def returned_urls(episode_id, urls) do
    from(a in all(),
      where: a.episode_id == ^episode_id and a.kind == "tool.completed",
      where: fragment("?::jsonb #>> '{status}' = 'completed'", a.payload),
      where:
        fragment("?::jsonb #>> '{input,server}' IS DISTINCT FROM 'responder-state'", a.payload) and
          fragment("?::jsonb #>> '{input,server}' IS DISTINCT FROM 'controller-tools'", a.payload),
      select:
        fragment(
          "(SELECT coalesce(jsonb_agg(DISTINCT returned), '[]'::jsonb) FROM jsonb_path_query(?::jsonb #> '{output}', '$.**') AS returned WHERE jsonb_typeof(returned) = 'string' AND (returned #>> '{}') = ANY(?))",
          a.payload,
          type(^urls, {:array, :string})
        )
    )
    |> visible()
  end

  @doc "How many events, and how many tool calls among them."
  def select_totals(queryable) do
    select(queryable, [episode_work_activity: a], %{
      tool_calls: filter(count(a.id), a.kind == "tool.started"),
      total: count(a.id)
    })
  end

  def ordered_by_occurred_at_desc(queryable) do
    order_by(queryable, [episode_work_activity: a],
      desc: a.occurred_at,
      desc: a.session_id,
      desc: a.sequence
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc """
  The tool calls of episode `episode_id` that keep their bodies, started and
  completed, in order, as `{coop_turn_id, kind, payload}`.
  """
  def tool_events(episode_id) do
    from(a in all(),
      where:
        a.episode_id == ^episode_id and a.kind in ["tool.started", "tool.completed"] and
          is_nil(a.operational_pruned_at),
      order_by: [asc: a.occurred_at, asc: a.sequence],
      select: {a.coop_turn_id, a.kind, a.payload}
    )
  end
end

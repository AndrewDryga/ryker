defmodule Ryker.Work.Turn.Query do
  @moduledoc "Work turns, for every read of `episode_work_turns`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Work.{Session, Turn}

  def all, do: from(turns in Turn, as: :episode_work_turns)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_work_turns: t], t.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_work_turns: t], t.episode_id == ^episode_id)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [episode_work_turns: t], t.session_id == ^session_id)

  @doc "Turns that reached Coop or produced anything: a candidate or a result."
  def begun(queryable) do
    where(
      queryable,
      [episode_work_turns: t],
      not is_nil(t.coop_turn_id) or not is_nil(t.candidate) or not is_nil(t.result_ref)
    )
  end

  def by_delivery_ref(queryable \\ all(), delivery_ref),
    do: where(queryable, [episode_work_turns: t], t.delivery_ref == ^delivery_ref)

  @doc "Answers whose delivery is blocked."
  def blocked_deliveries(queryable \\ all()) do
    where(
      queryable,
      [episode_work_turns: t],
      t.status == :blocked and not is_nil(t.delivery_ref)
    )
  end

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [episode_work_turns: t], desc: t.updated_at, desc: t.id)

  @doc "Episode `episode_id`'s owning turn while it waits, unleased, to start."
  def waiting_owner(episode_id) do
    from(t in all(),
      join: e in Episode,
      on: e.id == t.episode_id and t.turn_ref == e.owner_ref,
      where: t.episode_id == ^episode_id and t.status == :pending and is_nil(t.lease_ref)
    )
  end

  @doc """
  When the turns in `statuses` fall due after `since`, as
  `[next_attempt_at, lease_expires_at]`: the earliest retry, and the earliest
  lease that runs out.
  """
  def next_due_after(since, statuses) do
    from(t in all(),
      where: t.status in ^statuses,
      select: [
        filter(min(t.next_attempt_at), t.next_attempt_at > ^since),
        filter(min(t.lease_expires_at), not is_nil(t.lease_ref) and t.lease_expires_at > ^since)
      ]
    )
  end

  @doc """
  The turns of `episode`'s session `session_id` that a transfer left behind:
  pending or blocked under an owner the episode no longer has, oldest first.
  """
  def left_by_transfer(episode, session_id) do
    from(t in all(),
      where:
        t.episode_id == ^episode.id and t.session_id == ^session_id and
          t.turn_ref != ^episode.owner_ref and t.status in [:pending, :blocked],
      order_by: [asc: t.inserted_at, asc: t.id]
    )
  end

  def by_turn_ref(queryable, turn_ref),
    do: where(queryable, [episode_work_turns: t], t.turn_ref == ^turn_ref)

  @doc "Still running or stopped on a failure: pending, being cancelled or blocked."
  def unsettled(queryable) do
    where(
      queryable,
      [episode_work_turns: t],
      t.status in [:pending, :cancel_pending, :blocked]
    )
  end

  @doc "Session `session_id`'s turn the state-tools binding `endpoint`/`token_sha256` was made for."
  def state_tools_bound(session_id, endpoint, token_sha256) do
    where(
      all(),
      [episode_work_turns: t],
      t.session_id == ^session_id and t.state_tools_endpoint == ^endpoint and
        t.state_tools_token_sha256 == ^token_sha256
    )
  end

  @doc """
  The turn whose delivered reply is Slack message `message_ref` in channel
  `channel_ref` of `workspace_ref`, in thread `thread_ref` (nil: not in a
  thread), found by the message's ref (`episode_work_turns_receipt_message`):
  the lookup read every delivered turn's receipt as JSON on each repaint
  (2026-10-04 review).
  """
  def delivered_slack_message(workspace_ref, channel_ref, message_ref, thread_ref) do
    conversation_ref = "slack:#{workspace_ref}:#{channel_ref}"

    from(t in all(),
      where:
        not is_nil(t.external_receipt) and
          fragment("(?::jsonb)->>'transport' = 'slack'", t.external_receipt) and
          fragment("(?::jsonb)->>'conversation_ref' = ?", t.external_receipt, ^conversation_ref) and
          fragment("(?::jsonb)->>'message_ref' = ?", t.external_receipt, ^message_ref),
      order_by: [desc: t.delivered_at, desc: t.id],
      limit: 1
    )
    |> in_receipt_thread(thread_ref)
  end

  defp in_receipt_thread(queryable, nil) do
    where(
      queryable,
      [episode_work_turns: t],
      fragment("(?::jsonb)->>'thread_ref' IS NULL", t.external_receipt)
    )
  end

  defp in_receipt_thread(queryable, thread_ref) do
    where(
      queryable,
      [episode_work_turns: t],
      fragment("(?::jsonb)->>'thread_ref' = ?", t.external_receipt, ^thread_ref)
    )
  end

  def cancelling(queryable),
    do: where(queryable, [episode_work_turns: t], t.status == :cancel_pending)

  @doc "Turns still to start, run, stop or deliver."
  def unfinished(queryable) do
    where(
      queryable,
      [episode_work_turns: t],
      t.status in [:pending, :cancel_pending, :delivery_pending]
    )
  end

  def having_result(queryable),
    do: where(queryable, [episode_work_turns: t], not is_nil(t.result_ref))

  def select_ids(queryable), do: select(queryable, [episode_work_turns: t], t.id)

  def having_selected_inputs(queryable),
    do: where(queryable, [episode_work_turns: t], not is_nil(t.selected_input_refs))

  @doc "The inputs each turn chose to answer, as `{id, episode_id, selected_input_refs}`."
  def select_selected_inputs(queryable),
    do: select(queryable, [episode_work_turns: t], {t.id, t.episode_id, t.selected_input_refs})

  @doc "Each turn's Coop turn and when it was pruned, as `{coop_turn_id, operational_pruned_at}`."
  def select_pruning(queryable),
    do: select(queryable, [episode_work_turns: t], {t.coop_turn_id, t.operational_pruned_at})

  @doc "The Emisar account the session of turn `turn_id` of `episode_id` ran with."
  def session_emisar_authority(turn_id, episode_id) do
    from(t in all(),
      join: s in Session,
      on: s.id == t.session_id and s.episode_id == t.episode_id,
      where: t.id == ^turn_id and t.episode_id == ^episode_id,
      select: {s.emisar_connection_ref, s.emisar_account_ref, s.emisar_rpc_url}
    )
  end

  def select_episode_ids(queryable),
    do: select(queryable, [episode_work_turns: t], t.episode_id)

  def by_ids(queryable \\ all(), ids), do: where(queryable, [episode_work_turns: t], t.id in ^ids)

  def select_sessions(queryable),
    do: select(queryable, [episode_work_turns: t], {t.id, t.session_id})

  @doc """
  The latest delivered replies (at most eight) the platform named `target`
  in their receipts, each with its episode and delivery reference.
  """
  def delivered_as(target) do
    from(t in all(),
      join: e in Episode,
      on: e.id == t.episode_id,
      where:
        t.status == :settled and not is_nil(t.delivered_at) and not is_nil(t.external_receipt) and
          fragment("(?::jsonb)->>'transport' = ?", t.external_receipt, ^target.transport) and
          fragment(
            "(?::jsonb)->>'conversation_ref' = ?",
            t.external_receipt,
            ^target.conversation_ref
          ) and
          fragment("(?::jsonb)->>'message_ref' = ?", t.external_receipt, ^target.message_ref),
      order_by: [desc: t.delivered_at, desc: t.id],
      limit: 8,
      select: {e, t.delivery_ref}
    )
  end

  @doc "An episode's latest settled turn that has a result."
  def latest_settled_with_result(episode_id) do
    from(t in all(),
      where: t.episode_id == ^episode_id and t.status == :settled and not is_nil(t.result_ref),
      order_by: [desc: t.accepted_at, desc: t.inserted_at, desc: t.id],
      limit: 1
    )
  end

  @doc "The message of an episode's latest accepted answer, delivered or being delivered."
  def latest_answer_message(episode_id) do
    from(t in all(),
      where:
        t.episode_id == ^episode_id and t.status in [:settled, :delivery_pending] and
          not is_nil(t.result_ref),
      order_by: [desc: t.accepted_at, desc: t.inserted_at],
      limit: 1,
      select: fragment("?::jsonb ->> 'message'", t.delivery_document)
    )
  end

  @doc "The repository of an episode's latest turn whose session had one."
  def latest_repository_ref(episode_id) do
    from(t in all(),
      join: s in assoc(t, :session),
      where: t.episode_id == ^episode_id and not is_nil(s.repository_ref),
      order_by: [desc: t.inserted_at],
      limit: 1,
      select: s.repository_ref
    )
  end

  @doc "The turn `owner_ref` that owns `episode_id` and stopped on a failure."
  def blocked_owner(episode_id, owner_ref) do
    from(t in all(),
      where: t.episode_id == ^episode_id and t.turn_ref == ^owner_ref and t.status == :blocked,
      limit: 1
    )
  end

  @doc """
  Each of `episode_ids`' latest accepted turn that keeps its bodies, with what
  it delivered and why, as candidate outcomes show it.
  """
  def latest_accepted_outcomes(episode_ids) do
    from(t in all(),
      where: t.episode_id in ^episode_ids,
      where: not is_nil(t.accepted_at) and is_nil(t.operational_pruned_at),
      distinct: t.episode_id,
      order_by: [asc: t.episode_id, desc: t.accepted_at, desc: t.id],
      select: {t.episode_id, t.delivery_document, t.delivered_at, t.validation_intent}
    )
  end

  def by_episode_ids(queryable \\ all(), episode_ids),
    do: where(queryable, [episode_work_turns: t], t.episode_id in ^episode_ids)

  def excluding_ids(queryable, ids),
    do: where(queryable, [episode_work_turns: t], t.id not in ^ids)

  @doc "Turns whose reply was delivered."
  def delivered(queryable \\ all()),
    do: where(queryable, [episode_work_turns: t], not is_nil(t.delivered_at))

  def delivered_after(queryable, at),
    do: where(queryable, [episode_work_turns: t], t.delivered_at > ^at)

  def delivered_since(queryable, at),
    do: where(queryable, [episode_work_turns: t], t.delivered_at >= ^at)

  def delivered_before(queryable, at),
    do: where(queryable, [episode_work_turns: t], t.delivered_at < ^at)

  def select_episode_deliveries(queryable),
    do: select(queryable, [episode_work_turns: t], {t.episode_id, t.delivered_at})

  def ordered_by_recent(queryable),
    do: order_by(queryable, [episode_work_turns: t], desc: t.inserted_at, desc: t.id)

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [episode_work_turns: t], asc: t.inserted_at, asc: t.id)

  @doc "Each delivered answer as `{delivered_at, delivery_document}`."
  def select_deliveries(queryable),
    do: select(queryable, [episode_work_turns: t], {t.delivered_at, t.delivery_document})

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc """
  The turn `episode` stands on: the one that owns it, the one delivering its
  answer, or else its latest.
  """
  def current(%Episode{owner_kind: :turn, owner_ref: turn_ref, id: id}),
    do: id |> by_episode_id() |> by_turn_ref(turn_ref)

  def current(%Episode{owner_kind: :delivery, owner_ref: delivery_ref, id: id}),
    do: id |> by_episode_id() |> by_delivery_ref(delivery_ref)

  def current(%Episode{id: id}), do: id |> by_episode_id() |> ordered_by_recent() |> limit_to(1)

  @doc """
  The title each of `episode_id`'s accepted answers gave, in the order they
  were accepted, `limit` at most, as `{turn_id, title}`; an answer that set
  none reads nil.
  """
  def accepted_titles(episode_id, limit) do
    from(turn in all(),
      where:
        turn.episode_id == ^episode_id and not is_nil(turn.accepted_at) and
          not is_nil(turn.candidate),
      order_by: [asc: turn.accepted_at, asc: turn.id],
      limit: ^limit,
      # An accepted answer is a JSON object (`Ryker.Work.Validator`), and JSON
      # may escape a NUL, which Postgres refuses to read in any JSON value: one
      # anywhere in an answer failed the page (2026-10-05). It is read as a
      # space instead, which keeps the JSON valid.
      select:
        {turn.id,
         fragment(~S"(replace(?, '\u0000', '\u0020')::jsonb) ->> 'title'", turn.candidate)}
    )
  end

  @doc """
  What the turns of `queryable` used, summed: their reported cost and how
  many reported one, how many reported usage, their repairs, tokens, count and
  Work claims.
  """
  def select_usage_totals(queryable) do
    select(queryable, [episode_work_turns: t], %{
      cost:
        type(
          fragment(
            "COALESCE(SUM(CASE WHEN ? THEN COALESCE(?, 0) ELSE 0 END), 0)",
            t.usage_cost_recorded,
            t.usage_cost_usd
          ),
          :decimal
        ),
      costed:
        type(fragment("COUNT(*) FILTER (WHERE ?)::bigint", t.usage_cost_recorded), :integer),
      measured: type(fragment("COUNT(*) FILTER (WHERE ?)::bigint", t.usage_recorded), :integer),
      repairs:
        type(
          fragment(
            "COALESCE(SUM(GREATEST(COALESCE(?, 1) - 1, 0)), 0)::bigint",
            t.candidate_attempt
          ),
          :integer
        ),
      tokens:
        type(
          fragment(
            "COALESCE(SUM(CASE WHEN ? THEN COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) ELSE 0 END), 0)::bigint",
            t.usage_recorded,
            t.usage_input_tokens,
            t.usage_cached_input_tokens,
            t.usage_output_tokens,
            t.usage_reasoning_tokens
          ),
          :integer
        ),
      turns: count(t.id),
      work_claims: type(fragment("COALESCE(SUM(?), 0)::bigint", t.work_attempt_count), :integer)
    })
  end

  @doc "Turns whose reply reached one of `conversations` on `transport`."
  def delivered_in_conversations(transport, conversations) do
    from(t in all(),
      join: e in Episode,
      on: e.id == t.episode_id,
      where:
        e.destination_transport == ^transport and e.destination_conversation_ref in ^conversations and
          not is_nil(t.external_receipt)
    )
  end

  def by_status(queryable \\ all(), status),
    do: where(queryable, [episode_work_turns: t], t.status == ^status)

  def select_statuses(queryable), do: select(queryable, [episode_work_turns: t], t.status)

  @doc "Each episode's latest Work turn, as an automation's runs show it."
  def latest_per_episode do
    from(t in all(),
      distinct: t.episode_id,
      order_by: [asc: t.episode_id, desc: t.inserted_at, desc: t.id],
      select: %{
        accepted_at: t.accepted_at,
        delivered_at: t.delivered_at,
        episode_id: t.episode_id,
        failure_code: t.last_error_code,
        failure_detail: t.last_error_detail,
        finished_at: t.remote_finished_at,
        started_at: t.remote_started_at,
        turn_status: t.status,
        work_attempt_count: t.work_attempt_count
      }
    )
  end

  @doc "Settled, with the briefing and the accepted result still kept."
  def settled_with_bodies(queryable) do
    where(
      queryable,
      [episode_work_turns: t],
      t.status == :settled and is_nil(t.operational_pruned_at) and not is_nil(t.submission) and
        not is_nil(t.candidate)
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  @doc "Each turn with whether its lease is still current by the database clock."
  def select_with_lease_current(queryable) do
    select(
      queryable,
      [episode_work_turns: t],
      {t, t.lease_expires_at > fragment("clock_timestamp()")}
    )
  end

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end

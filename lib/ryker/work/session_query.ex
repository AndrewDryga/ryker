defmodule Ryker.Work.SessionQuery do
  @moduledoc "Work sessions, for every read of `episode_work_sessions`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Command, Placement}
  alias Ryker.Episodes.Episode
  alias Ryker.Work.{Session, Turn}

  def all, do: from(sessions in Session, as: :episode_work_sessions)

  @doc "The session of repository-knowledge run `run_id`."
  def for_knowledge_run(queryable \\ all(), run_id) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.execution_kind == :knowledge and s.knowledge_run_id == ^run_id
    )
  end

  @doc "Sessions not discarded that use Emisar connection `ref`."
  def using_emisar_connection(queryable \\ all(), ref) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.emisar_connection_ref == ^ref and s.cleanup_status != :discarded
    )
  end

  @doc "The session of improvement analysis run `run_id`."
  def for_improvement_run(queryable \\ all(), run_id) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.execution_kind == :improvement and s.improvement_run_id == ^run_id
    )
  end

  @doc "The session of learning pass `run_id`."
  def for_learning_run(queryable \\ all(), run_id) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.execution_kind == :learning and s.learning_run_id == ^run_id
    )
  end

  @doc "The routing session of generation `generation` of inbox entry `input_id`."
  def for_admission(input_id, generation) do
    where(
      all(),
      [episode_work_sessions: s],
      s.execution_kind == :admission and s.admission_input_id == ^input_id and
        s.generation == ^generation
    )
  end

  def by_external_ref(queryable \\ all(), external_ref),
    do: where(queryable, [episode_work_sessions: s], s.external_ref == ^external_ref)

  @doc """
  The oldest open routing session kept ready for `policy` and inserted after
  `cutoff`, locked and skipped while another claim holds it. Prepared ones
  come first: those whose agent will still be running at `running_past`.
  """
  def next_ready(policy, digest, cutoff, running_past) do
    from(s in all(),
      where: s.execution_kind == :admission and s.ready_state == :ready,
      where: is_nil(s.admission_input_id) and s.cleanup_status == :active,
      where: s.policy == ^policy and s.policy_digest == ^digest,
      where: s.inserted_at > ^cutoff,
      order_by: [
        desc: fragment("coalesce(? > ?, false)", s.warm_until, ^running_past),
        asc: s.inserted_at,
        asc: s.id
      ],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc "Sessions of the ready routing pool, whatever their state."
  def in_ready_pool(queryable \\ all()),
    do: where(queryable, [episode_work_sessions: s], not is_nil(s.ready_state))

  def with_ready_state(queryable \\ all(), states)

  def with_ready_state(queryable, states) when is_list(states),
    do: where(queryable, [episode_work_sessions: s], s.ready_state in ^states)

  def with_ready_state(queryable, state),
    do: where(queryable, [episode_work_sessions: s], s.ready_state == ^state)

  @doc "Ready sessions Coop has not been asked to prepare yet."
  def unprepared(queryable),
    do: where(queryable, [episode_work_sessions: s], is_nil(s.warm_until))

  def with_policy(queryable, policy, digest) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.policy == ^policy and s.policy_digest == ^digest
    )
  end

  def inserted_after(queryable, at),
    do: where(queryable, [episode_work_sessions: s], s.inserted_at > ^at)

  def inserted_by(queryable, at),
    do: where(queryable, [episode_work_sessions: s], s.inserted_at <= ^at)

  def oldest_first(queryable),
    do: order_by(queryable, [episode_work_sessions: s], asc: s.inserted_at, asc: s.id)

  def newest_first(queryable),
    do: order_by(queryable, [episode_work_sessions: s], desc: s.inserted_at, desc: s.id)

  @doc """
  The repository each of `episode_ids`' Work sessions was pinned to, as
  `{episode_id, repository_ref}`, oldest session first.
  """
  def pinned_repositories(episode_ids) do
    from(s in all(),
      where:
        s.episode_id in ^episode_ids and s.execution_kind == :work and
          not is_nil(s.repository_ref),
      order_by: [asc: s.inserted_at],
      select: {s.episode_id, s.repository_ref}
    )
  end

  def by_coop_session_id(queryable, coop_session_id),
    do: where(queryable, [episode_work_sessions: s], s.coop_session_id == ^coop_session_id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [episode_work_sessions: s], s.id in ^ids)

  @doc "Work session `session_id` of episode `episode_id`."
  def of_episode(episode_id, session_id) do
    where(
      all(),
      [episode_work_sessions: s],
      s.episode_id == ^episode_id and s.id == ^session_id
    )
  end

  @doc "Sessions whose Coop activity still has to be fetched."
  def awaiting_activity_sync(queryable \\ all()) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.activity_sync_pending == true and not is_nil(s.coop_session_id)
    )
  end

  def least_recently_updated_first(queryable),
    do: order_by(queryable, [episode_work_sessions: s], asc: s.updated_at, asc: s.id)

  @doc "The Work sessions of `session`'s episode of a later generation: what replaced it."
  def newer_work_sessions(session) do
    where(
      all(),
      [episode_work_sessions: s],
      s.episode_id == ^session.episode_id and s.execution_kind == :work and
        s.generation > ^session.generation
    )
  end

  def with_cleanup_status(queryable \\ all(), status),
    do: where(queryable, [episode_work_sessions: s], s.cleanup_status == ^status)

  @doc "Sessions whose cleanup failed and waits to retry after `now`."
  def cleanup_retrying_after(now) do
    where(
      all(),
      [episode_work_sessions: s],
      s.cleanup_status in [:close_pending, :plan_pending, :discard_pending] and
        not is_nil(s.cleanup_next_attempt_at) and s.cleanup_next_attempt_at > ^now
    )
  end

  @doc "Retained sessions counted by why each is kept, as `{retained_reason, count}`."
  def retained_by_reason do
    all()
    |> with_cleanup_status(:retained)
    |> group_by([episode_work_sessions: s], s.retained_reason)
    |> select([episode_work_sessions: s], {s.retained_reason, count(s.id)})
  end

  def select_last_discarded(queryable \\ all()),
    do: select(queryable, [episode_work_sessions: s], max(s.discarded_at))

  @doc "Sessions that task `task_ref` names: by external ref or by the offer it set up; at most two."
  def by_task_ref(task_ref) do
    from(s in all(),
      where:
        s.external_ref == ^task_ref or
          fragment("(?::jsonb ->> 'offer_ref') = ?", s.workspace_task, ^task_ref),
      limit: 2
    )
  end

  @doc "The latest earlier generation of `session`'s episode."
  def previous_generation(session) do
    from(s in all(),
      where: s.episode_id == ^session.episode_id and s.generation < ^session.generation,
      order_by: [desc: s.generation],
      limit: 1
    )
  end

  @doc """
  Unbound sessions whose create command a succeeded reconciliation proved
  became Coop session `coop_session_id`; at most two, so a caller can tell
  one from several.
  """
  def reconciled_into(coop_session_id) do
    from(s in all(),
      join: create in Command,
      on: create.session_id == s.id and create.kind == "create_session",
      join: reconciliation in Command,
      on:
        reconciliation.session_id == s.id and reconciliation.kind == "reconcile_operation" and
          fragment(
            "(?::jsonb ->> 'operation_key') = ?",
            reconciliation.payload,
            create.idempotency_key
          ),
      where: is_nil(s.coop_session_id) and reconciliation.status == :succeeded,
      where:
        fragment(
          "(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb",
          reconciliation.result
        ),
      where:
        fragment(
          "(?::jsonb -> 'body' ->> 'resource_id') = ?",
          reconciliation.result,
          ^coop_session_id
        ),
      where:
        fragment("(?::jsonb -> 'body' ->> 'resource_type') = 'session'", reconciliation.result),
      where:
        fragment(
          "(?::jsonb -> 'body' ->> 'method') = 'CreateRemoteSession'",
          reconciliation.result
        ),
      where: fragment("(?::jsonb -> 'body' ->> 'state') = 'succeeded'", reconciliation.result),
      distinct: true,
      select: s,
      limit: 2
    )
  end

  @doc """
  The sessions of job `job_ref` placed on worker `worker_id`, active and leased
  at `now`; at most two, so a caller can tell one from several.
  """
  def placed_job(job_ref, worker_id, now) do
    from(s in all(),
      join: p in Placement,
      on: p.session_id == s.id,
      where:
        s.external_ref == ^job_ref and p.worker_id == ^worker_id and p.state == :active and
          p.lease_expires_at > ^now,
      limit: 2,
      select: s
    )
  end

  def select_episode_ids(queryable),
    do: select(queryable, [episode_work_sessions: s], s.episode_id)

  def latest_generation_first(queryable),
    do: order_by(queryable, [episode_work_sessions: s], desc: s.generation)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_work_sessions: s], s.episode_id == ^episode_id)

  @doc """
  The session, episode and turn the state-tools token `token_sha256` names,
  while all three may still use it: the session is active and its placement,
  if it has one, holds its lease; the episode is working on that turn; and
  the turn is pending under an unexpired lease.
  """
  def state_tools_binding(token_sha256) do
    all()
    |> join(:inner, [episode_work_sessions: s], e in Episode,
      on: e.id == s.episode_id,
      as: :episode_kernel_episodes
    )
    |> join(:inner, [episode_work_sessions: s, episode_kernel_episodes: e], t in Turn,
      on: t.session_id == s.id and t.episode_id == e.id,
      as: :episode_work_turns
    )
    |> join(:left, [episode_work_sessions: s], p in Placement,
      on: p.session_id == s.id,
      as: :coop_session_placements
    )
    |> where([episode_work_turns: t], t.state_tools_token_sha256 == ^token_sha256)
    |> where(
      [episode_work_sessions: s, coop_session_placements: p],
      s.cleanup_status == :active and
        (is_nil(p.id) or
           (p.state == :active and p.lease_expires_at > fragment("clock_timestamp()")))
    )
    |> where(
      [episode_kernel_episodes: e, episode_work_turns: t],
      e.state == :working and e.owner_kind == :turn and t.turn_ref == e.owner_ref
    )
    |> where(
      [episode_work_turns: t],
      t.status == :pending and not is_nil(t.lease_ref) and
        t.lease_expires_at > fragment("clock_timestamp()")
    )
    |> select(
      [episode_work_sessions: s, episode_kernel_episodes: e, episode_work_turns: t],
      {s, e, t}
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_for_no_key_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")
  def lock_for_share_skip_locked(queryable), do: lock(queryable, "FOR SHARE SKIP LOCKED")

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_work_sessions: s], s.id == ^id)

  def select_placement(queryable) do
    select(queryable, [episode_work_sessions: s], %{
      environment_ref: s.environment_ref,
      repository_ref: s.repository_ref
    })
  end

  def select_generation(queryable),
    do: select(queryable, [episode_work_sessions: s], s.generation)
end

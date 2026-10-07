defmodule Ryker.Retention.Cleanup.Query do
  @moduledoc """
  Which Work sessions cleanup may claim, and when each became claimable
  (`Ryker.Retention.Custody`). Each query starts from
  `Ryker.Work.Session.Query.all/0` with the session's owner joined as
  `:episode_kernel_episodes`, `:conversation_learning_runs`,
  `:improvement_analysis_runs`, `:repository_knowledge_runs` or
  `:ingress_inbox_entries`.

  Operator and readiness projections share these, so a Work, learning or
  admission backlog can never be invisible to the surface that reports it.
  """
  use Ryker, :query
  alias Ryker.CoopFleet.{Placement, Worker}
  alias Ryker.Episodes.Episode
  alias Ryker.Improvement.AnalysisRun
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.LearningRun
  alias Ryker.Publication.Publication
  alias Ryker.RepositoryKnowledge.Run, as: KnowledgeRun
  alias Ryker.Work.{Session, Turn}

  @pending_statuses [:close_pending, :plan_pending, :discard_pending]
  @terminal_episode_states [:complete, :cancelled]
  @unfinished_turn_statuses [:pending, :cancel_pending, :delivery_pending]

  # The durable moment a session became claimable for cleanup, by phase. Ageing
  # from insertion counted conversation time and the intentional grace period as
  # stall; ageing from the last claim would hide a real backlog instead. A
  # pending phase is claimable no earlier than its retry time: a failed step
  # that came due, or one an operator resumed, aged from the phase's first
  # eligibility and read as a stall the moment it could run again. A retained
  # workspace is eligible again at its scheduled recheck, or when its
  # publication became durable.
  defmacrop eligible_at(session, episode, learning, improvement, knowledge, admission) do
    quote do
      fragment(
        """
        CASE
          WHEN ? IN ('active', 'close_pending') THEN GREATEST(COALESCE(?, ?, ?, ?, ?, ?), ?)
          WHEN ? = 'grace' THEN COALESCE(?, ?)
          WHEN ? IN ('plan_pending', 'discard_pending') THEN GREATEST(COALESCE(?, ?), ?)
          WHEN ? = 'retained' THEN COALESCE(
            ?,
            (SELECT max(published.published_at) FROM episode_publications AS published
              WHERE published.session_id = ? AND published.status = 'published'),
            ?
          )
          ELSE ?
        END
        """,
        unquote(session).cleanup_status,
        unquote(learning).remote_stopped_at,
        unquote(improvement).remote_stopped_at,
        unquote(knowledge).remote_stopped_at,
        unquote(admission).updated_at,
        unquote(episode).updated_at,
        unquote(session).updated_at,
        unquote(session).cleanup_next_attempt_at,
        unquote(session).cleanup_status,
        unquote(session).discard_after,
        unquote(session).updated_at,
        unquote(session).cleanup_status,
        unquote(session).discard_after,
        unquote(session).updated_at,
        unquote(session).cleanup_next_attempt_at,
        unquote(session).cleanup_status,
        unquote(session).cleanup_next_attempt_at,
        unquote(session).id,
        unquote(session).updated_at,
        unquote(session).updated_at
      )
    end
  end

  # The id of whatever owns a session: its episode, run or routed message.
  defmacrop owner_id(session) do
    quote do
      type(
        fragment(
          "COALESCE(?, ?, ?, ?, ?)",
          unquote(session).episode_id,
          unquote(session).learning_run_id,
          unquote(session).improvement_run_id,
          unquote(session).knowledge_run_id,
          unquote(session).admission_input_id
        ),
        :binary_id
      )
    end
  end

  @doc """
  Every session cleanup may claim at `now`, before the lease split: its owner
  is finished, no Work turn of it is unfinished, no publication still depends
  on it, and its cleanup phase is due.
  """
  def eligible(now) do
    from(session in Session.Query.all(),
      left_join: episode in Episode,
      as: :episode_kernel_episodes,
      on: episode.id == session.episode_id,
      left_join: learning in LearningRun,
      as: :conversation_learning_runs,
      on: learning.id == session.learning_run_id,
      left_join: improvement in AnalysisRun,
      as: :improvement_analysis_runs,
      on: improvement.id == session.improvement_run_id,
      left_join: knowledge in KnowledgeRun,
      as: :repository_knowledge_runs,
      on: knowledge.id == session.knowledge_run_id,
      left_join: admission in Entry,
      as: :ingress_inbox_entries,
      on: admission.id == session.admission_input_id,
      where: ^owner_finished(),
      where: session.id not in subquery(unfinished_session_ids()),
      where: session.id not in subquery(unpublished_session_ids()),
      where: ^cleanup_status_filter(now)
    )
  end

  @doc "Eligible sessions no other worker holds a live cleanup lease on."
  def claimable(now), do: now |> eligible() |> unleased_at(now)

  @doc "Sessions with no cleanup lease, or one that ran out by `now`."
  def unleased_at(queryable, now) do
    where(
      queryable,
      [episode_work_sessions: s],
      is_nil(s.cleanup_lease_ref) or s.cleanup_lease_expires_at <= ^now
    )
  end

  @doc "Sessions with a cleanup lease still held at `now`."
  def leased_at(queryable, now) do
    where(
      queryable,
      [episode_work_sessions: s],
      not is_nil(s.cleanup_lease_ref) and s.cleanup_lease_expires_at > ^now
    )
  end

  @doc "Claimable working copies: Work sessions with a repository."
  def working_copies(now) do
    now
    |> claimable()
    |> where(
      [episode_work_sessions: s],
      s.execution_kind == :work and not is_nil(s.repository_ref)
    )
  end

  @doc "The earliest moment one of `queryable`'s sessions, an `eligible/1` query, became claimable."
  def select_oldest_eligible_at(queryable) do
    from(
      [
        episode_work_sessions: session,
        episode_kernel_episodes: episode,
        conversation_learning_runs: learning,
        improvement_analysis_runs: improvement,
        repository_knowledge_runs: knowledge,
        ingress_inbox_entries: admission
      ] in queryable,
      select: min(eligible_at(session, episode, learning, improvement, knowledge, admission))
    )
  end

  @doc """
  Up to `limit` of `queryable`'s sessions, an `eligible/1` query, oldest due
  first, each as `{session, eligible_at}`.
  """
  def oldest_due_first(queryable, limit) do
    from(
      [
        episode_work_sessions: session,
        episode_kernel_episodes: episode,
        conversation_learning_runs: learning,
        improvement_analysis_runs: improvement,
        repository_knowledge_runs: knowledge,
        ingress_inbox_entries: admission
      ] in queryable,
      select:
        {session, eligible_at(session, episode, learning, improvement, knowledge, admission)},
      order_by: [
        asc: eligible_at(session, episode, learning, improvement, knowledge, admission),
        asc: session.id
      ],
      limit: ^limit
    )
  end

  @doc """
  The session cleanup claims next at `now`, leaving out `exclude`'s sessions
  and its workers' placements, oldest due first, as `{execution_kind,
  owner_id, session_id, placed_worker_id}`.
  """
  def next_candidate(now, exclude) do
    from(
      [
        episode_work_sessions: session,
        episode_kernel_episodes: episode,
        conversation_learning_runs: learning,
        improvement_analysis_runs: improvement,
        repository_knowledge_runs: knowledge,
        ingress_inbox_entries: admission,
        coop_session_placements: placement
      ] in placed(now),
      where: session.id not in ^exclude.session_ids,
      where: is_nil(placement.worker_id) or placement.worker_id not in ^exclude.worker_ids,
      order_by: [
        asc: eligible_at(session, episode, learning, improvement, knowledge, admission),
        asc: session.id
      ],
      select: {session.execution_kind, owner_id(session), session.id, placement.worker_id},
      limit: 1
    )
  end

  # Cleanup runs on the worker that still owns the fork, so fair draining needs
  # that identity before the claim, not after the call has already failed. The
  # lookup is lateral and indexed: a fleet-wide placement scan on every claim
  # would make the hot path grow with fleet history.
  defp placed(now) do
    current =
      from(placement in Placement,
        where: placement.session_id == parent_as(:episode_work_sessions).id,
        order_by: [desc: placement.generation],
        limit: 1,
        select: %{worker_id: placement.worker_id}
      )

    from([episode_work_sessions: session] in claimable(now),
      left_lateral_join: placement in subquery(current),
      as: :coop_session_placements,
      on: true
    )
  end

  @doc "Session `session_id`'s owner, as `{execution_kind, owner_id}`."
  def owner_identity(session_id) do
    from(session in Session.Query.by_id(session_id),
      select: {session.execution_kind, owner_id(session)}
    )
  end

  @doc "The row that owns a session of `kind`: its episode, run or routed message."
  def owner(:work, episode_id), do: Episode.Query.by_id(episode_id)
  def owner(:learning, run_id), do: LearningRun.Query.by_id(run_id)
  def owner(:improvement, run_id), do: AnalysisRun.Query.by_id(run_id)
  def owner(:knowledge, run_id), do: KnowledgeRun.Query.by_id(run_id)
  def owner(:admission, input_id), do: Entry.Query.by_id(input_id)

  @doc "Locks an owner row, waiting for it or, with `:skip_locked`, passing it over when held."
  def lock_owner(queryable, :skip_locked), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
  def lock_owner(queryable, :wait), do: lock(queryable, "FOR UPDATE")

  @doc "The cleanup leases worker `worker_ref` holds on sessions in a pending phase."
  def leases_of(worker_ref) do
    where(
      Session.Query.all(),
      [episode_work_sessions: s],
      s.cleanup_lease_owner == ^worker_ref and not is_nil(s.cleanup_lease_ref) and
        s.cleanup_status in ^@pending_statuses
    )
  end

  @doc """
  Pending cleanup deferred with one of `error_codes` whose worker reported in
  after the failure and since `cutoff`.
  """
  def deferred_for_reconnected_workers(error_codes, cutoff) do
    reconnected =
      from(placement in Placement,
        join: worker in Worker,
        on: worker.id == placement.worker_id,
        where: placement.session_id == parent_as(:episode_work_sessions).id,
        where: worker.last_seen_at > parent_as(:episode_work_sessions).updated_at,
        where: worker.last_seen_at >= ^cutoff,
        select: 1
      )

    from(session in Session.Query.all(),
      where: session.cleanup_status in ^@pending_statuses,
      where: not is_nil(session.cleanup_next_attempt_at),
      where: session.cleanup_last_error_code in ^error_codes,
      where: exists(subquery(reconnected))
    )
  end

  defp unfinished_session_ids do
    from(turn in Turn,
      where: turn.status in ^@unfinished_turn_statuses,
      select: turn.session_id
    )
  end

  defp unpublished_session_ids do
    from(publication in Publication,
      where: publication.status != :published,
      select: publication.session_id
    )
  end

  defp owner_finished do
    dynamic(
      ^work_finished() or ^learning_finished() or ^improvement_finished() or
        ^knowledge_finished() or ^admission_finished() or ^ready_retired()
    )
  end

  # A Work session is finished when its episode is, or once a newer generation
  # replaced it. A replaced session stayed open on its worker, holding its
  # workspace, until the episode ended, however long the episode then waited
  # (2026-10-04 review).
  defp work_finished do
    dynamic(
      [episode_work_sessions: session, episode_kernel_episodes: episode],
      session.execution_kind == :work and
        (episode.state in ^@terminal_episode_states or
           exists(
             from(newer in Session,
               where:
                 newer.episode_id == parent_as(:episode_work_sessions).episode_id and
                   newer.execution_kind == :work and
                   newer.generation > parent_as(:episode_work_sessions).generation,
               select: 1
             )
           ))
    )
  end

  defp learning_finished do
    dynamic(
      [episode_work_sessions: session, conversation_learning_runs: learning],
      session.execution_kind == :learning and not is_nil(learning.remote_stopped_at)
    )
  end

  defp improvement_finished do
    dynamic(
      [episode_work_sessions: session, improvement_analysis_runs: improvement],
      session.execution_kind == :improvement and not is_nil(improvement.remote_stopped_at)
    )
  end

  defp knowledge_finished do
    dynamic(
      [episode_work_sessions: session, repository_knowledge_runs: knowledge],
      session.execution_kind == :knowledge and not is_nil(knowledge.remote_stopped_at)
    )
  end

  defp admission_finished do
    dynamic(
      [episode_work_sessions: session, ingress_inbox_entries: admission],
      session.execution_kind == :admission and
        (admission.status in [:decided, :superseded] or
           admission.execution_generation > session.generation)
    )
  end

  # A routing session started ahead of time that no message claimed is
  # finished once the pool retires it (`Ryker.Admission.ReadySessions`).
  defp ready_retired do
    dynamic(
      [episode_work_sessions: session],
      session.execution_kind == :admission and is_nil(session.admission_input_id) and
        session.ready_state == :retired
    )
  end

  defp cleanup_status_filter(now) do
    pending = pending_status_filter(now)
    retained = retained_status_filter(now)

    dynamic(
      [episode_work_sessions: session],
      session.cleanup_status == :active or ^pending or
        (session.cleanup_status == :grace and session.discard_after <= ^now) or ^retained
    )
  end

  defp pending_status_filter(now) do
    dynamic(
      [episode_work_sessions: session],
      session.cleanup_status in ^@pending_statuses and
        (is_nil(session.cleanup_next_attempt_at) or session.cleanup_next_attempt_at <= ^now)
    )
  end

  # Retained work is reconsidered from fresh evidence, never from a manual edit:
  # an unmerged workspace once its publication is durable, and a dirty workspace
  # when its scheduled recheck falls due.
  defp retained_status_filter(now) do
    published_session_ids =
      from(publication in Publication,
        where: publication.status == :published,
        select: publication.session_id
      )

    dynamic(
      [episode_work_sessions: session],
      session.cleanup_status == :retained and
        ((session.retained_reason == "unpublished_unmerged" and
            session.id in subquery(published_session_ids)) or
           (session.retained_reason == "dirty" and
              not is_nil(session.cleanup_next_attempt_at) and
              session.cleanup_next_attempt_at <= ^now))
    )
  end
end

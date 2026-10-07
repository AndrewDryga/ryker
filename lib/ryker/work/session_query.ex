defmodule Ryker.Work.SessionQuery do
  @moduledoc "Work sessions, for every read of `episode_work_sessions`."
  import Ecto.Query
  alias Ryker.CoopFleet.Placement
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

  @doc "The session of learning pass `run_id`."
  def for_learning_run(queryable \\ all(), run_id) do
    where(
      queryable,
      [episode_work_sessions: s],
      s.execution_kind == :learning and s.learning_run_id == ^run_id
    )
  end

  def by_coop_session_id(queryable, coop_session_id),
    do: where(queryable, [episode_work_sessions: s], s.coop_session_id == ^coop_session_id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [episode_work_sessions: s], s.id in ^ids)

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

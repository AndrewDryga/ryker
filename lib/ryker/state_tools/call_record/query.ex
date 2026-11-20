defmodule Ryker.StateTools.CallRecord.Query do
  @moduledoc "Each state-tool call a Work turn made, for every read of `episode_work_state_tool_calls`."
  use Ryker, :query
  alias Ryker.StateTools.CallRecord
  alias Ryker.Work

  def all, do: from(calls in CallRecord, as: :episode_work_state_tool_calls)

  @doc "The latest `limit` calls an episode's turns made while the turns keep their bodies, newest first."
  def latest_by_episode_id(episode_id, limit) do
    all()
    |> join(:inner, [episode_work_state_tool_calls: c], t in Work.Turn,
      on: t.id == c.turn_id,
      as: :episode_work_turns
    )
    |> where(
      [episode_work_turns: t],
      t.episode_id == ^episode_id and is_nil(t.operational_pruned_at)
    )
    |> order_by([episode_work_state_tool_calls: c], desc: c.called_at, desc: c.id)
    |> limit(^limit)
  end

  def called_since(queryable, since),
    do: where(queryable, [episode_work_state_tool_calls: c], c.called_at >= ^since)

  def submitted_github_review(queryable \\ all(), turn_id, accepted_at, target) do
    from([episode_work_state_tool_calls: c] in queryable,
      where:
        c.turn_id == ^turn_id and c.tool == "submit_github_review" and c.status == "completed" and
          c.answered_at <= ^accepted_at and
          fragment("? @> ?", c.github_review, type(^target, :map)),
      order_by: [desc: c.answered_at, desc: c.id],
      limit: 1,
      select: c.github_review
    )
  end

  def observed_emisar_runs(queryable \\ all(), turn_id, attempt, connection_ref) do
    from([episode_work_state_tool_calls: c] in queryable,
      join: t in Work.Turn,
      on: t.id == c.turn_id,
      as: :episode_work_turns,
      join: s in Work.Session,
      on: s.id == t.session_id,
      as: :episode_work_sessions,
      join: candidate in Work.CandidateResponse,
      on: candidate.turn_id == t.id and candidate.candidate_attempt == ^attempt,
      as: :work_candidate_responses,
      where: c.turn_id == ^turn_id and s.emisar_connection_ref == ^connection_ref,
      where: c.status == "completed" and not is_nil(c.emisar_run),
      where:
        c.answered_at <= candidate.recorded_at and is_nil(t.operational_pruned_at) and
          is_nil(candidate.operational_pruned_at),
      select: c.emisar_run,
      distinct: true
    )
  end
end

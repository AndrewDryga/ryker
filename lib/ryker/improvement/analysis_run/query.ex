defmodule Ryker.Improvement.AnalysisRun.Query do
  @moduledoc "Each analysis of a flagged request, for every read of `improvement_analysis_runs`."
  use Ryker, :query
  alias Ryker.Improvement.{AnalysisRun, Candidate}

  def all, do: from(runs in AnalysisRun, as: :improvement_analysis_runs)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [improvement_analysis_runs: r], r.id == ^id)

  def by_candidate_id(queryable \\ all(), candidate_id),
    do: where(queryable, [improvement_analysis_runs: r], r.candidate_id == ^candidate_id)

  def by_policy(queryable \\ all(), policy, policy_digest) do
    where(
      queryable,
      [improvement_analysis_runs: r],
      r.policy == ^policy and r.policy_digest == ^policy_digest
    )
  end

  def by_error_code(queryable, error_code),
    do: where(queryable, [improvement_analysis_runs: r], r.error_code == ^error_code)

  def by_error_codes(queryable, error_codes),
    do: where(queryable, [improvement_analysis_runs: r], r.error_code in ^error_codes)

  @doc "Runs started on a worker that has not confirmed their remote execution stopped."
  def unstopped(queryable) do
    where(
      queryable,
      [improvement_analysis_runs: r],
      not is_nil(r.started_at) and is_nil(r.remote_stopped_at)
    )
  end

  @doc "Prepared runs that never started."
  def unstarted(queryable) do
    where(
      queryable,
      [improvement_analysis_runs: r],
      r.status == :prepared and is_nil(r.started_at)
    )
  end

  @doc "The runs of `candidate_ids` that still keep their bodies."
  def kept_for_candidates(candidate_ids) do
    where(
      all(),
      [improvement_analysis_runs: r],
      r.candidate_id in ^candidate_ids and is_nil(r.pruned_at)
    )
  end

  def ordered_by_generation(queryable),
    do: order_by(queryable, [improvement_analysis_runs: r], asc: r.generation)

  def select_max_generation(queryable),
    do: select(queryable, [improvement_analysis_runs: r], max(r.generation))

  @doc "The analyses of request `episode_id`'s candidates."
  def by_episode_id(episode_id) do
    from(r in all(),
      join: c in Candidate,
      on: c.id == r.candidate_id,
      where: c.episode_id == ^episode_id
    )
  end

  @doc "The analyses of message `input_id`'s candidates, while no request took it."
  def by_input_id(input_id) do
    from(r in all(),
      join: c in Candidate,
      on: c.id == r.candidate_id,
      where: c.input_id == ^input_id and is_nil(c.episode_id)
    )
  end

  def ordered_by_recent(queryable),
    do: order_by(queryable, [improvement_analysis_runs: r], desc: r.inserted_at, desc: r.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end

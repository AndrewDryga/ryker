defmodule Ryker.Behaviors.StandingAssignmentRun.Query do
  @moduledoc "Each input a standing assignment ran for, for every read of `standing_assignment_runs`."
  import Ecto.Query
  alias Ryker.Behaviors.{Behavior, StandingAssignmentRun}
  alias Ryker.Episodes.Episode

  def all, do: from(runs in StandingAssignmentRun, as: :standing_assignment_runs)

  def by_assignment_id(queryable \\ all(), assignment_id),
    do: where(queryable, [standing_assignment_runs: r], r.assignment_id == ^assignment_id)

  def by_source_input_ref(queryable \\ all(), input_ref),
    do: where(queryable, [standing_assignment_runs: r], r.source_input_ref == ^input_ref)

  @doc "The latest five assignments that decided `episode_id`'s start, each with its run."
  def decided_for_episode(episode_id) do
    all()
    |> join(:inner, [standing_assignment_runs: r], b in Behavior,
      on: b.id == r.assignment_id,
      as: :operator_behaviors
    )
    |> where(
      [standing_assignment_runs: r, operator_behaviors: b],
      r.episode_id == ^episode_id and r.outcome == :decided and b.kind == :standing_assignment
    )
    |> order_by([standing_assignment_runs: r], desc: r.inserted_at)
    |> limit(5)
    |> select([standing_assignment_runs: r, operator_behaviors: b], {r, b})
  end

  @doc "An assignment's latest `limit` runs, each with its episode's state, as an automation's page shows them."
  def recent_for_assignment(assignment_id, limit) do
    assignment_id
    |> by_assignment_id()
    |> join(:left, [standing_assignment_runs: r], e in Episode,
      on: e.id == r.episode_id,
      as: :episode_kernel_episodes
    )
    |> order_by([standing_assignment_runs: r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> select([standing_assignment_runs: r, episode_kernel_episodes: e], %{
      "decision_action" => r.decision_action,
      "decision_ref" => r.decision_ref,
      "episode_id" => r.episode_id,
      "episode_state" => e.state,
      "outcome" => r.outcome,
      "run_ref" => r.ref,
      "source_event_ref" => r.source_event_ref,
      "source_input_ref" => r.source_input_ref
    })
  end

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [standing_assignment_runs: r], asc: r.inserted_at)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end

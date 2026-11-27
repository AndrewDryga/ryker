defmodule Ryker.Operator.FleetJob.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.Operator.FleetJob

  def all, do: from(j in FleetJob, as: :fleet_jobs)
  def by_id(id), do: where(all(), [fleet_jobs: j], j.id == ^id)

  def by_episode(episode_id), do: where(all(), [fleet_jobs: j], j.episode_id == ^episode_id)

  def by_input(id), do: where(all(), [fleet_jobs: j], j.workspace_input_id == ^id)
  def retained_input(id), do: where(by_input(id), [fleet_jobs: j], not is_nil(j.episode_id))

  def active_input(episode) do
    from(j in by_episode(episode),
      join: e in assoc(j, :episode),
      where: e.state not in [:complete, :cancelled] and is_nil(e.history_pruned_at)
    )
  end

  @doc "The latest Work holder from one database snapshot, while the operator job can run services."
  def service_holder(job_id) do
    latest =
      from(s in Ryker.Work.Session,
        where: s.episode_id == parent_as(:fleet_jobs).episode_id and s.execution_kind == :work,
        order_by: [desc: s.generation],
        limit: 1
      )

    from(j in by_id(job_id),
      join: e in assoc(j, :episode),
      left_join: turn in Ryker.Work.Turn,
      on:
        turn.episode_id == j.episode_id and e.owner_kind == :turn and turn.turn_ref == e.owner_ref,
      where: is_nil(turn.cancellation_intent),
      inner_lateral_join: s in subquery(latest),
      on: true,
      join: p in Ryker.CoopFleet.Placement,
      on: p.session_id == s.id,
      join: w in subquery(Ryker.CoopFleet.Worker.Query.enrolled()),
      on: w.id == p.worker_id,
      where: e.state not in [:complete, :cancelled],
      where:
        s.cleanup_status == :active and not is_nil(s.coop_session_id) and
          not is_nil(s.worker_job_digest),
      where: p.state == :active and p.lease_expires_at > fragment("clock_timestamp()"),
      where: not is_nil(w.machine_daemon),
      select: %{
        job: j.id,
        owner: e.owner_ref,
        remote: s.coop_session_id,
        digest: s.worker_job_digest,
        placement: p.id,
        generation: p.generation,
        worker: w.id,
        epoch: w.enrollment_epoch,
        daemon: w.machine_daemon
      }
    )
  end
end

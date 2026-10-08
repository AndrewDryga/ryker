defmodule Ryker.CoopFleet.ControlPlane.Placements do
  @moduledoc """
  Session placement and worker choice.

  Places a frozen controller job on a worker with the capabilities,
  freshness and capacity it needs; recovers or
  replaces a placement whose lease or authority ended; renews a worker's
  placement leases on each poll; and answers whether the fleet could take a
  session at all without taking a slot to find out.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Bodies, JobAuthority, Placement}
  alias Ryker.CoopFleet.ControlPlane.{Commands, Shared}
  alias Ryker.CoopFleet.{Worker, WorkspaceCheckpointTransfer}
  alias Ryker.Repo
  alias Ryker.Work

  @creating_seconds 300
  @cleanup_phases [:close_pending, :plan_pending, :discard_pending]
  @holder_purpose "stop_or_cleanup"

  @spec place_session(Ecto.UUID.t(), map(), pos_integer()) ::
          {:ok, Placement.t()} | {:error, term()}
  def place_session(session_id, requirements, lease_seconds) do
    with :ok <- Shared.uuid(session_id, :session_id),
         {:ok, prepared} <- requirements(requirements),
         :ok <- Shared.lease_seconds(lease_seconds) do
      result =
        Repo.transaction(fn -> place_session_locked(session_id, prepared, lease_seconds) end)

      placement_result(result, session_id)
    end
  end

  defp placement_result({:ok, {:replacement_required, generation}}, session_id),
    do: {:error, {:coop_session_replacement_required, session_id, generation}}

  defp placement_result(
         {:ok, {:replacement_pending, generation, lease_expires_at}},
         session_id
       ),
       do: {:error, {:coop_session_replacement_pending, session_id, generation, lease_expires_at}}

  defp placement_result(result, _session_id), do: result

  @doc """
  Whether any current worker could take this session's next placement.

  Recovery is offered only when a worker has the required capabilities and
  capacity. This is a preflight check; actual placement also validates the
  session's frozen job without consulting current settings.
  """
  @spec worker_available?(Work.Session.t(), map()) :: boolean()
  def worker_available?(%Work.Session{}, requirements) do
    case requirements(requirements) do
      {:ok, prepared} ->
        now = Repo.now!()

        Worker.Query.all()
        |> Repo.all()
        |> Enum.any?(fn worker ->
          worker_current?(worker, prepared.workspace_ref, now) and
            worker_eligible?(worker, prepared, now) and
            worker.capacity["state"] == "eligible" and worker_has_capacity?(worker, now)
        end)

      {:error, _reason} ->
        false
    end
  end

  def worker_available?(_session, _requirements), do: false

  @doc """
  Whether the worker holding this session's placement has nothing else to do:
  the placement is current, the worker reported every runtime slot free, no
  session placed on it is being created, and no command waits for it.

  A prepare asks for exactly this. Coop answers it only once the agent is
  running, after waiting for a free runtime slot, and a worker runs one
  command at a time, so a prepare sent to a busy worker would hold every other
  command on it until then.
  """
  @spec worker_idle?(Ecto.UUID.t()) :: boolean()
  def worker_idle?(session_id) do
    now = Repo.now!()

    with {:ok, %Placement{} = placement} <- active_placement(session_id),
         true <- current?(placement, now),
         {:ok, %Worker{} = worker} <- Repo.fetch(Worker.Query.by_id(placement.worker_id)),
         true <- worker_current?(worker, placement.requirements["workspace_ref"], now),
         true <- every_slot_free?(worker),
         false <- session_being_created?(worker.id, now) do
      not Commands.waiting?(worker.id, now)
    else
      _busy_or_unplaced -> false
    end
  end

  defp active_placement(session_id),
    do: session_id |> Placement.Query.by_session_id() |> Placement.Query.active() |> Repo.fetch()

  defp every_slot_free?(worker) do
    worker.capacity["state"] == "eligible" and
      Enum.all?(~w(session turn workspace), fn kind ->
        total = capacity_slot(worker, "#{kind}_slots_total")
        is_integer(total) and total > 0 and capacity_slot(worker, "#{kind}_slots_free") == total
      end)
  end

  # Its creator is about to submit a turn a prepare would hold up. A create
  # takes seconds, a repository's at most a few minutes; an unbound placement
  # older than that is left over, not a session being created, and must not
  # stop every prepare on its worker.
  defp session_being_created?(worker_id, now),
    do: Repo.exists?(Placement.Query.unbound_since(worker_id, creating_since(now)))

  # The oldest a placement can be and still be a create under way.
  defp creating_since(now), do: DateTime.add(now, -@creating_seconds, :second)

  # A command waits only while the worker can still act on it: one the next poll
  # would deliver. Coop answers neither a command whose placement ended nor a
  # prepare past its minute of redelivery, which it cancels; counting those kept
  # the worker busy for good, and no routing session was ever prepared on it
  # again (2026-10-04 review).

  @doc """
  The snapshot this session's work could continue from on another worker.

  Both halves must hold: a checkpoint the host still has for the exact source
  the session is pinned to, and a worker that could take it. Either one missing
  means the offer is a promise the fleet cannot keep, and the operator would
  lose the working copy by accepting it.
  """
  @spec portable_workspace(Work.Session.t(), map(), String.t()) ::
          %{byte_size: pos_integer(), checkpoint_ref: String.t(), repository_ref: String.t()}
          | nil
  def portable_workspace(%Work.Session{} = session, requirements, body_root) do
    if worker_available?(session, requirements), do: portable_checkpoint(session, body_root)
  end

  def portable_workspace(_session, _requirements, _body_root), do: nil

  # The newest checkpoint a rotation of this session would actually restore:
  # same episode and repository, taken by this generation or one before it, and
  # pinned to the same repository source. Client.restore_checkpoint/1 selects by
  # the same rule, so the offer and the restore cannot disagree.
  # Recovery pages inspect only metadata and local file custody, not bundle bytes.
  defp portable_checkpoint(%Work.Session{repository_ref: nil}, _root), do: nil

  defp portable_checkpoint(%Work.Session{} = session, root) do
    session
    |> WorkspaceCheckpointTransfer.Query.latest_portable()
    |> Repo.peek()
    |> checkpoint_offer(session.repository_source, root)
  end

  defp checkpoint_offer(nil, _source, _root), do: nil

  defp checkpoint_offer({checkpoint, source}, expected_source, root) do
    if Work.RepositorySource.same?(source, expected_source) and
         checkpoint_available?(root, checkpoint),
       do: Map.take(checkpoint, [:byte_size, :checkpoint_ref, :repository_ref])
  end

  defp checkpoint_available?(root, checkpoint) do
    match?(
      {:ok, _, _},
      Bodies.fetch(root, checkpoint.body_command_id, :response, %{
        "sha256" => checkpoint.sha256,
        "byte_size" => checkpoint.byte_size
      })
    )
  end

  defp place_session_locked(session_id, requirements, lease_seconds) do
    lock_holding_workers(session_id)

    session =
      session_id
      |> Work.Session.Query.by_id()
      |> Work.Session.Query.lock_for_no_key_update()
      |> Repo.peek() ||
        Shared.rollback({:coop_session_not_found, session_id})

    validate_job_for_placement!(session)
    now = Repo.now!()

    case current_placement(session_id) do
      {:ok, %Placement{} = placement} ->
        cond do
          not current?(placement, now) ->
            replacement_required(placement, now)

          # A holder placement only ever stops or cleans up.
          holder_placement?(placement) and not stopping_or_cleaning?(session) ->
            {:replacement_required, placement.generation}

          true ->
            placement
        end

      {:error, :not_found} ->
        place_unassigned_session(session, requirements, lease_seconds, now)
    end
  end

  defp place_unassigned_session(session, requirements, lease_seconds, now) do
    case latest_placement(session.id) do
      {:ok, %Placement{} = placement} ->
        Commands.fail_undelivered_commands(placement, now)

        cond do
          cancelling_bound_session?(session) ->
            recover_cancellation_placement(session, placement, requirements, lease_seconds, now)

          cleaning_bound_session?(session) ->
            recover_cleanup_placement(session, placement, requirements, lease_seconds, now)

          bound_session?(session) ->
            # The worker still holds this session, so the work is not lost — only the placement
            # that addressed it is. Replacing the SESSION is the answer when its material is gone;
            # when the material is there it throws the material away, and a review cannot do that
            # at all, because the session is the thing being reviewed. Re-place it on the SAME
            # worker under the ordinary eligibility checks: a new generation fences every command
            # from the old placement, so this is one writer, the one that already has it. A worker
            # that is no longer current fails closed to replacement_required, as before.
            recover_bound_placement(session, placement, requirements, lease_seconds, now)

          true ->
            {:replacement_required, placement.generation}
        end

      {:error, :not_found} ->
        insert_placement(session, requirements, lease_seconds, now)
    end
  end

  defp validate_job_for_placement!(session) do
    unless bound_session?(session) and stopping_or_cleaning?(session) do
      case JobAuthority.validate(session) do
        {:ok, _session} -> :ok
        {:error, reason} -> Shared.rollback(reason)
      end
    end
  end

  @doc "Whether this placement is active and its lease has not run out."
  @spec current?(Placement.t(), DateTime.t()) :: boolean()
  def current?(%Placement{state: :active, lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def current?(%Placement{}, _now), do: false

  defp bound_session?(%Work.Session{coop_session_id: remote_id}) when is_binary(remote_id),
    do: true

  defp bound_session?(_session), do: false

  # A re-placement of a session the previous worker still holds goes back to
  # that worker under the ordinary eligibility checks; the caller decides what
  # an ineligible worker means for its session.
  defp recover_placement_on_previous_worker(session, previous, requirements, lease_seconds, now) do
    with {:ok, worker} <- Shared.lock_worker(previous.worker_id),
         true <-
           holder_reachable?(worker, requirements.workspace_ref, now) and
             is_nil(worker.drain_requested_at) and worker.state in [:eligible, :busy] and
             worker_eligible?(worker, requirements, now) and
             placement_authority_current?(previous.requirements, worker) do
      {:ok, insert_placement_on_worker(session, worker, requirements, lease_seconds, now)}
    else
      _gone_or_ineligible -> :ineligible
    end
  end

  defp recover_bound_placement(session, previous, requirements, lease_seconds, now) do
    case recover_placement_on_previous_worker(session, previous, requirements, lease_seconds, now) do
      {:ok, placement} -> placement
      :ineligible -> {:replacement_required, previous.generation}
    end
  end

  defp replacement_required(placement, now) do
    if DateTime.compare(placement.lease_expires_at, now) == :gt do
      {:replacement_pending, placement.generation, placement.lease_expires_at}
    else
      replaced =
        placement
        |> Placement.Changeset.replace()
        |> Repo.update!()

      Commands.fail_undelivered_commands(replaced, now)

      {:replacement_required, placement.generation}
    end
  end

  defp insert_placement(session, requirements, lease_seconds, now) do
    worker = choose_worker!(session, requirements, now)
    insert_placement_on_worker(session, worker, requirements, lease_seconds, now)
  end

  defp insert_placement_on_worker(session, worker, requirements, lease_seconds, now) do
    generation = next_placement_generation(session.id)
    id = Repo.generate_id()
    frozen_requirements = placement_requirements(session, worker, requirements)

    %{
      episode_id: session.episode_id,
      generation: generation,
      id: id,
      last_acked_event_sequence: 0,
      last_acked_session_event_sequence: 0,
      lease_expires_at: DateTime.add(now, lease_seconds, :second),
      lease_ref: "placement-lease:#{id}",
      requirements: frozen_requirements,
      requirements_fingerprint: CanonicalJSON.digest(frozen_requirements),
      session_id: session.id,
      state: :active,
      worker_id: worker.id
    }
    |> Placement.Changeset.insert(now)
    |> Repo.insert()
    |> Shared.unwrap_write()
  end

  defp cancelling_bound_session?(%Work.Session{id: session_id, coop_session_id: remote_id})
       when is_binary(remote_id) do
    session_id
    |> Work.Turn.Query.by_session_id()
    |> Work.Turn.Query.cancelling()
    |> Repo.exists?()
  end

  defp cancelling_bound_session?(_session), do: false

  defp cleaning_bound_session?(%Work.Session{cleanup_status: status} = session),
    do: status in @cleanup_phases and bound_session?(session)

  defp stopping_or_cleaning?(%Work.Session{cleanup_status: status} = session),
    do: status in @cleanup_phases or cancelling_bound_session?(session)

  defp recover_cancellation_placement(session, previous, requirements, lease_seconds, now) do
    case place_on_holder(session, previous, requirements, lease_seconds, now) do
      {:ok, placement} -> placement
      :unreachable -> Shared.rollback({:coop_worker_capacity_unavailable, session.id})
    end
  end

  defp recover_cleanup_placement(session, previous, requirements, lease_seconds, now) do
    case place_on_holder(session, previous, requirements, lease_seconds, now) do
      {:ok, placement} -> placement
      :unreachable -> {:replacement_required, previous.generation}
    end
  end

  # Stop and cleanup return to the exact holder even after settings or sandbox
  # changes. They need no new runtime slot and never authorize another turn.
  defp place_on_holder(session, previous, requirements, lease_seconds, now) do
    with {:ok, worker} <- Shared.lock_worker(previous.worker_id),
         true <- holder_reachable?(worker, requirements.workspace_ref, now) do
      holder = %{
        requirements
        | capability_names: [],
          capability_versions: %{},
          repository_ref: nil
      }

      holder = Map.put(holder, :purpose, @holder_purpose)
      {:ok, insert_placement_on_worker(session, worker, holder, lease_seconds, now)}
    else
      _gone_or_unreachable -> :unreachable
    end
  end

  defp holder_reachable?(%Worker{} = worker, workspace_ref, now) do
    cutoff = DateTime.add(now, -Worker.heartbeat_seconds(), :second)

    worker.workspace_ref == workspace_ref and worker.state != :revoked and
      is_nil(worker.revoked_at) and match?(%DateTime{}, worker.last_seen_at) and
      DateTime.compare(worker.last_seen_at, cutoff) != :lt and
      match?(%DateTime{}, worker.clock_at) and
      DateTime.diff(now, worker.clock_at, :second) |> abs() <=
        Shared.maximum_clock_skew_seconds()
  end

  defp holder_placement?(%Placement{requirements: %{"purpose" => @holder_purpose}}), do: true
  defp holder_placement?(%Placement{}), do: false

  defp worker_current?(%Worker{} = worker, workspace_ref, now) do
    cutoff = DateTime.add(now, -Worker.heartbeat_seconds(), :second)

    worker.workspace_ref == workspace_ref and worker.state == :eligible and
      is_nil(worker.drain_requested_at) and is_nil(worker.revoked_at) and
      match?(%DateTime{}, worker.last_seen_at) and
      DateTime.compare(worker.last_seen_at, cutoff) != :lt
  end

  defp worker_current?(nil, _workspace_ref, _now), do: false

  # A placement this poll took out of :active — its authority changed, or an
  # operator drained it — is never selected again by the renewal below, so an
  # expired one stayed current forever and readiness stayed red with
  # :expired_current_placements. Retire it on the same poll that observed it.
  defp retire_expired_placements(worker, now) do
    worker.id
    |> Placement.Query.expired_inactive(now)
    |> Placement.Query.lock_for_update()
    |> Repo.all()
    |> Enum.each(fn placement ->
      retired = placement |> Placement.Changeset.replace() |> Repo.update!()
      Commands.fail_undelivered_commands(retired, now)
    end)
  end

  @doc """
  Retires every placement still addressing `session_id`, whose worker session
  is gone. Retention settles a session as discarded only once its worker
  discarded it or can no longer hold it, so nothing addresses the session
  again; before 2026-09-27 its placement stayed active, and every poll of the
  worker renewed it.
  """
  @spec retire_session_placements(Ecto.UUID.t(), DateTime.t()) :: :ok
  def retire_session_placements(session_id, now) do
    lock_holding_workers(session_id)

    session_id
    |> Placement.Query.by_session_id()
    |> Placement.Query.current()
    |> Placement.Query.lock_for_update()
    |> Repo.all()
    |> Enum.each(fn placement ->
      retired = placement |> Placement.Changeset.retire() |> Repo.update!()
      Commands.fail_undelivered_commands(retired, now)
    end)
  end

  @abandoned_seconds 10 * 60

  @doc """
  Retires the placements no worker will renew: a revoked worker's, and those
  of a worker that has not polled for ten minutes and whose lease ran out ten
  minutes ago. Only a poll by its own worker retired a placement, so a
  revoked or vanished worker's stayed current until each session was placed
  again, and readiness stayed red (2026-10-04 review).

  A worker cannot poll a Ryker that is down, so a vanished worker is judged
  only once this Ryker has been up (`up_since`) for those ten minutes.
  """
  @spec retire_abandoned_placements(DateTime.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  def retire_abandoned_placements(now, up_since) do
    cutoff = DateTime.add(now, -@abandoned_seconds, :second)
    judge_vanished? = DateTime.compare(up_since, cutoff) != :gt
    query = Placement.Query.abandoned(cutoff, judge_vanished?)
    workers = query |> Placement.Query.select_worker_ids() |> Repo.all()

    Repo.transaction(fn ->
      Enum.each(Enum.sort(workers), &Shared.lock_worker/1)

      query
      |> Placement.Query.lock_for_update()
      |> Repo.all()
      |> Enum.map(fn placement ->
        retired = placement |> Placement.Changeset.replace() |> Repo.update!()
        Commands.fail_undelivered_commands(retired, now)
      end)
      |> length()
    end)
  end

  @doc false
  def renew_worker_placements(worker, now, lease_seconds) do
    expires_at = DateTime.add(now, lease_seconds, :second)
    retire_expired_placements(worker, now)

    placements =
      worker.id
      |> Placement.Query.by_worker_id()
      |> Placement.Query.active()
      |> Placement.Query.lock_for_update()
      |> Repo.all()

    # A lease that ran out with nothing placed in its stead is the worker's
    # still: this poll shows the worker holds it. Replacing it here disrupted
    # all work in flight whenever Ryker itself was down for more than a lease,
    # for a deploy or a stalled Docker VM (2026-10-04 review). A placement
    # another worker took over is no longer active and is not renewed.
    Enum.each(placements, fn placement ->
      changeset =
        if placement_authority_current?(placement.requirements, worker),
          do: Placement.Changeset.renew(placement, expires_at),
          else: Placement.Changeset.revoke(placement)

      Repo.update!(changeset)
    end)

    :ok
  end

  defp choose_worker!(session, requirements, now) do
    cutoff = DateTime.add(now, -Worker.heartbeat_seconds(), :second)

    case choose_worker_candidate(session, requirements, now, cutoff, [], nil) do
      %Worker{} = worker ->
        worker

      {:storage_refused, reason} ->
        Shared.rollback({:coop_worker_storage_refused, session.id, reason})

      nil ->
        Shared.rollback({:coop_worker_capacity_unavailable, session.id})
    end
  end

  defp choose_worker_candidate(session, requirements, now, cutoff, excluded_ids, refusal) do
    worker = worker_candidate(requirements, cutoff, excluded_ids)

    cond do
      is_nil(worker) ->
        if refusal, do: {:storage_refused, refusal}, else: nil

      storage_refused?(worker, session) ->
        skip(session, requirements, now, cutoff, excluded_ids, worker, storage_refusal(worker))

      worker_eligible?(worker, requirements, now) and
        worker.capacity["state"] == "eligible" and worker_has_capacity?(worker, now) ->
        worker

      true ->
        skip(session, requirements, now, cutoff, excluded_ids, worker, refusal)
    end
  end

  defp skip(session, requirements, now, cutoff, excluded_ids, worker, refusal) do
    choose_worker_candidate(
      session,
      requirements,
      now,
      cutoff,
      [worker.id | excluded_ids],
      refusal
    )
  end

  # A worker that reports its allocation refused stops receiving new sessions
  # that need a fork. Cleanup, control, and recovery of the work already on it
  # keep running, and it returns to service when it reports `open` again, so
  # there is no second hysteresis here to oscillate against the worker's own.
  defp storage_refused?(%Worker{storage: %{"allocation" => "refused"}}, session),
    do: fork_required?(session)

  defp storage_refused?(_worker, _session), do: false

  defp storage_refusal(%Worker{storage: %{"refusal_reason" => reason}}) when is_binary(reason),
    do: reason

  defp storage_refusal(_worker), do: "allocation_refused"

  defp fork_required?(%Work.Session{repository_ref: repository_ref}),
    do: is_binary(repository_ref)

  # A worker another placement has locked keeps that placement's choice and
  # is skipped, since several placements may arrive at once. Only when every
  # candidate is locked does the choice wait: a poll holds its worker's row
  # while it runs, and skipping it left a task that arrived mid-poll with no
  # worker at all, stopped for a person (2026-10-04 review).
  defp worker_candidate(requirements, cutoff, excluded_ids) do
    query = Worker.Query.placement_candidate(requirements, cutoff, excluded_ids)

    Repo.peek(Worker.Query.lock_next_free(query)) ||
      Repo.peek(Worker.Query.lock_for_update(query))
  end

  defp worker_has_capacity?(worker, now) do
    reserved_slots = reserved_placement_slots(worker.id, now)

    # A heartbeat can precede execution of an assigned create. Keep that
    # reservation until verified remote binding, not merely until the next poll.
    # Bound sessions use measured worker capacity and may park without a child.
    Enum.all?(
      ~w(session turn workspace),
      &(capacity_slot(worker, "#{&1}_slots_free") > reserved_slots)
    )
  end

  # Only a create still under way reserves a slot, for as long as
  # `session_being_created?/2` counts one. An older unbound placement is left
  # over, most often from a create Coop refused for good: its session stays
  # active and unbound and the worker renews the placement on every poll, so
  # counted it would hold its slot until retention retired the session.
  defp reserved_placement_slots(worker_id, now) do
    worker_id
    |> Placement.Query.unbound_since(creating_since(now))
    |> Placement.Query.without_closed_session()
    |> Repo.aggregate(:count)
  end

  defp worker_eligible?(worker, requirements, now) do
    capabilities_available?(
      worker.capabilities,
      requirements.capability_names,
      requirements.capability_versions
    ) and
      match?(%DateTime{}, worker.clock_at) and
      DateTime.diff(now, worker.clock_at, :second) |> abs() <= Shared.maximum_clock_skew_seconds()
  end

  defp capabilities_available?(capabilities, required_names, required_versions) do
    available = Map.new(capabilities, &{&1["name"], &1["version"]})

    Enum.all?(required_names, &Map.has_key?(available, &1)) and
      Enum.all?(required_versions, fn {name, version} -> available[name] == version end)
  end

  defp placement_requirements(session, worker, requirements) do
    document = %{
      "capability_names" => requirements.capability_names,
      "capability_versions" => requirements.capability_versions,
      "job_ref" => session.external_ref,
      "job_digest" => session.worker_job_digest,
      "sandbox_digest" => worker.sandbox_digest,
      "workspace_ref" => requirements.workspace_ref
    }

    case Map.get(requirements, :purpose) do
      nil -> document
      purpose -> Map.put(document, "purpose", purpose)
    end
  end

  defp placement_authority_current?(requirements, worker) do
    worker.workspace_ref == requirements["workspace_ref"] and
      worker.sandbox_digest == requirements["sandbox_digest"] and
      capabilities_available?(
        worker.capabilities,
        requirements["capability_names"],
        Map.get(requirements, "capability_versions", %{})
      )
  end

  defp capacity_slot(worker, name), do: Map.get(worker.capacity, name, 0)

  defp next_placement_generation(session_id) do
    generation =
      session_id
      |> Placement.Query.by_session_id()
      |> Placement.Query.select_max_generation()
      |> Repo.one()

    generation + 1
  end

  # A poll locks its worker and then that worker's commands and placements.
  # Recovery and retirement locked a placement and then its worker or its
  # commands, so a poll and either could each wait for the other
  # (2026-10-04 review). They lock the workers holding the session's
  # placements first, in one order, as the poll does.
  defp lock_holding_workers(session_id) do
    session_id
    |> Placement.Query.by_session_id()
    |> Placement.Query.select_worker_ids()
    |> Repo.all()
    |> Enum.each(&Shared.lock_worker/1)
  end

  defp current_placement(session_id) do
    session_id
    |> Placement.Query.by_session_id()
    |> Placement.Query.current()
    |> Placement.Query.lock_for_update()
    |> Repo.fetch()
  end

  defp latest_placement(session_id) do
    session_id
    |> Placement.Query.by_session_id()
    |> Placement.Query.ordered_by_generation_desc()
    |> Placement.Query.limit_to(1)
    |> Placement.Query.lock_for_update()
    |> Repo.fetch()
  end

  defp requirements(%{} = requirements) do
    workspace_ref = Map.get(requirements, :workspace_ref)
    repository_ref = Map.get(requirements, :repository_ref)
    capability_names = Map.get(requirements, :capability_names, [])
    capability_versions = Map.get(requirements, :capability_versions, %{})

    with :ok <- Shared.reference(workspace_ref, 256, :workspace_ref),
         :ok <- optional_reference(repository_ref, 256, :repository_ref),
         :ok <- references(capability_names, :capability_names),
         :ok <- capability_versions(capability_versions) do
      {:ok,
       %{
         capability_names: capability_names,
         capability_versions: capability_versions,
         repository_ref: repository_ref,
         workspace_ref: workspace_ref
       }}
    end
  end

  defp requirements(_requirements),
    do: {:error, {:invalid_coop_session_placement, :requirements}}

  defp references(values, field) when is_list(values) and length(values) <= 100 do
    if Enum.uniq(values) == values and
         Enum.all?(values, &(Shared.reference(&1, 256, field) == :ok)),
       do: :ok,
       else: {:error, {:invalid_coop_session_placement, field}}
  end

  defp references(_values, field), do: {:error, {:invalid_coop_session_placement, field}}

  defp capability_versions(versions) when is_map(versions) and map_size(versions) <= 100 do
    if Enum.all?(versions, fn {name, version} ->
         Shared.reference(name, 256, :capability_versions) == :ok and
           Shared.reference(version, 128, :capability_versions) == :ok
       end),
       do: :ok,
       else: {:error, {:invalid_coop_session_placement, :capability_versions}}
  end

  defp capability_versions(_versions),
    do: {:error, {:invalid_coop_session_placement, :capability_versions}}

  defp optional_reference(nil, _maximum, _field), do: :ok
  defp optional_reference(value, maximum, field), do: Shared.reference(value, maximum, field)
end

defmodule Ryker.CoopFleet.ControlPlane.Placements do
  @moduledoc """
  Session placement and worker choice.

  Places a session on one current worker with the policy, authority,
  repository, capabilities, freshness and capacity it needs; recovers or
  replaces a placement whose lease or authority ended; renews a worker's
  placement leases on each poll; and answers whether the fleet could take a
  session at all without taking a slot to find out.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Command, Placement, Worker, WorkspaceCheckpointTransfer}
  alias Ryker.CoopFleet.ControlPlane.{Commands, Shared}
  alias Ryker.Repo
  alias Ryker.Work.{RepositorySource, Session, Turn}

  @heartbeat_stale_seconds 60
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

  A recovery surface may only offer to move work when the fleet could actually
  accept it. The learning lane sat unplaceable for twelve hours on 2026-09-11
  because one worker advertised no digest for its policy, so this asks the same
  question placement asks — policy, authority, repository, capabilities,
  freshness and capacity — without taking a slot to find out.
  """
  @spec worker_available?(Session.t(), map()) :: boolean()
  def worker_available?(%Session{} = session, requirements) do
    case requirements(requirements) do
      {:ok, prepared} ->
        now = Repo.now!()

        Worker
        |> Repo.all()
        |> Enum.any?(fn worker ->
          worker_current?(worker, prepared.workspace_ref, now) and
            worker_eligible?(worker, session, prepared, now) and worker_has_capacity?(worker)
        end)

      {:error, _reason} ->
        false
    end
  end

  def worker_available?(_session, _requirements), do: false

  @doc """
  The snapshot this session's work could continue from on another worker.

  Both halves must hold: a checkpoint the host still has for the exact source
  the session is pinned to, and a worker that could take it. Either one missing
  means the offer is a promise the fleet cannot keep, and the operator would
  lose the working copy by accepting it.
  """
  @spec portable_workspace(Session.t(), map()) ::
          %{byte_size: pos_integer(), checkpoint_ref: String.t(), repository_ref: String.t()}
          | nil
  def portable_workspace(%Session{} = session, requirements) do
    if worker_available?(session, requirements), do: portable_checkpoint(session)
  end

  def portable_workspace(_session, _requirements), do: nil

  # The newest checkpoint a rotation of this session would actually restore:
  # same episode and repository, taken by this generation or one before it, and
  # pinned to the same repository source. Client.restore_checkpoint/1 selects by
  # the same rule, so the offer and the restore cannot disagree.
  # A checkpoint bundle is up to 64 MiB of ciphertext, and none of it belongs on
  # a recovery page, so this reads identity only.
  defp portable_checkpoint(%Session{repository_ref: nil}), do: nil

  defp portable_checkpoint(%Session{} = session) do
    from(transfer in WorkspaceCheckpointTransfer,
      join: command in Command,
      on: command.id == transfer.command_id,
      join: source in Session,
      on: source.id == command.session_id,
      where:
        source.episode_id == ^session.episode_id and
          source.generation <= ^session.generation and
          source.repository_ref == ^session.repository_ref and command.status == :succeeded,
      order_by: [desc: transfer.inserted_at, desc: transfer.id],
      select: {
        %{
          byte_size: transfer.bundle_byte_size,
          checkpoint_ref: transfer.checkpoint_ref,
          repository_ref: transfer.repository_ref
        },
        source.repository_source
      }
    )
    |> Repo.all()
    |> Enum.find_value(fn {checkpoint, source} ->
      RepositorySource.same?(source, session.repository_source) and checkpoint
    end)
  end

  defp place_session_locked(session_id, requirements, lease_seconds) do
    session =
      Repo.one(
        from(session in Session,
          where: session.id == ^session_id,
          lock: "FOR NO KEY UPDATE"
        )
      ) || Shared.rollback({:coop_session_not_found, session_id})

    now = Repo.now!()

    case current_placement(session_id) do
      %Placement{} = placement ->
        cond do
          not current?(placement, now) ->
            replacement_required(placement, now)

          # A placement on the holder's current policy only ever stops or cleans up.
          holder_placement?(placement) and not stopping_or_cleaning?(session) ->
            {:replacement_required, placement.generation}

          true ->
            placement
        end

      nil ->
        place_unassigned_session(session, requirements, lease_seconds, now)
    end
  end

  defp place_unassigned_session(session, requirements, lease_seconds, now) do
    case latest_placement(session.id) do
      %Placement{} = placement ->
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

      nil ->
        insert_placement(session, requirements, lease_seconds, now)
    end
  end

  @doc "Whether this placement is active and its lease has not run out."
  @spec current?(Placement.t(), DateTime.t()) :: boolean()
  def current?(%Placement{state: :active, lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def current?(%Placement{}, _now), do: false

  defp bound_session?(%Session{coop_session_id: remote_id}) when is_binary(remote_id), do: true
  defp bound_session?(_session), do: false

  # A re-placement of a session the previous worker still holds goes back to
  # that worker under the ordinary eligibility checks; the caller decides what
  # an ineligible worker means for its session.
  defp recover_placement_on_previous_worker(session, previous, requirements, lease_seconds, now) do
    worker = Shared.locked_worker(previous.worker_id)

    eligible =
      worker_current?(worker, requirements.workspace_ref, now) and
        worker_eligible?(worker, session, requirements, now) and
        placement_authority_current?(previous.requirements, worker) and
        worker_has_capacity?(worker)

    if eligible,
      do: {:ok, insert_placement_on_worker(session, worker, requirements, lease_seconds, now)},
      else: :ineligible
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
        |> change(%{state: :replaced})
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
    id = Ecto.UUID.generate()
    frozen_requirements = placement_requirements(session, worker, requirements)

    %Placement{inserted_at: now, updated_at: now}
    |> cast(
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
      },
      [
        :episode_id,
        :generation,
        :id,
        :last_acked_event_sequence,
        :last_acked_session_event_sequence,
        :lease_expires_at,
        :lease_ref,
        :requirements,
        :requirements_fingerprint,
        :session_id,
        :state,
        :worker_id
      ]
    )
    |> validate_required([
      :generation,
      :id,
      :lease_expires_at,
      :lease_ref,
      :requirements,
      :requirements_fingerprint,
      :session_id,
      :state,
      :worker_id
    ])
    |> unique_constraint([:session_id, :generation])
    |> unique_constraint(:session_id, name: :coop_session_placements_one_current)
    |> foreign_key_constraint(:session_id,
      name: :coop_session_placement_session_episode_fkey
    )
    |> foreign_key_constraint(:session_id,
      name: :coop_session_placements_session_id_fkey
    )
    |> foreign_key_constraint(:worker_id)
    |> check_constraint(:generation, name: :coop_session_placement_identity_valid)
    |> Repo.insert()
    |> Shared.unwrap_write()
  end

  defp cancelling_bound_session?(%Session{id: session_id, coop_session_id: remote_id})
       when is_binary(remote_id) do
    Repo.exists?(
      from(turn in Turn,
        where: turn.session_id == ^session_id and turn.status == :cancel_pending
      )
    )
  end

  defp cancelling_bound_session?(_session), do: false

  defp cleaning_bound_session?(%Session{cleanup_status: status} = session),
    do: status in @cleanup_phases and bound_session?(session)

  defp stopping_or_cleaning?(%Session{cleanup_status: status} = session),
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

  # Stopping a run and cleaning up after one do no policy work: Coop's worker
  # forwards get, cancel, close, discard planning and discard without naming a
  # policy, and its daemon never reads one for them. So they go back to the
  # worker that holds the session under whatever that worker runs now, and need
  # only that it still reports. Requiring the exact version and setup the
  # session started with stranded every cleanup and stop after a model change
  # in Settings: on 2026-09-23 two cleanups blocked behind a retry that could
  # never work, and a stop in the same place was deferred forever. The
  # placement pins what the worker runs now, so its own heartbeat keeps it, and
  # says what it is for so it never carries the session's next turn.
  defp place_on_holder(session, previous, requirements, lease_seconds, now) do
    worker = Shared.locked_worker(previous.worker_id)

    if holder_reachable?(worker, requirements.workspace_ref, now) do
      held = %{
        session
        | authority_digest: Map.get(worker.policy_authority_digests, session.policy),
          policy_digest: Map.get(worker.policy_digests, session.policy)
      }

      holder = %{
        requirements
        | capability_names: [],
          capability_versions: %{},
          repository_ref: nil
      }

      {:ok,
       insert_placement_on_worker(
         held,
         worker,
         Map.put(holder, :purpose, @holder_purpose),
         lease_seconds,
         now
       )}
    else
      :unreachable
    end
  end

  defp holder_reachable?(%Worker{} = worker, workspace_ref, now) do
    cutoff = DateTime.add(now, -@heartbeat_stale_seconds, :second)

    worker.workspace_ref == workspace_ref and worker.state != :revoked and
      is_nil(worker.revoked_at) and match?(%DateTime{}, worker.last_seen_at) and
      DateTime.compare(worker.last_seen_at, cutoff) != :lt and
      match?(%DateTime{}, worker.clock_at) and
      DateTime.diff(now, worker.clock_at, :second) |> abs() <=
        Shared.maximum_clock_skew_seconds()
  end

  defp holder_reachable?(nil, _workspace_ref, _now), do: false

  defp holder_placement?(%Placement{requirements: %{"purpose" => @holder_purpose}}), do: true
  defp holder_placement?(%Placement{}), do: false

  defp worker_current?(%Worker{} = worker, workspace_ref, now) do
    cutoff = DateTime.add(now, -@heartbeat_stale_seconds, :second)

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
    from(placement in Placement,
      where:
        placement.worker_id == ^worker.id and
          placement.state in ^(Placement.current_states() -- [:active]) and
          placement.lease_expires_at <= ^now,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Enum.each(fn placement ->
      retired = placement |> change(%{state: :replaced}) |> Repo.update!()
      Commands.fail_undelivered_commands(retired, now)
    end)
  end

  @doc false
  def renew_worker_placements(worker, now, lease_seconds) do
    expires_at = DateTime.add(now, lease_seconds, :second)
    retire_expired_placements(worker, now)

    placements =
      Repo.all(
        from(placement in Placement,
          where: placement.worker_id == ^worker.id and placement.state == :active,
          lock: "FOR UPDATE"
        )
      )

    Enum.each(placements, fn placement ->
      attributes =
        cond do
          DateTime.compare(placement.lease_expires_at, now) != :gt ->
            %{state: :replaced}

          placement_authority_current?(placement.requirements, worker) ->
            %{lease_expires_at: expires_at}

          true ->
            %{state: :revoking}
        end

      updated =
        placement
        |> change(attributes)
        |> Repo.update!()

      if updated.state == :replaced, do: Commands.fail_undelivered_commands(updated, now)
    end)

    :ok
  end

  defp choose_worker!(session, requirements, now) do
    cutoff = DateTime.add(now, -@heartbeat_stale_seconds, :second)

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

      worker_eligible?(worker, session, requirements, now) and worker_has_capacity?(worker) ->
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

  defp fork_required?(%Session{repository_ref: repository_ref}), do: is_binary(repository_ref)

  defp worker_candidate(requirements, cutoff, excluded_ids) do
    current_states = Enum.map(Placement.current_states(), &Atom.to_string/1)

    Repo.one(
      from(worker in Worker,
        where:
          worker.workspace_ref == ^requirements.workspace_ref and worker.state == :eligible and
            is_nil(worker.drain_requested_at) and is_nil(worker.revoked_at) and
            worker.last_seen_at >= ^cutoff and worker.id not in ^excluded_ids,
        order_by: [
          asc:
            fragment(
              "(SELECT count(*) FROM coop_session_placements AS placement WHERE placement.worker_id = ? AND placement.state = ANY(?))",
              worker.id,
              type(^current_states, {:array, :string})
            ),
          desc:
            fragment(
              "COALESCE((?::jsonb ->> 'turn_slots_free')::integer, 0)",
              worker.capacity
            ),
          desc:
            fragment(
              "COALESCE((?::jsonb ->> 'session_slots_free')::integer, 0)",
              worker.capacity
            ),
          asc: worker.id
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp worker_has_capacity?(worker) do
    reserved_slots = reserved_placement_slots(worker.id, worker.last_seen_at)

    Enum.all?(~w(session turn workspace), fn kind ->
      capacity_slot(worker, "#{kind}_slots_free") > reserved_slots
    end)
  end

  defp reserved_placement_slots(worker_id, reported_at) do
    closed =
      from(command in Command,
        where:
          command.placement_id == parent_as(:placement).id and
            command.kind == "close_session" and command.status == :succeeded,
        select: 1
      )

    Repo.aggregate(
      from(placement in Placement,
        as: :placement,
        where:
          placement.worker_id == ^worker_id and
            placement.inserted_at > ^reported_at and
            placement.state in ^Placement.current_states() and
            not exists(subquery(closed))
      ),
      :count
    )
  end

  defp worker_eligible?(worker, session, requirements, now) do
    worker.policy_digests[session.policy] == session.policy_digest and
      worker_authority_matches?(worker, session.policy, session.authority_digest) and
      repository_available?(worker.repositories, requirements.repository_ref) and
      capabilities_available?(
        worker.capabilities,
        requirements.capability_names,
        requirements.capability_versions
      ) and
      worker.capacity["state"] == "eligible" and
      DateTime.diff(now, worker.clock_at, :second) |> abs() <= Shared.maximum_clock_skew_seconds()
  end

  defp repository_available?(_repositories, nil), do: true

  defp repository_available?(repositories, repository_ref) do
    Enum.any?(repositories, &(&1["ref"] == repository_ref))
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
      "authority_digest" => session.authority_digest,
      "policy" => session.policy,
      "policy_digest" => session.policy_digest,
      "repository_ref" => requirements.repository_ref,
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
      worker.policy_digests[requirements["policy"]] == requirements["policy_digest"] and
      worker_authority_matches?(
        worker,
        requirements["policy"],
        requirements["authority_digest"]
      ) and
      repository_available?(worker.repositories, requirements["repository_ref"]) and
      capabilities_available?(
        worker.capabilities,
        requirements["capability_names"],
        Map.get(requirements, "capability_versions", %{})
      )
  end

  defp capacity_slot(worker, name), do: Map.get(worker.capacity, name, 0)

  defp worker_authority_matches?(_worker, _policy, nil), do: true

  defp worker_authority_matches?(worker, policy, authority_digest),
    do: worker.policy_authority_digests[policy] == authority_digest

  defp next_placement_generation(session_id) do
    Repo.one(
      from(placement in Placement,
        where: placement.session_id == ^session_id,
        select: coalesce(max(placement.generation), 0)
      )
    ) + 1
  end

  defp current_placement(session_id) do
    Repo.one(
      from(placement in Placement,
        where:
          placement.session_id == ^session_id and
            placement.state in ^Placement.current_states(),
        lock: "FOR UPDATE"
      )
    )
  end

  defp latest_placement(session_id) do
    Repo.one(
      from(placement in Placement,
        where: placement.session_id == ^session_id,
        order_by: [desc: placement.generation],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
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

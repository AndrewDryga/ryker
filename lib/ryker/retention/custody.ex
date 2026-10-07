defmodule Ryker.Retention.Custody do
  @moduledoc """
  PostgreSQL custody for exact Coop session cleanup.

  Cleanup is eligible only after the owning episode and every local Work turn
  are terminal, the owning learning, self-analysis or repository knowledge
  run has exact remote stop proof, an
  admission input has finished or advanced past that session generation, or a
  routing session started ahead of time was retired before any message
  claimed it (`Ryker.Admission.ReadySessions`); no unpublished publication may
  still depend on the session.
  Durable state records and episode history may outlive the remote workspace;
  their independent retention rules preserve them. PostgreSQL time and opaque
  leases provide the fleet fence; remote calls never run in these transactions.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.ControlPlane, as: FleetControlPlane
  alias Ryker.CoopFleet.Placement
  alias Ryker.CoopFleet.Worker, as: FleetWorker
  alias Ryker.Episodes.Episode
  alias Ryker.Improvement.AnalysisRun
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.LearningRun
  alias Ryker.Lease
  alias Ryker.Publication.Publication
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge.Run, as: KnowledgeRun
  alias Ryker.Retention.{Cleanup, Plan}
  alias Ryker.Work.Custody, as: WorkCustody
  alias Ryker.Work.{Session, Turn}

  @pending_statuses [:close_pending, :plan_pending, :discard_pending]
  @terminal_episode_states [:complete, :cancelled]
  # How many busy candidates one claim passes over before it answers nothing.
  @passed_over_limit 25

  @type claim :: %{
          owner:
            Episode.t()
            | LearningRun.t()
            | AnalysisRun.t()
            | KnowledgeRun.t()
            | Entry.t()
            | :ready_pool,
          lease_ref: String.t(),
          session: Session.t(),
          worker_id: String.t() | nil
        }

  @spec claim_next(String.t(), pos_integer(), keyword()) ::
          {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds, exclude \\ []) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds),
         {:ok, exclude} <- exclusions(exclude) do
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds, exclude) end)
    end
  end

  @doc """
  The working copies cleanup claims next, oldest due first, each with when it
  fell due: at most `limit` of them, and how many are due. Read-only.
  """
  @spec eligible_copies(DateTime.t(), pos_integer()) ::
          {[{Session.t(), DateTime.t()}], non_neg_integer()}
  def eligible_copies(%DateTime{} = now, limit) when is_integer(limit) and limit > 0 do
    copies = Cleanup.Query.working_copies(now)
    next = copies |> Cleanup.Query.oldest_due_first(limit) |> Repo.all()
    {next, Repo.aggregate(copies, :count)}
  end

  @spec freeze_close_revision(Ecto.UUID.t(), String.t(), pos_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def freeze_close_revision(session_id, lease_ref, revision) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(revision, :revision) do
      update_leased(session_id, lease_ref, :close_pending, fn session, _now ->
        freeze_close_locked(session, revision)
      end)
    end
  end

  @spec begin_grace(Ecto.UUID.t(), String.t(), non_neg_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def begin_grace(session_id, lease_ref, grace_seconds) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- nonnegative_integer(grace_seconds, :grace_seconds) do
      update_leased(session_id, lease_ref, :close_pending, fn session, now ->
        persist(session, %{
          cleanup_attempt_count: 0,
          cleanup_last_error_code: nil,
          cleanup_last_error_detail: nil,
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: nil,
          cleanup_status: :grace,
          discard_after: DateTime.add(now, grace_seconds, :second)
        })
      end)
    end
  end

  @spec mark_closed(Ecto.UUID.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def mark_closed(session_id, lease_ref) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref) do
      update_leased(session_id, lease_ref, :close_pending, fn session, now ->
        persist(session, %{
          cleanup_attempt_count: 0,
          cleanup_last_error_code: nil,
          cleanup_last_error_detail: nil,
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: nil,
          cleanup_status: :plan_pending,
          closed_at: session.closed_at || now
        })
      end)
    end
  end

  @spec freeze_plan_revision(Ecto.UUID.t(), String.t(), pos_integer(), boolean()) ::
          {:ok, Session.t()} | {:error, term()}
  def freeze_plan_revision(session_id, lease_ref, revision, accept_unmerged) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(revision, :revision),
         :ok <- boolean(accept_unmerged, :accept_unmerged) do
      update_leased(session_id, lease_ref, :plan_pending, fn session, _now ->
        freeze_plan_locked(session, revision, accept_unmerged)
      end)
    end
  end

  @spec store_plan(Ecto.UUID.t(), String.t(), map(), pos_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def store_plan(session_id, lease_ref, plan, retained_recheck_seconds) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(retained_recheck_seconds, :retained_recheck_seconds),
         true <- is_map(plan) or {:error, {:invalid_retention_custody, :plan}} do
      update_leased(session_id, lease_ref, :plan_pending, fn session, now ->
        store_plan_locked(session, plan, now, retained_recheck_seconds)
      end)
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_retention_custody, :plan}}
    end
  end

  @spec settle_absent(Ecto.UUID.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def settle_absent(session_id, lease_ref) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref) do
      update_leased(session_id, lease_ref, :close_pending, fn session, now ->
        settle_absent_locked(session, now)
      end)
    end
  end

  @spec settle_discard(Ecto.UUID.t(), String.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def settle_discard(session_id, lease_ref, operation_key, remote_session_id) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- reference(operation_key, :operation_key),
         :ok <- reference(remote_session_id, :remote_session_id) do
      update_leased(session_id, lease_ref, :discard_pending, fn session, now ->
        settle_discard_locked(session, operation_key, remote_session_id, now)
      end)
    end
  end

  @spec settle_remote_discarded(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def settle_remote_discarded(session_id, lease_ref, remote_session_id) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- reference(remote_session_id, :remote_session_id) do
      update_leased(session_id, lease_ref, @pending_statuses, fn session, now ->
        settle_remote_discarded_locked(session, remote_session_id, now)
      end)
    end
  end

  @doc """
  End cleanup for a session whose worker's Coop no longer knows it.

  The worker's own "session not found" is the proof that nothing is left to
  close or remove; the receipt says the remote session was absent, not that
  Ryker removed it.
  """
  @spec settle_remote_absent(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def settle_remote_absent(session_id, lease_ref, remote_session_id) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- reference(remote_session_id, :remote_session_id) do
      update_leased(session_id, lease_ref, @pending_statuses, fn session, now ->
        settle_remote_absent_locked(session, remote_session_id, now)
      end)
    end
  end

  @doc """
  End cleanup for a session whose worker was removed from Ryker.

  Removal revokes the worker's certificates and placements for good, so no
  command can reach the session again and nothing left on that worker is
  Ryker's to remove. A worker that is only away is not removed: the cleanup
  is refused with `{:retention_worker_unavailable, worker_id}` for the outage
  retry, decided here under the lease rather than by the caller's reading.
  """
  @spec settle_worker_removed(Ecto.UUID.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def settle_worker_removed(session_id, lease_ref) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref) do
      update_leased(session_id, lease_ref, @pending_statuses, fn session, now ->
        settle_worker_removed_locked(session, now)
      end)
    end
  end

  @spec defer(Ecto.UUID.t(), String.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def defer(session_id, lease_ref, retry_seconds, error_code, error_detail) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(retry_seconds, :retry_seconds),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      update_leased(session_id, lease_ref, @pending_statuses, fn session, now ->
        persist(session, %{
          cleanup_last_error_code: error_code,
          cleanup_last_error_detail: error_detail,
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: DateTime.add(now, retry_seconds, :second)
        })
      end)
    end
  end

  @spec block(Ecto.UUID.t(), String.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def block(session_id, lease_ref, error_code, error_detail) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      update_leased(session_id, lease_ref, @pending_statuses, fn session, _now ->
        persist(session, %{
          cleanup_blocked_from: session.cleanup_status,
          cleanup_last_error_code: error_code,
          cleanup_last_error_detail: error_detail,
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: nil,
          cleanup_status: :blocked
        })
      end)
    end
  end

  @spec advance_close(Ecto.UUID.t(), String.t(), pos_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def advance_close(session_id, lease_ref, generation) do
    advance_generation(session_id, lease_ref, :close_pending, :close_generation, generation, %{
      close_expected_revision: nil
    })
  end

  @spec advance_plan(Ecto.UUID.t(), String.t(), pos_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def advance_plan(session_id, lease_ref, generation) do
    advance_generation(
      session_id,
      lease_ref,
      :plan_pending,
      :discard_plan_generation,
      generation,
      %{
        discard_plan: nil,
        discard_plan_expected_revision: nil,
        discard_plan_fingerprint: nil,
        discard_plan_operation_id: nil
      }
    )
  end

  @spec close_key(Session.t()) :: String.t()
  def close_key(%Session{} = session),
    do: "ryker:retention:close:#{session.id}:g#{session.close_generation}"

  @spec plan_key(Session.t()) :: String.t()
  def plan_key(%Session{} = session),
    do: "ryker:retention:plan:#{session.id}:g#{session.discard_plan_generation}"

  @spec discard_key(Session.t()) :: String.t()
  def discard_key(%Session{} = session),
    do: "ryker:retention:discard:#{session.id}:g#{session.discard_generation}"

  @doc """
  Drop cleanup leases this dispatcher identity still owns after a restart.

  A restarted host holds no lease it wrote before the restart, so waiting for
  the lease to expire only delays the exact same work.
  """
  @spec release_worker_leases(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def release_worker_leases(worker_ref) do
    with :ok <- reference(worker_ref, :worker_ref) do
      {released, nil} =
        worker_ref
        |> Cleanup.Query.leases_of()
        |> Repo.update_all(
          set: [cleanup_lease_expires_at: nil, cleanup_lease_owner: nil, cleanup_lease_ref: nil]
        )

      {:ok, released}
    end
  end

  @doc """
  Make cleanup deferred by an outage due again once its own worker reconnects.

  A heartbeat that arrived after the failed attempt is fresh evidence that the
  exact deferred call is worth retrying now, instead of waiting out a backoff
  that was chosen while the worker was unreachable.
  """
  @spec reconsider_reconnected_workers([String.t()], pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconsider_reconnected_workers(error_codes, stale_seconds)
      when is_list(error_codes) and is_integer(stale_seconds) and stale_seconds > 0 do
    if Enum.all?(error_codes, &(bounded_text(&1, 128, :error_code) == :ok)) do
      cutoff = DateTime.add(Repo.now!(), -stale_seconds, :second)

      {reconsidered, nil} =
        error_codes
        |> Cleanup.Query.deferred_for_reconnected_workers(cutoff)
        |> Repo.update_all(set: [cleanup_next_attempt_at: nil])

      {:ok, reconsidered}
    else
      {:error, {:invalid_retention_custody, :error_codes}}
    end
  end

  def reconsider_reconnected_workers(_error_codes, _stale_seconds),
    do: {:error, {:invalid_retention_custody, :error_codes}}

  @spec published?(Session.t()) :: boolean()
  def published?(%Session{} = session) do
    publications = Publication.Query.by_session_id(session.id)

    Repo.exists?(Publication.Query.published(publications)) and
      not Repo.exists?(Publication.Query.unpublished(publications))
  end

  # A candidate whose owner another transaction holds, or that stopped being
  # claimable, is passed over for the next in line. Answering nothing would
  # read as an idle pass, and everything behind it would wait for the next
  # poll.
  defp claim_locked(worker_ref, lease_seconds, exclude, passed_over \\ 0)

  defp claim_locked(_worker_ref, _lease_seconds, _exclude, @passed_over_limit), do: nil

  defp claim_locked(worker_ref, lease_seconds, exclude, passed_over) do
    now = Repo.now!()

    case candidate(now, exclude) do
      nil ->
        nil

      {kind, owner_id, session_id, placed_worker_id} ->
        with owner when not is_nil(owner) <- lock_owner(kind, owner_id, :skip_locked),
             %Session{} = session <- lock_session(session_id),
             true <- claimable?(owner, session, now) do
          session = prepare_phase(session)
          lease_ref = "retention-lease:#{Ecto.UUID.generate()}"

          claimed =
            persist(session, %{
              cleanup_attempt_count: session.cleanup_attempt_count + 1,
              cleanup_last_error_code: nil,
              cleanup_last_error_detail: nil,
              cleanup_lease_expires_at: DateTime.add(now, lease_seconds, :second),
              cleanup_lease_owner: worker_ref,
              cleanup_lease_ref: lease_ref,
              cleanup_next_attempt_at: nil
            })

          %{
            owner: owner,
            lease_ref: lease_ref,
            session: claimed,
            worker_id: placed_worker_id
          }
        else
          _not_claimable ->
            exclude = %{exclude | session_ids: [session_id | exclude.session_ids]}
            claim_locked(worker_ref, lease_seconds, exclude, passed_over + 1)
        end
    end
  end

  defp candidate(now, exclude), do: Repo.one(Cleanup.Query.next_candidate(now, exclude))

  defp lock_owner(kind, id, lock) when kind in [:work, :learning, :improvement, :knowledge],
    do: kind |> Cleanup.Query.owner(id) |> Cleanup.Query.lock_owner(lock) |> Repo.one()

  # A routing session started ahead of time has no message until one claims
  # it. Until then the pool owns it, and the session's own state says whether
  # the pool gave it up; the session row is locked right after.
  defp lock_owner(:admission, nil, _lock), do: :ready_pool

  defp lock_owner(:admission, input_id, lock) do
    :admission
    |> Cleanup.Query.owner(input_id)
    |> Cleanup.Query.lock_owner(lock)
    |> Repo.one()
  end

  defp lock_owner(_, _, _), do: nil

  defp lock_identity_owner({kind, id}) when not is_nil(id), do: lock_owner(kind, id, :wait)
  defp lock_identity_owner({:admission, nil}), do: lock_owner(:admission, nil, :wait)
  defp lock_identity_owner(_identity), do: nil

  defp lock_session(session_id),
    do: session_id |> Session.Query.by_id() |> Session.Query.lock_for_update() |> Repo.one()

  defp claimable?(owner, session, now) do
    owner_finished?(owner, session) and
      not unfinished_turn?(session.id) and
      not unpublished_publication?(session.id) and
      lease_free?(session, now) and
      claimable_status?(session, now)
  end

  defp owner_finished?(%Episode{state: state}, session),
    do: state in @terminal_episode_states or replaced_work_session?(session)

  defp owner_finished?(%LearningRun{remote_stopped_at: %DateTime{}}, _session), do: true
  defp owner_finished?(%AnalysisRun{remote_stopped_at: %DateTime{}}, _session), do: true
  defp owner_finished?(%KnowledgeRun{remote_stopped_at: %DateTime{}}, _session), do: true

  defp owner_finished?(%Entry{status: status}, _session)
       when status in [:decided, :superseded],
       do: true

  defp owner_finished?(%Entry{execution_generation: current}, %Session{generation: generation}),
    do: current > generation

  defp owner_finished?(:ready_pool, %Session{ready_state: :retired, admission_input_id: nil}),
    do: true

  defp owner_finished?(_owner, _session), do: false

  defp replaced_work_session?(%Session{execution_kind: :work} = session),
    do: Repo.exists?(Session.Query.newer_work_sessions(session))

  defp replaced_work_session?(_session), do: false

  defp lease_free?(%Session{cleanup_lease_ref: nil}, _now), do: true

  defp lease_free?(%Session{cleanup_lease_expires_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  defp lease_free?(_session, _now), do: false

  defp claimable_status?(%Session{cleanup_status: :active}, _now), do: true

  defp claimable_status?(%Session{cleanup_status: status} = session, now)
       when status in @pending_statuses do
    is_nil(session.cleanup_next_attempt_at) or
      DateTime.compare(session.cleanup_next_attempt_at, now) != :gt
  end

  defp claimable_status?(%Session{cleanup_status: :grace, discard_after: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  defp claimable_status?(
         %Session{cleanup_status: :retained, retained_reason: "unpublished_unmerged"} = session,
         _now
       ),
       do: published?(session)

  defp claimable_status?(
         %Session{
           cleanup_status: :retained,
           cleanup_next_attempt_at: %DateTime{} = at,
           retained_reason: "dirty"
         },
         now
       ),
       do: DateTime.compare(at, now) != :gt

  defp claimable_status?(_session, _now), do: false

  defp prepare_phase(%Session{cleanup_status: :active} = session),
    do: persist(session, %{cleanup_status: :close_pending})

  defp prepare_phase(%Session{cleanup_status: :grace} = session),
    do: persist(session, %{cleanup_status: :close_pending})

  defp prepare_phase(%Session{cleanup_status: :retained} = session) do
    persist(session, %{
      cleanup_status: :plan_pending,
      discard_plan: nil,
      discard_plan_accept_unmerged: false,
      discard_plan_expected_revision: nil,
      discard_plan_fingerprint: nil,
      discard_plan_generation: session.discard_plan_generation + 1,
      discard_plan_operation_id: nil,
      retained_reason: nil
    })
  end

  defp prepare_phase(%Session{} = session), do: session

  defp unfinished_turn?(session_id),
    do: session_id |> Turn.Query.by_session_id() |> Turn.Query.unfinished() |> Repo.exists?()

  defp unpublished_publication?(session_id) do
    session_id
    |> Publication.Query.by_session_id()
    |> Publication.Query.unpublished()
    |> Repo.exists?()
  end

  defp store_plan_locked(session, plan, now, retained_recheck_seconds) do
    cond do
      plan["session_id"] != session.coop_session_id ->
        Repo.rollback(:retention_plan_session_mismatch)

      plan["revision"] != session.discard_plan_expected_revision ->
        Repo.rollback(:retention_plan_revision_mismatch)

      not is_binary(plan["operation_id"]) ->
        Repo.rollback(:retention_plan_operation_missing)

      true ->
        fingerprint = CanonicalJSON.digest(plan)
        workspace = plan["workspace"]

        {status, retained_reason} =
          cond do
            workspace["dirty"] -> {:retained, "dirty"}
            not Plan.discardable?(plan) -> {:retained, "unpublished_unmerged"}
            true -> {:discard_pending, nil}
          end

        # A workspace that is dirty today may be clean tomorrow. Schedule the
        # next fresh plan so the only way out of retention is new evidence.
        recheck_at =
          if retained_reason == "dirty",
            do: DateTime.add(now, retained_recheck_seconds, :second),
            else: nil

        persist(session, %{
          cleanup_attempt_count: 0,
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: recheck_at,
          cleanup_status: status,
          discard_plan: plan,
          discard_plan_fingerprint: fingerprint,
          discard_plan_operation_id: plan["operation_id"],
          retained_reason: retained_reason
        })
    end
  end

  # A discarded session has nothing left on any worker, so its placement ends
  # with it; otherwise the worker renews it on every poll, for good.
  defp settle(session, receipt, now) do
    :ok = FleetControlPlane.retire_session_placements(session.id, now)

    persist(session, %{
      cleanup_attempt_count: 0,
      cleanup_last_error_code: nil,
      cleanup_last_error_detail: nil,
      cleanup_lease_expires_at: nil,
      cleanup_lease_owner: nil,
      cleanup_lease_ref: nil,
      cleanup_next_attempt_at: nil,
      cleanup_receipt: receipt,
      cleanup_receipt_fingerprint: CanonicalJSON.digest(receipt),
      cleanup_status: :discarded,
      discarded_at: now,
      retained_reason: nil
    })
  end

  defp freeze_close_locked(%Session{close_expected_revision: nil} = session, revision),
    do: persist(session, %{close_expected_revision: revision})

  defp freeze_close_locked(%Session{close_expected_revision: revision} = session, revision),
    do: session

  defp freeze_close_locked(session, _revision),
    do: Repo.rollback({:retention_close_revision_conflict, session.close_expected_revision})

  defp freeze_plan_locked(
         %Session{discard_plan_expected_revision: nil} = session,
         revision,
         accept_unmerged
       ) do
    persist(session, %{
      discard_plan_accept_unmerged: accept_unmerged,
      discard_plan_expected_revision: revision
    })
  end

  defp freeze_plan_locked(
         %Session{
           discard_plan_accept_unmerged: accept_unmerged,
           discard_plan_expected_revision: revision
         } = session,
         revision,
         accept_unmerged
       ),
       do: session

  defp freeze_plan_locked(session, _revision, _accept_unmerged),
    do: Repo.rollback({:retention_plan_revision_conflict, session.discard_plan_expected_revision})

  # Ryker never learned a worker session for it, which is not proof the
  # worker made none: a create can succeed after its answer is lost.
  defp settle_absent_locked(%Session{coop_session_id: nil} = session, now) do
    receipt = %{
      "kind" => "never_bound",
      "local_session_id" => session.id,
      "remote_session_id" => nil,
      "remote_state" => "unknown"
    }

    settle(session, receipt, now)
  end

  defp settle_absent_locked(_session, _now),
    do: Repo.rollback(:retention_remote_session_bound)

  defp settle_discard_locked(session, operation_key, remote_session_id, now) do
    cond do
      session.coop_session_id != remote_session_id ->
        Repo.rollback(:retention_remote_session_mismatch)

      operation_key != discard_key(session) ->
        Repo.rollback(:retention_discard_operation_mismatch)

      true ->
        receipt = %{
          "kind" => "discarded",
          "local_session_id" => session.id,
          "operation_key" => operation_key,
          "remote_session_id" => remote_session_id,
          "remote_state" => "discarded"
        }

        settle(session, receipt, now)
    end
  end

  defp settle_remote_discarded_locked(
         %Session{coop_session_id: remote_session_id} = session,
         remote_session_id,
         now
       ) do
    receipt = %{
      "kind" => "already_discarded",
      "local_session_id" => session.id,
      "remote_session_id" => remote_session_id,
      "remote_state" => "discarded"
    }

    settle(session, receipt, now)
  end

  defp settle_remote_discarded_locked(_session, _remote_session_id, _now),
    do: Repo.rollback(:retention_remote_session_mismatch)

  defp settle_remote_absent_locked(
         %Session{coop_session_id: remote_session_id} = session,
         remote_session_id,
         now
       ) do
    receipt = %{
      "kind" => "remote_absent",
      "local_session_id" => session.id,
      "remote_session_id" => remote_session_id,
      "remote_state" => "absent"
    }

    settle(session, receipt, now)
  end

  defp settle_remote_absent_locked(_session, _remote_session_id, _now),
    do: Repo.rollback(:retention_remote_session_mismatch)

  defp settle_worker_removed_locked(session, now) do
    case holding_worker(session.id) do
      %FleetWorker{} = worker when worker.state == :revoked or not is_nil(worker.revoked_at) ->
        receipt = %{
          "kind" => "worker_removed",
          "local_session_id" => session.id,
          "remote_session_id" => session.coop_session_id,
          "remote_state" => "unreachable",
          "worker_id" => worker.id
        }

        settle(session, receipt, now)

      %FleetWorker{id: worker_id} ->
        Repo.rollback({:retention_worker_unavailable, worker_id})

      nil ->
        Repo.rollback({:retention_worker_unavailable, nil})
    end
  end

  # Cleanup runs only on the worker a session was last placed on: a bound
  # session is never placed anywhere else.
  defp holding_worker(session_id) do
    session_id
    |> Placement.Query.by_session_id()
    |> Placement.Query.with_joined_worker()
    |> Placement.Query.ordered_by_generation_desc()
    |> Placement.Query.limit_to(1)
    |> Placement.Query.select_workers()
    |> Repo.one()
  end

  defp advance_generation(session_id, lease_ref, status, field, generation, reset) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(generation, :generation) do
      update_leased(session_id, lease_ref, status, fn session, _now ->
        advance_generation_locked(session, field, generation, reset)
      end)
    end
  end

  defp advance_generation_locked(session, field, generation, reset) do
    case Map.fetch!(session, field) do
      ^generation -> persist(session, Map.merge(reset, %{field => generation + 1}))
      current -> Repo.rollback({:retention_generation_conflict, current})
    end
  end

  defp update_leased(session_id, lease_ref, statuses, callback) do
    statuses = List.wrap(statuses)

    Repo.transaction(fn ->
      {session, now} = leased!(session_id, lease_ref, statuses)
      callback.(session, now)
    end)
  end

  defp leased!(session_id, lease_ref, statuses) do
    identity = Repo.one(Cleanup.Query.owner_identity(session_id))

    owner = lock_identity_owner(identity)
    if is_nil(owner), do: Repo.rollback(:retention_session_not_found)

    session =
      session_id |> Session.Query.by_id() |> Session.Query.lock_for_update() |> Repo.one!()

    now = Repo.now!()

    if owner_finished?(owner, session) and session.cleanup_status in statuses and
         Lease.held?(session.cleanup_lease_ref, session.cleanup_lease_expires_at, lease_ref, now) do
      {session, now}
    else
      Repo.rollback(:retention_lease_lost)
    end
  end

  @doc """
  Saves a cleanup change to a session, checked and announced. Every cleanup
  change is stamped by the database clock: a returning worker's report
  (`last_seen_at`) is compared with it, and a host clock running ahead made a
  report a few milliseconds later look older. An operator's rearm or discard
  (`Ryker.Operator.Retention`) is saved the same way.
  """
  @spec persist(Session.t(), map()) :: Session.t()
  def persist(session, attributes) do
    session
    |> Session.Changeset.cleanup(Map.put_new(attributes, :updated_at, Repo.now!()))
    |> Repo.update()
    |> case do
      {:ok, stored} -> tap(stored, &WorkCustody.broadcast_session_updated/1)
      {:error, changeset} -> Repo.rollback({:retention_persistence_failed, changeset})
    end
  end

  defp uuid(value, _field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_retention_custody, :uuid}}
    end
  end

  defp uuid(_value, field), do: {:error, {:invalid_retention_custody, field}}

  defp uuids(values, field) when is_list(values) and length(values) <= 1_000 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, prepared} ->
      case uuid(value, field) do
        {:ok, cast} -> {:cont, {:ok, [cast | prepared]}}
        {:error, _reason} -> {:halt, {:error, {:invalid_retention_custody, field}}}
      end
    end)
  end

  defp uuids(_values, field), do: {:error, {:invalid_retention_custody, field}}

  defp exclusions(exclude) when is_list(exclude) do
    if Keyword.keyword?(exclude) and Keyword.keys(exclude) -- [:session_ids, :worker_ids] == [] do
      worker_ids = Keyword.get(exclude, :worker_ids, [])

      with {:ok, session_ids} <- uuids(Keyword.get(exclude, :session_ids, []), :session_ids),
           true <-
             is_list(worker_ids) and length(worker_ids) <= 1_000 and
               Enum.all?(worker_ids, &(reference(&1, :worker_ids) == :ok)) do
        {:ok, %{session_ids: session_ids, worker_ids: worker_ids}}
      else
        false -> {:error, {:invalid_retention_custody, :worker_ids}}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:invalid_retention_custody, :exclude}}
    end
  end

  defp exclusions(_exclude), do: {:error, {:invalid_retention_custody, :exclude}}

  defp reference(value, field), do: Reference.check(value, field, :invalid_retention_custody)

  defp bounded_text(value, maximum, field),
    do: Reference.check(value, field, :invalid_retention_custody, maximum)

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_retention_custody, field}}

  defp nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp nonnegative_integer(_value, field),
    do: {:error, {:invalid_retention_custody, field}}

  defp boolean(value, _field) when is_boolean(value), do: :ok
  defp boolean(_value, field), do: {:error, {:invalid_retention_custody, field}}
end

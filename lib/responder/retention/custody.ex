defmodule Responder.Retention.Custody do
  @moduledoc """
  PostgreSQL custody for exact Coop session cleanup.

  Cleanup is eligible only after the owning episode and every local Work turn
  are terminal, or the owning learning run has exact remote stop proof, and no
  unpublished publication still depends on the session.
  Durable state records and episode history may outlive the remote workspace;
  their independent retention rules preserve them. PostgreSQL time and opaque
  leases provide the fleet fence; remote calls never run in these transactions.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Retention.Plan
  alias Responder.State.LearningRun
  alias Responder.Work.{Session, Turn}

  @pending_statuses [:close_pending, :plan_pending, :discard_pending]
  @terminal_episode_states [:complete, :cancelled]
  @unfinished_turn_statuses [:pending, :cancel_pending, :delivery_pending]

  @type claim :: %{
          owner: Episode.t() | LearningRun.t(),
          lease_ref: String.t(),
          session: Session.t()
        }

  @spec claim_next(String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds, closed_session_grace_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds),
         :ok <- nonnegative_integer(closed_session_grace_seconds, :closed_session_grace_seconds) do
      Repo.transaction(fn ->
        claim_locked(worker_ref, lease_seconds, closed_session_grace_seconds)
      end)
      |> transaction_result()
    end
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

  @spec mark_closed(Ecto.UUID.t(), String.t(), non_neg_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def mark_closed(session_id, lease_ref, grace_seconds) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- nonnegative_integer(grace_seconds, :grace_seconds) do
      update_leased(session_id, lease_ref, :close_pending, fn session, now ->
        closed_at = session.closed_at || now

        persist(session, %{
          cleanup_last_error_code: nil,
          cleanup_last_error_detail: nil,
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: nil,
          cleanup_status: :grace,
          closed_at: closed_at,
          discard_after: DateTime.add(closed_at, grace_seconds, :second)
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

  @spec store_plan(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, term()}
  def store_plan(session_id, lease_ref, plan) do
    with {:ok, session_id} <- uuid(session_id, :session_id),
         :ok <- reference(lease_ref, :lease_ref),
         true <- is_map(plan) or {:error, {:invalid_retention_custody, :plan}} do
      update_leased(session_id, lease_ref, :plan_pending, fn session, _now ->
        store_plan_locked(session, plan)
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
    do: "responder:retention:close:#{session.id}:g#{session.close_generation}"

  @spec plan_key(Session.t()) :: String.t()
  def plan_key(%Session{} = session),
    do: "responder:retention:plan:#{session.id}:g#{session.discard_plan_generation}"

  @spec discard_key(Session.t()) :: String.t()
  def discard_key(%Session{} = session),
    do: "responder:retention:discard:#{session.id}:g#{session.discard_generation}"

  @spec published?(Session.t()) :: boolean()
  def published?(%Session{} = session) do
    Repo.exists?(
      from(publication in Publication,
        where: publication.session_id == ^session.id and publication.status == :published
      )
    ) and
      not Repo.exists?(
        from(publication in Publication,
          where: publication.session_id == ^session.id and publication.status != :published
        )
      )
  end

  defp claim_locked(worker_ref, lease_seconds, grace_seconds) do
    now = database_now!()

    case candidate(now) do
      nil ->
        nil

      {kind, owner_id, session_id} ->
        with owner when not is_nil(owner) <- lock_owner(kind, owner_id, :skip_locked),
             %Session{} = session <- lock_session(session_id),
             true <- claimable?(owner, session, now) do
          session = prepare_phase(session, grace_seconds)
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

          %{owner: owner, lease_ref: lease_ref, session: claimed}
        else
          _not_claimable -> nil
        end
    end
  end

  defp candidate(now) do
    now
    |> candidate_query()
    |> Repo.one()
  end

  defp candidate_query(now) do
    unfinished_session_ids = unfinished_session_ids()
    unpublished_session_ids = unpublished_session_ids()
    cleanup_status = cleanup_status_filter(now)

    from(session in Session,
      left_join: episode in Episode,
      on: episode.id == session.episode_id,
      left_join: learning in LearningRun,
      on: learning.id == session.learning_run_id,
      where:
        (session.execution_kind == :work and episode.state in ^@terminal_episode_states) or
          (session.execution_kind == :learning and not is_nil(learning.remote_stopped_at)),
      where: session.id not in subquery(unfinished_session_ids),
      where: session.id not in subquery(unpublished_session_ids),
      where: ^cleanup_status,
      order_by: [asc: session.inserted_at, asc: session.id],
      select:
        {session.execution_kind,
         type(
           fragment("COALESCE(?, ?)", session.episode_id, session.learning_run_id),
           :binary_id
         ), session.id},
      limit: 1
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

  defp cleanup_status_filter(now) do
    pending = pending_status_filter(now)
    retained = retained_status_filter()

    dynamic(
      [session, _episode],
      session.cleanup_status == :active or ^pending or
        (session.cleanup_status == :grace and session.discard_after <= ^now) or ^retained
    )
  end

  defp pending_status_filter(now) do
    dynamic(
      [session, _episode],
      session.cleanup_status in ^@pending_statuses and
        (is_nil(session.cleanup_next_attempt_at) or session.cleanup_next_attempt_at <= ^now) and
        (is_nil(session.cleanup_lease_ref) or session.cleanup_lease_expires_at <= ^now)
    )
  end

  defp retained_status_filter do
    published_session_ids =
      from(publication in Publication,
        where: publication.status == :published,
        select: publication.session_id
      )

    dynamic(
      [session, _episode],
      session.cleanup_status == :retained and
        session.retained_reason == "unpublished_unmerged" and
        session.id in subquery(published_session_ids)
    )
  end

  defp lock_owner(:work, episode_id, lock),
    do: lock_owner_query(from(e in Episode, where: e.id == ^episode_id), lock)

  defp lock_owner(:learning, run_id, lock),
    do: lock_owner_query(from(run in LearningRun, where: run.id == ^run_id), lock)

  defp lock_owner(_, _, _), do: nil

  defp lock_owner_query(query, :skip_locked),
    do: Repo.one(from(q in query, lock: "FOR UPDATE SKIP LOCKED"))

  defp lock_owner_query(query, :wait), do: Repo.one(from(q in query, lock: "FOR UPDATE"))

  defp lock_session(session_id) do
    Repo.one(from(session in Session, where: session.id == ^session_id, lock: "FOR UPDATE"))
  end

  defp claimable?(owner, session, now) do
    owner_finished?(owner) and
      not unfinished_turn?(session.id) and
      not unpublished_publication?(session.id) and
      claimable_status?(session, now)
  end

  defp owner_finished?(%Episode{state: state}), do: state in @terminal_episode_states
  defp owner_finished?(%LearningRun{remote_stopped_at: %DateTime{}}), do: true
  defp owner_finished?(_), do: false

  defp claimable_status?(%Session{cleanup_status: :active}, _now), do: true

  defp claimable_status?(%Session{cleanup_status: status} = session, now)
       when status in @pending_statuses do
    (is_nil(session.cleanup_next_attempt_at) or
       DateTime.compare(session.cleanup_next_attempt_at, now) != :gt) and
      (is_nil(session.cleanup_lease_ref) or
         DateTime.compare(session.cleanup_lease_expires_at, now) != :gt)
  end

  defp claimable_status?(%Session{cleanup_status: :grace, discard_after: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  defp claimable_status?(
         %Session{cleanup_status: :retained, retained_reason: "unpublished_unmerged"} = session,
         _now
       ),
       do: published?(session)

  defp claimable_status?(_session, _now), do: false

  defp prepare_phase(%Session{cleanup_status: :active} = session, _grace_seconds),
    do: persist(session, %{cleanup_status: :close_pending})

  defp prepare_phase(%Session{cleanup_status: :grace} = session, _grace_seconds),
    do: persist(session, %{cleanup_status: :plan_pending})

  defp prepare_phase(
         %Session{cleanup_status: :retained, retained_reason: "unpublished_unmerged"} = session,
         _grace_seconds
       ) do
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

  defp prepare_phase(%Session{} = session, _grace_seconds), do: session

  defp unfinished_turn?(session_id) do
    Repo.exists?(
      from(turn in Turn,
        where: turn.session_id == ^session_id and turn.status in ^@unfinished_turn_statuses
      )
    )
  end

  defp unpublished_publication?(session_id) do
    Repo.exists?(
      from(publication in Publication,
        where: publication.session_id == ^session_id and publication.status != :published
      )
    )
  end

  defp store_plan_locked(session, plan) do
    cond do
      plan["session_id"] != session.coop_session_id ->
        Repo.rollback(:retention_plan_session_mismatch)

      plan["revision"] != session.discard_plan_expected_revision ->
        Repo.rollback(:retention_plan_revision_mismatch)

      not is_binary(plan["operation_id"]) ->
        Repo.rollback(:retention_plan_operation_missing)

      true ->
        fingerprint = fingerprint(plan)
        workspace = plan["workspace"]

        {status, retained_reason} =
          cond do
            workspace["dirty"] -> {:retained, "dirty"}
            not Plan.discardable?(plan) -> {:retained, "unpublished_unmerged"}
            true -> {:discard_pending, nil}
          end

        persist(session, %{
          cleanup_lease_expires_at: nil,
          cleanup_lease_owner: nil,
          cleanup_lease_ref: nil,
          cleanup_next_attempt_at: nil,
          cleanup_status: status,
          discard_plan: plan,
          discard_plan_fingerprint: fingerprint,
          discard_plan_operation_id: plan["operation_id"],
          retained_reason: retained_reason
        })
    end
  end

  defp settle(session, receipt, now) do
    persist(session, %{
      cleanup_last_error_code: nil,
      cleanup_last_error_detail: nil,
      cleanup_lease_expires_at: nil,
      cleanup_lease_owner: nil,
      cleanup_lease_ref: nil,
      cleanup_next_attempt_at: nil,
      cleanup_receipt: receipt,
      cleanup_receipt_fingerprint: fingerprint(receipt),
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

  defp settle_absent_locked(%Session{coop_session_id: nil} = session, now) do
    receipt = %{
      "kind" => "never_bound",
      "local_session_id" => session.id,
      "remote_session_id" => nil,
      "remote_state" => "absent"
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
    |> transaction_result()
  end

  defp leased!(session_id, lease_ref, statuses) do
    identity =
      Repo.one(
        from(session in Session,
          where: session.id == ^session_id,
          select:
            {session.execution_kind,
             type(
               fragment("COALESCE(?, ?)", session.episode_id, session.learning_run_id),
               :binary_id
             )}
        )
      )

    owner =
      case identity do
        {kind, id} when not is_nil(id) -> lock_owner(kind, id, :wait)
        _ -> nil
      end

    if is_nil(owner), do: Repo.rollback(:retention_session_not_found)

    session =
      Repo.one!(from(session in Session, where: session.id == ^session_id, lock: "FOR UPDATE"))

    now = database_now!()

    if owner_finished?(owner) and session.cleanup_status in statuses and
         session.cleanup_lease_ref == lease_ref and
         match?(%DateTime{}, session.cleanup_lease_expires_at) and
         DateTime.compare(session.cleanup_lease_expires_at, now) == :gt do
      {session, now}
    else
      Repo.rollback(:retention_lease_lost)
    end
  end

  defp persist(session, attributes) do
    session
    |> Ecto.Changeset.change(attributes)
    |> Ecto.Changeset.check_constraint(:cleanup_status,
      name: :episode_work_session_cleanup_state_valid
    )
    |> Ecto.Changeset.check_constraint(:cleanup_lease_ref,
      name: :episode_work_session_cleanup_lease_valid
    )
    |> Ecto.Changeset.check_constraint(:discard_plan,
      name: :episode_work_session_discard_plan_valid
    )
    |> Ecto.Changeset.check_constraint(:cleanup_receipt,
      name: :episode_work_session_cleanup_receipt_valid
    )
    |> Ecto.Changeset.check_constraint(:cleanup_blocked_from,
      name: :episode_work_session_cleanup_blocked_valid
    )
    |> Repo.update()
    |> case do
      {:ok, stored} -> stored
      {:error, changeset} -> Repo.rollback({:retention_persistence_failed, changeset})
    end
  end

  defp fingerprint(document) do
    document
    |> CanonicalJSON.encode!()
    |> then(fn bytes -> :crypto.hash(:sha256, bytes) end)
    |> Base.encode16(case: :lower)
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp uuid(value, _field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_retention_custody, :uuid}}
    end
  end

  defp uuid(_value, field), do: {:error, {:invalid_retention_custody, field}}

  defp reference(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_retention_custody, :reference}}
  end

  defp reference(_value, field), do: {:error, {:invalid_retention_custody, field}}

  defp bounded_text(value, maximum, _field) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..maximum,
      do: :ok,
      else: {:error, {:invalid_retention_custody, :text}}
  end

  defp bounded_text(_value, _maximum, field),
    do: {:error, {:invalid_retention_custody, field}}

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_retention_custody, field}}

  defp nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp nonnegative_integer(_value, field),
    do: {:error, {:invalid_retention_custody, field}}

  defp boolean(value, _field) when is_boolean(value), do: :ok
  defp boolean(_value, field), do: {:error, {:invalid_retention_custody, field}}
end

defmodule Ryker.Operator.Retention do
  @moduledoc """
  Audited local-operator recovery for retained Coop cleanup custody.

  Rearm restores the exact cleanup phase captured when automation blocked. An
  explicit unmerged discard never skips Coop review: it clears the old plan and
  asks Coop for a fresh plan with unmerged acceptance. Dirty work is never an
  eligible operator discard.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Operator.{Actions, RetentionAction}
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Retention
  alias Ryker.Work

  @pending_statuses [:close_pending, :plan_pending, :discard_pending]

  @spec rearm(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rearm(session_ref, actor_ref, action_ref),
    do: change(:rearm, session_ref, nil, actor_ref, action_ref)

  @spec discard_unmerged(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def discard_unmerged(session_ref, actor_ref, action_ref),
    do: change(:discard_unmerged, session_ref, nil, actor_ref, action_ref)

  @spec discard_unmerged(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def discard_unmerged(session_ref, expected_plan_fingerprint, actor_ref, action_ref) do
    change(
      :discard_unmerged,
      session_ref,
      expected_plan_fingerprint,
      actor_ref,
      action_ref
    )
  end

  defp change(action, session_ref, expected_plan_fingerprint, actor_ref, action_ref) do
    with :ok <- reference(session_ref, :session_ref),
         :ok <- optional_fingerprint(expected_plan_fingerprint),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(action_ref, :action_ref) do
      request = %{
        "action" => Atom.to_string(action),
        "actor_ref" => actor_ref,
        "session_ref" => session_ref
      }

      request =
        if is_binary(expected_plan_fingerprint),
          do: Map.put(request, "expected_plan_fingerprint", expected_plan_fingerprint),
          else: request

      request_fingerprint = CanonicalJSON.digest(request)

      Repo.transaction(fn ->
        change_locked(
          action,
          session_ref,
          expected_plan_fingerprint,
          actor_ref,
          action_ref,
          request_fingerprint
        )
      end)
    end
  end

  defp change_locked(
         action,
         session_ref,
         expected_plan_fingerprint,
         actor_ref,
         action_ref,
         fingerprint
       ) do
    AdvisoryLock.hold!(action_ref)

    locked =
      action_ref
      |> RetentionAction.Query.by_action_ref()
      |> RetentionAction.Query.lock_for_update()

    case Repo.one(locked) do
      %RetentionAction{request_fingerprint: ^fingerprint} = entry ->
        session = Repo.one!(Work.Session.Query.by_id(entry.session_id))
        %{action: entry, outcome: :duplicate, session: session}

      %RetentionAction{} ->
        Repo.rollback(:retention_operator_action_conflict)

      nil ->
        session =
          session_ref
          |> Work.Session.Query.by_external_ref()
          |> Work.Session.Query.lock_for_update()
          |> Repo.one() || Repo.rollback(:retention_session_not_found)

        {outcome, previous_status, previous_plan_fingerprint, updated} =
          transition(action, session, expected_plan_fingerprint)

        entry =
          insert_action!(
            updated,
            action,
            actor_ref,
            action_ref,
            fingerprint,
            previous_status,
            previous_plan_fingerprint
          )

        %{action: entry, outcome: outcome, session: updated}
    end
  end

  defp transition(:rearm, %Work.Session{cleanup_status: :blocked} = session, nil)
       when session.cleanup_blocked_from in @pending_statuses do
    previous_status = session.cleanup_status

    updated =
      Retention.Custody.persist(session, %{
        cleanup_attempt_count: 0,
        cleanup_blocked_from: nil,
        cleanup_last_error_code: nil,
        cleanup_last_error_detail: nil,
        cleanup_lease_expires_at: nil,
        cleanup_lease_owner: nil,
        cleanup_lease_ref: nil,
        # Due now, and due from now: readiness ages a resumed step from here.
        cleanup_next_attempt_at: Repo.now!(),
        cleanup_status: session.cleanup_blocked_from
      })

    {:rearmed, previous_status, session.discard_plan_fingerprint, updated}
  end

  defp transition(:rearm, %Work.Session{cleanup_status: :blocked}, nil),
    do: Repo.rollback(:retention_blocked_phase_unknown)

  defp transition(:rearm, %Work.Session{}, nil),
    do: Repo.rollback(:retention_cleanup_not_blocked)

  defp transition(:discard_unmerged, %Work.Session{retained_reason: "dirty"}, _expected),
    do: Repo.rollback(:retention_dirty_workspace)

  defp transition(
         :discard_unmerged,
         %Work.Session{
           cleanup_status: :retained,
           discard_plan: %{"workspace" => workspace},
           discard_plan_fingerprint: fingerprint,
           retained_reason: "unpublished_unmerged"
         } = session,
         expected_plan_fingerprint
       )
       when is_map(workspace) and is_binary(fingerprint) do
    cond do
      is_binary(expected_plan_fingerprint) and expected_plan_fingerprint != fingerprint ->
        Repo.rollback(:retention_discard_plan_stale)

      workspace["dirty"] == true ->
        Repo.rollback(:retention_dirty_workspace)

      workspace["unmerged"] != true ->
        Repo.rollback(:retention_unmerged_plan_missing)

      true ->
        updated =
          Retention.Custody.persist(session, %{
            cleanup_attempt_count: 0,
            cleanup_blocked_from: nil,
            cleanup_last_error_code: nil,
            cleanup_last_error_detail: nil,
            cleanup_lease_expires_at: nil,
            cleanup_lease_owner: nil,
            cleanup_lease_ref: nil,
            # Due now, and due from now: readiness ages the decision from here.
            cleanup_next_attempt_at: Repo.now!(),
            cleanup_status: :plan_pending,
            discard_plan: nil,
            discard_plan_accept_unmerged: true,
            discard_plan_expected_revision: nil,
            discard_plan_fingerprint: nil,
            discard_plan_generation: session.discard_plan_generation + 1,
            discard_plan_operation_id: nil,
            retained_reason: nil
          })

        {:discard_requested, :retained, fingerprint, updated}
    end
  end

  defp transition(:discard_unmerged, %Work.Session{}, _expected_plan_fingerprint),
    do: Repo.rollback(:retention_unmerged_discard_unavailable)

  defp insert_action!(
         session,
         action,
         actor_ref,
         action_ref,
         fingerprint,
         previous_status,
         previous_plan_fingerprint
       ) do
    occurred_at = Repo.now!()

    %{
      id: Repo.generate_id(),
      session_id: session.id,
      action_ref: action_ref,
      request_fingerprint: fingerprint,
      actor_ref: actor_ref,
      action: action,
      previous_status: previous_status,
      result_status: session.cleanup_status,
      previous_plan_fingerprint: previous_plan_fingerprint,
      occurred_at: occurred_at
    }
    |> RetentionAction.Changeset.insert()
    |> Repo.insert!()
    |> tap(&Actions.broadcast_action_recorded(&1.id))
  end

  defp reference(value, _field) when is_binary(value) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_retention_operator, :reference}}
  end

  defp reference(_value, field), do: {:error, {:invalid_retention_operator, field}}

  defp optional_fingerprint(nil), do: :ok

  defp optional_fingerprint(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_retention_operator, :expected_plan_fingerprint}}
  end

  defp optional_fingerprint(_value),
    do: {:error, {:invalid_retention_operator, :expected_plan_fingerprint}}
end

defmodule Responder.Retention.Operator do
  @moduledoc """
  Audited local-operator recovery for retained Coop cleanup custody.

  Rearm restores the exact cleanup phase captured when automation blocked. An
  explicit unmerged discard never skips Coop review: it clears the old plan and
  asks Coop for a fresh plan with unmerged acceptance. Dirty work is never an
  eligible operator discard.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Repo
  alias Responder.Retention.OperatorAction
  alias Responder.Work.Session

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
  def discard_unmerged(session_ref, expected_plan_fingerprint, actor_ref, action_ref),
    do:
      change(
        :discard_unmerged,
        session_ref,
        expected_plan_fingerprint,
        actor_ref,
        action_ref
      )

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
      |> transaction_result()
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
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [action_ref])

    case Repo.one(
           from(entry in OperatorAction,
             where: entry.action_ref == ^action_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %OperatorAction{request_fingerprint: ^fingerprint} = entry ->
        session = Repo.get!(Session, entry.session_id)
        %{action: entry, outcome: :duplicate, session: session}

      %OperatorAction{} ->
        Repo.rollback(:retention_operator_action_conflict)

      nil ->
        session =
          Repo.one(
            from(session in Session,
              where: session.external_ref == ^session_ref,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:retention_session_not_found)

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

  defp transition(:rearm, %Session{cleanup_status: :blocked} = session, nil)
       when session.cleanup_blocked_from in @pending_statuses do
    previous_status = session.cleanup_status

    updated =
      persist(session, %{
        cleanup_attempt_count: 0,
        cleanup_blocked_from: nil,
        cleanup_last_error_code: nil,
        cleanup_last_error_detail: nil,
        cleanup_lease_expires_at: nil,
        cleanup_lease_owner: nil,
        cleanup_lease_ref: nil,
        cleanup_next_attempt_at: nil,
        cleanup_status: session.cleanup_blocked_from
      })

    {:rearmed, previous_status, session.discard_plan_fingerprint, updated}
  end

  defp transition(:rearm, %Session{cleanup_status: :blocked}, nil),
    do: Repo.rollback(:retention_blocked_phase_unknown)

  defp transition(:rearm, %Session{}, nil),
    do: Repo.rollback(:retention_cleanup_not_blocked)

  defp transition(:discard_unmerged, %Session{retained_reason: "dirty"}, _expected),
    do: Repo.rollback(:retention_dirty_workspace)

  defp transition(
         :discard_unmerged,
         %Session{
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
          persist(session, %{
            cleanup_attempt_count: 0,
            cleanup_blocked_from: nil,
            cleanup_last_error_code: nil,
            cleanup_last_error_detail: nil,
            cleanup_lease_expires_at: nil,
            cleanup_lease_owner: nil,
            cleanup_lease_ref: nil,
            cleanup_next_attempt_at: nil,
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

  defp transition(:discard_unmerged, %Session{}, _expected_plan_fingerprint),
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
    occurred_at = database_now!()

    %OperatorAction{}
    |> Ecto.Changeset.cast(
      %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        action_ref: action_ref,
        request_fingerprint: fingerprint,
        actor_ref: actor_ref,
        action: action,
        previous_status: previous_status,
        result_status: session.cleanup_status,
        previous_plan_fingerprint: previous_plan_fingerprint,
        occurred_at: occurred_at
      },
      [
        :id,
        :session_id,
        :action_ref,
        :request_fingerprint,
        :actor_ref,
        :action,
        :previous_status,
        :result_status,
        :previous_plan_fingerprint,
        :occurred_at
      ]
    )
    |> Ecto.Changeset.validate_required([
      :id,
      :session_id,
      :action_ref,
      :request_fingerprint,
      :actor_ref,
      :action,
      :previous_status,
      :result_status,
      :occurred_at
    ])
    |> Ecto.Changeset.validate_length(:action_ref, min: 1, max: 1_024)
    |> Ecto.Changeset.validate_length(:actor_ref, min: 1, max: 1_024)
    |> Ecto.Changeset.validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> Ecto.Changeset.unique_constraint(:action_ref)
    |> Ecto.Changeset.foreign_key_constraint(:session_id)
    |> Ecto.Changeset.check_constraint(:action_ref, name: :retention_operator_action_valid)
    |> Repo.insert!()
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
    |> Ecto.Changeset.check_constraint(:cleanup_blocked_from,
      name: :episode_work_session_cleanup_blocked_valid
    )
    |> Repo.update!()
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp reference(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_retention_operator, :reference}}
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

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end

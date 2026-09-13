defmodule Ryker.CoopFleet.WorkerLifecycle do
  @moduledoc """
  Operator-owned drain, resume, and revocation custody for one Coop worker.

  Drain stops new placement while allowing already leased work to finish.
  Revocation immediately invalidates central placement/state authority, every
  client certificate, and every unused enrollment token. The first operator
  decision remains the durable audit identity on exact retries.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.CoopFleet.{Certificate, EnrollmentToken, Placement, Protocol, Worker}
  alias Ryker.Repo

  @type result :: %{status: :draining | :duplicate | :resumed | :revoked, worker: Worker.t()}

  @spec drain(String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def drain(worker_id, operator_ref) do
    with :ok <- reference(worker_id, :worker_id),
         :ok <- reference(operator_ref, :operator_ref) do
      Repo.transaction(fn -> drain_locked(worker_id, operator_ref) end)
    end
  end

  @spec resume(String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def resume(worker_id, operator_ref) do
    with :ok <- reference(worker_id, :worker_id),
         :ok <- reference(operator_ref, :operator_ref) do
      Repo.transaction(fn -> resume_locked(worker_id) end)
    end
  end

  @spec revoke(String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def revoke(worker_id, operator_ref) do
    with :ok <- reference(worker_id, :worker_id),
         :ok <- reference(operator_ref, :operator_ref) do
      Repo.transaction(fn -> revoke_locked(worker_id, operator_ref) end)
    end
  end

  defp drain_locked(worker_id, operator_ref) do
    worker = locked_worker!(worker_id)

    cond do
      worker.state == :revoked ->
        rollback(:coop_worker_revoked)

      worker.drain_requested_at ->
        %{status: :duplicate, worker: worker}

      true ->
        now = Repo.now!()

        updated =
          worker
          |> change(%{
            drain_requested_at: now,
            drain_requested_by: operator_ref,
            state: :draining
          })
          |> check_constraint(:state, name: :coop_worker_identity_valid)
          |> Repo.update()
          |> unwrap_write()

        %{status: :draining, worker: updated}
    end
  end

  defp resume_locked(worker_id) do
    worker = locked_worker!(worker_id)

    cond do
      worker.state == :revoked ->
        rollback(:coop_worker_revoked)

      is_nil(worker.drain_requested_at) ->
        %{status: :duplicate, worker: worker}

      true ->
        updated =
          worker
          |> change(%{
            drain_requested_at: nil,
            drain_requested_by: nil,
            state: :offline
          })
          |> check_constraint(:state, name: :coop_worker_identity_valid)
          |> Repo.update()
          |> unwrap_write()

        %{status: :resumed, worker: updated}
    end
  end

  defp revoke_locked(worker_id, operator_ref) do
    worker = locked_worker!(worker_id)

    if worker.state == :revoked do
      %{status: :duplicate, worker: worker}
    else
      now = Repo.now!()

      Repo.update_all(
        from(certificate in Certificate,
          where: certificate.worker_id == ^worker.id and is_nil(certificate.revoked_at)
        ),
        set: [revoked_at: now, revoked_by: operator_ref]
      )

      Repo.delete_all(
        from(token in EnrollmentToken,
          where: token.worker_id == ^worker.id and is_nil(token.consumed_at)
        )
      )

      Repo.update_all(
        from(placement in Placement,
          where:
            placement.worker_id == ^worker.id and
              placement.state in ^Placement.current_states()
        ),
        set: [lease_expires_at: now, state: :revoking, updated_at: now]
      )

      updated =
        worker
        |> change(%{
          drain_requested_at: worker.drain_requested_at || now,
          drain_requested_by: worker.drain_requested_by || operator_ref,
          revoked_at: now,
          revoked_by: operator_ref,
          state: :revoked
        })
        |> check_constraint(:state, name: :coop_worker_identity_valid)
        |> Repo.update()
        |> unwrap_write()

      %{status: :revoked, worker: updated}
    end
  end

  defp locked_worker!(worker_id) do
    Repo.one(from(worker in Worker, where: worker.id == ^worker_id, lock: "FOR UPDATE")) ||
      rollback(:coop_worker_not_found)
  end

  defp reference(value, field) do
    if Protocol.reference?(value),
      do: :ok,
      else: {:error, {:invalid_coop_worker_lifecycle, field}}
  end

  defp unwrap_write({:ok, value}), do: value

  defp unwrap_write({:error, changeset}),
    do: rollback({:coop_worker_lifecycle_failed, changeset.errors})

  defp rollback(reason), do: Repo.rollback(reason)
end

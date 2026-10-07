defmodule Ryker.CoopFleet.Command.Changeset do
  @moduledoc "How a command for a Coop worker is queued, delivered and settled (`Ryker.CoopFleet.Command`)."
  import Ecto.Changeset
  alias Ryker.CoopFleet.Command

  @fields [
    :command_version,
    :id,
    :idempotency_key,
    :kind,
    :payload,
    :payload_fingerprint,
    :placement_generation,
    :placement_id,
    :session_id,
    :status,
    :worker_id
  ]

  @doc "A command queued on a current placement, for its worker to pick up."
  def insert(attributes) do
    %Command{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:placement_id, name: :coop_worker_command_placement_identity_fkey)
    |> check_constraint(:kind, name: :coop_worker_command_identity_valid)
    |> check_constraint(:status, name: :coop_worker_command_result_valid)
  end

  @doc "A poll handed the command to its worker."
  def deliver(%Command{} = command, at), do: change(command, delivered_at: at, status: :delivered)

  @doc "The worker said it has the command."
  def acknowledge(%Command{} = command, at),
    do: change(command, acknowledged_at: at, status: :acknowledged)

  @doc "The worker reported how the command ended."
  def settle(%Command{} = command, attributes) do
    command
    |> change(attributes)
    |> check_constraint(:status, name: :coop_worker_command_result_valid)
  end

  @doc "The worker reported a result Ryker cannot take as it stands."
  def uncertain(%Command{} = command, at, operation_key, fingerprint, error) do
    command
    |> change(
      completed_at: at,
      error: error,
      operation_key: operation_key,
      result_fingerprint: fingerprint,
      status: :uncertain
    )
    |> check_constraint(:status, name: :coop_worker_command_result_valid)
  end

  @doc "The command can no longer reach its worker, and fails with `error`."
  def fail(%Command{} = command, at, error, fingerprint) do
    command
    |> change(
      completed_at: at,
      error: error,
      operation_key: command.idempotency_key,
      result_fingerprint: fingerprint,
      status: :failed
    )
    |> check_constraint(:status, name: :coop_worker_command_result_valid)
  end
end

defmodule Ryker.CoopFleet.ControlPlane.Shared do
  @moduledoc """
  Validation, locking, limit and rollback helpers more than one control-plane
  part needs.
  """

  alias Ryker.CoopFleet.{Protocol, Worker}
  alias Ryker.Repo

  @maximum_lease_seconds 3_600
  @maximum_clock_skew_seconds 30

  # The one clock-skew limit. The poll refuses a heartbeat whose clock is
  # further off than this, and placement passes over a worker whose last
  # reported clock drifted past it.
  @doc false
  def maximum_clock_skew_seconds, do: @maximum_clock_skew_seconds

  @doc false
  @spec lock_worker(String.t()) :: {:ok, Worker.t()} | {:error, :not_found}
  def lock_worker(worker_id) do
    worker_id |> Worker.Query.by_id() |> Worker.Query.lock_for_update() |> Repo.fetch()
  end

  @doc false
  def lease_seconds(value)
      when is_integer(value) and value > 0 and value <= @maximum_lease_seconds,
      do: :ok

  def lease_seconds(_value), do: {:error, {:invalid_coop_session_placement, :lease_seconds}}

  @doc false
  def reference(value, maximum, field) do
    if Protocol.reference?(value, maximum),
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, field}}
  end

  @doc false
  def uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:invalid_coop_worker_control_plane, field}}
    end
  end

  @doc false
  def unwrap_write({:ok, value}), do: value
  def unwrap_write({:error, changeset}), do: rollback({:coop_worker_store_error, changeset})

  @doc false
  def rollback(reason), do: Repo.rollback(reason)
end

defmodule Ryker.CoopFleet.Worker.Changeset do
  @moduledoc "How a Coop worker's row changes (`Ryker.CoopFleet.Worker`)."
  use Ryker, :changeset
  alias Ryker.CoopFleet.Worker

  @identity [:certificate_sha256, :id, :workspace_ref, :state]
  @heartbeat_required [
    :build_version,
    :capabilities,
    :capacity,
    :clock_at,
    :last_seen_at,
    :protocol_version,
    :sandbox_digest,
    :state
  ]

  @doc "A worker known by its first certificate, enrolled or vouched for."
  def insert(attributes) do
    %Worker{}
    |> cast(attributes, @identity)
    |> validate_required(@identity)
    |> unique_constraint(:certificate_sha256)
    |> check_constraint(:id, name: :coop_worker_identity_valid)
  end

  @doc "The worker's identity moves to a newly issued certificate."
  def bind_certificate(%Worker{} = worker, certificate_sha256) do
    worker
    |> change(certificate_sha256: certificate_sha256)
    |> unique_constraint(:certificate_sha256)
  end

  @doc "What a poll reports about the worker, as of `last_seen_at`."
  def heartbeat(%Worker{} = worker, attributes) do
    worker
    |> change(attributes)
    |> validate_required(@heartbeat_required)
    |> check_constraint(:id, name: :coop_worker_identity_valid)
    |> check_constraint(:capacity, name: :coop_worker_documents_valid)
    |> check_constraint(:storage, name: :coop_worker_storage_valid)
  end

  @doc "An operator asks the worker to take no new work."
  def drain(%Worker{} = worker, at, operator_ref) do
    worker
    |> change(drain_requested_at: at, drain_requested_by: operator_ref, state: :draining)
    |> check_constraint(:state, name: :coop_worker_identity_valid)
  end

  @doc "An operator lets a drained worker take work again."
  def resume(%Worker{} = worker) do
    worker
    |> change(drain_requested_at: nil, drain_requested_by: nil, state: :offline)
    |> check_constraint(:state, name: :coop_worker_identity_valid)
  end

  @doc "An operator revokes the worker. A drain asked for earlier keeps who asked and when."
  def revoke(%Worker{} = worker, at, operator_ref) do
    worker
    |> change(
      drain_requested_at: worker.drain_requested_at || at,
      drain_requested_by: worker.drain_requested_by || operator_ref,
      revoked_at: at,
      revoked_by: operator_ref,
      state: :revoked
    )
    |> check_constraint(:state, name: :coop_worker_identity_valid)
  end
end

defmodule Ryker.CoopFleet.ControlPlane.Workers do
  @moduledoc """
  Worker identity and the poll transaction.

  Binds an authenticated transport identity — a certificate the fleet issued
  or a digest an operator vouched for directly — to its enrolled worker row,
  records the heartbeat a poll carries, and applies the rest of that poll in
  one transaction through the other control-plane parts: placement leases,
  command acknowledgements and results, event batches, and command delivery.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.CoopFleet.{Certificate, Protocol, Worker}
  alias Ryker.CoopFleet.ControlPlane.{Commands, Events, Placements, Shared}
  alias Ryker.Repo

  # Registers a worker under a certificate digest the operator vouches for
  # directly, without an enrollment token. No operator surface calls this;
  # production workers enroll through `Ryker.CoopFleet.Enrollment`, and the
  # fleet tests use this to bind a worker to a digest they mint themselves.
  @doc false
  @spec authorize_worker(String.t(), String.t(), String.t()) ::
          {:ok, Worker.t()} | {:error, term()}
  def authorize_worker(worker_id, workspace_ref, certificate_sha256) do
    with :ok <- Shared.reference(worker_id, 256, :worker_id),
         :ok <- Shared.reference(workspace_ref, 256, :workspace_ref),
         :ok <- digest(certificate_sha256, :certificate_sha256) do
      Repo.transaction(fn ->
        authorize_worker_locked(worker_id, workspace_ref, certificate_sha256)
      end)
    end
  end

  @spec handle_poll_certificate(binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_poll_certificate(certificate, document, options \\ [])

  def handle_poll_certificate(certificate, document, options) when is_binary(certificate) do
    certificate_sha256 = certificate_digest(certificate)

    case active_certificate_worker(certificate_sha256) do
      nil ->
        {:error, :coop_worker_certificate_not_authorized}

      worker_id ->
        handle_poll(
          worker_id,
          document,
          Keyword.put(options, :certificate_sha256, certificate_sha256)
        )
    end
  end

  def handle_poll_certificate(_certificate, _document, _options),
    do: {:error, :coop_worker_certificate_not_authorized}

  @spec authenticate_certificate(binary()) :: {:ok, String.t()} | {:error, term()}
  def authenticate_certificate(certificate)
      when is_binary(certificate) and byte_size(certificate) > 0 do
    certificate_sha256 = certificate_digest(certificate)

    case active_certificate_worker(certificate_sha256) do
      worker_id when is_binary(worker_id) -> {:ok, worker_id}
      nil -> {:error, :coop_worker_certificate_not_authorized}
    end
  end

  def authenticate_certificate(_certificate),
    do: {:error, :coop_worker_certificate_not_authorized}

  @spec handle_poll(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_poll(authenticated_worker_id, document, options \\ []) do
    lease_seconds = Keyword.get(options, :lease_seconds, 60)
    certificate_sha256 = Keyword.get(options, :certificate_sha256)
    state_tools_secret = Keyword.get(options, :state_tools_secret)

    with :ok <- Shared.reference(authenticated_worker_id, 256, :worker_id),
         :ok <- Shared.lease_seconds(lease_seconds),
         {:ok, poll} <- Protocol.poll(document),
         :ok <- poll_identity(authenticated_worker_id, poll) do
      Repo.transaction(fn ->
        apply_poll(
          authenticated_worker_id,
          poll,
          lease_seconds,
          certificate_sha256,
          state_tools_secret
        )
      end)
    end
  end

  defp authorize_worker_locked(worker_id, workspace_ref, certificate_sha256) do
    worker =
      case Shared.locked_worker(worker_id) do
        nil ->
          %Worker{}
          |> cast(
            %{
              certificate_sha256: certificate_sha256,
              id: worker_id,
              workspace_ref: workspace_ref,
              state: :offline
            },
            [:certificate_sha256, :id, :workspace_ref, :state]
          )
          |> validate_required([:certificate_sha256, :id, :workspace_ref, :state])
          |> unique_constraint(:certificate_sha256)
          |> check_constraint(:id, name: :coop_worker_identity_valid)
          |> Repo.insert()
          |> Shared.unwrap_write()

        %Worker{workspace_ref: ^workspace_ref, certificate_sha256: ^certificate_sha256} = worker ->
          worker

        %Worker{workspace_ref: ^workspace_ref, certificate_sha256: stored} ->
          Shared.rollback({:coop_worker_certificate_conflict, stored, certificate_sha256})

        %Worker{workspace_ref: stored} ->
          Shared.rollback({:coop_worker_workspace_conflict, stored, workspace_ref})
      end

    ensure_manual_certificate!(worker_id, certificate_sha256)
    worker
  end

  defp apply_poll(worker_id, poll, lease_seconds, certificate_sha256, state_tools_secret) do
    now = Repo.now!()
    hello = poll["worker"]
    worker = authenticated_worker!(worker_id, hello["workspace_ref"], certificate_sha256)
    clock_at = parse_timestamp!(hello["clock_at"])
    ensure_clock_skew!(worker_id, clock_at, now)

    worker =
      worker
      |> change(%{
        build_version: hello["build_version"],
        capabilities: hello["capabilities"],
        capacity: hello["capacity"],
        clock_at: clock_at,
        last_seen_at: now,
        policy_authority_digests: hello["policy_authority_digests"],
        policy_digests: hello["policy_digests"],
        protocol_version: hello["protocol_version"],
        repositories: hello["repositories"],
        sandbox_digest: hello["sandbox_digest"],
        state: heartbeat_state(worker, hello["state"]),
        storage: hello["storage"],
        storage_reclaimed_bytes: reclaimed_bytes(worker, hello["storage"])
      })
      |> validate_required([
        :build_version,
        :capabilities,
        :capacity,
        :clock_at,
        :last_seen_at,
        :policy_authority_digests,
        :policy_digests,
        :protocol_version,
        :repositories,
        :sandbox_digest,
        :state
      ])
      |> check_constraint(:id, name: :coop_worker_identity_valid)
      |> check_constraint(:capacity, name: :coop_worker_documents_valid)
      |> check_constraint(:storage, name: :coop_worker_storage_valid)
      |> Repo.update()
      |> Shared.unwrap_write()

    Placements.renew_worker_placements(worker, now, lease_seconds)
    Commands.acknowledge_commands(worker_id, poll["acknowledged_command_ids"], now)

    acknowledged_result_command_ids =
      Commands.apply_command_results(worker_id, poll["command_results"], now)

    event_acknowledgements = Events.apply_event_batches(worker_id, poll["event_batches"], now)
    commands = Commands.deliver_commands(worker_id, now, state_tools_secret)

    response = %{
      "acknowledged_result_command_ids" => acknowledged_result_command_ids,
      "commands" => commands,
      "event_acknowledgements" => event_acknowledgements,
      "poll_ref" => poll["poll_ref"],
      "server_time" => DateTime.to_iso8601(now),
      "version" => Protocol.version()
    }

    case Protocol.response(response) do
      {:ok, prepared} -> prepared
      {:error, reason} -> Shared.rollback(reason)
    end
  end

  defp authenticated_worker!(worker_id, workspace_ref, certificate_sha256) do
    case Shared.locked_worker(worker_id) do
      nil ->
        Shared.rollback({:coop_worker_not_authorized, worker_id})

      %Worker{workspace_ref: stored} when stored != workspace_ref ->
        Shared.rollback({:coop_worker_workspace_mismatch, stored, workspace_ref})

      %Worker{state: :revoked} ->
        Shared.rollback({:coop_worker_revoked, worker_id})

      %Worker{} = worker when is_binary(certificate_sha256) ->
        unless active_certificate_for_worker?(certificate_sha256, worker_id),
          do: Shared.rollback(:coop_worker_certificate_not_authorized)

        worker

      %Worker{} = worker ->
        worker
    end
  end

  defp heartbeat_state(%Worker{drain_requested_at: %DateTime{}}, _reported), do: :draining
  defp heartbeat_state(%Worker{}, reported), do: String.to_existing_atom(reported)

  # Reclamation is only ever the worker's own reported inactive disposable bytes
  # falling. Ryker never estimates bytes it did not measure, so a report that
  # omits storage leaves the running total exactly where it was.
  defp reclaimed_bytes(%Worker{storage: %{"disposable_bytes" => previous}} = worker, %{
         "disposable_bytes" => current
       })
       when is_integer(previous) and is_integer(current) do
    worker.storage_reclaimed_bytes + max(previous - current, 0)
  end

  defp reclaimed_bytes(%Worker{} = worker, _storage), do: worker.storage_reclaimed_bytes

  defp poll_identity(authenticated_worker_id, poll) do
    reported_worker_id = poll["worker"]["id"]

    if authenticated_worker_id == reported_worker_id,
      do: :ok,
      else:
        {:error, {:coop_worker_identity_mismatch, authenticated_worker_id, reported_worker_id}}
  end

  defp digest(value, field) do
    if Protocol.digest?(value),
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, field}}
  end

  defp parse_timestamp!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> normalize_microseconds(datetime)
      _invalid -> Shared.rollback({:invalid_coop_worker_poll, :timestamp})
    end
  end

  defp normalize_microseconds(%DateTime{microsecond: {value, _precision}} = datetime) do
    %{datetime | microsecond: {value, 6}}
  end

  defp ensure_clock_skew!(worker_id, clock_at, now) do
    if abs(DateTime.diff(now, clock_at, :second)) > Shared.maximum_clock_skew_seconds() do
      Shared.rollback({:coop_worker_clock_skew, worker_id})
    end
  end

  defp certificate_digest(certificate),
    do: :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

  defp active_certificate_worker(certificate_sha256) do
    Repo.one(
      from(certificate in Certificate,
        join: worker in Worker,
        on: worker.id == certificate.worker_id,
        where:
          certificate.sha256 == ^certificate_sha256 and is_nil(certificate.revoked_at) and
            certificate.not_before <= fragment("clock_timestamp()") and
            certificate.expires_at > fragment("clock_timestamp()") and
            worker.state != :revoked,
        select: worker.id
      )
    )
  end

  defp active_certificate_for_worker?(certificate_sha256, worker_id) do
    Repo.exists?(
      from(certificate in Certificate,
        where:
          certificate.sha256 == ^certificate_sha256 and certificate.worker_id == ^worker_id and
            is_nil(certificate.revoked_at) and
            certificate.not_before <= fragment("clock_timestamp()") and
            certificate.expires_at > fragment("clock_timestamp()")
      )
    )
  end

  defp ensure_manual_certificate!(worker_id, certificate_sha256) do
    now = Repo.now!()

    %Certificate{}
    |> cast(
      %{
        expires_at: DateTime.add(now, 10 * 365 * 24 * 60 * 60, :second),
        issued_by: "manual-authorization",
        not_before: now,
        serial_number: "manual-#{String.slice(certificate_sha256, 0, 16)}",
        sha256: certificate_sha256,
        source: :manual,
        worker_id: worker_id
      },
      [:expires_at, :issued_by, :not_before, :serial_number, :sha256, :source, :worker_id]
    )
    |> validate_required([
      :expires_at,
      :issued_by,
      :not_before,
      :serial_number,
      :sha256,
      :source,
      :worker_id
    ])
    |> foreign_key_constraint(:worker_id)
    |> check_constraint(:sha256, name: :coop_worker_certificate_valid)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :sha256)
    |> Shared.unwrap_write()
  end
end

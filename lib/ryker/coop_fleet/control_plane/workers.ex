defmodule Ryker.CoopFleet.ControlPlane.Workers do
  @moduledoc """
  Worker identity and the poll transaction.

  Binds an authenticated transport identity — a certificate the fleet issued
  or a digest an operator vouched for directly — to its enrolled worker row,
  records the heartbeat a poll carries, and applies the rest of that poll in
  one transaction through the other control-plane parts: placement leases,
  command acknowledgements and results, event batches, and command delivery.

  A poll that changes what a page shows about the worker (its state, what it
  can run, whether it takes new copies, or its return after going quiet) is
  announced after the poll commits (`subscribe_workers/0`), and so is a worker
  that stops polling (`announce_quiet/1`). A heartbeat that only moves
  `last_seen_at` or re-measures storage is not: a worker polls every few
  seconds. What a poll reports about a session is announced on the session's
  request (`Ryker.Episodes`).
  """
  alias Ryker.CoopFleet.Certificate
  alias Ryker.CoopFleet.ControlPlane.{Commands, Events, Placements, Shared}
  alias Ryker.CoopFleet.{Protocol, Worker}
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @spec handle_poll_certificate(binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_poll_certificate(certificate, document, options \\ [])

  def handle_poll_certificate(certificate, document, options) when is_binary(certificate) do
    certificate_sha256 = Crypto.sha256_hex(certificate)

    case active_certificate_worker(certificate_sha256) do
      nil ->
        {:error, :coop_worker_certificate_not_authorized}

      worker_id ->
        handle_poll(worker_id, certificate_sha256, document, options)
    end
  end

  def handle_poll_certificate(_certificate, _document, _options),
    do: {:error, :coop_worker_certificate_not_authorized}

  @spec authenticate_certificate(binary()) :: {:ok, String.t()} | {:error, term()}
  def authenticate_certificate(certificate)
      when is_binary(certificate) and byte_size(certificate) > 0 do
    certificate_sha256 = Crypto.sha256_hex(certificate)

    case active_certificate_worker(certificate_sha256) do
      worker_id when is_binary(worker_id) -> {:ok, worker_id}
      nil -> {:error, :coop_worker_certificate_not_authorized}
    end
  end

  def authenticate_certificate(_certificate),
    do: {:error, :coop_worker_certificate_not_authorized}

  # The worker the certificate named polls; its heartbeat checks the
  # certificate again under the worker's lock, so one revoked meanwhile stops
  # it there. A poll with no certificate skipped that check, and only tests
  # ever sent one (2026-10-04 review).
  defp handle_poll(authenticated_worker_id, certificate_sha256, document, options) do
    lease_seconds = Keyword.get(options, :lease_seconds, 60)
    state_tools_secret = Keyword.get(options, :state_tools_secret)

    with :ok <- Shared.reference(authenticated_worker_id, 256, :worker_id),
         :ok <- Shared.lease_seconds(lease_seconds),
         {:ok, poll} <- Protocol.poll(document),
         :ok <- poll_identity(authenticated_worker_id, poll),
         {:ok, now} <-
           Repo.transaction(fn ->
             heartbeat(authenticated_worker_id, poll, lease_seconds, certificate_sha256)
           end) do
      body_root = Keyword.get(options, :body_root)

      # Each result and each event batch is applied in a transaction of its
      # own. The poll was one transaction, so one item Ryker refused refused
      # the whole poll: the worker sent it again and again, nothing else it
      # reported counted, and its leases ran out (2026-10-04 review).
      acknowledged_result_command_ids =
        Commands.apply_command_results(
          authenticated_worker_id,
          poll["command_results"],
          now,
          body_root
        )

      event_acknowledgements =
        Events.apply_event_batches(authenticated_worker_id, poll["event_batches"], now)

      announce_reported_sessions(poll["event_batches"])

      Repo.transaction(fn ->
        _locked = Shared.lock_worker(authenticated_worker_id)

        commands =
          Commands.deliver_commands(
            authenticated_worker_id,
            now,
            state_tools_secret,
            body_root,
            Keyword.get(options, :checkpoint_key)
          )

        answer(poll, now, commands, acknowledged_result_command_ids, event_acknowledgements)
      end)
    end
  end

  defp answer(poll, now, commands, acknowledged_result_command_ids, event_acknowledgements) do
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

  # The worker says it is alive: its heartbeat is saved, its placements are
  # renewed and the commands it acknowledged are marked, before anything it
  # reported is applied.
  defp heartbeat(worker_id, poll, lease_seconds, certificate_sha256) do
    now = Repo.now!()
    hello = poll["worker"]
    worker = authenticated_worker!(worker_id, hello["workspace_ref"], certificate_sha256)
    clock_at = parse_timestamp!(hello["clock_at"])
    ensure_clock_skew!(worker_id, clock_at, now)

    previous = worker

    worker =
      worker
      |> Worker.Changeset.heartbeat(%{
        build_version: hello["build_version"],
        capabilities: hello["capabilities"],
        capacity: hello["capacity"],
        clock_at: clock_at,
        last_seen_at: now,
        protocol_version: hello["protocol_version"],
        sandbox_digest: hello["sandbox_digest"],
        state: heartbeat_state(worker, hello["state"]),
        storage: hello["storage"],
        storage_reclaimed_bytes: reclaimed_bytes(worker, hello["storage"])
      })
      |> Repo.update()
      |> Shared.unwrap_write()

    if status_changed?(previous, worker, now), do: broadcast_worker_updated(worker.id)
    Placements.renew_worker_placements(worker, now, lease_seconds)
    Commands.acknowledge_commands(worker_id, poll["acknowledged_command_ids"], now)
    now
  end

  defp authenticated_worker!(worker_id, workspace_ref, certificate_sha256) do
    case Shared.lock_worker(worker_id) do
      {:error, :not_found} ->
        Shared.rollback({:coop_worker_not_authorized, worker_id})

      {:ok, %Worker{workspace_ref: stored}} when stored != workspace_ref ->
        Shared.rollback({:coop_worker_workspace_mismatch, stored, workspace_ref})

      {:ok, %Worker{state: :revoked}} ->
        Shared.rollback({:coop_worker_revoked, worker_id})

      {:ok, worker} ->
        unless active_certificate_for_worker?(certificate_sha256, worker_id),
          do: Shared.rollback(:coop_worker_certificate_not_authorized)

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

  defp parse_timestamp!(value) do
    case UTCDateTime.parse(value) do
      {:ok, datetime} -> UTCDateTime.to_usec(datetime)
      _invalid -> Shared.rollback({:invalid_coop_worker_poll, :timestamp})
    end
  end

  defp ensure_clock_skew!(worker_id, clock_at, now) do
    if abs(DateTime.diff(now, clock_at, :second)) > Shared.maximum_clock_skew_seconds() do
      Shared.rollback({:coop_worker_clock_skew, worker_id})
    end
  end

  defp active_certificate_worker(certificate_sha256) do
    Repo.one(Certificate.Query.active_worker_id(certificate_sha256))
  end

  defp active_certificate_for_worker?(certificate_sha256, worker_id) do
    certificate_sha256
    |> Certificate.Query.by_sha256()
    |> Certificate.Query.by_worker_id(worker_id)
    |> Certificate.Query.in_force()
    |> Repo.exists?()
  end

  # -- PubSub ------------------------------------------------------------------

  # What pages read from a worker row, and whether it had gone quiet: a worker
  # silent past its heartbeat (`Worker.heartbeat_seconds/0`) is stale.
  @status_fields ~w(state capacity capabilities build_version sandbox_digest protocol_version drain_requested_at)a

  @doc """
  Subscribes the caller to Coop worker status: `{:coop_worker_updated,
  worker_id}` once a poll changes a worker's state, capacity, capabilities,
  storage or build, or brings it back after it stopped reporting, and that
  poll has committed; or once a worker stops reporting.
  """
  def subscribe_workers, do: Ryker.PubSub.subscribe(workers_topic())

  def unsubscribe_workers, do: Ryker.PubSub.unsubscribe(workers_topic())

  @doc """
  Announces each worker in `reporting` whose heartbeat has gone stale since,
  and returns the workers reporting now.

  A worker that stops polling writes nothing, so no commit says it went quiet;
  `Ryker.ControlPlane.WorkerLiveness` asks every few seconds while the console
  runs, starting from an empty set. A worker that comes back is announced by
  its first poll.
  """
  @spec announce_quiet(MapSet.t(String.t())) :: MapSet.t(String.t())
  def announce_quiet(%MapSet{} = reporting) do
    cutoff = DateTime.add(Repo.now!(), -Worker.heartbeat_seconds(), :second)

    current =
      cutoff
      |> Worker.Query.seen_since()
      |> Worker.Query.select_ids()
      |> Repo.all()
      |> MapSet.new()

    reporting |> MapSet.difference(current) |> Enum.each(&broadcast_worker_updated/1)
    current
  end

  defp workers_topic, do: "coop:workers"

  defp status_changed?(previous, current, now) do
    status(previous) != status(current) or is_nil(previous.last_seen_at) or
      DateTime.diff(now, previous.last_seen_at, :second) > Worker.heartbeat_seconds()
  end

  # A worker measures its storage as files come and go, so the bytes move on
  # almost every poll; what a page decides on is whether the worker takes new
  # copies and why not. The bytes are as of the page's last redraw.
  defp status(worker),
    do: worker |> Map.take(@status_fields) |> Map.put(:storage, storage_state(worker.storage))

  defp storage_state(%{"allocation" => allocation} = storage),
    do: {allocation, storage["refusal_reason"]}

  defp storage_state(_unmeasured), do: nil

  defp broadcast_worker_updated(worker_id) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(workers_topic(), {:coop_worker_updated, worker_id})
    end)
  end

  # What a worker reported about a session shows on the session's request.
  defp announce_reported_sessions(batches) do
    case for(%{"session_ref" => ref, "events" => [_ | _]} <- batches, do: ref) do
      [] ->
        :ok

      session_ids ->
        session_ids
        |> Work.Session.Query.by_ids()
        |> Work.Session.Query.select_episode_ids()
        |> Repo.all()
        |> Enum.each(&Episodes.broadcast_episode_updated/1)
    end
  end
end

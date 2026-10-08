defmodule Ryker.CoopFleet.ControlPlane.Commands do
  @moduledoc """
  The command queue between Ryker and a placement's worker.

  Enqueues idempotent commands against a current placement, delivers them on
  the worker's poll with any state-tools binding materialized, records the
  acknowledgements and results the worker reports, and fails the queued
  commands a placement ended before they ever left Ryker. A command's caller
  hears once it settles (`subscribe_settled/1`).
  """
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Bodies, Command}
  alias Ryker.CoopFleet.ControlPlane.{Placements, Shared}
  alias Ryker.CoopFleet.{Placement, Protocol, Requests}
  alias Ryker.Repo
  alias Ryker.StateTools
  alias Ryker.Work
  require Logger

  @purposes ~w(
    api_request
    get_review
    get_review_gate_output
    get_checkpoint_bundle
    ensure_workspace
    create_session
    get_session
    get_session_evidence
    submit_turn
    get_turn
    get_output_artifact
    get_changes
    get_changes_page
    run_review
    plan_discard
    discard_session
    validate_candidate
    cancel_turn
    fence_operation
    checkpoint_workspace
    close_session
    prepare_session
    reconcile_operation
  )

  @terminal_command_states [:succeeded, :failed, :uncertain]

  # A prepare holds the worker's one command slot until Coop has the agent
  # running, and Coop allows it the job's hour-long turn timeout. Redelivery
  # is what renews a running command's lease on the worker, so a prepare is
  # redelivered for a minute at most: past that its lease runs out and the
  # worker cancels it, rather than hold every other command behind an agent
  # that is not starting. A healthy one answers in seconds.
  @prepare_redelivery_seconds 60

  # A read answers only its caller, and a caller waits for it about as long as
  # Ryker waits on Coop (30 s, `Ryker.Defaults` coop `receive_timeout_ms`).
  # Every poll sent every read nobody waited for any more, oldest first, so
  # after a long command the worker ran stale reads before newer work: 19 of
  # 10,215 reads in the week to 2026-10-07 ran after their caller had gone
  # (2026-10-04 review). Two minutes after it was asked, a read is no longer
  # sent: one the worker has is cancelled when its lease runs out, and one it
  # never had fails when its placement ends.
  @read_wait_seconds 120

  # Session -> key -> placement is the shared lock order for enqueue and fence.
  # Source preparation and waiting on the remote worker never hold these locks.
  @doc """
  Delivers `{:coop_command_settled, command_id}` once the command succeeds,
  fails or turns uncertain, to an alias of the calling process
  (`Ryker.PubSub.subscribe_alias/1`): a caller waits on its command and then
  goes on, and a late message is dropped with the alias. The caller polled
  the row every 250 ms, two queries a tick, and heard of a result up to a
  tick late (2026-10-04 review).
  """
  @spec subscribe_settled(Ecto.UUID.t()) :: reference()
  def subscribe_settled(command_id), do: Ryker.PubSub.subscribe_alias(settled_topic(command_id))

  @spec unsubscribe_settled(Ecto.UUID.t(), reference()) :: :ok
  def unsubscribe_settled(command_id, alias),
    do: Ryker.PubSub.unsubscribe_alias(settled_topic(command_id), alias)

  defp settled(%Command{id: id} = command) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast_to_aliases(settled_topic(id), {:coop_command_settled, id})
    end)

    command
  end

  defp settled_topic(command_id), do: "coop-command:" <> command_id

  @doc false
  def with_session_command(session_id, key, callback) do
    with :ok <- Shared.uuid(session_id, :session_id),
         :ok <- Shared.reference(key, 512, :idempotency_key) do
      Repo.transaction(fn ->
        session =
          session_id
          |> Work.Session.Query.by_id()
          |> Work.Session.Query.lock_for_no_key_update()
          |> Repo.peek() ||
            Shared.rollback({:coop_session_not_found, session_id})

        AdvisoryLock.hold!("coop-command:" <> key)

        callback.(session, Repo.peek(Command.Query.by_idempotency_key(key)))
      end)
    end
  end

  @doc false
  def create_intent(session, task \\ nil) do
    Map.take(session, [
      :id,
      :generation,
      :external_ref,
      :policy,
      :policy_digest,
      :authority_digest,
      :repository_ref,
      :repository_context,
      :repository_source,
      :environment_ref,
      :workspace_task
    ])
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
    |> Map.put("task", task)
  end

  @doc false
  def local_fence?(%Command{
        placement_id: nil,
        status: :failed,
        error: %{"code" => "operation_not_enqueued"}
      }),
      do: true

  def local_fence?(_command), do: false

  @doc false
  def fence_command(%Work.Session{} = session, kind, intent, key)
      when kind in ~w(create_session submit_turn) do
    with_session_command(session.id, key, fn current, command ->
      unless create_intent(current) == create_intent(session),
        do: Shared.rollback({:coop_worker_command_conflict, key})

      fence_command_locked(command, current, kind, intent, key)
    end)
  end

  defp fence_command_locked(%Command{} = command, session, kind, intent, key) do
    if command.session_id == session.id and command.kind == kind and
         (not local_fence?(command) or command.payload == intent),
       do: command,
       else: Shared.rollback({:coop_worker_command_conflict, key})
  end

  defp fence_command_locked(nil, session, kind, intent, key) do
    error = %{
      "code" => "operation_not_enqueued",
      "status" => 409,
      "detail" => "The fleet mutation was fenced before it could reach Coop."
    }

    command = %Command{
      id: Repo.generate_id(),
      session_id: session.id,
      kind: kind,
      payload: intent,
      payload_fingerprint: CanonicalJSON.digest(intent),
      idempotency_key: key,
      status: :failed,
      operation_key: key,
      error: error,
      completed_at: Repo.now!()
    }

    Repo.insert!(%{command | result_fingerprint: CanonicalJSON.digest(error)})
  end

  @spec enqueue_command(Ecto.UUID.t(), String.t(), map(), String.t()) ::
          {:ok, Command.t()} | {:error, term()}
  def enqueue_command(placement_id, kind, payload, idempotency_key) do
    with :ok <- Shared.uuid(placement_id, :placement_id),
         :ok <- enum(kind, @purposes, :command_kind),
         :ok <- CanonicalJSON.validate(payload, max_bytes: 768 * 1_024),
         :ok <- Shared.reference(idempotency_key, 512, :idempotency_key) do
      enqueue_on_placement(placement_id, kind, payload, idempotency_key)
    else
      {:error, {:too_large, _actual, _limit}} ->
        {:error, {:invalid_coop_worker_command, :payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_on_placement(placement_id, kind, payload, idempotency_key) do
    case Repo.fetch(Placement.Query.by_id(placement_id)) do
      {:ok, %Placement{session_id: session_id}} ->
        with_session_command(
          session_id,
          idempotency_key,
          &enqueue_command_locked(&1, &2, placement_id, kind, payload, idempotency_key)
        )

      {:error, :not_found} ->
        {:error, {:coop_session_placement_not_found, placement_id}}
    end
  end

  # `existing` is the command already under `idempotency_key`, read under the
  # same locks (`with_session_command/3`).
  defp enqueue_command_locked(session, existing, placement_id, kind, payload, idempotency_key) do
    fingerprint =
      CanonicalJSON.digest(%{
        "idempotency_key" => idempotency_key,
        "kind" => kind,
        "payload" => payload,
        "placement_id" => placement_id,
        "version" => Protocol.version()
      })

    case existing do
      %Command{payload_fingerprint: ^fingerprint} = command ->
        command

      %Command{} ->
        Shared.rollback({:coop_worker_command_conflict, idempotency_key})

      nil ->
        validate_create_lifecycle(session, kind)
        now = Repo.now!()

        placement =
          placement_id
          |> Placement.Query.by_id()
          |> Placement.Query.lock_for_update()
          |> Repo.peek() ||
            Shared.rollback({:coop_session_placement_not_found, placement_id})

        unless Placements.current?(placement, now),
          do: Shared.rollback({:coop_session_placement_not_current, placement_id})

        case placement_request(placement, kind, payload) do
          :ok -> :ok
          {:error, reason} -> Shared.rollback(reason)
        end

        %{
          command_version: Protocol.version(),
          id: Repo.generate_id(),
          idempotency_key: idempotency_key,
          kind: kind,
          payload: payload,
          payload_fingerprint: fingerprint,
          placement_generation: placement.generation,
          placement_id: placement.id,
          session_id: placement.session_id,
          status: :queued,
          worker_id: placement.worker_id
        }
        |> Command.Changeset.insert()
        |> Repo.insert()
        |> Shared.unwrap_write()
    end
  end

  defp validate_create_lifecycle(session, "create_session") do
    unless session.cleanup_status == :active and is_nil(session.coop_session_id),
      do: Shared.rollback({:coop_fleet_authority_mismatch, :worker_job})
  end

  defp validate_create_lifecycle(_session, _kind), do: :ok

  defp placement_request(
         %{requirements: %{"purpose" => "stop_or_cleanup"}} = placement,
         kind,
         payload
       ) do
    with {:ok, request} <- Requests.encode(kind, payload, placement),
         {:ok, %Work.Session{coop_session_id: id}} when is_binary(id) <-
           Repo.fetch(Work.Session.Query.by_id(placement.session_id)),
         true <- cleanup_request?(request, id) do
      :ok
    else
      _ -> {:error, :coop_cleanup_only_placement}
    end
  end

  defp placement_request(_placement, _kind, _payload), do: :ok

  defp cleanup_request?(%{"method" => "GET"}, _id), do: true
  defp cleanup_request?(%{"method" => "POST", "path" => "/v1/operations/fence"}, _id), do: true

  defp cleanup_request?(%{"method" => "POST", "path" => path}, id) when is_binary(path) do
    prefix = "/v1/sessions/" <> URI.encode(id, &URI.char_unreserved?/1)

    case String.split(path, prefix, parts: 2) do
      ["", suffix] ->
        suffix in ~w(/close /discard-plan /discard) or cancel_path?(suffix)

      _ ->
        false
    end
  end

  defp cleanup_request?(_request, _id), do: false

  defp cancel_path?(path) do
    case String.split(path, "/") do
      ["", "turns", id, "cancel"] when id != "" ->
        not String.contains?(URI.decode(id), ["/", "\\", <<0>>])

      _ ->
        false
    end
  end

  @doc "Whether a poll at `now` would still give worker `worker_id` a command."
  @spec waiting?(String.t(), DateTime.t()) :: boolean()
  def waiting?(worker_id, now), do: Repo.exists?(waiting(worker_id, now))

  defp waiting(worker_id, now) do
    Command.Query.waiting_on(
      worker_id,
      now,
      DateTime.add(now, -@prepare_redelivery_seconds, :second),
      DateTime.add(now, -@read_wait_seconds, :second)
    )
  end

  @doc false
  def fail_undelivered_commands(placement, now) do
    commands =
      placement.id
      |> Command.Query.by_placement_id()
      |> Command.Query.queued()
      |> Command.Query.lock_for_update()
      |> Repo.all()

    Enum.each(commands, fn command ->
      error = %{
        "code" => "operation_not_enqueued",
        "detail" => "command never left Ryker before its placement ended",
        "status" => 409
      }

      reject_command(command, error, now)
    end)

    :ok
  end

  defp reject_command(command, error, now) do
    fingerprint =
      CanonicalJSON.digest(%{
        "command_id" => command.id,
        "error" => error,
        "operation_key" => command.idempotency_key,
        "resource" => nil,
        "state" => "failed"
      })

    command
    |> Command.Changeset.fail(now, error, fingerprint)
    |> Repo.update!()
    |> settled()
  end

  @doc false
  def acknowledge_commands(worker_id, command_ids, now) do
    Enum.each(command_ids, fn command_id ->
      command = fetch_and_lock_command!(command_id, worker_id)

      cond do
        command.status in @terminal_command_states or command.status == :acknowledged ->
          :ok

        command.status == :delivered ->
          command
          |> Command.Changeset.acknowledge(now)
          |> Repo.update!()

        true ->
          Shared.rollback({:coop_worker_command_not_delivered, command_id})
      end
    end)
  end

  # Each result in a transaction of its own, which locks the worker first as
  # every path to its placements does. A refused result is left
  # unacknowledged, so the worker keeps it and sends it again.
  @doc false
  def apply_command_results(worker_id, results, now, body_root),
    do: Enum.flat_map(results, &applied_result(worker_id, &1, now, body_root))

  defp applied_result(worker_id, result, now, body_root) do
    applied =
      Repo.transaction(fn ->
        _locked = Shared.fetch_and_lock_worker(worker_id)
        apply_command_result(worker_id, result, now, body_root)
      end)

    case applied do
      {:ok, command_id} ->
        [command_id]

      {:error, reason} ->
        Logger.warning(
          "worker #{worker_id} result for command #{result["command_id"]} refused: " <>
            inspect(reason)
        )

        []
    end
  end

  defp apply_command_result(worker_id, result, now, body_root) do
    command = fetch_and_lock_command!(result["command_id"], worker_id)
    fingerprint = CanonicalJSON.digest(result)
    placement = fetch_and_lock_command_placement!(command)

    cond do
      command.operation_key != nil and command.result_fingerprint == fingerprint ->
        :ok

      command.operation_key != nil ->
        Shared.rollback({:coop_worker_command_result_conflict, command.id})

      command.status == :queued ->
        Shared.rollback({:coop_worker_command_not_delivered, command.id})

      command.idempotency_key != result["operation_key"] ->
        Shared.rollback({:coop_worker_operation_key_mismatch, command.id})

      not Placements.current?(placement, now) ->
        record_uncertain(command, result, fingerprint, now, %{
          "code" => "placement_not_authorized",
          "detail" => "worker result arrived after placement authority ended",
          "status" => 409
        })

      # Refusing the whole poll failed every later one from this worker too,
      # and a worker that had reported the result cannot upload its body again.
      not response_body_received?(command.id, body_root, result) ->
        record_uncertain(command, result, fingerprint, now, %{
          "code" => "response_body_missing",
          "detail" => "the worker reported a response body Ryker never received",
          "status" => 409
        })

      true ->
        attributes = %{
          completed_at: now,
          error: result["error"],
          operation_key: result["operation_key"],
          result: result["resource"],
          result_fingerprint: fingerprint,
          status: String.to_existing_atom(result["state"])
        }

        command
        |> Command.Changeset.settle(attributes)
        |> Repo.update()
        |> Shared.unwrap_write()
        |> settled()
    end

    command.id
  end

  defp record_uncertain(command, result, fingerprint, now, error) do
    command
    |> Command.Changeset.uncertain(now, result["operation_key"], fingerprint, error)
    |> Repo.update()
    |> Shared.unwrap_write()
    |> settled()
  end

  defp response_body_received?(id, root, result) do
    case get_in(result, ["resource", "body_ref"]) do
      nil -> true
      reference -> match?({:ok, _body, _identity}, Bodies.fetch(root, id, :response, reference))
    end
  end

  @doc false
  def deliver_commands(worker_id, now, state_tools_secret, body_root, checkpoint_key) do
    commands =
      worker_id
      |> waiting(now)
      |> Command.Query.ordered_by_oldest()
      |> Command.Query.limit_to(100)
      |> Command.Query.lock_next_free()
      |> Command.Query.select_with_placements()
      |> Repo.all()

    {delivered, _bytes} =
      Enum.reduce(commands, {[], 0}, fn {command, placement}, acc ->
        case materialize_command_payload(
               command,
               placement,
               state_tools_secret,
               body_root,
               checkpoint_key
             ) do
          {:ok, request} ->
            deliver_command(command, placement, request, now, acc)

          {:error, _reason} when command.status == :queued ->
            reject_command(
              command,
              %{
                "code" => "invalid_command",
                "status" => 400,
                "detail" => "The frozen request cannot be prepared."
              },
              now
            )

            acc

          _deferred ->
            # A storage outage or an already-delivered request cannot roll back
            # other results and the heartbeat that keeps their placements alive.
            acc
        end
      end)

    Enum.reverse(delivered)
  end

  defp deliver_command(command, placement, request, now, {delivered, bytes} = acc) do
    envelope = %{
      "command_id" => command.id,
      "command_version" => command.command_version,
      "idempotency_key" => command.idempotency_key,
      "kind" => "api_request",
      "lease_expires_at" => DateTime.to_iso8601(placement.lease_expires_at),
      "lease_ref" => placement.lease_ref,
      "payload" => request,
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id,
      "worker_id" => placement.worker_id
    }

    size = byte_size(CanonicalJSON.encode!(envelope))

    if bytes + size <= 768 * 1_024 do
      if command.status == :queued do
        command |> Command.Changeset.deliver(now) |> Repo.update!()
      end

      {[envelope | delivered], bytes + size}
    else
      acc
    end
  end

  defp materialize_command_payload(
         command,
         placement,
         state_tools_secret,
         body_root,
         checkpoint_key
       ) do
    with :ok <- placement_request(placement, command.kind, command.payload),
         {:ok, payload} <-
           materialize_binding_at(command.payload, command, placement, state_tools_secret, [
             "controller_tools"
           ]),
         {:ok, payload} <-
           materialize_binding_at(payload, command, placement, state_tools_secret, [
             "request",
             "controller_tools"
           ]),
         {:ok, request} <- Requests.encode(command.kind, payload, placement) do
      case Bodies.prepare_request(request, body_root, command.id, checkpoint_key) do
        {:ok, request} -> {:ok, request}
        {:error, reason} -> {:defer, {:error, reason}}
      end
    end
  end

  defp materialize_binding_at(payload, command, placement, state_tools_secret, path) do
    case get_in(payload, path) do
      nil ->
        {:ok, payload}

      descriptor ->
        with {:ok, binding} <-
               materialize_binding(command, placement, descriptor, state_tools_secret) do
          {:ok, put_in(payload, path, binding)}
        end
    end
  end

  defp materialize_binding(
         command,
         placement,
         %{"endpoint" => endpoint, "token_sha256" => token_sha256} = descriptor,
         state_tools_secret
       )
       when map_size(descriptor) == 2 and is_struct(state_tools_secret, Ryker.Secret) do
    session = Repo.peek(Work.Session.Query.by_id(command.session_id))

    turn =
      command.session_id
      |> Work.Turn.Query.state_tools_bound(endpoint, token_sha256)
      |> Work.Turn.Query.limit_to(1)
      |> Work.Turn.Query.lock_for_update()
      |> Repo.peek()

    with %Work.Session{} <- session,
         %Work.Turn{} <- turn,
         {:ok, binding} <-
           Work.StateBinding.derive(
             session,
             turn,
             Work.StateBinding.placement_scope(placement),
             endpoint,
             state_tools_secret
           ),
         true <- binding.token_sha256 == token_sha256,
         {:ok, _current} <- StateTools.Binding.resolve(binding.token) do
      {:ok, Work.StateBinding.document(binding)}
    else
      _invalid -> {:error, {:coop_worker_state_binding_not_current, command.id}}
    end
  end

  defp materialize_binding(command, _placement, _descriptor, _state_tools_secret),
    do: {:error, {:coop_worker_state_binding_not_current, command.id}}

  defp fetch_and_lock_command!(command_id, worker_id) do
    command_id
    |> Command.Query.by_id()
    |> Command.Query.by_worker_id(worker_id)
    |> Command.Query.lock_for_update()
    |> Repo.peek() || Shared.rollback({:coop_worker_command_not_found, command_id})
  end

  defp fetch_and_lock_command_placement!(command) do
    command
    |> Placement.Query.by_command()
    |> Placement.Query.lock_for_update()
    |> Repo.peek() || Shared.rollback({:coop_session_placement_not_found, command.session_id})
  end

  defp enum(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, field}}
  end
end

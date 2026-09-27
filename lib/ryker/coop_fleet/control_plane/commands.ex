defmodule Ryker.CoopFleet.ControlPlane.Commands do
  @moduledoc """
  The command queue between Ryker and a placement's worker.

  Enqueues idempotent commands against a current placement, delivers them on
  the worker's poll with any state-tools binding materialized, records the
  acknowledgements and results the worker reports, and fails the queued
  commands a placement ended before they ever left Ryker.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Bodies, Command, Placement, Protocol, Requests}
  alias Ryker.CoopFleet.ControlPlane.{Placements, Shared}
  alias Ryker.Repo
  alias Ryker.StateTools.Binding
  alias Ryker.Work.{Session, StateBinding, Turn}

  @purposes ~w(
    api_request
    get_review
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
    reconcile_operation
  )

  @terminal_command_states [:succeeded, :failed, :uncertain]

  # Session -> key -> placement is the shared lock order for enqueue and fence.
  # Source preparation and waiting on the remote worker never hold these locks.
  @doc false
  def with_session_command(session_id, key, callback) do
    with :ok <- Shared.uuid(session_id, :session_id),
         :ok <- Shared.reference(key, 512, :idempotency_key) do
      Repo.transaction(fn ->
        session =
          Repo.one(
            from(session in Session, where: session.id == ^session_id, lock: "FOR NO KEY UPDATE")
          ) ||
            Shared.rollback({:coop_session_not_found, session_id})

        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "coop-command:" <> key
        ])

        callback.(session, Repo.get_by(Command, idempotency_key: key))
      end)
    end
  end

  @doc false
  def create_intent(session, task \\ nil),
    do:
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

  @doc false
  def local_fence?(%Command{
        placement_id: nil,
        status: :failed,
        error: %{"code" => "operation_not_enqueued"}
      }),
      do: true

  def local_fence?(_command), do: false

  @doc false
  def fence_command(%Session{} = session, kind, intent, key)
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
      id: Ecto.UUID.generate(),
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

      {:error, _reason} = error ->
        error
    end
  end

  defp enqueue_on_placement(placement_id, kind, payload, idempotency_key) do
    case Repo.get(Placement, placement_id) do
      %Placement{session_id: session_id} ->
        with_session_command(session_id, idempotency_key, fn session, _command ->
          enqueue_command_locked(session, placement_id, kind, payload, idempotency_key)
        end)

      nil ->
        {:error, {:coop_session_placement_not_found, placement_id}}
    end
  end

  defp enqueue_command_locked(session, placement_id, kind, payload, idempotency_key) do
    fingerprint =
      CanonicalJSON.digest(%{
        "idempotency_key" => idempotency_key,
        "kind" => kind,
        "payload" => payload,
        "placement_id" => placement_id,
        "version" => Protocol.version()
      })

    case Repo.one(from(command in Command, where: command.idempotency_key == ^idempotency_key)) do
      %Command{payload_fingerprint: ^fingerprint} = command ->
        command

      %Command{} ->
        Shared.rollback({:coop_worker_command_conflict, idempotency_key})

      nil ->
        validate_create_lifecycle(session, kind)
        now = Repo.now!()

        placement =
          Repo.one(
            from(placement in Placement,
              where: placement.id == ^placement_id,
              lock: "FOR UPDATE"
            )
          ) || Shared.rollback({:coop_session_placement_not_found, placement_id})

        unless Placements.current?(placement, now),
          do: Shared.rollback({:coop_session_placement_not_current, placement_id})

        case placement_request(placement, kind, payload) do
          :ok -> :ok
          {:error, reason} -> Shared.rollback(reason)
        end

        %Command{}
        |> cast(
          %{
            command_version: Protocol.version(),
            id: Ecto.UUID.generate(),
            idempotency_key: idempotency_key,
            kind: kind,
            payload: payload,
            payload_fingerprint: fingerprint,
            placement_generation: placement.generation,
            placement_id: placement.id,
            session_id: placement.session_id,
            status: :queued,
            worker_id: placement.worker_id
          },
          [
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
        )
        |> validate_required([
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
        ])
        |> unique_constraint(:idempotency_key)
        |> foreign_key_constraint(:placement_id,
          name: :coop_worker_command_placement_identity_fkey
        )
        |> check_constraint(:kind, name: :coop_worker_command_identity_valid)
        |> check_constraint(:status, name: :coop_worker_command_result_valid)
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
         %Session{coop_session_id: id} when is_binary(id) <-
           Repo.get(Session, placement.session_id),
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

  @doc false
  def fail_undelivered_commands(placement, now) do
    commands =
      Repo.all(
        from(command in Command,
          where: command.placement_id == ^placement.id and command.status == :queued,
          lock: "FOR UPDATE"
        )
      )

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
    |> change(%{
      completed_at: now,
      error: error,
      operation_key: command.idempotency_key,
      result_fingerprint: fingerprint,
      status: :failed
    })
    |> check_constraint(:status, name: :coop_worker_command_result_valid)
    |> Repo.update!()
  end

  @doc false
  def acknowledge_commands(worker_id, command_ids, now) do
    Enum.each(command_ids, fn command_id ->
      command = locked_command!(command_id, worker_id)

      cond do
        command.status in @terminal_command_states or command.status == :acknowledged ->
          :ok

        command.status == :delivered ->
          command
          |> change(%{acknowledged_at: now, status: :acknowledged})
          |> Repo.update!()

        true ->
          Shared.rollback({:coop_worker_command_not_delivered, command_id})
      end
    end)
  end

  @doc false
  def apply_command_results(worker_id, results, now, body_root) do
    Enum.map(results, &apply_command_result(worker_id, &1, now, body_root))
  end

  defp apply_command_result(worker_id, result, now, body_root) do
    command = locked_command!(result["command_id"], worker_id)
    fingerprint = CanonicalJSON.digest(result)
    placement = locked_command_placement!(command)

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
        command
        |> change(%{
          completed_at: now,
          error: %{
            "code" => "placement_not_authorized",
            "detail" => "worker result arrived after placement authority ended",
            "status" => 409
          },
          operation_key: result["operation_key"],
          result_fingerprint: fingerprint,
          status: :uncertain
        })
        |> check_constraint(:status, name: :coop_worker_command_result_valid)
        |> Repo.update()
        |> Shared.unwrap_write()

      true ->
        verify_response_body(command.id, body_root, get_in(result, ["resource", "body_ref"]))

        attributes = %{
          completed_at: now,
          error: result["error"],
          operation_key: result["operation_key"],
          result: result["resource"],
          result_fingerprint: fingerprint,
          status: String.to_existing_atom(result["state"])
        }

        command
        |> change(attributes)
        |> check_constraint(:status, name: :coop_worker_command_result_valid)
        |> Repo.update()
        |> Shared.unwrap_write()
    end

    command.id
  end

  defp verify_response_body(_id, _root, nil), do: :ok

  defp verify_response_body(id, root, reference) do
    case Bodies.fetch(root, id, :response, reference) do
      {:ok, _path, _identity} -> :ok
      _ -> Shared.rollback({:coop_worker_response_body_missing, id})
    end
  end

  @doc false
  def deliver_commands(worker_id, now, state_tools_secret, body_root, checkpoint_key) do
    commands =
      Repo.all(
        from(command in Command,
          join: placement in Placement,
          on: placement.id == command.placement_id,
          where:
            command.worker_id == ^worker_id and
              command.status in [:queued, :delivered, :acknowledged] and
              placement.state == :active and placement.lease_expires_at > ^now,
          order_by: [asc: command.inserted_at, asc: command.id],
          limit: 100,
          lock: "FOR UPDATE SKIP LOCKED",
          select: {command, placement}
        )
      )

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
        command |> change(%{delivered_at: now, status: :delivered}) |> Repo.update!()
      end

      placement |> change(%{last_command_id: command.id}) |> Repo.update!()
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
        {:error, _reason} = error -> {:defer, error}
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
       when map_size(descriptor) == 2 and is_binary(state_tools_secret) do
    session = Repo.get(Session, command.session_id)

    turn =
      Repo.one(
        from(turn in Turn,
          where:
            turn.session_id == ^command.session_id and
              turn.state_tools_endpoint == ^endpoint and
              turn.state_tools_token_sha256 == ^token_sha256,
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

    with %Session{} <- session,
         %Turn{} <- turn,
         {:ok, binding} <-
           StateBinding.derive(
             session,
             turn,
             StateBinding.placement_scope(placement),
             endpoint,
             state_tools_secret
           ),
         true <- binding.token_sha256 == token_sha256,
         {:ok, _current} <- Binding.resolve(binding.token) do
      {:ok, StateBinding.document(binding)}
    else
      _invalid -> {:error, {:coop_worker_state_binding_not_current, command.id}}
    end
  end

  defp materialize_binding(command, _placement, _descriptor, _state_tools_secret),
    do: {:error, {:coop_worker_state_binding_not_current, command.id}}

  defp locked_command!(command_id, worker_id) do
    Repo.one(
      from(command in Command,
        where: command.id == ^command_id and command.worker_id == ^worker_id,
        lock: "FOR UPDATE"
      )
    ) || Shared.rollback({:coop_worker_command_not_found, command_id})
  end

  defp locked_command_placement!(command) do
    Repo.one(
      from(placement in Placement,
        where:
          placement.id == ^command.placement_id and
            placement.worker_id == ^command.worker_id and
            placement.session_id == ^command.session_id and
            placement.generation == ^command.placement_generation,
        lock: "FOR UPDATE"
      )
    ) || Shared.rollback({:coop_session_placement_not_found, command.session_id})
  end

  defp enum(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, field}}
  end
end

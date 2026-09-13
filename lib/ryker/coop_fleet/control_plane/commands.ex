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
  alias Ryker.CoopFleet.{Command, Placement, Protocol}
  alias Ryker.CoopFleet.ControlPlane.{Placements, Shared}
  alias Ryker.Repo
  alias Ryker.StateTools.Binding
  alias Ryker.Work.{Session, StateBinding, Turn}

  @terminal_command_states [:succeeded, :failed, :uncertain]

  @spec enqueue_command(Ecto.UUID.t(), String.t(), map(), String.t()) ::
          {:ok, Command.t()} | {:error, term()}
  def enqueue_command(placement_id, kind, payload, idempotency_key) do
    with :ok <- Shared.uuid(placement_id, :placement_id),
         :ok <- enum(kind, Protocol.command_kinds(), :command_kind),
         :ok <- CanonicalJSON.validate(payload, max_bytes: 768 * 1_024),
         :ok <- Shared.reference(idempotency_key, 512, :idempotency_key) do
      Repo.transaction(fn ->
        enqueue_command_locked(placement_id, kind, payload, idempotency_key)
      end)
    else
      {:error, {:too_large, _actual, _limit}} ->
        {:error, {:invalid_coop_worker_command, :payload}}

      {:error, _reason} = error ->
        error
    end
  end

  defp enqueue_command_locked(placement_id, kind, payload, idempotency_key) do
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
    end)

    :ok
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
  def apply_command_results(worker_id, results, now) do
    Enum.map(results, fn result ->
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
    end)
  end

  @doc false
  def deliver_commands(worker_id, now, state_tools_secret) do
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

    Enum.map(commands, fn {command, placement} ->
      if command.status == :queued do
        command
        |> change(%{delivered_at: now, status: :delivered})
        |> Repo.update!()
      end

      placement
      |> change(%{last_command_id: command.id})
      |> Repo.update!()

      %{
        "command_id" => command.id,
        "command_version" => command.command_version,
        "idempotency_key" => command.idempotency_key,
        "kind" => command.kind,
        "lease_expires_at" => DateTime.to_iso8601(placement.lease_expires_at),
        "lease_ref" => placement.lease_ref,
        "payload" => materialize_command_payload!(command, placement, state_tools_secret),
        "placement_generation" => placement.generation,
        "session_ref" => placement.session_id,
        "worker_id" => placement.worker_id
      }
    end)
  end

  defp materialize_command_payload!(command, placement, state_tools_secret) do
    command.payload
    |> materialize_binding_at!(command, placement, state_tools_secret, ["responder_binding"])
    |> materialize_binding_at!(
      command,
      placement,
      state_tools_secret,
      ["request", "responder_binding"]
    )
  end

  defp materialize_binding_at!(payload, command, placement, state_tools_secret, path) do
    case get_in(payload, path) do
      nil ->
        payload

      descriptor ->
        put_in(
          payload,
          path,
          materialize_binding!(command, placement, descriptor, state_tools_secret)
        )
    end
  end

  defp materialize_binding!(
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
      StateBinding.document(binding)
    else
      _invalid -> Shared.rollback({:coop_worker_state_binding_not_current, command.id})
    end
  end

  defp materialize_binding!(command, _placement, _descriptor, _state_tools_secret),
    do: Shared.rollback({:coop_worker_state_binding_not_current, command.id})

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

defmodule Ryker.CoopFleet.Bridge do
  @moduledoc """
  Synchronous Ryker-side adapter over durable worker commands.

  Work remains the caller-facing state machine. This bridge places its exact
  immutable session, enqueues one idempotent API request, and waits only on
  the durable command row. Network delivery and worker retries happen through
  the outbound poll protocol.
  """

  import Ecto.Query

  alias Ryker.CoopFleet.{Bodies, Checkpoints, Command, ControlPlane, Placement}
  alias Ryker.CoopFleet.ControlPlane.Commands
  alias Ryker.Repo
  alias Ryker.Work.Session

  @option_keys [
    :body_root,
    :checkpoint_key,
    :checkpoint_secrets,
    :capability_names,
    :capability_versions,
    :lease_seconds,
    :max_waits,
    :poll_interval_ms,
    :wait,
    :workspace_ref
  ]

  @spec execute(Session.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(%Session{} = session, kind, payload, idempotency_key, options) do
    with {:ok, settings} <- settings(options),
         {:ok, command} <-
           enqueue(session, kind, payload, idempotency_key, settings),
         :ok <- Checkpoints.prepare_restore(command, options) do
      await(command.id, settings, settings.max_waits)
    end
  end

  def execute(_session, _kind, _payload, _idempotency_key, _options),
    do: {:error, {:invalid_coop_worker_bridge, :session}}

  defp enqueue(session, kind, payload, key, settings) do
    result =
      Commands.with_session_command(session.id, key, fn current, command ->
        enqueue_locked(command, current, session, kind, payload, key, settings)
      end)

    case result do
      {:ok, {:placement_ended, reason}} -> {:error, reason}
      result -> result
    end
  end

  defp enqueue_locked(%Command{} = command, current, _original, kind, payload, key, _settings) do
    expected =
      if Commands.local_fence?(command) and kind == "create_session",
        do: Commands.create_intent(current, payload["external_ref"]),
        else: payload

    if command.session_id == current.id and command.kind == kind and command.payload == expected,
      do: command,
      else: Repo.rollback({:coop_worker_command_conflict, key})
  end

  defp enqueue_locked(nil, current, original, kind, payload, key, settings) do
    validate_new_create(current, original, kind)

    with {:ok, placement} <-
           ControlPlane.place_session(
             current.id,
             requirements(current, settings),
             settings.lease_seconds
           ),
         {:ok, command} <- ControlPlane.enqueue_command(placement.id, kind, payload, key) do
      command
    else
      # Retiring an expired placement must commit even when no command was
      # enqueued. Rolling it back makes every recovery retry retire it again.
      {:error, {:coop_session_replacement_required, _, _} = reason} ->
        {:placement_ended, reason}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate_new_create(current, original, "create_session") do
    unless current.cleanup_status == :active and is_nil(current.coop_session_id) and
             current.create_generation == original.create_generation and
             Commands.create_intent(current) == Commands.create_intent(original) and
             current.worker_job_digest == original.worker_job_digest,
           do: Repo.rollback({:coop_fleet_authority_mismatch, :worker_job})
  end

  defp validate_new_create(_current, _original, _kind), do: :ok

  @doc "Whether a worker would take this session's placement now, without taking a slot."
  @spec accepts?(Session.t(), keyword()) :: boolean()
  def accepts?(%Session{} = session, options) do
    case settings(options) do
      {:ok, settings} -> ControlPlane.worker_available?(session, requirements(session, settings))
      {:error, _reason} -> false
    end
  end

  @doc """
  Places `session` as `execute/5` would, without enqueuing anything. A session bound to a
  worker session goes back to the worker holding it or nowhere.
  """
  @spec place(Session.t(), keyword()) :: {:ok, Placement.t()} | {:error, term()}
  def place(%Session{} = session, options) do
    with {:ok, settings} <- settings(options) do
      ControlPlane.place_session(
        session.id,
        requirements(session, settings),
        settings.lease_seconds
      )
    end
  end

  defp requirements(session, settings),
    do: %{
      capability_names: settings.capability_names,
      capability_versions: settings.capability_versions,
      repository_ref: session.repository_ref,
      workspace_ref: settings.workspace_ref
    }

  @spec await_command(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_command(command_id, options) do
    with {:ok, settings} <- settings(options) do
      await(command_id, settings, settings.max_waits)
    end
  end

  defp await(command_id, settings, left) when left > 0 do
    case Repo.get(Command, command_id) do
      %Command{placement_id: nil, status: :failed, error: %{"code" => "operation_not_enqueued"}} =
          command ->
        await_result(command, command_id, settings, left)

      %Command{} = command ->
        with :ok <- current_placement(command) do
          await_result(command, command_id, settings, left)
        end

      nil ->
        await_result(nil, command_id, settings, left)
    end
  end

  defp await(command_id, _settings, 0),
    do: {:error, {:coop_worker_command_timeout, command_id}}

  defp await_result(%Command{status: :succeeded} = command, _id, settings, _left),
    do: command_response(command, settings.body_root, settings.checkpoint_key)

  defp await_result(%Command{status: :failed, error: error}, _id, _settings, _left)
       when is_map(error) do
    {:error,
     {:coop_error, Map.get(error, "status", 0), error["code"] || "worker_command_failed",
      error["detail"] || "worker command failed"}}
  end

  defp await_result(%Command{status: :uncertain, error: error}, _id, _settings, _left)
       when is_map(error),
       do: {:error, {:coop_unavailable, error["detail"] || "worker command outcome is uncertain"}}

  defp await_result(%Command{status: status}, command_id, settings, left)
       when status in [:queued, :delivered, :acknowledged] do
    case settings.wait.() do
      :ok -> await(command_id, settings, left - 1)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_coop_worker_bridge_wait, other}}
    end
  end

  defp await_result(nil, command_id, _settings, _left),
    do: {:error, {:coop_worker_command_not_found, command_id}}

  defp await_result(%Command{}, _command_id, _settings, _left),
    do: {:error, {:invalid_coop_worker_bridge, :command_state}}

  @doc false
  def command_response(%Command{id: id, result: %{"body_ref" => reference} = result}, root, key) do
    with {:ok, stored, ^reference} <- Bodies.fetch(root, id, :response, reference) do
      headers = Map.get(result, "headers", %{})
      streamed_response(result, stored, reference, key, headers)
    end
  end

  def command_response(%Command{result: result}, _root, _key), do: response(result)

  defp streamed_response(result, stored, reference, key, headers) do
    if json_body?(headers) do
      json_response(result, stored, key)
    else
      with {:ok, nil} <- response(Map.delete(result, "body_ref")) do
        {:ok, %{stored_body: stored, body_ref: reference, headers: headers}}
      end
    end
  end

  defp json_response(result, stored, key) do
    with {:ok, bytes} <- Bodies.read(stored, key, 8 * 1_024 * 1_024),
         {:ok, body} <- Jason.decode(bytes) do
      response(result |> Map.delete("body_ref") |> Map.put("body", body))
    else
      _ -> {:error, {:coop_protocol_error, :response_body}}
    end
  end

  defp json_body?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "content-type" and
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
          "application/json"
    end)
  end

  @doc false
  def response(%{"status" => status, "body" => body}) when status in 200..299,
    do: {:ok, body}

  def response(%{"status" => status} = result) when status in 400..599 do
    problem = result["body"] || %{}
    nested = if is_map(problem), do: problem["error"] || problem, else: %{}
    error = if is_map(nested), do: nested, else: %{}

    {:error,
     {:coop_error, status, error["code"] || "coop_request_failed",
      error["detail"] || "Coop API request failed"}}
  end

  def response(%{"status" => status} = result)
      when status in 200..299 and map_size(result) <= 2 and not is_map_key(result, "body_ref"),
      do: {:ok, nil}

  def response(_response), do: {:error, {:invalid_coop_worker_bridge, :response}}

  defp current_placement(command) do
    placement = Repo.one(from(value in Placement, where: value.id == ^command.placement_id))
    now = Repo.now!()

    cond do
      placement && placement.state == :active &&
          DateTime.compare(placement.lease_expires_at, now) == :gt ->
        :ok

      placement && placement.state in [:assigning, :draining, :revoking] &&
          DateTime.compare(placement.lease_expires_at, now) == :gt ->
        {:error,
         {:coop_session_replacement_pending, command.session_id, command.placement_generation,
          placement.lease_expires_at}}

      true ->
        {:error,
         {:coop_session_replacement_required, command.session_id, command.placement_generation}}
    end
  end

  defp settings(options) when is_list(options) do
    if valid_option_list?(options) do
      options |> prepare_settings() |> validate_settings()
    else
      invalid_options()
    end
  end

  defp settings(_options), do: {:error, {:invalid_coop_worker_bridge, :options}}

  defp valid_option_list?(options),
    do:
      Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
        Keyword.keys(options) -- @option_keys == []

  defp prepare_settings(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 100)

    %{
      body_root: Keyword.get(options, :body_root),
      checkpoint_key: Keyword.get(options, :checkpoint_key),
      checkpoint_secrets: Keyword.get(options, :checkpoint_secrets, Ryker.Secret.new([])),
      capability_names: Keyword.get(options, :capability_names, []),
      capability_versions: Keyword.get(options, :capability_versions, %{}),
      lease_seconds: Keyword.get(options, :lease_seconds, 60),
      max_waits: Keyword.get(options, :max_waits, 3_000),
      poll_interval_ms: poll_interval_ms,
      wait: Keyword.get(options, :wait, fn -> Process.sleep(poll_interval_ms) end),
      workspace_ref: Keyword.get(options, :workspace_ref)
    }
  end

  defp validate_settings(settings) do
    if valid_settings?(settings) do
      {:ok, Map.delete(settings, :poll_interval_ms)}
    else
      invalid_options()
    end
  end

  defp valid_settings?(settings) do
    Enum.all?([
      is_nil(settings.body_root) or
        (is_binary(settings.body_root) and Path.type(settings.body_root) == :absolute),
      valid_capability_names?(settings.capability_names),
      valid_capability_versions?(settings.capability_versions),
      is_integer(settings.lease_seconds),
      settings.lease_seconds in 1..3_600,
      is_integer(settings.max_waits),
      settings.max_waits in 1..100_000,
      is_integer(settings.poll_interval_ms),
      settings.poll_interval_ms in 1..60_000,
      is_binary(settings.workspace_ref),
      settings.workspace_ref != "",
      is_function(settings.wait, 0)
    ])
  end

  defp valid_capability_names?(names) when is_list(names), do: Enum.all?(names, &is_binary/1)
  defp valid_capability_names?(_names), do: false

  defp valid_capability_versions?(versions)
       when is_map(versions) and map_size(versions) <= 100 do
    Enum.all?(versions, fn {name, version} ->
      is_binary(name) and name != "" and is_binary(version) and version != ""
    end)
  end

  defp valid_capability_versions?(_versions), do: false

  defp invalid_options, do: {:error, {:invalid_coop_worker_bridge, :options}}
end

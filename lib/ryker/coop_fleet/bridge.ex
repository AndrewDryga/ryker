defmodule Ryker.CoopFleet.Bridge do
  @moduledoc """
  Synchronous Ryker-side adapter over durable worker commands.

  Work remains the caller-facing state machine. This bridge places its exact
  immutable session, enqueues one idempotent typed command, and waits only on
  the durable command row. Network delivery and worker retries happen through
  the outbound poll protocol.
  """

  import Ecto.Query

  alias Ryker.CoopFleet.{Command, ControlPlane, Placement}
  alias Ryker.Repo
  alias Ryker.Work.Session

  @option_keys [
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
         {:ok, placement} <-
           ControlPlane.place_session(
             session.id,
             %{
               capability_names: settings.capability_names,
               capability_versions: settings.capability_versions,
               repository_ref: session.repository_ref,
               workspace_ref: settings.workspace_ref
             },
             settings.lease_seconds
           ),
         {:ok, command} <-
           ControlPlane.enqueue_command(placement.id, kind, payload, idempotency_key) do
      await(command.id, settings, settings.max_waits)
    end
  end

  def execute(_session, _kind, _payload, _idempotency_key, _options),
    do: {:error, {:invalid_coop_worker_bridge, :session}}

  @spec await_command(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_command(command_id, options) do
    with {:ok, settings} <- settings(options) do
      await(command_id, settings, settings.max_waits)
    end
  end

  defp await(command_id, settings, left) when left > 0 do
    case Repo.get(Command, command_id) do
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

  defp await_result(%Command{status: :succeeded, result: result}, _id, _settings, _left)
       when is_map(result),
       do: {:ok, result}

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

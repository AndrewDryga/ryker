defmodule Responder.Retention.Worker do
  @moduledoc "A small polling process for ownership cleanup."

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Polling

  alias Responder.Retention.{Custody, Dispatcher}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)

    if name,
      do: GenServer.start_link(__MODULE__, options, name: name),
      else: GenServer.start_link(__MODULE__, options)
  end

  @impl GenServer
  def init(options) do
    dispatcher = Keyword.get(options, :dispatcher, Dispatcher)
    dispatcher_options = Keyword.get(options, :dispatcher_options)
    maintenance = Keyword.get(options, :maintenance)
    maintenance_options = Keyword.get(options, :maintenance_options)
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 60_000)

    if is_atom(dispatcher) and is_list(dispatcher_options) and
         Keyword.keyword?(dispatcher_options) and is_integer(poll_interval_ms) and
         poll_interval_ms > 0 and maintenance?(maintenance, maintenance_options) do
      reconcile_restart(dispatcher_options)
      send(self(), :poll)

      {:ok,
       %{
         dispatcher: dispatcher,
         dispatcher_options: dispatcher_options,
         maintenance: maintenance,
         maintenance_options: maintenance_options,
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_retention_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:retention, state.poll_interval_ms, fn ->
        _result = process_once(state.dispatcher, state.dispatcher_options)
        _ = Progress.beat(:retention)
        _maintenance = maintain_once(state.maintenance, state.maintenance_options)
        state.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  # A restarted host owns none of the cleanup leases it wrote before the restart.
  # Waiting for them to expire only delayed the same work behind the lease clock.
  defp reconcile_restart(dispatcher_options) do
    case Keyword.fetch(dispatcher_options, :worker_ref) do
      {:ok, worker_ref} when is_binary(worker_ref) ->
        case Custody.release_worker_leases(worker_ref) do
          {:ok, 0} -> :ok
          {:ok, released} -> Logger.info("retention released #{released} restarted leases")
          {:error, reason} -> Logger.error("retention lease release failed: #{inspect(reason)}")
        end

      _missing ->
        :ok
    end
  rescue
    error -> Logger.error("retention lease release crashed: #{Exception.message(error)}")
  end

  defp maintain_once(nil, nil), do: :ok

  defp maintain_once(maintenance, options) do
    case maintenance.prune(options) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.error("retention data pruning failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("retention data pruning crashed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.error("retention data pruning caught #{kind}: #{inspect(reason)}")
  end

  defp maintenance?(nil, nil), do: true

  defp maintenance?(maintenance, options) when is_atom(maintenance) and is_map(options) do
    Code.ensure_loaded?(maintenance) and function_exported?(maintenance, :prune, 1)
  end

  defp maintenance?(_maintenance, _options), do: false

  defp process_once(dispatcher, options) do
    case dispatcher.run_pass(options) do
      {:ok, %{attempted: 0}} ->
        :ok

      {:ok, pass} ->
        if pass.blocked > 0 or pass.deferred > 0,
          do:
            Logger.warning(
              "retention pass executed #{pass.executed}, deferred #{pass.deferred}, " <>
                "blocked #{pass.blocked}, stopped on #{pass.stopped}"
            ),
          else: :ok

      {:error, reason} ->
        Logger.error("retention dispatcher failed: #{inspect(reason)}")
    end
  end
end

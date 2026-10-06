defmodule Ryker.Retention.Worker do
  @moduledoc "A small polling process for ownership cleanup and data pruning."

  use Ryker.PollingWorker, lane: :retention, interval: :poll_interval_ms
  require Logger
  alias Ryker.CoopFleet.{Bodies, ControlPlane}
  alias Ryker.Observability.Progress
  alias Ryker.Repo
  alias Ryker.Retention.{Custody, Data, Dispatcher}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl Ryker.PollingWorker
  def setup(options) do
    dispatcher = Keyword.get(options, :dispatcher, Dispatcher)
    dispatcher_options = Keyword.get(options, :dispatcher_options)
    maintenance = Keyword.get(options, :maintenance, Data)
    maintenance_options = Keyword.get(options, :maintenance_options)
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 60_000)

    if is_atom(dispatcher) and is_list(dispatcher_options) and
         Keyword.keyword?(dispatcher_options) and is_integer(poll_interval_ms) and
         poll_interval_ms > 0 and is_atom(maintenance) and is_map(maintenance_options) do
      reconcile_restart(dispatcher_options)

      {:ok,
       %{
         dispatcher: dispatcher,
         dispatcher_options: dispatcher_options,
         maintenance: maintenance,
         maintenance_options: maintenance_options,
         body_root: Keyword.get(options, :body_root),
         poll_interval_ms: poll_interval_ms,
         up_since: DateTime.utc_now()
       }}
    else
      {:stop, {:invalid_retention_worker, :options}}
    end
  end

  @impl Ryker.PollingWorker
  def poll(state) do
    _result = process_once(state.dispatcher, state.dispatcher_options)
    _ = Progress.beat(:retention)
    _maintenance = maintain_once(state.maintenance, state.maintenance_options, state.body_root)
    _placements = retire_abandoned_placements(state.up_since)
    state.poll_interval_ms
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

  # A command body is an orphan once its command row is gone, whatever else
  # the pass pruned, so a pass that failed whole or in part still clears them.
  defp maintain_once(maintenance, options, body_root) do
    prune_data(maintenance, options)
    prune_bodies(body_root)
  end

  defp prune_data(maintenance, options) do
    case maintenance.prune(options) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.error("retention data pruning failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("retention data pruning crashed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.error("retention data pruning caught #{kind}: #{inspect(reason)}")
  end

  defp prune_bodies(body_root) do
    case Bodies.prune_orphans(body_root) do
      :ok -> :ok
      {:error, reason} -> Logger.error("retention body pruning failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("retention body pruning crashed: #{Exception.message(error)}")
  end

  defp retire_abandoned_placements(up_since) do
    case ControlPlane.retire_abandoned_placements(Repo.now!(), up_since) do
      {:ok, 0} -> :ok
      {:ok, retired} -> Logger.info("retired #{retired} placements no worker will renew")
      {:error, reason} -> Logger.error("placement sweep failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("placement sweep crashed: #{Exception.message(error)}")
  end

  defp process_once(dispatcher, options) do
    case dispatcher.run_pass(options) do
      {:ok, %{attempted: 0}} ->
        :ok

      {:ok, pass} ->
        if pass.blocked > 0 or pass.deferred > 0 do
          Logger.warning(
            "retention pass executed #{pass.executed}, deferred #{pass.deferred}, " <>
              "blocked #{pass.blocked}, stopped on #{pass.stopped}"
          )
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("retention dispatcher failed: #{inspect(reason)}")
    end
  end
end

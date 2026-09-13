defmodule Ryker.Slack.MembershipReconciler do
  @moduledoc """
  Bounded recovery for Slack bot membership events missed while disconnected.

  Only a complete Slack listing can repair both missed joins and missed leaves.
  A temporary or partial listing failure therefore cannot falsely remove a
  channel or erase its configuration.
  """

  use GenServer

  require Logger

  @default_interval_ms 5 * 60 * 1_000

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options) do
    options = options!(options)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl GenServer
  def init(options) do
    send(self(), :reconcile)
    {:ok, options}
  end

  @impl GenServer
  def handle_info(:reconcile, options) do
    case run_once(options) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Slack membership reconciliation failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :reconcile, options.interval_ms)
    {:noreply, options}
  end

  @spec run_once(map()) :: {:ok, map()} | {:error, term()}
  def run_once(options) do
    snapshot_started_at = DateTime.utc_now()

    with {:ok, channels} <- options.api.joined_conversations(options.client),
         managed_channel_refs <- managed_channel_refs(channels, options),
         {:ok, results} <-
           options.configurations.reconcile_joined(
             options.workspace_ref,
             Enum.reject(channels, &(&1.channel_ref in managed_channel_refs)),
             options.setup_options.catalog
           ),
         {:ok, left} <-
           options.configurations.reconcile_absent(
             options.workspace_ref,
             channels,
             snapshot_started_at
           ),
         {:ok, prompted} <- prompt_sessions(results, options) do
      {:ok, %{channels: length(channels), left: left, prompted: prompted}}
    end
  end

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "Slack membership reconciler requires unique options")
  end

  def options!(%{} = options) do
    required = [:api, :client, :configurations, :setup_handler, :setup_options, :workspace_ref]
    optional = [:interval_ms, :managed_channel?, :name]
    keys = Map.keys(options)
    interval_ms = Map.get(options, :interval_ms, @default_interval_ms)
    managed_channel? = Map.get(options, :managed_channel?)

    if keys -- (required ++ optional) == [] and Enum.all?(required, &(&1 in keys)) and
         is_integer(interval_ms) and interval_ms in 30_000..3_600_000 and
         (is_nil(managed_channel?) or is_function(managed_channel?, 2)) do
      options
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:name, nil)
    else
      raise ArgumentError, "invalid Slack membership reconciler options"
    end
  end

  def options!(_options), do: raise(ArgumentError, "invalid Slack membership reconciler options")

  defp managed_channel_refs(channel_refs, %{
         managed_channel?: callback,
         workspace_ref: workspace_ref
       })
       when is_function(callback, 2) do
    channel_refs
    |> Enum.map(& &1.channel_ref)
    |> Enum.filter(&callback.(workspace_ref, &1))
  end

  defp managed_channel_refs(_channel_refs, _options), do: []

  # Only a membership the reconciler itself repaired gets a welcome. Channels
  # that were already joined keep their existing welcome (or none): a periodic
  # sweep must never flood configured channels with unsolicited hellos.
  defp prompt_sessions(results, options) do
    Enum.reduce_while(results, {:ok, 0}, fn
      %{configuration: %{} = configuration, status: :joined}, {:ok, count} ->
        case options.setup_handler.ensure_welcome(configuration, nil, options.setup_options) do
          {:ok, _outcome} -> {:cont, {:ok, count + 1}}
          {:error, _reason} = error -> {:halt, error}
        end

      _result, {:ok, count} ->
        {:cont, {:ok, count}}
    end)
  end
end

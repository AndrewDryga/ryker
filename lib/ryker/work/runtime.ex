defmodule Ryker.Work.Runtime do
  @moduledoc """
  Supervises a bounded pool of workers sharing one configured Coop API adapter.

  Each slot receives only the shared Coop adapter and a distinct lease
  identity. Episode authority is pinned during admission and cannot be selected
  by a worker. Product assembly supplies the durable outbound fleet adapter;
  component tests supply a test double in its place.
  """

  use Supervisor
  alias Ryker.Options
  alias Ryker.StateTools.Capabilities
  alias Ryker.Work.{ActivitySyncWorker, Executor, Worker}

  @fields [
    :api,
    :client,
    :concurrency,
    :connected,
    :platform_tools,
    :poll_interval_ms,
    :receive_timeout_ms,
    :state_tool_capabilities,
    :state_tools_endpoint,
    :state_tools_secret,
    :worker_ref
  ]
  @lease_seconds 300
  @default_concurrency 4
  @maximum_concurrency 32
  @maximum_receive_timeout_ms div(@lease_seconds * 1_000, 3)

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [configuration]},
      type: :supervisor
    }
  end

  @spec start_link(keyword() | map()) :: Supervisor.on_start()
  def start_link(configuration) do
    Supervisor.start_link(__MODULE__, configuration, name: __MODULE__)
  end

  @impl Supervisor
  def init(configuration) do
    options = options!(configuration)

    workers =
      for slot <- 1..options.concurrency do
        worker_options = [
          dispatcher_options: [
            executor_options: executor_options(options),
            lease_seconds: @lease_seconds,
            worker_ref: "#{options.worker_ref}:slot-#{slot}"
          ],
          poll_interval_ms: options.poll_interval_ms
        ]

        Supervisor.child_spec({Worker, worker_options}, id: {Worker, slot})
      end

    Supervisor.init(activity_sync(options) ++ workers, strategy: :one_for_one)
  end

  defp executor_options(options) do
    [
      client: options.client,
      api: options.api,
      connected: options.connected,
      max_block_ms: options.receive_timeout_ms,
      platform_tools: options.platform_tools,
      poll_interval_ms: options.poll_interval_ms,
      state_tool_capabilities: options.state_tool_capabilities,
      state_tools_endpoint: options.state_tools_endpoint,
      state_tools_secret: options.state_tools_secret
    ]
  end

  # Only a direct Coop client lists a session's events; the fleet client a
  # release runs reads activity from the worker's event batches, and this
  # worker woke four times a second there to do nothing (2026-10-04 review).
  defp activity_sync(options) do
    if Code.ensure_loaded?(options.api) and function_exported?(options.api, :list_events, 4) do
      [
        Supervisor.child_spec(
          {ActivitySyncWorker,
           api: options.api, client: options.client, poll_interval_ms: options.poll_interval_ms},
          id: ActivitySyncWorker
        )
      ]
    else
      []
    end
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    concurrency = Map.get(configuration, :concurrency, @default_concurrency)
    platform_tools = Map.get(configuration, :platform_tools)
    connected = Map.get(configuration, :connected)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    receive_timeout_ms = Map.get(configuration, :receive_timeout_ms, 30_000)
    state_tools_endpoint = Map.get(configuration, :state_tools_endpoint)
    state_tools_secret = Map.get(configuration, :state_tools_secret)

    state_tool_capabilities =
      Map.get(
        configuration,
        :state_tool_capabilities,
        if(state_tools_endpoint, do: Capabilities.default(), else: nil)
      )

    validate_concurrency!(concurrency)
    validate_positive!(poll_interval_ms, :poll_interval_ms)
    validate_positive!(receive_timeout_ms, :receive_timeout_ms)
    validate_receive_timeout!(receive_timeout_ms)
    validate_ref!(worker_ref, :worker_ref)
    {api, client} = coop_adapter!(configuration)

    options = %{
      api: api,
      client: client,
      concurrency: concurrency,
      connected: connected,
      platform_tools: platform_tools,
      poll_interval_ms: poll_interval_ms,
      receive_timeout_ms: receive_timeout_ms,
      state_tool_capabilities: state_tool_capabilities,
      state_tools_endpoint: state_tools_endpoint,
      state_tools_secret: state_tools_secret,
      worker_ref: worker_ref
    }

    # The executor's own check of what each worker will run with; a second copy
    # here disagreed with it on platform tool names (2026-10-04 review).
    case Executor.check_options([{:lease_seconds, @lease_seconds} | executor_options(options)]) do
      :ok -> options
      {:error, {:invalid_work_executor, field}} -> raise ArgumentError, "work #{field} is invalid"
    end
  end

  defp normalize_configuration!(configuration) do
    Options.normalize!(configuration, @fields, [:api, :client, :worker_ref],
      list: "work configuration must use unique known fields",
      map: "work configuration has missing or unknown fields",
      other: "work configuration must be a map or keyword list"
    )
  end

  defp validate_positive!(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(_value, field) do
    raise ArgumentError, "work #{field} must be a positive integer"
  end

  defp validate_concurrency!(value)
       when is_integer(value) and value > 0 and value <= @maximum_concurrency,
       do: :ok

  defp validate_concurrency!(_value) do
    raise ArgumentError, "work concurrency must be between 1 and #{@maximum_concurrency}"
  end

  defp validate_receive_timeout!(value) when value < @maximum_receive_timeout_ms, do: :ok

  defp validate_receive_timeout!(_value) do
    raise ArgumentError,
          "work receive_timeout_ms must fit within the durable lease heartbeat window"
  end

  defp coop_adapter!(%{api: api, client: client})
       when is_atom(api) and not is_nil(api) and not is_nil(client) do
    if Code.ensure_loaded?(api) and function_exported?(api, :get_session, 2),
      do: {api, client},
      else: raise(ArgumentError, "work api must implement the Coop session contract")
  end

  defp coop_adapter!(_configuration),
    do: raise(ArgumentError, "work requires a trusted Coop adapter")

  defp validate_ref!(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: raise(ArgumentError, "work reference must be a bounded nonblank string")
  end

  defp validate_ref!(_value, field) do
    raise ArgumentError, "work #{field} must be a bounded string"
  end
end

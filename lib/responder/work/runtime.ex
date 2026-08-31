defmodule Responder.Work.Runtime do
  @moduledoc """
  Supervises a bounded pool of workers sharing one configured Coop API adapter.

  Each slot receives only the shared Coop socket and a distinct lease identity.
  Episode authority is pinned during admission and cannot be selected by a
  worker. Product mode supplies the durable outbound fleet adapter; component
  tests may explicitly supply the private Unix-socket adapter.
  """

  use Supervisor

  alias Responder.Coop.Client
  alias Responder.Work.{Session, StateBinding, Turn, Worker}

  @fields [
    :api,
    :client,
    :concurrency,
    :poll_interval_ms,
    :receive_timeout_ms,
    :socket,
    :state_tool_capabilities,
    :state_tools_endpoint,
    :state_tools_secret,
    :worker_ref
  ]
  @lease_seconds 300
  @default_concurrency 4
  @maximum_concurrency 32
  @maximum_receive_timeout_ms div(@lease_seconds * 1_000, 3)
  @default_state_tool_capabilities [:event_waits, :publication, :schedules]
  @state_tool_capabilities [:emisar_approvals, :event_waits, :publication, :schedules]

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

    children =
      for slot <- 1..options.concurrency do
        worker_options = [
          dispatcher_options: [
            executor_options: [
              client: options.client,
              api: options.api,
              max_block_ms: options.receive_timeout_ms,
              poll_interval_ms: options.poll_interval_ms,
              state_tool_capabilities: options.state_tool_capabilities,
              state_tools_endpoint: options.state_tools_endpoint,
              state_tools_secret: options.state_tools_secret
            ],
            lease_seconds: @lease_seconds,
            worker_ref: "#{options.worker_ref}:slot-#{slot}"
          ],
          poll_interval_ms: options.poll_interval_ms
        ]

        Supervisor.child_spec({Worker, worker_options}, id: {Worker, slot})
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    concurrency = Map.get(configuration, :concurrency, @default_concurrency)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    receive_timeout_ms = Map.get(configuration, :receive_timeout_ms, 30_000)
    state_tools_endpoint = Map.get(configuration, :state_tools_endpoint)
    state_tools_secret = Map.get(configuration, :state_tools_secret)

    state_tool_capabilities =
      Map.get(
        configuration,
        :state_tool_capabilities,
        if(state_tools_endpoint, do: @default_state_tool_capabilities, else: nil)
      )

    validate_concurrency!(concurrency)
    validate_positive!(poll_interval_ms, :poll_interval_ms)
    validate_positive!(receive_timeout_ms, :receive_timeout_ms)
    validate_receive_timeout!(receive_timeout_ms)
    validate_ref!(worker_ref, :worker_ref)
    validate_state_tools!(state_tools_endpoint, state_tools_secret)
    validate_state_tool_capabilities!(state_tool_capabilities, state_tools_endpoint)
    {api, client} = coop_adapter!(configuration, receive_timeout_ms)

    %{
      api: api,
      client: client,
      concurrency: concurrency,
      poll_interval_ms: poll_interval_ms,
      receive_timeout_ms: receive_timeout_ms,
      state_tool_capabilities: state_tool_capabilities,
      state_tools_endpoint: state_tools_endpoint,
      state_tools_secret: state_tools_secret,
      worker_ref: worker_ref
    }
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "work configuration must use unique known fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)
    required = [:worker_ref]

    if keys -- @fields == [] and Enum.all?(required, &(&1 in keys)) and
         ((:socket in keys and :api not in keys and :client not in keys) or
            (:socket not in keys and :api in keys and :client in keys)),
       do: configuration,
       else: raise(ArgumentError, "work configuration has missing or unknown fields")
  end

  defp normalize_configuration!(_configuration) do
    raise ArgumentError, "work configuration must be a map or keyword list"
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

  defp coop_adapter!(%{api: api, client: client}, _receive_timeout_ms)
       when is_atom(api) and not is_nil(client) do
    if Code.ensure_loaded?(api) and function_exported?(api, :get_session, 2),
      do: {api, client},
      else: raise(ArgumentError, "work api must implement the Coop session contract")
  end

  defp coop_adapter!(%{socket: socket}, receive_timeout_ms) do
    validate_ref!(socket, :socket)

    case Client.new(
           finch: Responder.CoopFinch,
           receive_timeout: receive_timeout_ms,
           socket: socket
         ) do
      {:ok, client} -> {Client, client}
      {:error, reason} -> raise ArgumentError, "invalid work Coop client: #{inspect(reason)}"
    end
  end

  defp validate_ref!(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: raise(ArgumentError, "work reference must be a bounded nonblank string")
  end

  defp validate_ref!(_value, field) do
    raise ArgumentError, "work #{field} must be a bounded string"
  end

  defp validate_state_tools!(nil, nil), do: :ok

  defp validate_state_tools!(endpoint, secret) do
    case StateBinding.derive(
           %Session{id: Ecto.UUID.generate()},
           %Turn{id: Ecto.UUID.generate()},
           "local:configuration-validation",
           endpoint,
           secret
         ) do
      {:ok, _binding} -> :ok
      {:error, _reason} -> raise ArgumentError, "work state-tools binding is invalid"
    end
  end

  defp validate_state_tool_capabilities!(nil, nil), do: :ok

  defp validate_state_tool_capabilities!(capabilities, endpoint)
       when is_binary(endpoint) and is_list(capabilities) do
    if capabilities == Enum.uniq(capabilities) and
         Enum.all?(capabilities, &(&1 in @state_tool_capabilities)),
       do: :ok,
       else: raise(ArgumentError, "work state_tool_capabilities must be unique known atoms")
  end

  defp validate_state_tool_capabilities!(_capabilities, _endpoint) do
    raise ArgumentError, "work state_tool_capabilities require a state-tools endpoint"
  end
end

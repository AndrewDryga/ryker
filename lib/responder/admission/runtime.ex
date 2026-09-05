defmodule Responder.Admission.Runtime do
  @moduledoc """
  Supervises bounded admission slots from one trusted configuration.

  Incoming events cannot select the Coop socket, policy, worker identity, or
  execution limits.
  """

  use Supervisor

  alias Responder.Admission.{FleetSession, Worker}
  alias Responder.Coop.Client

  @fields [
    :api,
    :client,
    :concurrency,
    :decision_timeout_ms,
    :policy,
    :policy_digest,
    :poll_interval_ms,
    :receive_timeout_ms,
    :socket,
    :worker_ref
  ]
  @lease_seconds 300
  @maximum_decision_timeout_ms @lease_seconds * 1_000
  @maximum_receive_timeout_ms div(@lease_seconds * 1_000, 3)

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}, type: :supervisor}
  end

  def start_link(configuration),
    do: Supervisor.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl Supervisor
  def init(configuration) do
    options = options!(configuration)

    children =
      for slot <- 1..options.concurrency do
        Supervisor.child_spec(
          {Worker,
           [
             dispatcher_options: [
               executor_options: [
                 api: options.api,
                 bind_execution_session: options.bind_execution_session,
                 client: options.client,
                 maximum_elapsed_ms: options.decision_timeout_ms,
                 policy: options.policy,
                 policy_digest: options.policy_digest,
                 prepare_execution_session: options.prepare_execution_session,
                 settle_execution_session: options.settle_execution_session
               ],
               lease_seconds: @lease_seconds,
               worker_ref: "#{options.worker_ref}:slot-#{slot}"
             ],
             poll_interval_ms: options.poll_interval_ms
           ]},
          id: {Worker, slot}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    policy = Map.fetch!(configuration, :policy)
    policy_digest = Map.fetch!(configuration, :policy_digest)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    concurrency = Map.get(configuration, :concurrency, 4)
    decision_timeout_ms = Map.get(configuration, :decision_timeout_ms, 30_000)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    receive_timeout_ms = Map.get(configuration, :receive_timeout_ms, 30_000)

    validate_positive!(poll_interval_ms, :poll_interval_ms)

    unless is_integer(concurrency) and concurrency in 1..32,
      do: raise(ArgumentError, "admission concurrency must be between 1 and 32")

    validate_positive!(decision_timeout_ms, :decision_timeout_ms)
    validate_decision_timeout!(decision_timeout_ms)
    validate_positive!(receive_timeout_ms, :receive_timeout_ms)
    validate_receive_timeout!(receive_timeout_ms)
    validate_ref!(policy, :policy)
    validate_digest!(policy_digest)
    validate_ref!(worker_ref, :worker_ref)

    {api, client, callbacks} = coop_adapter!(configuration, receive_timeout_ms)

    Map.merge(callbacks, %{
      api: api,
      client: client,
      concurrency: concurrency,
      decision_timeout_ms: decision_timeout_ms,
      policy: policy,
      policy_digest: policy_digest,
      poll_interval_ms: poll_interval_ms,
      worker_ref: worker_ref
    })
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "admission configuration must use unique known fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)
    required = [:policy, :policy_digest, :worker_ref]

    adapter =
      (:socket in keys and :api not in keys and :client not in keys) or
        (:socket not in keys and :api in keys and :client in keys)

    if keys -- @fields == [] and Enum.all?(required, &(&1 in keys)) and adapter,
      do: configuration,
      else: raise(ArgumentError, "admission configuration has missing or unknown fields")
  end

  defp normalize_configuration!(_configuration) do
    raise ArgumentError, "admission configuration must be a map or keyword list"
  end

  defp validate_positive!(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(_value, field) do
    raise ArgumentError, "admission #{field} must be a positive integer"
  end

  defp validate_receive_timeout!(value) when value <= @maximum_receive_timeout_ms, do: :ok

  defp validate_receive_timeout!(_value) do
    raise ArgumentError,
          "admission receive_timeout_ms must fit within the durable lease heartbeat window"
  end

  defp validate_decision_timeout!(value) when value <= @maximum_decision_timeout_ms, do: :ok

  defp validate_decision_timeout!(_value) do
    raise ArgumentError, "admission decision_timeout_ms must fit within the durable lease window"
  end

  defp coop_adapter!(%{api: api, client: client}, _receive_timeout_ms)
       when is_atom(api) and not is_nil(client) do
    if Code.ensure_loaded?(api) and function_exported?(api, :get_session, 2) do
      callbacks = %{
        bind_execution_session: &FleetSession.bind/2,
        prepare_execution_session: fn entry, policy -> FleetSession.ensure(entry, policy) end,
        settle_execution_session: &FleetSession.settle/2
      }

      {api, client, callbacks}
    else
      raise ArgumentError, "admission api must implement the Coop session contract"
    end
  end

  defp coop_adapter!(%{socket: socket}, receive_timeout_ms) do
    validate_ref!(socket, :socket)

    case Client.new(
           finch: Responder.CoopFinch,
           receive_timeout: receive_timeout_ms,
           socket: socket
         ) do
      {:ok, client} ->
        callbacks = %{
          bind_execution_session: fn _entry, _session_id -> :ok end,
          prepare_execution_session: fn _entry, _policy -> :ok end,
          settle_execution_session: fn _entry, _session_id -> :ok end
        }

        {Client, client, callbacks}

      {:error, reason} ->
        raise ArgumentError, "invalid admission Coop client: #{inspect(reason)}"
    end
  end

  defp validate_ref!(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: raise(ArgumentError, "admission reference must be a bounded nonblank string")
  end

  defp validate_ref!(_value, field) do
    raise ArgumentError, "admission #{field} must be a bounded string"
  end

  defp validate_digest!(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: raise(ArgumentError, "admission policy_digest must be a lowercase SHA-256 digest")
  end
end

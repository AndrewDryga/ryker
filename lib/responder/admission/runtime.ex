defmodule Responder.Admission.Runtime do
  @moduledoc """
  Builds the optional admission worker from a small trusted configuration.

  Incoming events cannot select the Coop socket, policy, worker identity, or
  execution limits.
  """

  alias Responder.Admission.Worker
  alias Responder.Coop.Client

  @fields [:policy, :poll_interval_ms, :receive_timeout_ms, :socket, :worker_ref]
  @lease_seconds 300
  @maximum_receive_timeout_ms div(@lease_seconds * 1_000, 3)

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Supervisor.child_spec(
      {Worker,
       [
         dispatcher_options: [
           executor_options: [client: options.client, policy: options.policy],
           lease_seconds: @lease_seconds,
           worker_ref: options.worker_ref
         ],
         poll_interval_ms: options.poll_interval_ms
       ]},
      id: __MODULE__
    )
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    socket = Map.fetch!(configuration, :socket)
    policy = Map.fetch!(configuration, :policy)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    receive_timeout_ms = Map.get(configuration, :receive_timeout_ms, 30_000)

    validate_positive!(poll_interval_ms, :poll_interval_ms)
    validate_positive!(receive_timeout_ms, :receive_timeout_ms)
    validate_receive_timeout!(receive_timeout_ms)
    validate_ref!(policy, :policy)
    validate_ref!(worker_ref, :worker_ref)

    case Client.new(
           finch: Responder.CoopFinch,
           receive_timeout: receive_timeout_ms,
           socket: socket
         ) do
      {:ok, client} ->
        %{
          client: client,
          policy: policy,
          poll_interval_ms: poll_interval_ms,
          worker_ref: worker_ref
        }

      {:error, reason} ->
        raise ArgumentError, "invalid admission Coop client: #{inspect(reason)}"
    end
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
    required = [:policy, :socket, :worker_ref]

    if keys -- @fields == [] and Enum.all?(required, &(&1 in keys)),
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

  defp validate_ref!(value, _field) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: raise(ArgumentError, "admission reference must be a bounded nonblank string")
  end

  defp validate_ref!(_value, field) do
    raise ArgumentError, "admission #{field} must be a bounded string"
  end
end

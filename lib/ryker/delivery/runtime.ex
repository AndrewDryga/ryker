defmodule Ryker.Delivery.Runtime do
  @moduledoc """
  Supervises independent bounded pools for messages, reactions, and model-requested actions.

  The trusted adapter registry owns platform credentials and bindings. A worker
  receives only that prepared registry plus an opaque lease identity.
  """

  use Supervisor

  alias Ryker.Delivery.{Adapters, Worker}

  @fields [
    :action_concurrency,
    :adapters,
    :lease_seconds,
    :max_attempts,
    :message_concurrency,
    :poll_interval_ms,
    :reaction_concurrency,
    :retry_base_seconds,
    :retry_max_seconds,
    :worker_ref
  ]
  @maximum_concurrency 32

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
      worker_children(:message, options.message_concurrency, options) ++
        worker_children(:reaction, options.reaction_concurrency, options) ++
        worker_children(:action, options.action_concurrency, options)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    registrations = Map.fetch!(configuration, :adapters)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    message_concurrency = Map.get(configuration, :message_concurrency, 2)
    reaction_concurrency = Map.get(configuration, :reaction_concurrency, 1)
    action_concurrency = Map.get(configuration, :action_concurrency, 1)
    lease_seconds = Map.get(configuration, :lease_seconds, 60)
    max_attempts = Map.get(configuration, :max_attempts, 8)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    retry_base_seconds = Map.get(configuration, :retry_base_seconds, 1)
    retry_max_seconds = Map.get(configuration, :retry_max_seconds, 60)

    validate_concurrency!(message_concurrency, reaction_concurrency, action_concurrency)
    validate_positive!(lease_seconds, :lease_seconds)
    validate_positive!(max_attempts, :max_attempts)
    validate_positive!(poll_interval_ms, :poll_interval_ms)
    validate_positive!(retry_base_seconds, :retry_base_seconds)
    validate_positive!(retry_max_seconds, :retry_max_seconds)
    validate_retry_bounds!(retry_base_seconds, retry_max_seconds)
    validate_ref!(worker_ref)

    adapters =
      case Adapters.new(registrations) do
        {:ok, adapters} -> adapters
        {:error, reason} -> raise ArgumentError, "invalid delivery adapters: #{inspect(reason)}"
      end

    %{
      action_concurrency: action_concurrency,
      adapters: adapters,
      lease_seconds: lease_seconds,
      max_attempts: max_attempts,
      message_concurrency: message_concurrency,
      poll_interval_ms: poll_interval_ms,
      reaction_concurrency: reaction_concurrency,
      retry_base_seconds: retry_base_seconds,
      retry_max_seconds: retry_max_seconds,
      worker_ref: worker_ref
    }
  end

  defp worker_children(kind, concurrency, options) do
    for slot <- 1..concurrency do
      worker_options = [
        dispatcher_options: [
          adapters: options.adapters,
          kind: kind,
          lease_seconds: options.lease_seconds,
          max_attempts: options.max_attempts,
          retry_base_seconds: options.retry_base_seconds,
          retry_max_seconds: options.retry_max_seconds,
          worker_ref: "#{options.worker_ref}:#{kind}:slot-#{slot}"
        ],
        poll_interval_ms: options.poll_interval_ms
      ]

      Supervisor.child_spec({Worker, worker_options}, id: {Worker, kind, slot})
    end
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "delivery configuration must use unique known fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)
    required = [:adapters, :worker_ref]

    if keys -- @fields == [] and Enum.all?(required, &(&1 in keys)),
      do: configuration,
      else: raise(ArgumentError, "delivery configuration has missing or unknown fields")
  end

  defp normalize_configuration!(_configuration) do
    raise ArgumentError, "delivery configuration must be a map or keyword list"
  end

  defp validate_concurrency!(messages, reactions, actions)
       when is_integer(messages) and messages > 0 and is_integer(reactions) and reactions > 0 and
              is_integer(actions) and actions > 0 and
              messages + reactions + actions <= @maximum_concurrency,
       do: :ok

  defp validate_concurrency!(_messages, _reactions, _actions) do
    raise ArgumentError,
          "delivery message, reaction, and action concurrency must total between 3 and #{@maximum_concurrency}"
  end

  defp validate_positive!(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(_value, field) do
    raise ArgumentError, "delivery #{field} must be a positive integer"
  end

  defp validate_retry_bounds!(base, maximum) when maximum >= base, do: :ok

  defp validate_retry_bounds!(_base, _maximum) do
    raise ArgumentError, "delivery retry_max_seconds must be at least retry_base_seconds"
  end

  defp validate_ref!(value) when is_binary(value) do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: raise(ArgumentError, "delivery worker_ref must be a bounded nonblank string")
  end

  defp validate_ref!(_value) do
    raise ArgumentError, "delivery worker_ref must be a bounded string"
  end
end

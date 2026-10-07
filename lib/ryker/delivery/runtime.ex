defmodule Ryker.Delivery.Runtime do
  @moduledoc """
  Supervises independent bounded pools for messages, routing responses,
  model-requested actions and the weekly report.

  The trusted adapter registry owns platform credentials and bindings. A worker
  receives only that prepared registry plus an opaque lease identity.
  """
  use Supervisor
  alias Ryker.Defaults
  alias Ryker.Delivery.{Adapters, Worker}
  alias Ryker.Options

  @fields [
    :action_concurrency,
    :adapters,
    :lease_seconds,
    :max_attempts,
    :message_concurrency,
    :poll_interval_ms,
    :report_concurrency,
    :routing_concurrency,
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
        worker_children(:routing, options.routing_concurrency, options) ++
        worker_children(:action, options.action_concurrency, options) ++
        worker_children(:report, options.report_concurrency, options)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    # What the configuration leaves out is the shipped default.
    options = Map.merge(Defaults.fetch!(:delivery), normalize_configuration!(configuration))

    validate_concurrency!(
      options.message_concurrency,
      options.routing_concurrency,
      options.action_concurrency,
      options.report_concurrency
    )

    for field <- [
          :lease_seconds,
          :max_attempts,
          :poll_interval_ms,
          :retry_base_seconds,
          :retry_max_seconds
        ],
        do: validate_positive!(Map.fetch!(options, field), field)

    validate_retry_bounds!(options.retry_base_seconds, options.retry_max_seconds)
    validate_ref!(Map.fetch!(options, :worker_ref))

    case Adapters.new(Map.fetch!(options, :adapters)) do
      {:ok, adapters} -> %{options | adapters: adapters}
      {:error, reason} -> raise ArgumentError, "invalid delivery adapters: #{inspect(reason)}"
    end
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

  defp normalize_configuration!(configuration) do
    Options.normalize!(configuration, @fields, [:adapters, :worker_ref],
      list: "delivery configuration must use unique known fields",
      map: "delivery configuration has missing or unknown fields",
      other: "delivery configuration must be a map or keyword list"
    )
  end

  defp validate_concurrency!(messages, routing, actions, reports)
       when is_integer(messages) and messages > 0 and is_integer(routing) and routing > 0 and
              is_integer(actions) and actions > 0 and is_integer(reports) and reports > 0 and
              messages + routing + actions + reports <= @maximum_concurrency,
       do: :ok

  defp validate_concurrency!(_messages, _routing, _actions, _reports) do
    raise ArgumentError,
          "delivery message, routing, action and report concurrency must total between 4 and #{@maximum_concurrency}"
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

defmodule Ryker.Publication.Runtime do
  @moduledoc """
  Supervises a bounded pool for review, notification, and draft publication.
  """

  use Supervisor

  alias Ryker.Coop.Client
  alias Ryker.Delivery.Adapters
  alias Ryker.Publication.{FollowupWorker, Worker}

  @fields [
    :concurrency,
    :coop_api,
    :coop_client,
    :delivery_adapters,
    :followup_interval_seconds,
    :lease_seconds,
    :poll_interval_ms,
    :publisher,
    :publisher_binding,
    :receive_timeout_ms,
    :retry_base_seconds,
    :retry_max_seconds,
    :socket,
    :worker_ref
  ]
  @maximum_concurrency 16

  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}, type: :supervisor}
  end

  def start_link(configuration),
    do: Supervisor.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl Supervisor
  def init(configuration) do
    options = options!(configuration)

    publication_workers =
      for slot <- 1..options.concurrency do
        dispatcher_options = [
          executor_options: [
            adapters: options.delivery_adapters,
            api: options.coop_api,
            client: options.coop_client,
            publisher: options.publisher,
            publisher_binding: options.publisher_binding
          ],
          lease_seconds: options.lease_seconds,
          retry_base_seconds: options.retry_base_seconds,
          retry_max_seconds: options.retry_max_seconds,
          worker_ref: "#{options.worker_ref}:slot-#{slot}"
        ]

        Supervisor.child_spec(
          {Worker,
           dispatcher_options: dispatcher_options, poll_interval_ms: options.poll_interval_ms},
          id: {Worker, slot}
        )
      end

    followup_dispatcher_options = [
      executor_options: [
        adapters: options.delivery_adapters,
        api: options.status_api,
        client: options.status_client
      ],
      interval_seconds: options.followup_interval_seconds,
      lease_seconds: options.lease_seconds,
      retry_base_seconds: options.retry_base_seconds,
      retry_max_seconds: max(options.retry_max_seconds, options.followup_interval_seconds),
      worker_ref: "#{options.worker_ref}:followup"
    ]

    followup_worker =
      Supervisor.child_spec(
        {FollowupWorker,
         dispatcher_options: followup_dispatcher_options,
         poll_interval_ms: options.poll_interval_ms},
        id: FollowupWorker
      )

    Supervisor.init(publication_workers ++ [followup_worker], strategy: :one_for_one)
  end

  def options!(configuration) do
    configuration = normalize!(configuration)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    publisher = Map.fetch!(configuration, :publisher)
    publisher_binding = Map.fetch!(configuration, :publisher_binding)
    concurrency = Map.get(configuration, :concurrency, 2)
    lease_seconds = Map.get(configuration, :lease_seconds, 60)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    receive_timeout_ms = Map.get(configuration, :receive_timeout_ms, 30_000)
    retry_base_seconds = Map.get(configuration, :retry_base_seconds, 1)
    retry_max_seconds = Map.get(configuration, :retry_max_seconds, 60)
    followup_interval_seconds = Map.get(configuration, :followup_interval_seconds, 120)

    validate_integer!(concurrency, 1, @maximum_concurrency, :concurrency)
    validate_integer!(lease_seconds, 1, 86_400, :lease_seconds)
    validate_integer!(poll_interval_ms, 1, 60_000, :poll_interval_ms)
    validate_integer!(receive_timeout_ms, 1, lease_seconds * 1_000 - 1, :receive_timeout_ms)
    validate_integer!(retry_base_seconds, 1, 86_400, :retry_base_seconds)
    validate_integer!(retry_max_seconds, retry_base_seconds, 86_400, :retry_max_seconds)
    validate_integer!(followup_interval_seconds, 30, 3_600, :followup_interval_seconds)
    validate_ref!(worker_ref)
    validate_publisher!(publisher)
    {status_api, status_client} = status_source!(publisher_binding)

    delivery_adapters =
      case configuration |> Map.fetch!(:delivery_adapters) |> Adapters.new() do
        {:ok, adapters} ->
          adapters

        {:error, reason} ->
          raise ArgumentError, "invalid publication delivery adapters: #{inspect(reason)}"
      end

    {coop_api, coop_client} = coop_adapter!(configuration, receive_timeout_ms)

    %{
      coop_api: coop_api,
      coop_client: coop_client,
      concurrency: concurrency,
      delivery_adapters: delivery_adapters,
      followup_interval_seconds: followup_interval_seconds,
      lease_seconds: lease_seconds,
      poll_interval_ms: poll_interval_ms,
      publisher: publisher,
      publisher_binding: publisher_binding,
      receive_timeout_ms: receive_timeout_ms,
      retry_base_seconds: retry_base_seconds,
      retry_max_seconds: retry_max_seconds,
      status_api: status_api,
      status_client: status_client,
      worker_ref: worker_ref
    }
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
       do: configuration |> Map.new() |> normalize!(),
       else: raise(ArgumentError, "publication configuration must use unique known fields")
  end

  defp normalize!(%{} = configuration) do
    required = [:delivery_adapters, :publisher, :publisher_binding, :worker_ref]
    keys = Map.keys(configuration)

    if keys -- @fields == [] and Enum.all?(required, &Map.has_key?(configuration, &1)) and
         ((:socket in keys and :coop_api not in keys and :coop_client not in keys) or
            (:socket not in keys and :coop_api in keys and :coop_client in keys)),
       do: configuration,
       else: raise(ArgumentError, "publication configuration has missing or unknown fields")
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "publication configuration must be a map or keyword list")

  defp validate_integer!(value, minimum, maximum, _field)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_integer!(_value, _minimum, _maximum, field),
    do: raise(ArgumentError, "publication #{field} is outside its safe bound")

  defp validate_ref!(value) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
             :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
           do: raise(ArgumentError, "publication worker_ref must be a bounded nonblank string")
  end

  defp validate_publisher!(publisher) do
    unless is_atom(publisher) and Code.ensure_loaded?(publisher) and
             function_exported?(publisher, :publish, 2),
           do: raise(ArgumentError, "publication publisher must implement publish/2")
  end

  defp coop_adapter!(%{coop_api: api, coop_client: client}, _receive_timeout_ms)
       when is_atom(api) and not is_nil(client) do
    if Code.ensure_loaded?(api) and function_exported?(api, :run_review, 4),
      do: {api, client},
      else: raise(ArgumentError, "publication Coop API must implement review custody")
  end

  defp coop_adapter!(%{socket: socket}, receive_timeout_ms) do
    case Client.new(
           finch: Ryker.CoopFinch,
           receive_timeout: receive_timeout_ms,
           socket: socket
         ) do
      {:ok, client} ->
        {Client, client}

      {:error, reason} ->
        raise ArgumentError, "invalid publication Coop client: #{inspect(reason)}"
    end
  end

  defp status_source!(%{api: api, client: client}) do
    unless is_atom(api) and Code.ensure_loaded?(api) and
             function_exported?(api, :get_publication_status, 3),
           do:
             raise(
               ArgumentError,
               "publication publisher binding must expose get_publication_status/3"
             )

    {api, client}
  end

  defp status_source!(_binding) do
    raise ArgumentError, "publication publisher binding must expose a GitHub status source"
  end
end

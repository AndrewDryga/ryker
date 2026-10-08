defmodule Ryker.Publication.Runtime do
  @moduledoc """
  Supervises a bounded pool for review, notification, and draft publication.

  The configuration names the Coop adapter explicitly; product assembly hands
  the pool the outbound fleet client.
  """
  use Supervisor
  alias Ryker.Adapter
  alias Ryker.Delivery
  alias Ryker.Options
  alias Ryker.Publication.{FollowupWorker, Worker}

  @fields [
    :concurrency,
    :coop_api,
    :coop_client,
    :delivery_adapters,
    :followup_interval_seconds,
    :lease_seconds,
    :poll_interval_ms,
    :repositories,
    :status_api,
    :status_client,
    :retry_base_seconds,
    :retry_max_seconds,
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
            repositories: options.repositories
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
    repositories = Map.fetch!(configuration, :repositories)
    concurrency = Map.get(configuration, :concurrency, 2)
    lease_seconds = Map.get(configuration, :lease_seconds, 60)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 250)
    retry_base_seconds = Map.get(configuration, :retry_base_seconds, 1)
    retry_max_seconds = Map.get(configuration, :retry_max_seconds, 60)
    followup_interval_seconds = Map.get(configuration, :followup_interval_seconds, 120)

    validate_integer!(concurrency, 1, @maximum_concurrency, :concurrency)
    validate_integer!(lease_seconds, 1, 86_400, :lease_seconds)
    validate_integer!(poll_interval_ms, 1, 60_000, :poll_interval_ms)
    validate_integer!(retry_base_seconds, 1, 86_400, :retry_base_seconds)
    validate_integer!(retry_max_seconds, retry_base_seconds, 86_400, :retry_max_seconds)
    validate_integer!(followup_interval_seconds, 30, 3_600, :followup_interval_seconds)
    validate_ref!(worker_ref)

    unless is_map(repositories),
      do: raise(ArgumentError, "publication repositories must be a map")

    {status_api, status_client} = status_source!(configuration)

    delivery_adapters =
      case Delivery.Adapters.new(Map.fetch!(configuration, :delivery_adapters)) do
        {:ok, adapters} ->
          adapters

        {:error, reason} ->
          raise ArgumentError, "invalid publication delivery adapters: #{inspect(reason)}"
      end

    {coop_api, coop_client} = coop_adapter!(configuration)

    %{
      coop_api: coop_api,
      coop_client: coop_client,
      concurrency: concurrency,
      delivery_adapters: delivery_adapters,
      followup_interval_seconds: followup_interval_seconds,
      lease_seconds: lease_seconds,
      poll_interval_ms: poll_interval_ms,
      repositories: repositories,
      retry_base_seconds: retry_base_seconds,
      retry_max_seconds: retry_max_seconds,
      status_api: status_api,
      status_client: status_client,
      worker_ref: worker_ref
    }
  end

  defp normalize!(configuration) do
    Options.normalize!(
      configuration,
      @fields,
      [
        :coop_api,
        :coop_client,
        :delivery_adapters,
        :repositories,
        :status_api,
        :status_client,
        :worker_ref
      ],
      list: "publication configuration must use unique known fields",
      map: "publication configuration has missing or unknown fields",
      other: "publication configuration must be a map or keyword list"
    )
  end

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

  defp coop_adapter!(%{coop_api: api, coop_client: client})
       when is_atom(api) and not is_nil(api) and not is_nil(client) do
    if Adapter.implements?(api, run_review: 4, publish_review: 6),
      do: {api, client},
      else: raise(ArgumentError, "publication Coop API must implement review custody")
  end

  defp coop_adapter!(_configuration),
    do: raise(ArgumentError, "publication requires a trusted Coop adapter")

  defp status_source!(%{status_api: api, status_client: client}) do
    unless Adapter.implements?(api, get_publication_status: 3) do
      raise(
        ArgumentError,
        "publication status API must implement get_publication_status/3"
      )
    end

    {api, client}
  end

  defp status_source!(_binding) do
    raise ArgumentError, "publication requires a GitHub status source"
  end
end

defmodule Ryker.Emisar.ApprovalRuntime do
  @moduledoc """
  Supervises a bounded pool of durable Emisar approval monitors.
  """

  use Supervisor

  alias Ryker.Emisar.ApprovalWorker

  @fields [
    :api,
    :client,
    :connection_ref,
    :concurrency,
    :lease_seconds,
    :poll_interval_ms,
    :poll_seconds,
    :presentation,
    :presentation_timeout_ms,
    :presenter,
    :retry_base_seconds,
    :retry_max_seconds,
    :worker_ref
  ]
  @maximum_concurrency 16

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)

    %{
      id: {__MODULE__, options!(configuration).connection_ref},
      start: {__MODULE__, :start_link, [configuration]},
      type: :supervisor
    }
  end

  @spec start_link(keyword() | map()) :: Supervisor.on_start()
  def start_link(configuration), do: Supervisor.start_link(__MODULE__, configuration)

  @impl Supervisor
  def init(configuration) do
    options = options!(configuration)

    children =
      for slot <- 1..options.concurrency do
        dispatcher_options = [
          api: options.api,
          client: options.client,
          connection_ref: options.connection_ref,
          lease_seconds: options.lease_seconds,
          poll_seconds: options.poll_seconds,
          presentation: options.presentation,
          presenter: options.presenter,
          retry_base_seconds: options.retry_base_seconds,
          retry_max_seconds: options.retry_max_seconds,
          worker_ref: "#{options.worker_ref}:slot-#{slot}"
        ]

        Supervisor.child_spec(
          {ApprovalWorker,
           dispatcher_options: dispatcher_options, poll_interval_ms: options.poll_interval_ms},
          id: {ApprovalWorker, slot}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)
    api = Map.fetch!(configuration, :api)
    client = Map.fetch!(configuration, :client)
    connection_ref = Map.fetch!(configuration, :connection_ref)
    worker_ref = Map.fetch!(configuration, :worker_ref)
    concurrency = Map.get(configuration, :concurrency, 2)
    lease_seconds = Map.get(configuration, :lease_seconds, 60)
    poll_interval_ms = Map.get(configuration, :poll_interval_ms, 1_000)
    poll_seconds = Map.get(configuration, :poll_seconds, 3)
    presentation = Map.fetch!(configuration, :presentation)
    presentation_timeout_ms = Map.fetch!(configuration, :presentation_timeout_ms)
    presenter = Map.get(configuration, :presenter, Ryker.Emisar.ApprovalPresenter)
    retry_base_seconds = Map.get(configuration, :retry_base_seconds, 2)
    retry_max_seconds = Map.get(configuration, :retry_max_seconds, 300)

    validate_api!(api)
    validate_presenter!(presenter)
    validate_integer!(concurrency, 1, @maximum_concurrency, :concurrency)
    validate_integer!(lease_seconds, 1, 86_400, :lease_seconds)
    validate_integer!(poll_interval_ms, 1, 300_000, :poll_interval_ms)
    validate_integer!(poll_seconds, 1, 86_400, :poll_seconds)
    validate_integer!(presentation_timeout_ms, 0, 60_000, :presentation_timeout_ms)
    validate_integer!(retry_base_seconds, 1, 86_400, :retry_base_seconds)
    validate_integer!(retry_max_seconds, retry_base_seconds, 86_400, :retry_max_seconds)
    validate_ref!(worker_ref)
    validate_ref!(connection_ref)

    if lease_seconds * 1_000 <= presentation_timeout_ms,
      do: raise(ArgumentError, "Emisar approval lease_seconds must exceed presentation timeout")

    %{
      api: api,
      client: client,
      connection_ref: connection_ref,
      concurrency: concurrency,
      lease_seconds: lease_seconds,
      poll_interval_ms: poll_interval_ms,
      poll_seconds: poll_seconds,
      presentation: presentation,
      presentation_timeout_ms: presentation_timeout_ms,
      presenter: presenter,
      retry_base_seconds: retry_base_seconds,
      retry_max_seconds: retry_max_seconds,
      worker_ref: worker_ref
    }
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
       do: configuration |> Map.new() |> normalize!(),
       else: raise(ArgumentError, "Emisar approval configuration must use unique known fields")
  end

  defp normalize!(%{} = configuration) do
    required = [
      :api,
      :client,
      :connection_ref,
      :presentation,
      :presentation_timeout_ms,
      :worker_ref
    ]

    if Map.keys(configuration) -- @fields == [] and
         Enum.all?(required, &Map.has_key?(configuration, &1)),
       do: configuration,
       else: raise(ArgumentError, "Emisar approval configuration has missing or unknown fields")
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "Emisar approval configuration must be a map or keyword list")

  defp validate_api!(api) do
    unless is_atom(api) and Code.ensure_loaded?(api) and
             function_exported?(api, :wait_for_run, 2),
           do: raise(ArgumentError, "Emisar approval API must implement wait_for_run/2")
  end

  defp validate_presenter!(presenter) do
    unless is_atom(presenter) and Code.ensure_loaded?(presenter) and
             function_exported?(presenter, :publish, 3) and
             function_exported?(presenter, :permanent?, 1),
           do: raise(ArgumentError, "Emisar approval presenter is invalid")
  end

  defp validate_integer!(value, minimum, maximum, _field)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_integer!(_value, _minimum, _maximum, field),
    do: raise(ArgumentError, "Emisar approval #{field} is outside its safe bound")

  defp validate_ref!(value) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
             :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
           do:
             raise(ArgumentError, "Emisar approval worker_ref must be a bounded nonblank string")
  end
end

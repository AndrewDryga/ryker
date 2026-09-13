defmodule Ryker.Retention.Runtime do
  @moduledoc "Supervises exact Coop ownership cleanup and retention maintenance."

  use Supervisor

  alias Ryker.Reference
  alias Ryker.Retention.{Data, Worker}

  @required [
    :audit_data_seconds,
    :batch_limit,
    :batch_seconds,
    :client,
    :closed_session_grace_seconds,
    :closed_work_seconds,
    :conversation_memory_seconds,
    :disposable_bytes_limit,
    :episode_history_seconds,
    :lease_seconds,
    :max_attempts,
    :operational_data_seconds,
    :poll_interval_ms,
    :reclaim_target_seconds,
    :retained_recheck_seconds,
    :retry_base_seconds,
    :retry_max_seconds,
    :storage_high_watermark_bytes,
    :storage_low_watermark_bytes,
    :storage_reserve_bytes,
    :worker_ref
  ]

  @optional [:api, :learning_api, :learning_client]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _settings = options!(configuration)

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
    settings = options!(configuration)

    dispatcher_options = [
      api: settings.api,
      batch_limit: settings.batch_limit,
      batch_seconds: settings.batch_seconds,
      client: settings.client,
      closed_session_grace_seconds: settings.closed_session_grace_seconds,
      learning_api: settings.learning_api,
      learning_client: settings.learning_client,
      lease_seconds: settings.lease_seconds,
      max_attempts: settings.max_attempts,
      retained_recheck_seconds: settings.retained_recheck_seconds,
      retry_base_seconds: settings.retry_base_seconds,
      retry_max_seconds: settings.retry_max_seconds,
      worker_ref: settings.worker_ref
    ]

    children = [
      {Worker,
       [
         dispatcher_options: dispatcher_options,
         maintenance: Data,
         maintenance_options: %{
           audit_data_seconds: settings.audit_data_seconds,
           closed_work_seconds: settings.closed_work_seconds,
           conversation_memory_seconds: settings.conversation_memory_seconds,
           episode_history_seconds: settings.episode_history_seconds,
           operational_data_seconds: settings.operational_data_seconds
         },
         poll_interval_ms: settings.poll_interval_ms
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)

    settings =
      configuration
      |> Map.put_new(:api, Ryker.Coop.Client)
      |> then(&Map.put_new(&1, :learning_api, &1.api))
      |> then(&Map.put_new(&1, :learning_client, &1.client))

    validate!(settings)
    settings
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
       do: configuration |> Map.new() |> normalize!(),
       else: raise(ArgumentError, "retention configuration must use unique known fields")
  end

  defp normalize!(%{} = configuration) do
    keys = Map.keys(configuration)

    if keys -- (@required ++ @optional) == [] and
         Enum.all?(@required, &Map.has_key?(configuration, &1)),
       do: configuration,
       else: raise(ArgumentError, "retention configuration has missing or unknown fields")
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "retention configuration must be a map or keyword list")

  defp validate!(settings) do
    positive_fields = [
      :audit_data_seconds,
      :batch_limit,
      :batch_seconds,
      :closed_work_seconds,
      :conversation_memory_seconds,
      :disposable_bytes_limit,
      :episode_history_seconds,
      :lease_seconds,
      :max_attempts,
      :operational_data_seconds,
      :poll_interval_ms,
      :reclaim_target_seconds,
      :retained_recheck_seconds,
      :retry_base_seconds,
      :retry_max_seconds,
      :storage_high_watermark_bytes,
      :storage_low_watermark_bytes,
      :storage_reserve_bytes
    ]

    valid =
      runtime_dependencies_valid?(settings) and
        positive_fields_valid?(settings, positive_fields) and
        retry_bounds_valid?(settings) and
        retention_horizons_valid?(settings) and
        storage_budgets_valid?(settings) and
        Reference.valid?(settings.worker_ref)

    unless valid, do: raise(ArgumentError, "retention configuration is outside its safe bounds")
  end

  # Watermarks that cross, or a reserve larger than the high watermark, would
  # either never release pressure or refuse allocation permanently.
  defp storage_budgets_valid?(settings) do
    settings.storage_low_watermark_bytes < settings.storage_high_watermark_bytes and
      settings.storage_reserve_bytes < settings.storage_high_watermark_bytes and
      settings.disposable_bytes_limit <= settings.storage_high_watermark_bytes and
      settings.batch_limit <= 1_000 and
      settings.batch_seconds * 1_000 <= settings.poll_interval_ms
  end

  defp runtime_dependencies_valid?(settings) do
    is_atom(settings.api) and is_atom(settings.learning_api) and not is_nil(settings.client) and
      not is_nil(settings.learning_client) and
      is_integer(settings.closed_session_grace_seconds) and
      settings.closed_session_grace_seconds >= 0
  end

  defp positive_fields_valid?(settings, fields) do
    Enum.all?(fields, &(is_integer(settings[&1]) and settings[&1] > 0))
  end

  defp retry_bounds_valid?(settings),
    do: settings.retry_max_seconds >= settings.retry_base_seconds

  defp retention_horizons_valid?(settings) do
    settings.operational_data_seconds <= settings.closed_work_seconds and
      settings.closed_work_seconds <= settings.episode_history_seconds and
      settings.episode_history_seconds <= settings.audit_data_seconds and
      settings.operational_data_seconds <= settings.conversation_memory_seconds
  end
end

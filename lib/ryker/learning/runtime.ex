defmodule Ryker.Learning.Runtime do
  @moduledoc "A small supervised learning pool, configured by the host rather than incoming messages."
  use Supervisor
  alias Ryker.Reference
  alias Ryker.Coop.Client
  alias Ryker.Learning.Worker

  @fields ~w(api client socket policy policy_digest worker_ref concurrency batch_size quiet_seconds
    maximum_delay_seconds poll_interval_ms receive_timeout_ms execution_timeout_seconds)a

  @doc "The current host configuration, used only when explicitly requesting new learning work."
  def configured_options do
    case Application.get_env(:ryker, :learning) do
      nil -> {:error, :learning_disabled}
      configuration -> {:ok, options!(configuration)}
    end
  rescue
    ArgumentError -> {:error, :learning_configuration_invalid}
  end

  def child_spec(configuration) do
    options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}, type: :supervisor}
  end

  def start_link(configuration),
    do: Supervisor.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl true
  def init(configuration) do
    settings = options!(configuration)

    children =
      for slot <- 1..settings.concurrency do
        Supervisor.child_spec(
          {Worker, %{settings | worker_ref: "#{settings.worker_ref}:slot-#{slot}"}},
          id: {Worker, slot}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  def options!(configuration) when is_list(configuration) do
    unless Keyword.keyword?(configuration) and
             Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
           do: raise(ArgumentError, "learning configuration must have unique known fields")

    options!(Map.new(configuration))
  end

  def options!(%{} = config) do
    validate_identity!(config)

    timeout = integer!(config, :receive_timeout_ms, 30_000, 1..30_000)
    {api, client} = adapter!(config, timeout)
    quiet = integer!(config, :quiet_seconds, 10, 0..300)
    maximum_delay = integer!(config, :maximum_delay_seconds, 60, 1..600)

    if quiet > maximum_delay,
      do: raise(ArgumentError, "learning quiet_seconds must fit maximum_delay_seconds")

    %{
      api: api,
      client: client,
      policy: config.policy,
      policy_digest: config.policy_digest,
      worker_ref: config.worker_ref,
      concurrency: integer!(config, :concurrency, 1, 1..8),
      batch_size: integer!(config, :batch_size, 16, 1..16),
      quiet_seconds: quiet,
      maximum_delay_seconds: maximum_delay,
      lease_seconds: 300,
      step_delay_seconds: 2,
      execution_timeout_seconds: integer!(config, :execution_timeout_seconds, 600, 30..1800),
      poll_interval_ms: integer!(config, :poll_interval_ms, 1000, 100..60_000)
    }
  end

  def options!(_),
    do: raise(ArgumentError, "learning configuration must be a map or keyword list")

  defp validate_identity!(config) do
    unless Map.keys(config) -- @fields == [] and
             Enum.all?(~w(policy policy_digest worker_ref)a, &Map.has_key?(config, &1)),
           do: raise(ArgumentError, "learning configuration has missing or unknown fields")

    for key <- [:policy, :worker_ref], do: validate_reference!(config[key], key)

    unless is_binary(config.policy_digest) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, config.policy_digest),
           do: raise(ArgumentError, "learning policy_digest must be a SHA-256 digest")
  end

  defp validate_reference!(value, key) do
    unless Reference.valid?(value, 160),
      do: raise(ArgumentError, "learning #{key} must be a bounded nonblank reference")
  end

  defp adapter!(%{socket: socket} = config, timeout) do
    if Map.has_key?(config, :api) or Map.has_key?(config, :client),
      do: raise(ArgumentError, "learning cannot select both local and fleet execution")

    case Client.new(finch: Ryker.CoopFinch, socket: socket, receive_timeout: timeout) do
      {:ok, client} -> {Client, client}
      {:error, _} -> raise ArgumentError, "invalid learning Coop socket"
    end
  end

  defp adapter!(%{api: api, client: client}, _timeout)
       when is_atom(api) and not is_nil(api) and not is_nil(client),
       do: {api, client}

  defp adapter!(_, _), do: raise(ArgumentError, "learning requires a trusted Coop adapter")

  defp integer!(config, key, default, range) do
    value = Map.get(config, key, default)

    unless is_integer(value) and value in range,
      do: raise(ArgumentError, "learning #{key} is outside its supported bounds")

    value
  end
end

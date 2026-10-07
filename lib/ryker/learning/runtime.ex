defmodule Ryker.Learning.Runtime do
  @moduledoc "A small supervised learning pool, configured by the host rather than incoming messages."
  use Supervisor
  alias Ryker.Config
  alias Ryker.Learning.Worker
  alias Ryker.{Options, Reference}

  @fields ~w(api client policy policy_digest worker_ref concurrency batch_size quiet_seconds
    maximum_delay_seconds poll_interval_ms execution_timeout_seconds)a

  @doc "The current host configuration, used only when explicitly requesting new learning work."
  def configured_options do
    case Config.get_env(:learning) do
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

  def options!(configuration) do
    config =
      Options.normalize!(configuration, @fields, ~w(policy policy_digest worker_ref)a,
        list: "learning configuration must have unique known fields",
        map: "learning configuration has missing or unknown fields",
        other: "learning configuration must be a map or keyword list"
      )

    validate_identity!(config)

    {api, client} = adapter!(config)
    quiet = integer!(config, :quiet_seconds, 300, 0..300)
    maximum_delay = integer!(config, :maximum_delay_seconds, 1_800, 1..3_600)

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

  defp validate_identity!(config) do
    for key <- [:policy, :worker_ref], do: validate_reference!(config[key], key)

    unless is_binary(config.policy_digest) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, config.policy_digest),
           do: raise(ArgumentError, "learning policy_digest must be a SHA-256 digest")
  end

  defp validate_reference!(value, key) do
    unless Reference.valid?(value, 160),
      do: raise(ArgumentError, "learning #{key} must be a bounded nonblank reference")
  end

  defp adapter!(%{api: api, client: client})
       when is_atom(api) and not is_nil(api) and not is_nil(client),
       do: {api, client}

  defp adapter!(_config), do: raise(ArgumentError, "learning requires a trusted Coop adapter")

  defp integer!(config, key, default, range) do
    value = Map.get(config, key, default)

    unless is_integer(value) and value in range,
      do: raise(ArgumentError, "learning #{key} is outside its supported bounds")

    value
  end
end

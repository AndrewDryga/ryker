defmodule Ryker.Improvement.Runtime do
  @moduledoc """
  The small self-analysis pool: one slot by default, running on the learning
  policy and its models (`Ryker.Runtime.Assembly`). It starts analyses only
  while background learning is on (`enabled`); with learning off it only
  finishes the ones already out at Coop.
  """
  use Supervisor
  alias Ryker.Improvement.Worker
  alias Ryker.{Options, Reference}

  @fields ~w(api client policy policy_digest worker_ref enabled concurrency quiet_seconds
    poll_interval_ms execution_timeout_seconds)a

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

  @doc "The runtime settings, validated, or an `ArgumentError` naming the one that is wrong."
  def options!(configuration) do
    config =
      Options.normalize!(configuration, @fields, ~w(api client policy policy_digest worker_ref)a,
        list: "self-analysis configuration must have unique known fields",
        map: "self-analysis configuration has missing or unknown fields",
        other: "self-analysis configuration must be a map or keyword list"
      )

    for key <- [:policy, :worker_ref] do
      unless Reference.valid?(config[key], 160),
        do: raise(ArgumentError, "self-analysis #{key} must be a bounded nonblank reference")
    end

    unless is_binary(config.policy_digest) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, config.policy_digest),
           do: raise(ArgumentError, "self-analysis policy_digest must be a SHA-256 digest")

    unless is_atom(config.api) and not is_nil(config.api) and not is_nil(config.client),
      do: raise(ArgumentError, "self-analysis requires a trusted Coop adapter")

    unless is_boolean(Map.get(config, :enabled, true)),
      do: raise(ArgumentError, "self-analysis enabled must be true or false")

    %{
      api: config.api,
      client: config.client,
      policy: config.policy,
      policy_digest: config.policy_digest,
      worker_ref: config.worker_ref,
      enabled: Map.get(config, :enabled, true),
      concurrency: integer!(config, :concurrency, 1, 1..2),
      quiet_seconds: integer!(config, :quiet_seconds, 300, 0..3_600),
      poll_interval_ms: integer!(config, :poll_interval_ms, 1_000, 100..60_000),
      execution_timeout_seconds: integer!(config, :execution_timeout_seconds, 600, 30..1_800),
      lease_seconds: 300,
      step_delay_seconds: 2,
      retry_delay_seconds: 60
    }
  end

  defp integer!(config, key, default, range) do
    value = Map.get(config, key, default)

    unless is_integer(value) and value in range,
      do: raise(ArgumentError, "self-analysis #{key} is outside its supported bounds")

    value
  end
end

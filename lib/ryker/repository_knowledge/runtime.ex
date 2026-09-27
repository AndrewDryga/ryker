defmodule Ryker.RepositoryKnowledge.Runtime do
  @moduledoc """
  The knowledge lane (`Ryker.RepositoryKnowledge`): one slot, running where
  Work and GitHub both run (`Ryker.Runtime.Assembly`). Its model turns go
  through Work's Coop adapter under each repository's own read-only policy,
  and it reads and proposes RYKER.md through the GitHub App
  (`Ryker.GitHub.RepositoryFiles`).
  """
  use Supervisor

  alias Ryker.{Options, Reference}
  alias Ryker.RepositoryKnowledge.Worker

  @fields ~w(api client remote worker_ref poll_interval_ms execution_timeout_seconds
    idle_interval_ms)a

  def child_spec(configuration) do
    options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}, type: :supervisor}
  end

  def start_link(configuration),
    do: Supervisor.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl true
  def init(configuration) do
    Supervisor.init([{Worker, options!(configuration)}], strategy: :one_for_one)
  end

  @doc "The runtime settings, validated, or an `ArgumentError` naming the one that is wrong."
  def options!(configuration) do
    config =
      Options.normalize!(configuration, @fields, ~w(api client worker_ref)a,
        list: "repository knowledge configuration must have unique known fields",
        map: "repository knowledge configuration has missing or unknown fields",
        other: "repository knowledge configuration must be a map or keyword list"
      )

    unless Reference.valid?(config.worker_ref, 160),
      do:
        raise(
          ArgumentError,
          "repository knowledge worker_ref must be a bounded nonblank reference"
        )

    unless is_atom(config.api) and not is_nil(config.api) and not is_nil(config.client),
      do: raise(ArgumentError, "repository knowledge requires a trusted Coop adapter")

    remote = Map.get(config, :remote, Ryker.GitHub.RepositoryFiles)

    unless is_atom(remote) and Code.ensure_loaded?(remote) and
             function_exported?(remote, :publish, 3),
           do: raise(ArgumentError, "repository knowledge requires a GitHub remote")

    %{
      api: config.api,
      client: config.client,
      remote: remote,
      worker_ref: config.worker_ref,
      poll_interval_ms: integer!(config, :poll_interval_ms, 1_000, 100..60_000),
      idle_interval_ms: integer!(config, :idle_interval_ms, 10_000, 100..3_600_000),
      execution_timeout_seconds: integer!(config, :execution_timeout_seconds, 1_800, 60..3_600),
      lease_seconds: 300,
      step_delay_seconds: 5,
      retry_delay_seconds: 60
    }
  end

  defp integer!(config, key, default, range) do
    value = Map.get(config, key, default)

    unless is_integer(value) and value in range,
      do: raise(ArgumentError, "repository knowledge #{key} is outside its supported bounds")

    value
  end
end

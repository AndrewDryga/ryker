defmodule Ryker.ControlPlane.Updates do
  @moduledoc """
  Bridges commit-aware PostgreSQL invalidations to scoped LiveView subscribers.

  Notifications carry only table names and are deliberately not durable. Views
  subscribe before taking a snapshot and periodically reconcile missed hints.
  A burst is coalesced before projections query their own durable source.
  """
  use GenServer
  alias Ryker.PubSub
  alias Ryker.Repo

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(_options) do
    connection_options =
      Repo.config()
      |> Keyword.take([
        :hostname,
        :port,
        :username,
        :password,
        :database,
        :ssl,
        :socket_dir,
        :socket,
        :socket_options,
        :parameters,
        :types,
        :connect_timeout
      ])
      |> Keyword.merge(auto_reconnect: true, sync_connect: false)

    with {:ok, connection} <- Postgrex.Notifications.start_link(connection_options),
         {status, reference} when status in [:ok, :eventually] <-
           Postgrex.Notifications.listen(connection, "ryker_control_plane") do
      {:ok, %{connection: connection, reference: reference, pending: MapSet.new(), timer: nil}}
    end
  end

  @impl true
  def handle_info(
        {:notification, connection, reference, "ryker_control_plane", table},
        %{connection: connection, reference: reference} = state
      ) do
    pending = MapSet.union(state.pending, MapSet.new(domains(table)))
    timer = state.timer || Process.send_after(self(), :broadcast, 100)
    {:noreply, %{state | pending: pending, timer: timer}}
  end

  def handle_info(:broadcast, state) do
    Enum.each(state.pending, fn domain ->
      Phoenix.PubSub.broadcast(PubSub, "control-plane:#{domain}", :control_plane_changed)
    end)

    {:noreply, %{state | pending: MapSet.new(), timer: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.connection), do: GenServer.stop(state.connection, :normal)
  end

  def domain("/"), do: "activity"
  def domain(path), do: path |> String.split("/", trim: true) |> List.first()

  @doc """
  The pages whose live views a change to this table can alter, by the first
  segment of their path. Every settings-like table without a rule of its own
  reaches the pages that show configuration.
  """
  @spec domains(String.t()) :: [String.t()]
  def domains("execution_usage"), do: ~w(activity timeline conversations usage)
  def domains("episode_operator_reviews"), do: ~w(activity timeline memory)

  def domains("episode_schedule" <> _),
    do: ~w(activity schedules channels timeline conversations)

  def domains("episode_event_subscriptions"),
    do: ~w(activity follow-ups timeline conversations)

  def domains("episode_state_" <> _),
    do: ~w(activity timeline incident-rooms conversations memory)

  def domains("episode_" <> _),
    do: ~w(activity timeline incident-rooms conversations usage working-copies failures)

  def domains("ingress_" <> _),
    do: ~w(activity timeline conversations usage failures channels)

  def domains("admission_" <> _),
    do: ~w(activity timeline conversations usage failures)

  def domains("slack_incident_" <> _),
    do: ~w(activity incident-rooms timeline conversations channels failures)

  def domains("slack_" <> _),
    do:
      ~w(activity channels environments incident-rooms timeline conversations failures integrations setup repositories)

  # Chat names each conversation's environment in its list and its head.
  def domains("environment_" <> _),
    do: ~w(environments channels repositories integrations setup conversations)

  def domains("control_plane_conversations"), do: ~w(conversations)

  def domains("coop_" <> _),
    do: ~w(activity working-copies timeline conversations repositories settings setup failures)

  def domains("conversation_" <> _), do: ~w(memory conversations channels timeline)
  def domains("operational_memory_" <> _), do: ~w(memory conversations timeline)
  def domains("memory_" <> _), do: ~w(memory conversations timeline)

  def domains("operator_behaviors"),
    do: ~w(rules instructions memory setup channels timeline)

  def domains("standing_assignment_runs"), do: ~w(rules timeline)
  def domains("platform_actions"), do: ~w(activity timeline conversations failures)
  def domains("delivery_" <> _), do: ~w(activity timeline conversations failures)
  def domains("ryker_operator_actions"), do: ~w(activity failures)

  def domains(_table),
    do: ~w(activity usage settings integrations setup environments channels repositories)
end

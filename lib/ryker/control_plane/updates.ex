defmodule Ryker.ControlPlane.Updates do
  @moduledoc """
  Bridges commit-aware PostgreSQL invalidations to scoped LiveView subscribers.

  Notifications carry only table names and are deliberately not durable. Views
  subscribe before taking a snapshot and periodically reconcile missed hints.
  A burst is coalesced before projections query their own durable source.
  """
  use GenServer
  alias Ryker.ControlPlane.PubSub
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

  defp domains("execution_usage"), do: ~w(activity admission timeline conversations usage)
  defp domains("episode_operator_reviews"), do: ~w(activity timeline findings)

  defp domains("episode_schedule" <> _),
    do: ~w(activity schedules channels timeline conversations)

  defp domains("episode_event_subscriptions"),
    do: ~w(activity subscriptions timeline conversations)

  defp domains("episode_state_" <> _),
    do: ~w(activity timeline incident-rooms conversations findings memory)

  defp domains("episode_" <> _),
    do: ~w(activity timeline incident-rooms conversations usage workspaces failures)

  defp domains("ingress_" <> _),
    do: ~w(activity admission timeline conversations usage failures channels)

  defp domains("admission_" <> _),
    do: ~w(activity admission timeline conversations usage failures)

  defp domains("slack_incident_" <> _),
    do: ~w(activity incident-rooms timeline conversations channels failures)

  defp domains("slack_" <> _),
    do:
      ~w(activity channels incident-rooms timeline conversations failures configuration repositories)

  defp domains("coop_" <> _),
    do: ~w(activity workspaces timeline conversations repositories configuration failures)

  defp domains("conversation_" <> _), do: ~w(memory conversations channels timeline)
  defp domains("operational_memory_" <> _), do: ~w(memory conversations timeline)
  defp domains("memory_" <> _), do: ~w(memory conversations timeline)

  defp domains("operator_behaviors"),
    do: ~w(rules preferences guidance memory configuration channels timeline)

  defp domains("standing_assignment_runs"), do: ~w(rules timeline)
  defp domains("platform_actions"), do: ~w(activity timeline conversations failures)
  defp domains("delivery_" <> _), do: ~w(activity timeline conversations failures)
  defp domains("ryker_operator_actions"), do: ~w(activity failures)
  defp domains(_table), do: ~w(activity usage configuration)
end

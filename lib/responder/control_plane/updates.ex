defmodule Responder.ControlPlane.Updates do
  @moduledoc """
  Bridges commit-aware PostgreSQL invalidations to scoped LiveView subscribers.

  Notifications carry only table names and are deliberately not durable. Views
  subscribe before taking a snapshot and periodically reconcile missed hints.
  A burst is coalesced before projections query their own durable source.
  """
  use GenServer
  alias Responder.ControlPlane.PubSub
  alias Responder.Repo

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
           Postgrex.Notifications.listen(connection, "responder_control_plane") do
      {:ok, %{connection: connection, reference: reference, pending: MapSet.new(), timer: nil}}
    end
  end

  @impl true
  def handle_info(
        {:notification, connection, reference, "responder_control_plane", table},
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

  defp domains("card_lab_" <> _), do: ["card-lab"]
  defp domains("execution_usage"), do: ~w(activity admission episodes lab usage calibration)
  defp domains("episode_operator_reviews"), do: ~w(activity episodes decisions findings)
  defp domains("episode_schedule" <> _), do: ~w(activity schedules channels episodes lab)
  defp domains("episode_event_subscriptions"), do: ~w(activity subscriptions episodes lab)

  defp domains("episode_state_" <> _),
    do: ~w(activity episodes incidents lab decisions findings memory)

  defp domains("episode_" <> _),
    do: ~w(activity episodes incidents lab usage workspaces failures)

  defp domains("ingress_" <> _), do: ~w(activity admission episodes lab usage failures channels)

  defp domains("admission_" <> _),
    do: ~w(activity admission episodes lab usage failures calibration)

  defp domains("slack_incident_" <> _), do: ~w(activity incidents episodes lab channels failures)

  defp domains("slack_" <> _),
    do: ~w(activity channels incidents episodes lab failures configuration repositories)

  defp domains("coop_" <> _),
    do: ~w(activity workspaces episodes lab repositories configuration failures)

  defp domains("conversation_" <> _), do: ~w(memory lab channels episodes)
  defp domains("operational_memory_" <> _), do: ~w(memory lab episodes)
  defp domains("memory_" <> _), do: ~w(memory lab episodes)

  defp domains("operator_behaviors"),
    do: ~w(rules preferences guidance memory configuration channels episodes)

  defp domains("standing_assignment_runs"), do: ~w(rules episodes)
  defp domains("platform_actions"), do: ~w(activity episodes lab failures)
  defp domains("delivery_" <> _), do: ~w(activity episodes lab failures)
  defp domains("responder_operator_actions"), do: ~w(activity failures)
  defp domains(_table), do: ~w(activity calibration configuration)
end

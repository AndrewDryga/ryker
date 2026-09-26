defmodule Ryker.ControlPlane.ProductReadiness do
  @moduledoc """
  Whether Chat and Slack can run right now: Chat's state in words, and
  Slack's as the running evidence `Integrations.slack/1` reads, which says it
  in the words every page uses.

  These states come from the applied runtime and the live worker fleet, not
  from the presence of saved credentials. They never expose worker
  identities, policy names, credentials, or queue data.
  """

  alias Ryker.Observability
  alias Ryker.Settings
  alias Ryker.Slack.Gateway

  @spec current() :: %{chat: map(), slack: %{state: atom()}}
  def current do
    case Settings.fetch() do
      {:ok, snapshot} -> current(snapshot)
      {:error, _reason} -> unavailable()
    end
  rescue
    _error -> unavailable()
  end

  @spec current(Settings.snapshot()) :: %{chat: map(), slack: %{state: atom()}}
  def current(snapshot) do
    control_plane = Application.get_env(:ryker, :control_plane)
    slack = Application.get_env(:ryker, :slack)

    runtime = %{
      chat_profile: if(is_map(control_plane), do: chat_profile(control_plane)),
      slack_configured: is_map(slack),
      slack_connected: Gateway.connected?()
    }

    from(snapshot, Observability.fleet(), runtime)
  rescue
    _error -> unavailable()
  end

  # Chat can run once the console holds a Work profile for it: the one
  # outside any environment, or any environment's.
  defp chat_profile(control_plane) do
    Map.get(control_plane, :fallback_work_profile) ||
      control_plane
      |> Map.get(:environments, %{})
      |> Map.values()
      |> Enum.find_value(&Map.get(&1, :work_profile))
  end

  @doc false
  def from(snapshot, fleet_result, runtime) do
    chat = chat_state(Map.get(runtime, :chat_profile), fleet_result)

    slack =
      slack_state(
        snapshot.slack.enabled,
        chat,
        Map.get(runtime, :slack_configured, false),
        Map.get(runtime, :slack_connected, false)
      )

    %{chat: chat, slack: slack}
  end

  defp chat_state(nil, _fleet),
    do:
      state(
        :setting_up,
        "Chat is finishing setup",
        "The bundled worker is installing the Chat policy. This page will update when it is ready."
      )

  defp chat_state(_profile, {:error, _reason}),
    do:
      state(
        :worker_unavailable,
        "Chat is waiting for its worker",
        "The bundled worker is not reporting readiness yet."
      )

  defp chat_state(_profile, {:ok, %{required: false}}),
    do:
      state(
        :setting_up,
        "Chat is finishing setup",
        "Work placement has not been applied yet."
      )

  defp chat_state(_profile, {:ok, fleet}) do
    cond do
      fleet.eligible_workers == 0 ->
        state(
          :worker_unavailable,
          "Chat is waiting for its worker",
          "The bundled worker is offline or still starting."
        )

      fleet.available_policy_profiles < fleet.required_policy_profiles ->
        state(
          :policy_unavailable,
          "Chat policies are still loading",
          "The bundled worker has not advertised every policy Ryker needs."
        )

      true ->
        state(:ready, "Chat is ready", "Messages can be accepted and processed.")
    end
  end

  # Slack switched on waits for the same worker Chat does before its own
  # runtime and connection matter.
  defp slack_state(false, _chat, _configured, _connected), do: %{state: :not_connected}

  defp slack_state(true, %{state: chat_state}, _configured, _connected)
       when chat_state != :ready,
       do: %{state: chat_state}

  defp slack_state(true, _chat, false, _connected), do: %{state: :runtime_unavailable}
  defp slack_state(true, _chat, true, false), do: %{state: :connecting}
  defp slack_state(true, _chat, true, true), do: %{state: :ready}

  defp state(name, title, detail), do: %{state: name, title: title, detail: detail}

  defp unavailable do
    chat =
      state(
        :worker_unavailable,
        "Chat readiness is unavailable",
        "Ryker could not read the current worker state."
      )

    %{chat: chat, slack: %{state: :unknown}}
  end
end

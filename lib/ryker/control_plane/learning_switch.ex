defmodule Ryker.ControlPlane.LearningSwitch do
  @moduledoc """
  The one control on the Learning page: a button that says what it will do,
  "Turn off learning" or "Turn on learning".

  It saves the same Learning setting the settings catalog defines, through
  the same command and against the revision the page was read at, so a change
  someone made elsewhere is shown instead of being overwritten. Turning
  learning off pauses new passes; passes already running finish.
  """
  use Phoenix.LiveComponent

  alias Ryker.ControlPlane.SettingsView

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("switch", %{"enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    %{view: view, commands: commands} = socket.assigns

    case attempt(fn -> commands.save.(:learning, %{"enabled" => enabled}, view.revision) end) do
      {:ok, snapshot} ->
        {:noreply, socket |> saved(SettingsView.view(snapshot)) |> assign(:error, nil)}

      {:error, {:settings_conflict, current}} ->
        {:noreply,
         socket
         |> saved(SettingsView.view(current))
         |> assign(:error, "Settings changed somewhere else. Check learning, then try again.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, "Learning could not be changed. Try again.")}
    end
  end

  # The shell holds the settings every other editor reads; it learns the new
  # revision at once rather than on its next refresh.
  defp saved(socket, view) do
    send(self(), {:settings_saved, view})
    assign(socket, :view, view)
  end

  defp attempt(command) do
    command.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :settings_unavailable}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :enabled, assigns.view.snapshot.learning.enabled)

    ~H"""
    <div id={@id} class="learning-switch">
      <button
        type="button"
        class="ui-button secondary"
        phx-click="switch"
        phx-value-enabled={to_string(!@enabled)}
        phx-target={@myself}
      >
        {if @enabled, do: "Turn off learning", else: "Turn on learning"}
      </button>
      <p :if={@error} class="learning-switch-error" role="alert">{@error}</p>
    </div>
    """
  end
end

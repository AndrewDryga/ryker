defmodule Ryker.ControlPlane.LearningSwitch do
  @moduledoc """
  The one control on the Learning page: a button that says what it will do,
  "Turn off learning" or "Turn on learning".

  It saves the same Learning setting the settings catalog defines, through
  the same command and against the revision the page was read at, so a change
  someone made elsewhere is shown instead of being overwritten. Turning
  learning off pauses new passes, so it asks first, the way every setting
  that stops something does; passes already running finish. Turning it on
  starts nothing that cannot be stopped again, so it does not ask.

  After a save the page is drawn again at once, so the line that says
  whether learning is on never lags behind the button. The question is a
  `Kit.confirm_modal/1` over the page, so the page head never grows.
  """
  use Phoenix.LiveComponent

  alias Ryker.ControlPlane.{Kit, SettingsView}

  # The shell holds the open question, like every other confirmation.
  @question {"turn-off-learning", "learning"}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:confirm, fn -> nil end)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("switch", %{"enabled" => "false"}, %{assigns: %{confirm: @question}} = socket),
    do: save(socket, "false")

  def handle_event("switch", %{"enabled" => "true"}, socket), do: save(socket, "true")

  # Turning learning off without its question answered changes nothing.
  def handle_event("switch", _params, socket), do: {:noreply, socket}

  defp save(socket, enabled) do
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
  # revision at once rather than on its next refresh, and draws the page again.
  defp saved(socket, view) do
    send(self(), {:learning_switched, view})
    assign(socket, :view, view)
  end

  defp attempt(command) do
    command.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :settings_unavailable}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        enabled: assigns.view.snapshot.learning.enabled,
        asking: assigns.confirm == @question
      )

    ~H"""
    <div id={@id} class="learning-switch">
      <Kit.confirm_modal
        :if={@asking}
        id={@id <> "-question"}
        title="Turn off learning?"
        text="Ryker stops learning from new messages, and stops analyzing requests people were unhappy with, until you turn it on again. What it already learned stays, and passes already running finish."
        label="Turn off learning"
        cancel="cancel-settings-action"
        phx-click="switch"
        phx-value-enabled="false"
        phx-target={@myself}
      />
      <button
        :if={@enabled}
        type="button"
        class="ui-button secondary"
        phx-click="confirm-settings-action"
        phx-value-action="turn-off-learning"
        phx-value-ref="learning"
      >
        Turn off learning
      </button>
      <button
        :if={not @enabled}
        type="button"
        class="ui-button secondary"
        phx-click="switch"
        phx-value-enabled="true"
        phx-target={@myself}
      >
        Turn on learning
      </button>
      <p :if={@error} class="learning-switch-error" role="alert">{@error}</p>
    </div>
    """
  end
end

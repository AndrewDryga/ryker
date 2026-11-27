defmodule Ryker.ControlPlane.SkillSettings do
  @moduledoc "Additional Work procedures selected for one environment."
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit, SettingsView}
  alias Ryker.Skills

  @impl true
  def update(assigns, socket) do
    scope = assigns.environment

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:selected, scope.enabled_skills)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event(
        "set-skill",
        %{"name" => name, "enabled" => enabled, "revision" => revision},
        socket
      )
      when enabled in ["true", "false"] do
    %{selected: selected, view: view} = socket.assigns

    if name in Skills.names(view.snapshot.work.installed_skills) and
         revision == to_string(view.revision) do
      names =
        if enabled == "true", do: Enum.uniq([name | selected]), else: List.delete(selected, name)

      save(socket, Enum.sort(names))
    else
      {:noreply,
       assign(socket, :error, "Settings changed. Review the current selection and try again.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(socket, names) do
    %{commands: commands, environment: environment, view: view} = socket.assigns

    save_change(socket, fn ->
      commands.put_environment.(%{ref: environment.ref, enabled_skills: names}, view.revision)
    end)
  end

  defp save_change(socket, command) do
    case command.() do
      {:ok, snapshot} ->
        send(self(), {:settings_editor_saved, SettingsView.view(snapshot)})
        {:noreply, assign(socket, :error, nil)}

      {:error, {:settings_conflict, current}} ->
        send(self(), {:settings_editor_saved, SettingsView.view(current)})

        {:noreply,
         assign(socket, :error, "Settings changed. Review the current selection and try again.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, "The skill setting could not be saved.")}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:noreply,
       assign(socket, :error, "Ryker could not reach its settings. Try again in a moment.")}
  end

  defp button_label(%{inherited: true, enabled: true}),
    do: "Use installation setting only"

  defp button_label(%{inherited: true}),
    do: "Keep enabled here if disabled installation-wide"

  defp button_label(%{enabled: true}), do: "Disable for this environment"
  defp button_label(%{enabled: false}), do: "Enable for this environment"

  @impl true
  def render(assigns) do
    rows =
      for skill <- Skills.catalog(assigns.view.snapshot.work.installed_skills) do
        name = skill["name"]

        %{
          name: name,
          title: name |> String.replace("-", " ") |> String.capitalize(),
          description: skill["description"],
          enabled: name in assigns.selected,
          inherited: name in assigns.view.snapshot.work.enabled_skills
        }
      end

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id={@id}>
      <Kit.section_card
        title="Skills for this environment"
        lede="Choose additional procedures Ryker can consult here."
      >
        <div :for={row <- @rows} class="kit-card-part">
          <h3>{row.title}</h3>
          <p>{row.description}</p>
          <p :if={row.inherited}>
            {if row.enabled,
              do: "Enabled here and installation-wide",
              else: "Enabled installation-wide"}
          </p>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="set-skill"
            phx-target={@myself}
            phx-value-name={row.name}
            phx-value-enabled={to_string(!row.enabled)}
            phx-value-revision={@view.revision}
            aria-label={button_label(row) <> " · " <> row.name}
          >
            {button_label(row)}
          </button>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} />
      </Kit.section_card>
    </div>
    """
  end
end

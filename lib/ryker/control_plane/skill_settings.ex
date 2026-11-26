defmodule Ryker.ControlPlane.SkillSettings do
  @moduledoc "The procedures an operator enables installation-wide or in one environment."
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit, SettingsView}
  alias Ryker.Skills

  @impl true
  def update(assigns, socket) do
    scope = assigns.environment || assigns.view.snapshot.work

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:selected, scope.enabled_skills)
     |> assign_new(:removing, fn -> nil end)
     |> assign_new(:remove_revision, fn -> nil end)
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

  def handle_event("ask-remove", %{"name" => name}, %{assigns: %{environment: nil}} = socket) do
    {:noreply,
     assign(socket, removing: name, remove_revision: socket.assigns.view.revision, error: nil)}
  end

  def handle_event("cancel-remove", _params, socket),
    do: {:noreply, assign(socket, :removing, nil)}

  def handle_event("remove", _params, %{assigns: %{environment: nil, removing: name}} = socket)
      when is_binary(name) do
    save_change(assign(socket, :removing, nil), fn ->
      socket.assigns.commands.remove_skill.(name, socket.assigns.remove_revision)
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(socket, names) do
    %{commands: commands, environment: environment, view: view} = socket.assigns

    save_change(socket, fn ->
      case environment do
        nil ->
          commands.save_work_skills.(names, view.revision)

        %{ref: ref} ->
          commands.put_environment.(%{ref: ref, enabled_skills: names}, view.revision)
      end
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

      {:error, {:skill_in_use, scopes}} ->
        {:noreply,
         assign(
           socket,
           :error,
           "Before removing this skill, disable it where it is selected: #{Enum.join(scopes, ", ")}."
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, "The skill setting could not be saved.")}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:noreply,
       assign(socket, :error, "Ryker could not reach its settings. Try again in a moment.")}
  end

  defp button_label(%{inherited: true, enabled: true}, _environment),
    do: "Use installation setting only"

  defp button_label(%{inherited: true}, _environment),
    do: "Keep enabled here if disabled installation-wide"

  defp button_label(%{enabled: true}, nil), do: "Disable installation-wide"
  defp button_label(%{enabled: false}, nil), do: "Enable installation-wide"
  defp button_label(%{enabled: true}, _environment), do: "Disable for this environment"
  defp button_label(%{enabled: false}, _environment), do: "Enable for this environment"

  @impl true
  def render(assigns) do
    rows =
      for skill <- Skills.catalog(assigns.view.snapshot.work.installed_skills) do
        name = skill["name"]

        %{
          name: name,
          source: skill["source"],
          document: skill["document"],
          title: name |> String.replace("-", " ") |> String.capitalize(),
          description: skill["description"],
          enabled: name in assigns.selected,
          inherited:
            assigns.environment != nil and name in assigns.view.snapshot.work.enabled_skills
        }
      end

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id={@id}>
      <Kit.section_card
        title={if @environment, do: "Skills for this environment", else: "Skill catalog"}
        lede={
          if @environment,
            do: "Choose additional procedures Ryker can consult here.",
            else: "Choose procedures Ryker can consult anywhere on this installation."
        }
      >
        <div :for={row <- @rows} class="kit-card-part">
          <h3>{row.title}</h3>
          <p>{row.description}</p>
          <p :if={!@environment && !row.source}>Bundled with Ryker</p>
          <p :if={!@environment && row.source}>
            <a href={row.source}>View installed revision on GitHub</a>
          </p>
          <Components.disclosure
            :if={!@environment}
            id={"procedure-" <> row.name}
            label="Read procedure"
          >
            <pre class="model-document-text">{row.document}</pre>
          </Components.disclosure>
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
            aria-label={button_label(row, @environment) <> " · " <> row.name}
          >
            {button_label(row, @environment)}
          </button>
          <button
            :if={!@environment && row.source && @removing != row.name}
            type="button"
            class="ui-button secondary"
            phx-click="ask-remove"
            phx-target={@myself}
            phx-value-name={row.name}
          >Remove</button>
          <div :if={@removing == row.name}>
            <p>Remove {row.name} from the catalog?</p>
            <button
              type="button"
              class="ui-button secondary"
              phx-click="cancel-remove"
              phx-target={@myself}
            >Cancel</button>
            <button type="button" class="ui-button secondary" phx-click="remove" phx-target={@myself}>Remove skill</button>
          </div>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} />
      </Kit.section_card>
    </div>
    """
  end
end

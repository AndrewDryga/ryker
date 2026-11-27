defmodule Ryker.ControlPlane.SkillInstallPage do
  @moduledoc "Two independent ways to import a skill, with restoration for removed bundled skills."
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, SettingsView, SkillImport, SkillPage}
  alias Ryker.Skills

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("restore", %{"name" => name}, %{assigns: a} = socket) do
    case a.commands.restore_skill.(name, a.view.revision) do
      {:ok, snapshot} ->
        send(self(), {:settings_editor_saved, SettingsView.view(snapshot)})
        {:noreply, push_navigate(socket, to: "/skills/" <> name)}

      {:error, _} ->
        {:noreply,
         assign(socket, :error, "Could not restore this skill. Review the current catalog.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="skill-install-options">
        <.live_component
          :for={method <- ~w(github paste)}
          module={SkillImport}
          id={"install-skill-" <> method}
          method={method}
          view={@view}
          commands={@commands}
        />
      </div>
      <div
        :for={name <- Skills.names(%{}) -- Skills.names(@view.snapshot.work.installed_skills)}
        class="skill-availability"
      >
        <span>{SkillPage.title(name)} · Bundled with Ryker</span>
        <button
          type="button"
          class="ui-button secondary"
          phx-click="restore"
          phx-value-name={name}
          phx-target={@myself}
        >Restore skill</button>
      </div>
      <Components.form_feedback :if={@error} message={@error} tone={:error} />
    </div>
    """
  end
end

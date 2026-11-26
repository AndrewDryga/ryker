defmodule Ryker.ControlPlane.SkillImport do
  @moduledoc "Preview an unauthenticated GitHub read before installing the exact server-held document."
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit, SettingsView}
  alias Ryker.Skills

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:url, fn -> "" end)
     |> assign_new(:preview, fn -> nil end)
     |> assign_new(:loading, fn -> false end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)}
  end

  @impl true
  def handle_event("preview", %{"url" => url}, socket) when is_binary(url) do
    url = String.trim(url)

    {:noreply,
     socket
     |> assign(url: url, loading: true, preview: nil, notice: nil, error: nil)
     |> start_async(:preview, fn -> Skills.preview(url) end)}
  end

  def handle_event("install", _params, %{assigns: %{preview: %{} = preview}} = socket) do
    %{commands: commands, reviewed_revision: revision} = socket.assigns

    case commands.install_skill.(preview, revision) do
      {:ok, snapshot} ->
        send(self(), {:settings_editor_saved, SettingsView.view(snapshot)})

        {:noreply,
         assign(socket,
           preview: nil,
           url: "",
           error: nil,
           notice: "#{preview["name"]} installed."
         )}

      {:error, {:settings_conflict, current}} ->
        send(self(), {:settings_editor_saved, SettingsView.view(current)})

        {:noreply,
         assign(socket, preview: nil, error: "Settings changed. Preview the skill again.")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message(reason))}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:noreply,
       assign(
         socket,
         :error,
         "Ryker could not save this skill. Try installing the reviewed version again."
       )}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, preview: nil, error: nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:preview, {:ok, {:ok, skill}}, socket) do
    {:noreply,
     assign(socket,
       loading: false,
       preview: skill,
       reviewed_revision: socket.assigns.view.revision
     )}
  end

  def handle_async(:preview, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading: false, error: message(reason))}

  def handle_async(:preview, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, loading: false, error: message(:github_unavailable))}

  defp message(:invalid_url) do
    "Use a public github.com repository, skill folder, or SKILL.md file URL. For a branch with slashes, use a commit permalink."
  end

  defp message(:skill_not_found) do
    "No public SKILL.md was found there. For a repository of skills, open the individual skill folder and paste its URL."
  end

  defp message(:github_limited),
    do: "GitHub refused the public read or reached its request limit. Try again later."

  defp message(:skill_name_taken) do
    "Another skill already uses this name. Only the same GitHub file can update an installed skill."
  end

  defp message(:skill_too_large), do: "Choose a SKILL.md file no larger than 32 KiB."

  defp message(:skill_limit),
    do: "The installed skills exceed this installation’s catalog size limit."

  defp message(:invalid_skill),
    do: "The file needs a valid skill name, description and Markdown procedure."

  defp message(_reason), do: "Ryker could not read the skill from GitHub. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Kit.section_card
        title="Install from GitHub"
        lede="Import the SKILL.md procedure from a public repository. Companion scripts and files are outside this import."
      >
        <form :if={!@preview} phx-submit="preview" phx-target={@myself} class="kit-form-section">
          <div class="settings-field">
            <label for="skill-github-url">GitHub URL</label>
            <input
              id="skill-github-url"
              type="url"
              name="url"
              required
              maxlength="2048"
              value={@url}
              placeholder="https://github.com/owner/repository/tree/main/skills/name"
            />
          </div>
          <button type="submit" class="ui-button secondary" disabled={@loading}>{if @loading,
            do: "Reading…",
            else: "Preview skill"}</button>
        </form>
        <div :if={@preview} class="kit-card-part">
          <h3>{@preview["name"]}</h3><p>{@preview["description"]}</p>
          <p><a href={@preview["source"]}>Source at the reviewed commit</a></p>
          <pre class="model-document-text">{@preview["document"]}</pre>
          <button type="button" class="ui-button primary" phx-click="install" phx-target={@myself}>
            {if Map.has_key?(@view.snapshot.work.installed_skills, @preview["name"]),
              do: "Install this revision",
              else: "Install skill"}
          </button>
          <button type="button" class="ui-button secondary" phx-click="cancel" phx-target={@myself}>Cancel</button>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} />
        <p :if={@notice} role="status">{@notice}</p>
      </Kit.section_card>
    </div>
    """
  end
end

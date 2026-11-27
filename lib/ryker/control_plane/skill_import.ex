defmodule Ryker.ControlPlane.SkillImport do
  @moduledoc "Preview and install a skill from pasted Markdown or a public GitHub URL."
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit, SettingsView}
  alias Ryker.Skills

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:url, fn -> "" end)
     |> assign_new(:document, fn -> "" end)
     |> assign_new(:preview, fn -> nil end)
     |> assign_new(:loading, fn -> false end)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("preview", %{"document" => document}, %{assigns: %{method: "paste"}} = socket)
      when is_binary(document) do
    socket = assign(socket, document: document, error: nil, preview: nil)
    {:noreply, show_preview(Skills.preview_paste(document), socket)}
  end

  def handle_event("preview", %{"url" => url}, %{assigns: %{method: "github"}} = socket)
      when is_binary(url) do
    url = String.trim(url)

    {:noreply,
     socket
     |> assign(url: url, loading: true, preview: nil, error: nil)
     |> start_async(:preview, fn -> Skills.preview(url) end)}
  end

  def handle_event("install", _params, %{assigns: %{preview: %{} = preview}} = socket) do
    %{commands: commands, reviewed_revision: revision} = socket.assigns

    case commands.install_skill.(preview, revision) do
      {:ok, snapshot} ->
        send(self(), {:settings_editor_saved, SettingsView.view(snapshot)})

        {:noreply, push_navigate(socket, to: "/skills/" <> preview["name"])}

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

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, preview: nil, error: nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:preview, {:ok, result}, socket), do: {:noreply, show_preview(result, socket)}

  def handle_async(:preview, {:exit, _reason}, socket),
    do: {:noreply, show_preview({:error, :github_unavailable}, socket)}

  defp show_preview({:ok, skill}, socket) do
    assign(socket,
      loading: false,
      preview: skill,
      reviewed_revision: socket.assigns.view.revision
    )
  end

  defp show_preview({:error, reason}, socket),
    do: assign(socket, loading: false, error: message(reason))

  defp message(:invalid_url) do
    "Use a public github.com repository, skill folder, or SKILL.md file URL. For a branch with slashes, use a commit permalink."
  end

  defp message(:skill_not_found) do
    "No public SKILL.md was found there. For a repository of skills, open the individual skill folder and paste its URL."
  end

  defp message(:github_limited),
    do: "GitHub refused the public read or reached its request limit. Try again later."

  defp message(:skill_name_taken) do
    "A skill with this name already exists. Open it to edit it, or choose a different name."
  end

  defp message(:skill_too_large), do: "Choose a SKILL.md file no larger than 32 KiB."

  defp message(:skill_limit),
    do: "The installed skills exceed this installation’s catalog size limit."

  defp message(:invalid_skill),
    do: "The file needs a valid skill name, description and Markdown procedure."

  defp message(_reason), do: "Ryker could not complete the import. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Kit.form_card label="Install skill" class="skill-install">
        <form
          :if={!@preview}
          phx-submit="preview"
          phx-target={@myself}
          class="kit-form-section skill-import-form"
        >
          <Kit.segmented
            label="Skill source"
            options={[
              {"GitHub", "/skills/install/github", @method == "github"},
              {"Paste Markdown", "/skills/install/paste", @method == "paste"}
            ]}
            patch
          />
          <div :if={@method == "paste"} class="settings-field">
            <label for="skill-markdown">SKILL.md</label>
            <span id="markdown-help" class="skill-hint">Paste the whole file, including its name and description. Maximum 32 KiB.</span>
            <textarea
              id="skill-markdown"
              name="document"
              aria-describedby="markdown-help"
              placeholder={
                ~s(---\nname: my-skill\ndescription: When to use this skill\n---\n\nWrite the instructions here.)
              }
              rows="10"
              spellcheck="false"
              required
            >{@document}</textarea>
          </div>
          <div :if={@method == "github"} class="settings-field">
            <label for="skill-github-url">GitHub URL</label>
            <span id="url-help" class="skill-hint">Link to a public repository, a skill folder, or its SKILL.md file.</span>
            <input
              id="skill-github-url"
              type="url"
              aria-describedby="url-help"
              name="url"
              required
              maxlength="2048"
              value={@url}
              placeholder="https://github.com/owner/repository/tree/main/skills/name"
            />
          </div>
          <div class="skill-actions">
            <button type="submit" class="ui-button primary" disabled={@loading}>{if @loading,
              do: "Reading…",
              else: "Preview skill"}</button><.link navigate="/skills" class="ui-button secondary">Cancel</.link>
          </div>
        </form>
        <div :if={@preview} class="skill-review">
          <h2>{Ryker.ControlPlane.SkillPage.title(@preview["name"])}</h2><p>
            {@preview["description"]}
          </p>
          <p :if={@preview["source"]}>
            <a href={@preview["source"]}>Source at the reviewed commit</a>
          </p>
          <p class="skill-hint">Installs the reviewed Markdown only. New skills start disabled.</p>
          <Ryker.ControlPlane.SkillPage.procedure document={@preview["document"]} />
          <Components.disclosure id="skill-raw" label="View SKILL.md">
            <pre class="model-document-text">{@preview["document"]}</pre>
          </Components.disclosure>
          <div class="skill-actions">
            <button type="button" class="ui-button primary" phx-click="install" phx-target={@myself}>
              {if @method == "github" and
                    Map.has_key?(@view.snapshot.work.installed_skills, @preview["name"]),
                  do: "Install this revision",
                  else: "Install skill"}
            </button>
            <button type="button" class="ui-button secondary" phx-click="cancel" phx-target={@myself}>
              {if @method == "paste", do: "Edit Markdown", else: "Change URL"}
            </button>
          </div>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} />
      </Kit.form_card>
      <div
        :for={name <- Skills.names(%{}) -- Skills.names(@view.snapshot.work.installed_skills)}
        class="skill-availability"
      >
        <span>{Ryker.ControlPlane.SkillPage.title(name)} · Bundled with Ryker</span>
        <button
          type="button"
          class="ui-button secondary"
          phx-click="restore"
          phx-value-name={name}
          phx-target={@myself}
        >Restore skill</button>
      </div>
    </div>
    """
  end
end

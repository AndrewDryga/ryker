defmodule Ryker.ControlPlane.SkillPage do
  @moduledoc "The Work skill directory and its installation-level detail page."
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit, KnowledgeDocument, Paths, SettingsView}
  alias Ryker.Skills

  def title(name), do: name |> String.replace("-", " ") |> String.capitalize()

  def catalog(assigns) do
    assigns =
      assign(assigns, :skills, Skills.catalog(assigns.view.snapshot.work.installed_skills))

    ~H"""
    <div id="skill-catalog">
      <Kit.entity_list :if={@skills != []} label="Skills">
        <Kit.entity_row
          :for={skill <- @skills}
          icon={:book}
          name={title(skill["name"])}
          href={"/skills/" <> skill["name"]}
          link_row
          text={skill["description"]}
          meta={[origin(skill)]}
          state={state(skill["name"], @view.snapshot)}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@skills == []}
        icon={:book}
        title="No skills installed"
        text="Install a procedure to make it available to Ryker."
      />
    </div>
    """
  end

  defp origin(%{"modified" => true, "source" => _}), do: "GitHub · Edited locally"
  defp origin(%{"modified" => true}), do: "Bundled · Edited locally"
  defp origin(%{"source" => _}), do: "GitHub"
  defp origin(_skill), do: "Bundled with Ryker"

  defp state(name, snapshot) do
    count = Enum.count(snapshot.environments, &(name in &1.enabled_skills))

    cond do
      name in snapshot.work.enabled_skills -> {:on, "Installation-wide"}
      count == 1 -> {:on, "1 environment"}
      count > 1 -> {:on, "#{count} environments"}
      true -> {:off, "Disabled"}
    end
  end

  def procedure(assigns) do
    body =
      Regex.replace(~r/\A---\r?\n.*?\r?\n---[ \t]*\r?\n/s, assigns.document, "") |> String.trim()

    {heading, content} = KnowledgeDocument.render(body, %{github_repository: nil, commit: nil})
    assigns = assign(assigns, heading: heading, content: content)

    ~H"""
    <div class="markdown-preview knowledge-document skill-procedure">
      <h3 :if={@heading}>{@heading}</h3>{@content}
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    skill = Skills.find(assigns.view.snapshot.work.installed_skills, assigns.name)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:skill, skill)
     |> assign_new(:draft, fn -> nil end)
     |> assign_new(:deleting, fn -> nil end)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("edit", _, %{assigns: %{skill: %{} = skill}} = socket) do
    {:noreply,
     assign(socket,
       draft: skill["document"],
       revision: socket.assigns.view.revision,
       error: nil
     )}
  end

  def handle_event("draft", %{"document" => doc}, socket),
    do: {:noreply, assign(socket, :draft, doc)}

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, draft: nil, deleting: nil, error: nil)}

  def handle_event(
        "save",
        %{"document" => doc},
        %{assigns: %{draft: draft, revision: revision} = a} = socket
      )
      when is_binary(draft) do
    persist(
      assign(socket, :draft, doc),
      fn -> a.commands.edit_skill.(a.name, doc, revision) end,
      :save
    )
  end

  def handle_event("toggle", %{"revision" => revision}, %{assigns: a} = socket) do
    selected = a.view.snapshot.work.enabled_skills

    if revision == to_string(a.view.revision) do
      names = if a.name in selected, do: List.delete(selected, a.name), else: [a.name | selected]

      persist(
        socket,
        fn -> a.commands.save_work_skills.(Enum.sort(names), a.view.revision) end,
        :toggle
      )
    else
      {:noreply, assign(socket, :error, "Settings changed. Review the current selection.")}
    end
  end

  def handle_event("ask-delete", _, socket),
    do: {:noreply, assign(socket, deleting: socket.assigns.view.revision, error: nil)}

  def handle_event("delete", _, %{assigns: %{deleting: revision} = a} = socket)
      when not is_nil(revision),
      do: persist(socket, fn -> a.commands.remove_skill.(a.name, revision) end, :delete)

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp persist(socket, command, action) do
    case command.() do
      {:ok, snapshot} ->
        send(self(), {:settings_editor_saved, SettingsView.view(snapshot)})
        socket = assign(socket, draft: nil, deleting: nil, error: nil)
        {:noreply, if(action == :delete, do: push_navigate(socket, to: "/skills"), else: socket)}

      {:error, {:settings_conflict, current}} ->
        send(self(), {:settings_editor_saved, SettingsView.view(current)})

        {:noreply,
         assign(
           socket,
           :error,
           "Settings changed. Cancel and reopen to review the latest version."
         )}

      {:error, {:skill_in_use, scopes}} ->
        {:noreply,
         assign(socket, :error, "Disable this skill first in " <> Enum.join(scopes, ", ") <> ".")}

      {:error, :skill_limit} ->
        {:noreply,
         assign(
           socket,
           :error,
           "The catalog is full. Shorten the procedure or remove an unused skill."
         )}

      {:error, _} ->
        {:noreply,
         assign(
           socket,
           :error,
           "Keep the original name and a description in the header, with a Markdown procedure under 32 KiB."
         )}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:noreply, assign(socket, :error, "Settings are unavailable. Try again.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Kit.empty :if={!@skill} icon={:book} title="This skill is no longer installed" />
      <div :if={@skill} class="skill-detail">
        <div class="skill-availability">
          <div>
            <strong>Installation-wide</strong><p>
              Make this procedure available in every environment.
            </p>
          </div>
          <button
            class="ui-button secondary"
            disabled={!is_nil(@draft)}
            phx-click="toggle"
            phx-target={@myself}
            phx-value-revision={@view.revision}
          >{if @name in @view.snapshot.work.enabled_skills,
            do: "Disable installation-wide",
            else: "Enable installation-wide"}</button>
        </div>
        <p
          :for={env <- Enum.filter(@view.snapshot.environments, &(@name in &1.enabled_skills))}
          class="skill-scope"
        >
          Enabled in <.link navigate={Paths.edit_environment(env.ref)}>{env.display_name}</.link>
        </p>
        <Kit.form_card label="Procedure">
          <div class="skill-document-head">
            <div>
              <h2>Procedure</h2><small>{origin(@skill)}
              <a :if={@skill["source"]} href={@skill["source"]}>Original revision ↗</a></small>
            </div>
            <button
              :if={is_nil(@draft)}
              class="ui-button secondary"
              phx-click="edit"
              phx-target={@myself}
            >Edit procedure</button>
          </div>
          <.procedure :if={is_nil(@draft)} document={@skill["document"]} />
          <form
            :if={!is_nil(@draft)}
            id="edit-skill-form"
            phx-change="draft"
            phx-submit="save"
            phx-target={@myself}
            class="skill-editor settings-field"
          >
            <label for="skill-document">SKILL.md</label>
            <textarea id="skill-document" name="document" spellcheck="false" rows="16" required>{@draft}</textarea>
            <div class="skill-actions">
              <button class="ui-button primary" phx-disable-with="Saving…">Save changes</button><button
                type="button"
                class="ui-button secondary"
                phx-click="cancel"
                phx-target={@myself}
              >Cancel</button>
            </div>
          </form>
        </Kit.form_card>
        <Components.form_feedback :if={@error && !@deleting} message={@error} tone={:error} />
        <div>
          <button
            class="ui-button danger"
            disabled={!is_nil(@draft)}
            phx-click="ask-delete"
            phx-target={@myself}
          >Delete skill</button>
        </div>
        <Kit.confirm_modal
          :if={@deleting}
          id="delete-skill"
          title={"Delete " <> title(@name) <> "?"}
          text="Remove this procedure from this installation’s catalog. Earlier work keeps its saved revision."
          label="Delete skill"
          cancel="cancel"
          target={@myself}
          phx-click="delete"
          phx-target={@myself}
          error={@error}
        />
      </div>
    </div>
    """
  end
end

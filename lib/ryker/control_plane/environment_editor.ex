defmodule Ryker.ControlPlane.EnvironmentEditor do
  @moduledoc """
  Adds or edits one environment: its name, what it is for, the repositories
  work in it may use, its Emisar account and whether it is the default.

  The repositories are every added repository, the chosen ones first and in
  their order: work changes the first and only reads the others, and Move up
  and Move down change that order. A live refresh never overwrites an unsaved
  draft; a refused save keeps the draft and says what to fix in words; a save
  against settings that changed underneath is refused rather than written
  over them. The LiveView closes the editor once a save lands.
  """

  use Phoenix.LiveComponent

  alias Ryker.ControlPlane.{Components, Environments, SettingsView}
  alias Ryker.Settings
  alias Ryker.Settings.Environment

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    cond do
      not Map.has_key?(socket.assigns, :draft) ->
        {:ok, reset(socket)}

      not socket.assigns.dirty ->
        {:ok, reset(socket)}

      # The installation has one revision, so a save anywhere moves it. The
      # draft is stale only when this environment itself changed underneath.
      saved(socket.assigns.view, socket.assigns.ref) == socket.assigns.baseline ->
        {:ok, assign(socket, :expected_revision, socket.assigns.view.revision)}

      true ->
        {:ok, socket}
    end
  end

  defp reset(socket) do
    %{view: view, ref: ref} = socket.assigns
    baseline = saved(view, ref)

    assign(socket,
      baseline: baseline,
      draft: baseline || blank(view),
      dirty: false,
      error: nil,
      expected_revision: view.revision
    )
  end

  defp saved(_view, "new"), do: nil

  defp saved(view, ref) do
    case Environments.find(view.snapshot, ref) do
      nil ->
        nil

      environment ->
        %{
          description: environment.description || "",
          display_name: environment.display_name,
          emisar_connection_ref: environment.emisar_connection_ref,
          is_default: environment.is_default,
          repositories: Environment.repository_refs(environment)
        }
    end
  end

  # The first environment an installation gets becomes its default unless
  # the person says otherwise.
  defp blank(view) do
    %{
      description: "",
      display_name: "",
      emisar_connection_ref: nil,
      is_default: is_nil(Environment.default(view.snapshot)),
      repositories: []
    }
  end

  @impl true
  def handle_event("change", %{"environment" => params}, socket),
    do: {:noreply, socket |> put_draft(params) |> assign(:error, nil)}

  def handle_event("move", %{"repository" => ref, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    repositories = move(socket.assigns.draft.repositories, ref, direction)

    {:noreply,
     assign(socket, draft: %{socket.assigns.draft | repositories: repositories}, dirty: true)}
  end

  def handle_event("save", %{"environment" => params}, socket),
    do: {:noreply, socket |> put_draft(params) |> save()}

  # The browser sends the chosen repositories in the order the list shows
  # them: the chosen ones first, in their order, then the rest. A box ticked
  # just now therefore lands after the ones already chosen.
  defp put_draft(socket, params) do
    draft = socket.assigns.draft

    repositories =
      case Map.fetch(params, "repositories") do
        {:ok, values} ->
          ticked = values |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))
          kept = Enum.filter(draft.repositories, &(&1 in ticked))
          kept ++ Enum.uniq(ticked -- kept)

        :error ->
          draft.repositories
      end

    draft = %{
      draft
      | description: text(params, "description", draft.description),
        display_name: text(params, "display_name", draft.display_name),
        emisar_connection_ref:
          case Map.get(params, "emisar_connection_ref", draft.emisar_connection_ref) do
            ref when ref in [nil, ""] -> nil
            ref -> ref
          end,
        is_default:
          if(Map.has_key?(params, "is_default"),
            do: params["is_default"] == "true",
            else: draft.is_default
          ),
        repositories: repositories
    }

    assign(socket, draft: draft, dirty: true)
  end

  defp text(params, key, fallback) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing -> fallback
    end
  end

  defp move(repositories, ref, direction) do
    case Enum.find_index(repositories, &(&1 == ref)) do
      nil ->
        repositories

      index ->
        target = if direction == "up", do: index - 1, else: index + 1

        if target in 0..(length(repositories) - 1)//1 do
          repositories
          |> List.replace_at(index, Enum.at(repositories, target))
          |> List.replace_at(target, ref)
        else
          repositories
        end
    end
  end

  defp save(socket) do
    %{draft: draft, ref: ref, view: view} = socket.assigns
    name = String.trim(draft.display_name)

    attributes = %{
      ref: if(ref == "new", do: new_ref(name, view), else: ref),
      display_name: name,
      description: String.trim(draft.description),
      repositories: draft.repositories,
      emisar_connection_ref: draft.emisar_connection_ref,
      is_default: draft.is_default
    }

    case attempt(fn ->
           Settings.put_environment(
             attributes,
             socket.assigns.expected_revision,
             Settings.actor()
           )
         end) do
      {:ok, snapshot} ->
        send(self(), {:environment_saved, SettingsView.view(snapshot), "#{name} was saved."})
        assign(socket, dirty: false, error: nil)

      {:error, reason} ->
        assign(socket, :error, error(reason))
    end
  end

  defp new_ref(name, view),
    do: Environments.new_ref(name, Enum.map(view.snapshot.environments, & &1.ref))

  # A database that stops answering mid-save must not take the draft with it.
  defp attempt(command) do
    command.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :settings_unavailable}
  end

  defp error({:invalid_settings, errors}) do
    case errors |> Enum.map(&refused/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> "The environment could not be saved. Reload the page and try again."
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp error({:settings_conflict, _current}),
    do:
      "This environment changed while you were editing it, so nothing was saved. " <>
        "Reload the page to see it now, then make your change again."

  defp error(:settings_forbidden), do: "This console is not allowed to change settings."

  defp error(:settings_unavailable),
    do: "Ryker could not reach its settings, so nothing was saved. Try again in a moment."

  defp error(_reason), do: "The environment could not be saved. Reload the page and try again."

  defp refused({:display_name, :required}), do: "Give the environment a name."
  defp refused({:display_name, _length}), do: "Use a name of 80 characters or fewer."
  defp refused({:description, _length}), do: "Keep the description to 500 characters or fewer."

  defp refused({:repositories, :companion_name}),
    do:
      "Ryker can only read a repository after the first when its name is up to 48 lowercase " <>
        "letters, numbers, dashes or underscores. Move it first or leave it out."

  defp refused({:repositories, :unknown_repository}),
    do: "A chosen repository is no longer added. Reload the page and choose again."

  defp refused({:repositories, _list}), do: "Choose each repository once, and 33 at most."

  defp refused({:emisar_connection_ref, _unknown}),
    do: "That Emisar account no longer exists. Choose another one."

  defp refused(_other), do: nil

  @impl true
  def render(assigns) do
    snapshot = assigns.view.snapshot
    chosen = assigns.draft.repositories

    unchosen =
      for repository <- snapshot.repositories,
          repository.ref not in chosen,
          do: choice(snapshot, repository.ref, nil)

    choices =
      Enum.map(Enum.with_index(chosen), fn {ref, position} -> choice(snapshot, ref, position) end) ++
        Enum.sort_by(unchosen, &String.downcase(&1.name))

    assigns =
      assign(assigns,
        accounts: snapshot.emisar_connections,
        choices: choices,
        last: length(chosen) - 1,
        title:
          if(assigns.ref == "new",
            do: "Add an environment",
            else:
              "Edit " <> ((assigns.baseline && assigns.baseline.display_name) || "environment")
          )
      )

    ~H"""
    <div id={@id} class="settings-editor environment-editor">
      <h3 class="settings-editor-heading">{@title}</h3>
      <form
        id={"#{@id}-form"}
        class="settings-form"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
        data-dirty={to_string(@dirty)}
        autocomplete="off"
      >
        <div class="settings-field">
          <label for={"#{@id}-name"}>Name</label>
          <input
            id={"#{@id}-name"}
            type="text"
            name="environment[display_name]"
            value={@draft.display_name}
            maxlength="80"
            required
          />
        </div>
        <div class="settings-field">
          <label for={"#{@id}-description"}>Description</label>
          <p class="settings-help" id={"#{@id}-description-help"}>
            Optional. What work in this environment is for.
          </p>
          <input
            id={"#{@id}-description"}
            type="text"
            name="environment[description]"
            value={@draft.description}
            maxlength="500"
            aria-describedby={"#{@id}-description-help"}
          />
        </div>
        <fieldset class="settings-field">
          <legend>Repositories</legend>
          <p class="settings-help">
            Changes go to the first repository; the others are read only.
          </p>
          <input type="hidden" name="environment[repositories][]" value="" />
          <ol :if={@choices != []} class="environment-repositories">
            <li
              :for={choice <- @choices}
              class="environment-repository"
              data-repository={choice.ref}
            >
              <input
                type="checkbox"
                id={"#{@id}-repository-#{choice.ref}"}
                name="environment[repositories][]"
                value={choice.ref}
                checked={not is_nil(choice.position)}
              />
              <label for={"#{@id}-repository-#{choice.ref}"}>
                <strong>{choice.name}</strong>
                <small :if={choice.position == 0}>Changes go here</small>
                <small :if={choice.position && choice.position > 0}>Read only</small>
              </label>
              <span :if={choice.position} class="environment-repository-order">
                <button
                  type="button"
                  class="ui-button quiet"
                  phx-click="move"
                  phx-value-repository={choice.ref}
                  phx-value-direction="up"
                  phx-target={@myself}
                  disabled={choice.position == 0}
                  title="Move up"
                ><Components.icon name={:arrow_up} /><span class="sr-only">Move {choice.name} up</span></button>
                <button
                  type="button"
                  class="ui-button quiet"
                  phx-click="move"
                  phx-value-repository={choice.ref}
                  phx-value-direction="down"
                  phx-target={@myself}
                  disabled={choice.position == @last}
                  title="Move down"
                ><Components.icon name={:arrow_down} /><span class="sr-only">Move {choice.name} down</span></button>
              </span>
            </li>
          </ol>
          <p :if={@choices == []} class="settings-help">
            No repositories are added yet. <.link navigate="/repositories">Add repositories</.link>
            first, or save without any: Ryker then works here without code.
          </p>
        </fieldset>
        <div class="settings-field">
          <label for={"#{@id}-emisar"}>Emisar account</label>
          <p class="settings-help" id={"#{@id}-emisar-help"}>
            Work here sends the actions it wants to run to this account, where a person approves them.
          </p>
          <select
            id={"#{@id}-emisar"}
            name="environment[emisar_connection_ref]"
            aria-describedby={"#{@id}-emisar-help"}
          >
            <option value="" selected={is_nil(@draft.emisar_connection_ref)}>None</option>
            <option
              :for={account <- @accounts}
              value={account.ref}
              selected={account.ref == @draft.emisar_connection_ref}
            >
              {account.display_name}
            </option>
          </select>
        </div>
        <div class="settings-field settings-field-boolean">
          <input type="hidden" name="environment[is_default]" value="false" />
          <input
            type="checkbox"
            id={"#{@id}-default"}
            name="environment[is_default]"
            value="true"
            checked={@draft.is_default}
            aria-describedby={"#{@id}-default-help"}
          />
          <label for={"#{@id}-default"}>Use as default</label>
          <p class="settings-help" id={"#{@id}-default-help"}>
            Chat and every conversation without its own environment work here.
          </p>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
        <div class="settings-actions">
          <button type="submit" class="ui-button primary" phx-disable-with="Saving…">
            {if @ref == "new", do: "Add environment", else: "Save changes"}
          </button>
          <.link patch="/environments" class="ui-button secondary">Cancel</.link>
        </div>
      </form>
    </div>
    """
  end

  defp choice(snapshot, ref, position),
    do: %{ref: ref, name: Environments.repository_name(snapshot, ref), position: position}
end

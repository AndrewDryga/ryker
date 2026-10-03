defmodule Ryker.ControlPlane.EnvironmentEditor do
  @moduledoc """
  Adds or edits one environment, on its own page: its name, what it is for,
  the repositories work in it may use and how, its Emisar account and whether
  it is the default environment.

  Every added repository is listed once, by name, in the same place whatever
  is chosen. A chosen repository is read only or read and write, and one of
  them is the default: the one a task changes unless it picks another, so it
  is always read and write (Andrew, 2026-09-27: "can we here limit read or
  read/write access per repo?", and of ordering them to pick the default:
  "default can be just a checkbox button or smth like that"). A repository
  starts read and write when it is chosen, as every repository was before
  access could be limited; Read only limits it.

  A live refresh never overwrites an unsaved draft; a refused save keeps the
  draft and says what to fix in words; a save against settings that changed
  underneath is refused rather than written over them. The LiveView returns
  to the list once a save lands.
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

  defp saved(_view, nil), do: nil

  defp saved(view, ref) do
    case Environments.find(view.snapshot, ref) do
      nil ->
        nil

      environment ->
        refs = Environment.repository_refs(environment)

        %{
          access: Map.new(environment.repositories, &{&1.repository_ref, &1.access}),
          default_repository: List.first(refs),
          description: environment.description || "",
          display_name: environment.display_name,
          emisar_connection_ref: environment.emisar_connection_ref,
          is_default: environment.is_default,
          repositories: Enum.sort(refs)
        }
    end
  end

  # The first environment an installation gets becomes its default unless
  # the person says otherwise.
  defp blank(view) do
    %{
      access: %{},
      default_repository: nil,
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

  def handle_event("save", %{"environment" => params}, socket),
    do: {:noreply, socket |> put_draft(params) |> save()}

  # Unticking two dozen repositories one by one to keep three (Andrew, 2026-10-03, on blitz:
  # "i need a way to select/deselect each").
  def handle_event("choose-all", _params, socket) do
    refs = Enum.map(socket.assigns.view.snapshot.repositories, & &1.ref)
    {:noreply, socket |> choose(refs) |> assign(:error, nil)}
  end

  def handle_event("choose-none", _params, socket),
    do: {:noreply, socket |> choose([]) |> assign(:error, nil)}

  defp choose(socket, refs) do
    draft = socket.assigns.draft
    repositories = Enum.sort(refs)
    access = access(%{}, draft, repositories)

    assign(socket, draft: with_repositories(draft, repositories, access, nil), dirty: true)
  end

  defp put_draft(socket, params) do
    draft = socket.assigns.draft

    repositories =
      case Map.fetch(params, "repositories") do
        {:ok, values} ->
          values |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

        :error ->
          draft.repositories
      end
      |> Enum.sort()

    access = access(params, draft, repositories)

    draft = %{
      with_repositories(draft, repositories, access, params["default_repository"])
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
          )
    }

    assign(socket, draft: draft, dirty: true)
  end

  defp with_repositories(draft, repositories, access, chosen_default) do
    default = default_repository(chosen_default, draft, repositories, access)

    %{
      draft
      | access: if(default, do: Map.put(access, default, :read_write), else: access),
        default_repository: default,
        repositories: repositories
    }
  end

  # Each chosen repository's access as the form says it, else as the draft
  # had it; one chosen just now starts read and write.
  defp access(params, draft, repositories) do
    submitted = if is_map(params["access"]), do: params["access"], else: %{}

    Map.new(repositories, fn ref ->
      access =
        case Map.get(submitted, ref) do
          "read_write" -> :read_write
          "read_only" -> :read_only
          _absent -> Map.get(draft.access, ref, :read_write)
        end

      {ref, access}
    end)
  end

  # The default as chosen, else the one the draft had while it is still
  # chosen, else the first chosen read and write repository, else the first.
  defp default_repository(chosen, draft, repositories, access) do
    cond do
      repositories == [] -> nil
      chosen in repositories -> chosen
      draft.default_repository in repositories -> draft.default_repository
      true -> Enum.find(repositories, &(access[&1] == :read_write)) || hd(repositories)
    end
  end

  defp text(params, key, fallback) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing -> fallback
    end
  end

  defp save(socket) do
    %{draft: draft, ref: ref, view: view} = socket.assigns
    name = String.trim(draft.display_name)
    default = draft.default_repository

    attributes = %{
      ref: ref || new_ref(name, view),
      display_name: name,
      description: String.trim(draft.description),
      # Settings keep the default first; the rest have no order that matters.
      repositories:
        if(default, do: [default | List.delete(draft.repositories, default)], else: []),
      access: draft.access,
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

  defp refused({:display_name, :taken}),
    do: "Another environment already has this name. Choose a different one."

  defp refused({:display_name, _length}), do: "Use a name of 80 characters or fewer."
  defp refused({:description, _length}), do: "Keep the description to 500 characters or fewer."

  # With several repositories, work opens every one it does not change
  # beside the one it does, under the repository's own name, so every name
  # has to fit.
  defp refused({:repositories, :companion_name}),
    do:
      "With more than one repository, each name has to be up to 48 lowercase letters, " <>
        "numbers, dashes or underscores, so Ryker can open it beside the others. " <>
        "Leave out the one whose name does not fit."

  defp refused({:repositories, :unknown_repository}),
    do: "A chosen repository is no longer added. Reload the page and choose again."

  defp refused({:repositories, _list}), do: "Choose each repository once, and 33 at most."

  defp refused({:access, :default_read_only}),
    do: "The default repository is the one a task changes, so it has to be read and write."

  defp refused({:access, _reason}),
    do: "A chosen repository is no longer added. Reload the page and choose again."

  defp refused({:emisar_connection_ref, _unknown}),
    do: "That Emisar account no longer exists. Choose another one."

  defp refused(_other), do: nil

  @impl true
  def render(assigns) do
    snapshot = assigns.view.snapshot
    %{draft: draft} = assigns

    choices =
      snapshot.repositories
      |> Enum.map(fn repository ->
        chosen = repository.ref in draft.repositories

        %{
          ref: repository.ref,
          name: Environments.repository_name(snapshot, repository.ref),
          chosen: chosen,
          access: chosen && Map.get(draft.access, repository.ref, :read_write),
          default: chosen and repository.ref == draft.default_repository
        }
      end)
      |> Enum.sort_by(&String.downcase(&1.name))

    assigns = assign(assigns, accounts: snapshot.emisar_connections, choices: choices)

    ~H"""
    <div id={@id} class="environment-editor">
      <form
        id={"#{@id}-form"}
        class="settings-form"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
        data-dirty={to_string(@dirty)}
        autocomplete="off"
      >
        <div class="kit-form-section">
          <div class="settings-field">
            <label for={"#{@id}-name"}>Name</label>
            <input
              id={"#{@id}-name"}
              type="text"
              name="environment[display_name]"
              value={@draft.display_name}
              maxlength="80"
              placeholder="Production"
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
        </div>
        <div class="kit-form-section">
          <fieldset class="settings-field" aria-describedby={"#{@id}-repositories-help"}>
            <legend>Repositories</legend>
            <p class="settings-help" id={"#{@id}-repositories-help"}>
              Work here can read every repository you choose. A task changes one that is read and
              write: the default, unless it picks another. The default is always read and write.
            </p>
            <input type="hidden" name="environment[repositories][]" value="" />
            <div :if={length(@choices) > 1} class="environment-repositories-choose">
              <button
                type="button"
                class="ui-button quiet"
                phx-click="choose-all"
                phx-target={@myself}
                disabled={Enum.all?(@choices, & &1.chosen)}
              >
                Select all
              </button>
              <button
                type="button"
                class="ui-button quiet"
                phx-click="choose-none"
                phx-target={@myself}
                disabled={not Enum.any?(@choices, & &1.chosen)}
              >
                Select none
              </button>
            </div>
            <div :if={@choices != []} class="environment-repositories">
              <div class="environment-repositories-head" aria-hidden="true">
                <span>Repository</span>
                <span>Access</span>
                <span>Default</span>
              </div>
              <div
                :for={choice <- @choices}
                class="environment-repository"
                data-repository={choice.ref}
                data-chosen={to_string(choice.chosen)}
              >
                <span class="environment-repository-name">
                  <input
                    type="checkbox"
                    id={"#{@id}-repository-#{choice.ref}"}
                    name="environment[repositories][]"
                    value={choice.ref}
                    checked={choice.chosen}
                  />
                  <label for={"#{@id}-repository-#{choice.ref}"}>{choice.name}</label>
                </span>
                <span class="environment-repository-access">
                  <select
                    :if={choice.chosen}
                    id={"#{@id}-access-#{choice.ref}"}
                    name={"environment[access][#{choice.ref}]"}
                    aria-label={"What work may do in #{choice.name}"}
                    disabled={choice.default}
                  >
                    <option value="read_write" selected={choice.access == :read_write}>
                      Read and write
                    </option>
                    <option value="read_only" selected={choice.access == :read_only}>
                      Read only
                    </option>
                  </select>
                  <input
                    :if={choice.default}
                    type="hidden"
                    name={"environment[access][#{choice.ref}]"}
                    value="read_write"
                  />
                </span>
                <span class="environment-repository-default">
                  <input
                    :if={choice.chosen}
                    type="radio"
                    id={"#{@id}-default-#{choice.ref}"}
                    name="environment[default_repository]"
                    value={choice.ref}
                    checked={choice.default}
                    aria-label={"Make #{choice.name} the default"}
                  />
                </span>
              </div>
            </div>
            <p :if={@choices == []} class="settings-help">
              No repositories are added yet.
              <.link navigate="/repositories/new">Add repositories</.link>
              first, or save without any: Ryker then works here without code.
            </p>
          </fieldset>
        </div>
        <div class="kit-form-section settings-field">
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
        <div class="kit-form-section settings-field settings-field-boolean">
          <input type="hidden" name="environment[is_default]" value="false" />
          <input
            type="checkbox"
            id={"#{@id}-default"}
            name="environment[is_default]"
            value="true"
            checked={@draft.is_default}
            aria-describedby={"#{@id}-default-help"}
          />
          <label for={"#{@id}-default"}>Default environment</label>
          <p class="settings-help" id={"#{@id}-default-help"}>
            Chat and every conversation without its own environment work here.
          </p>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
        <div class="settings-actions">
          <button type="submit" class="ui-button primary" phx-disable-with="Saving…">
            {if is_nil(@ref), do: "Add environment", else: "Save changes"}
          </button>
          <.link patch="/environments" class="ui-button secondary">Cancel</.link>
        </div>
      </form>
    </div>
    """
  end
end

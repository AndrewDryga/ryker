defmodule Responder.ControlPlane.SettingsEditor do
  @moduledoc """
  One explicit Save/Cancel editor per settings section.

  A live refresh never overwrites an unsaved draft, a rejected save keeps the
  draft and says which field was refused, and a revision that moved under the
  editor shows what is saved now instead of quietly overwriting it. Shortening
  a retention horizon takes a second step that names what would age out.
  """

  use Phoenix.LiveComponent

  alias Responder.ControlPlane.{SettingsSections, SettingsView}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    cond do
      not Map.has_key?(socket.assigns, :draft) -> {:ok, reset(socket)}
      socket.assigns.dirty -> {:ok, socket}
      socket.assigns.saved_revision == assigns.view.revision -> {:ok, socket}
      true -> {:ok, reset(socket)}
    end
  end

  @impl true
  def handle_event("edit", params, socket) do
    {:noreply, socket |> draft(params) |> assign(message: "")}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("select-item", %{"item" => key}, socket),
    do: {:noreply, reset(socket, key)}

  def handle_event("new-item", _params, socket), do: {:noreply, reset(socket, nil)}

  def handle_event("review-current", _params, socket),
    do: {:noreply, assign(socket, conflict: nil, expected_revision: socket.assigns.view.revision)}

  def handle_event("save", params, socket) do
    socket = draft(socket, params)
    {:noreply, write(socket, save_command(socket, payload(socket)))}
  end

  def handle_event("confirm", _params, socket) do
    payload = payload(socket, %{"confirmation" => socket.assigns.confirmation})
    {:noreply, write(socket, save_command(socket, payload))}
  end

  def handle_event("delete-item", %{"item" => key}, socket) do
    %{commands: commands, section: section} = socket.assigns
    result = attempt(fn -> commands.delete_item.(section.key, key, expected(socket)) end)
    {:noreply, write(socket, result, :new)}
  end

  # The row being edited travels with the values: a generated identifier is not
  # an editable field, and without it every correction would try to add a row.
  defp payload(socket, extra \\ %{}) do
    socket.assigns.draft
    |> Map.merge(extra)
    |> then(fn draft ->
      if socket.assigns.item_key,
        do: Map.put(draft, "item_key", socket.assigns.item_key),
        else: draft
    end)
  end

  defp save_command(socket, draft) do
    %{commands: commands, section: section} = socket.assigns

    attempt(fn ->
      case section.kind do
        :collection -> commands.put_item.(section.key, draft, expected(socket))
        _singleton -> commands.save.(section.key, draft, expected(socket))
      end
    end)
  end

  # A database that stops answering mid-save must not take the typed draft with
  # it, and must not look like a refusal: the operator is told the save is
  # unconfirmed and keeps every value they entered.
  defp attempt(command) do
    command.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :settings_unavailable}
  end

  defp expected(socket), do: socket.assigns.expected_revision

  # Every write lands here so that one place decides what a rejected save does
  # to the draft: it keeps it. Losing typed work to a validation error is the
  # reason operators keep settings in a file.
  defp write(socket, result, next \\ :saved)

  defp write(socket, {:ok, snapshot}, next) do
    view = SettingsView.view(snapshot)
    send(self(), {:settings_saved, view})

    socket
    |> assign(:view, view)
    |> reset(if(next == :new, do: nil, else: saved_item_key(socket)))
    |> assign(
      :message,
      "#{if next == :new, do: "Removed", else: "Saved"}. Revision #{view.revision}."
    )
  end

  defp write(socket, {:error, {:settings_conflict, current}}, _next) do
    current = SettingsView.view(current)

    assign(socket,
      view: current,
      conflict: SettingsSections.draft(socket.assigns.section, current, socket.assigns.item_key),
      errors: [],
      impact: nil,
      error:
        "These settings changed since you started editing. Your draft has not been saved; " <>
          "review what is saved now, then save again."
    )
  end

  defp write(socket, {:error, {:invalid_settings, errors}}, _next),
    do: assign(socket, errors: errors, impact: nil, error: nil, message: "")

  defp write(socket, {:error, :retention_impact_confirmation_required}, _next) do
    preview =
      attempt(fn ->
        socket.assigns.commands.preview_retention.(socket.assigns.draft, expected(socket))
      end)

    case preview do
      {:ok, preview} ->
        assign(socket,
          confirmation: preview.confirmation,
          errors: [],
          error: nil,
          impact: preview
        )

      {:error, reason} ->
        assign(socket, impact: nil, error: error(reason))
    end
  end

  defp write(socket, {:error, reason}, _next),
    do: assign(socket, errors: [], impact: nil, error: error(reason))

  defp error(:settings_not_initialized),
    do: "This installation has no settings yet. Reload the page and create them first."

  defp error(:settings_forbidden),
    do: "This console is not allowed to change settings."

  defp error(:settings_revision_changed),
    do: "The settings revision moved. Reload the page and try again."

  defp error(:settings_unavailable),
    do: "The settings database did not answer. Your draft is preserved; try again."

  defp error(_reason),
    do: "This change could not be saved. Your draft is preserved; try again."

  defp reset(socket, item_key \\ :keep) do
    %{section: section, view: view} = socket.assigns

    item_key =
      case item_key do
        :keep -> Map.get(socket.assigns, :item_key)
        key -> key
      end

    assign(socket,
      confirmation: nil,
      conflict: nil,
      dirty: false,
      draft: SettingsSections.draft(section, view, item_key),
      error: nil,
      errors: [],
      expected_revision: view.revision,
      impact: nil,
      item_key: item_key,
      message: "",
      saved_revision: view.revision
    )
  end

  # After a save the editor follows the row it just wrote rather than jumping
  # back to a blank form. A generated identifier is not in the form, so adding
  # such a row returns to a blank one.
  defp saved_item_key(%{assigns: %{section: %{kind: :collection} = section}} = socket) do
    case Map.get(socket.assigns.draft, Atom.to_string(section.item_key)) do
      value when is_binary(value) and value != "" -> value
      _generated -> socket.assigns.item_key
    end
  end

  defp saved_item_key(_socket), do: :keep

  defp draft(socket, params) do
    known = Enum.map(socket.assigns.section.fields, &SettingsSections.field_name/1)
    submitted = Map.take(params, known)

    draft = Map.new(known, fn name -> {name, Map.get(submitted, name, "")} end)

    baseline =
      SettingsSections.draft(
        socket.assigns.section,
        socket.assigns.view,
        Map.get(socket.assigns, :item_key)
      )

    assign(socket, draft: draft, dirty: draft != baseline)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="settings-section" aria-labelledby={"#{@id}-title"}>
      <div class="settings-section-head">
        <h2 id={"#{@id}-title"}>{@section.title}</h2>
        <p class="settings-description">{@section.description}</p>
        <ul :if={@section[:credentials]} class="settings-credentials">
          <li :for={credential <- credentials(@section, @view)} data-status={credential.status}>
            <code>{credential.name}</code>
            <span>{credential_status(credential.status)}</span>
          </li>
        </ul>
      </div>
      <table :if={@section.kind == :collection and items(@section, @view) != []} class="settings-rows">
        <thead>
          <tr>
            <th :for={field <- @section.fields}>{field.label}</th>
            <th :if={@section[:row_status]}>Fleet</th>
            <th><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- items(@section, @view)} data-item={item_key(@section, item)}>
            <td :for={field <- @section.fields}>
              {SettingsSections.form_value(
                field,
                Map.get(item, field.name)
              )}
            </td>
            <td
              :if={@section[:row_status]}
              class="settings-row-status"
              data-tone={row_status(@section, item, @view).tone}
            >
              {row_status(@section, item, @view).label}
            </td>
            <td class="settings-row-actions">
              <button
                type="button"
                class="ui-button secondary"
                phx-click="select-item"
                phx-value-item={item_key(@section, item)}
                phx-target={@myself}
              >Edit</button>
              <button
                type="button"
                class="ui-button danger"
                phx-click="delete-item"
                phx-value-item={item_key(@section, item)}
                phx-target={@myself}
              >Remove</button>
            </td>
          </tr>
        </tbody>
      </table>
      <form
        id={"#{@id}-form"}
        phx-change="edit"
        phx-submit="save"
        phx-target={@myself}
        data-dirty={to_string(@dirty)}
      >
        <input :if={@item_key} type="hidden" name="item_key" value={@item_key} />
        <div :for={field <- @section.fields} class="settings-field">
          <label for={input_id(@id, field)}>{field.label}</label>
          <p :if={field[:help]} class="settings-help" id={help_id(@id, field)}>{field.help}</p>
          <.control
            field={field}
            id={input_id(@id, field)}
            help={if field[:help], do: help_id(@id, field)}
            value={Map.get(@draft, SettingsSections.field_name(field), "")}
            options={options(field, @view)}
            invalid={invalid?(@errors, field)}
            locked={field[:identity] && not is_nil(@item_key)}
          />
          <p :if={invalid?(@errors, field)} class="settings-error" role="alert">
            {field.label} {reason(@errors, field)}
          </p>
        </div>
        <div :if={@impact} class="settings-impact">
          <h3>Shortening a horizon</h3>
          <p>
            These records would be older than the horizon you typed and become eligible for
            cleanup. Live waits, approvals, schedules and unpublished work keep their history
            regardless of age.
          </p>
          <ul>
            <li :for={{field, rows} <- @impact.impact}>
              <strong>{horizon_label(@section, field)}</strong>
              <span :for={row <- rows}>{row.count} {row.label}</span>
            </li>
          </ul>
          <button type="button" class="ui-button danger" phx-click="confirm" phx-target={@myself}>
            Apply these horizons
          </button>
        </div>
        <p :if={@error} class="settings-error" role="alert">{@error}</p>
        <div :if={@conflict} class="settings-conflict">
          <h3>Saved now</h3>
          <dl>
            <div :for={field <- @section.fields}>
              <dt>{field.label}</dt>
              <dd>{Map.get(@conflict, SettingsSections.field_name(field))}</dd>
            </div>
          </dl>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="review-current"
            phx-target={@myself}
          >
            Keep my draft and save over this version
          </button>
        </div>
        <div class="settings-actions">
          <button type="submit" class="ui-button primary" disabled={!@dirty or not is_nil(@conflict)}>
            {if @section.kind == :collection and is_nil(@item_key), do: "Add", else: "Save changes"}
          </button>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="cancel"
            phx-target={@myself}
            disabled={!@dirty}
          >Cancel</button>
          <button
            :if={@section.kind == :collection and @item_key}
            type="button"
            class="ui-button secondary"
            phx-click="new-item"
            phx-target={@myself}
          >New entry</button>
          <span role="status">{@message}</span>
        </div>
      </form>
    </section>
    """
  end

  attr(:field, :map, required: true)
  attr(:id, :string, required: true)
  attr(:help, :string, default: nil)
  attr(:value, :string, required: true)
  attr(:options, :list, default: [])
  attr(:invalid, :boolean, default: false)
  attr(:locked, :boolean, default: false)

  # Execution evidence, shown so an operator can compare a pin against the fleet,
  # and deliberately not an input: this value is copied from an advertisement.
  defp control(%{field: %{kind: :evidence}} = assigns) do
    ~H"""
    <output id={@id} class="settings-evidence">
      {if @value == "", do: "not pinned yet", else: @value}
    </output>
    """
  end

  defp control(%{field: %{kind: :boolean}} = assigns) do
    ~H"""
    <input type="hidden" name={SettingsSections.field_name(@field)} value="false" />
    <input
      type="checkbox"
      id={@id}
      name={SettingsSections.field_name(@field)}
      value="true"
      checked={@value == "true"}
      aria-describedby={@help}
    />
    """
  end

  defp control(%{field: %{kind: :select}} = assigns) do
    ~H"""
    <select
      id={@id}
      name={SettingsSections.field_name(@field)}
      aria-describedby={@help}
      aria-invalid={to_string(@invalid)}
    >
      <option value="">Not set</option>
      <option :for={{value, label} <- @options} value={value} selected={@value == value}>
        {label}
      </option>
    </select>
    """
  end

  defp control(%{field: %{kind: :list}} = assigns) do
    ~H"""
    <input
      type="text"
      id={@id}
      name={SettingsSections.field_name(@field)}
      value={@value}
      aria-describedby={@help}
      aria-invalid={to_string(@invalid)}
      placeholder="Comma separated"
      readonly={@locked}
    />
    """
  end

  defp control(assigns) do
    ~H"""
    <input
      type={input_type(@field.kind)}
      id={@id}
      name={SettingsSections.field_name(@field)}
      value={@value}
      inputmode={if @field.kind == :decimal, do: "decimal"}
      min={if @field.kind in [:integer, :days], do: "1"}
      step={if @field.kind in [:integer, :days], do: "1"}
      aria-describedby={@help}
      aria-invalid={to_string(@invalid)}
      placeholder={@field[:placeholder]}
      readonly={@locked}
    />
    """
  end

  defp input_type(:days), do: "number"
  defp input_type(:integer), do: "number"
  defp input_type(:date), do: "date"
  defp input_type(:time), do: "time"
  defp input_type(_kind), do: "text"

  defp input_id(id, field), do: "#{id}-#{SettingsSections.field_name(field)}"
  defp help_id(id, field), do: input_id(id, field) <> "-help"

  defp items(section, view), do: SettingsSections.items(section, view)

  defp row_status(%{row_status: {module, function}}, item, view),
    do: apply(module, function, [item, view])

  defp item_key(section, item), do: to_string(Map.get(item, section.item_key))

  defp options(field, view),
    do: if(field[:options], do: SettingsSections.options(field, view), else: [])

  defp credentials(section, view),
    do: Enum.filter(view.credentials, &(&1.name in section.credentials))

  defp credential_status(:configured), do: "configured"
  defp credential_status(:missing), do: "not supplied by this deployment"
  defp credential_status(:invalid), do: "supplied but unusable"

  defp invalid?(errors, field),
    do: Enum.any?(errors, fn {name, _reason} -> name == field.name end)

  defp reason(errors, field) do
    case Enum.find(errors, fn {name, _reason} -> name == field.name end) do
      {_name, reason} -> phrase(reason)
      nil -> ""
    end
  end

  defp phrase(:required), do: "is required."
  defp phrase(:required_to_enable), do: "is required before this can be turned on."
  defp phrase(:format), do: "is not in the expected format."
  defp phrase(:inclusion), do: "is not one of the supported values."
  defp phrase(:length), do: "is too long or too short."
  defp phrase(:number), do: "is outside the supported range."
  defp phrase(:days), do: "must be a whole number of days."
  defp phrase(:integer), do: "must be a whole number."
  defp phrase(:decimal), do: "must be a number."
  defp phrase(:date), do: "must be a date."
  defp phrase(:time), do: "must be a time."
  defp phrase(:slack_ids), do: "must be unique Slack IDs."
  defp phrase(:unknown_repository), do: "names a repository that is not configured."
  defp phrase(:unknown_context), do: "names a context that is not configured."
  defp phrase(:already_bound), do: "is already taken by another entry."
  defp phrase(:referenced), do: "is still referenced by another setting."
  defp phrase(:git_ref), do: "must be a safe Git reference."
  defp phrase(:absolute_path), do: "must be an absolute path."
  defp phrase(:timezone), do: "is not a known time zone."
  defp phrase(:github_required), do: "requires a connected GitHub App."
  defp phrase(:slack_required), do: "requires a connected Slack workspace."
  defp phrase(_reason), do: "was refused."

  defp horizon_label(section, field) do
    case Enum.find(section.fields, &(&1.name == field)) do
      nil -> to_string(field)
      %{label: label} -> label
    end
  end
end

defmodule Ryker.ControlPlane.SettingsEditor do
  @moduledoc """
  One explicit Save/Cancel editor per settings section.

  A live refresh never overwrites an unsaved draft, a rejected save keeps the
  draft and says which field was refused, and a revision that moved under the
  editor shows what is saved now instead of quietly overwriting it. Shortening
  a retention limit takes a second step that names what would age out, and
  removing a row takes a second step that says what removing it does.

  A list section reads as rows on the page (see `Kit`); a row is edited in
  place, and a new row is added below the list.
  """

  use Phoenix.LiveComponent

  alias Phoenix.LiveView.JS
  alias Ryker.BundledCoop
  alias Ryker.ControlPlane.{Components, Kit, SettingsRows, SettingsSections, SettingsView}

  @impact_words %{
    "ingress inputs" => "received messages",
    "work turns" => "model and tool steps",
    "memory entries" => "memory entries",
    "knowledge topics" => "conversation topics",
    "closed work sessions" => "finished work sessions",
    "terminal episodes" => "finished requests",
    "settings edits" => "settings changes",
    "instruction edits" => "instruction changes",
    "channel setting audit" => "channel setting changes"
  }

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.put_new(assigns, :show_header, true))

    cond do
      not Map.has_key?(socket.assigns, :draft) -> {:ok, reset(socket)}
      socket.assigns.saved_revision == assigns.view.revision -> {:ok, socket}
      socket.assigns.dirty -> {:ok, follow(socket)}
      true -> {:ok, reset(socket)}
    end
  end

  # The installation has one revision, so saving any section moves it. A draft
  # here is only stale if what *this* section holds changed underneath it;
  # otherwise the editor follows the new revision and keeps the draft, instead
  # of reporting a conflict with a version that reads exactly the same.
  defp follow(socket) do
    %{section: section, view: view} = socket.assigns

    if SettingsSections.draft(section, view, socket.assigns.item_key) == socket.assigns.baseline do
      assign(socket,
        conflict: nil,
        error: nil,
        expected_revision: view.revision,
        saved_revision: view.revision
      )
    else
      socket
    end
  end

  @impl true
  def handle_event("edit", params, socket) do
    {:noreply, socket |> draft(params) |> assign(message: "")}
  end

  def handle_event("cancel", _params, %{assigns: %{section: %{kind: :collection}}} = socket),
    do: {:noreply, reset(socket, nil)}

  def handle_event("cancel", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("select-item", %{"item" => key}, socket),
    do: {:noreply, reset(socket, key)}

  def handle_event("new-item", _params, socket),
    do: {:noreply, socket |> reset(nil) |> assign(:editor_visible, true)}

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

  def handle_event("ask-remove", %{"item" => key}, socket) when is_binary(key),
    do: {:noreply, assign(socket, removing: key, remove_error: nil, message: "")}

  def handle_event("cancel-remove", _params, socket),
    do: {:noreply, assign(socket, removing: nil, remove_error: nil)}

  # Removing takes two steps: the row's Remove asks, and only the button in
  # that question removes. A remove that arrives without the question having
  # been asked is treated as the asking, so one stray click never deletes.
  def handle_event("delete-item", %{"item" => key}, %{assigns: %{removing: key}} = socket) do
    %{commands: commands, section: section} = socket.assigns
    result = attempt(fn -> commands.delete_item.(section.key, key, expected(socket)) end)
    {:noreply, removed(socket, result)}
  end

  def handle_event("delete-item", %{"item" => key}, socket) when is_binary(key),
    do: {:noreply, assign(socket, removing: key, remove_error: nil, message: "")}

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

  defp removed(socket, {:ok, _snapshot} = result), do: write(socket, result, :new)

  # The list moved while the question was open. The row may read differently
  # now, so the question stays open against what is saved now.
  defp removed(socket, {:error, {:settings_conflict, current}}) do
    view = SettingsView.view(current)

    assign(socket,
      view: view,
      expected_revision: view.revision,
      remove_error:
        "This list changed while the question was open. Check the row, then confirm again."
    )
  end

  defp removed(socket, {:error, {:invalid_settings, errors}}) do
    message =
      if Enum.any?(errors, fn {_field, reason} -> reason == :referenced end),
        do: "Another setting still uses it. Change that setting first.",
        else: "It could not be removed. Reload the page and try again."

    assign(socket, :remove_error, message)
  end

  defp removed(socket, {:error, reason}), do: assign(socket, :remove_error, error(reason))

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
    |> assign(:message, if(next == :new, do: "Removed.", else: "Saved."))
  end

  defp write(socket, {:error, {:settings_conflict, current}}, _next) do
    current = SettingsView.view(current)

    assign(socket,
      view: current,
      conflict: current,
      errors: [],
      impact: nil,
      error:
        "These settings changed since you started editing. Your draft has not been saved; " <>
          "review what is saved now, then save again."
    )
  end

  # A refusal that names one of this form's fields is shown at that field; one
  # about the section as a whole, such as limits kept in the wrong order, is
  # shown above the Save button. Neither may be dropped.
  defp write(socket, {:error, {:invalid_settings, errors}}, _next) do
    names = Enum.map(socket.assigns.section.fields, & &1.name)
    {field_errors, section_errors} = Enum.split_with(errors, fn {name, _} -> name in names end)

    assign(socket,
      errors: field_errors,
      impact: nil,
      error: section_error(section_errors),
      message: ""
    )
  end

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

  defp section_error([]), do: nil

  defp section_error([{:retention, :ordering} | _rest]),
    do:
      "These limits are out of order. Keep each kind of data at least as long as the one " <>
        "above it, and conversation memory at least as long as prompts, replies and tool activity."

  defp section_error([{:retention, :incomplete} | _rest]),
    do: "Fill in every limit, then save again."

  defp section_error(_errors),
    do: "This change was refused. Check the values and save again."

  defp error(:settings_not_initialized),
    do: "This installation has no settings yet. Reload the page and create them first."

  defp error(:settings_forbidden),
    do: "This console is not allowed to change settings."

  defp error(:settings_revision_changed),
    do: "The settings changed in the meantime. Reload the page and try again."

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

    baseline = SettingsSections.draft(section, view, item_key)

    assign(socket,
      baseline: baseline,
      confirmation: nil,
      conflict: nil,
      dirty: false,
      draft: baseline,
      error: nil,
      errors: [],
      expected_revision: view.revision,
      impact: nil,
      item_key: item_key,
      message: "",
      removing: nil,
      remove_error: nil,
      saved_revision: view.revision,
      editor_visible: section.kind != :collection or not is_nil(item_key)
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
    draft = SettingsSections.submitted(socket.assigns.section, params)
    assign(socket, draft: draft, dirty: draft != socket.assigns.baseline)
  end

  @impl true
  def render(assigns) do
    %{section: section, view: view} = assigns
    collection? = section.kind == :collection
    rows = if collection?, do: rows(section, view), else: []
    open? = editor_open?(assigns)

    assigns =
      assign(assigns,
        collection?: collection?,
        rows: rows,
        open?: open?,
        placement: placement(collection?, open?, assigns.item_key, rows),
        notice: notice(section, view),
        noun: noun(section)
      )

    ~H"""
    <section
      id={@id}
      class={["settings-block", @collection? && "settings-collection"]}
      aria-label={@section.title}
    >
      <Kit.section_head :if={@show_header} title={@section.title} lede={@section.description}>
        <:actions :if={@collection? and !@open?}>
          <.add_button noun={@noun} myself={@myself} />
        </:actions>
      </Kit.section_head>
      <div :if={!@show_header and @collection?} class="settings-collection-bar">
        <p>{count(@rows, @noun)}</p>
        <.add_button :if={!@open?} noun={@noun} myself={@myself} />
      </div>
      <p :if={@notice} class="settings-notice">
        {@notice.text}
        <.link :if={@notice[:href]} navigate={@notice.href}>{@notice.link}</.link>
      </p>
      <Kit.entity_list :if={@rows != []} label={@section.title}>
        <Kit.entity_row
          :for={{key, row} <- @rows}
          name={row.name}
          state={row.state}
          text={row.text}
          meta={row.meta}
          class={[@item_key == key && "is-editing"]}
        >
          <:actions :if={@item_key != key}>
            <button
              type="button"
              class="ui-button secondary"
              phx-click="select-item"
              phx-value-item={key}
              phx-target={@myself}
            >Edit</button>
            <button
              type="button"
              class="ui-button quiet"
              phx-click="ask-remove"
              phx-value-item={key}
              phx-target={@myself}
            >Remove</button>
          </:actions>
          <:details>
            <p :if={row.address} class="settings-address">
              <span>Address</span>
              <code>{row.address}</code>
              <button
                type="button"
                class="copy-value"
                data-copy-value={row.address}
                aria-label={"Copy the address for #{row.name}"}
              >
                <Components.icon name={:copy} />
                <span class="sr-only" data-copy-status aria-live="polite"></span>
              </button>
            </p>
            <details :if={row.details != []} class="settings-row-details">
              <summary>Details</summary>
              <dl>
                <div :for={{label, value} <- row.details}>
                  <dt>{label}</dt>
                  <dd><code>{value}</code></dd>
                </div>
              </dl>
            </details>
            <div
              :if={@removing == key}
              class="settings-confirm"
              role="group"
              aria-label={"Remove #{row.name}?"}
              tabindex="-1"
              phx-mounted={JS.focus()}
            >
              <p>
                <strong>Remove {row.name}?</strong> {SettingsRows.removal(@section)}
              </p>
              <Components.form_feedback :if={@remove_error} message={@remove_error} tone={:error} />
              <div class="settings-confirm-actions">
                <button
                  type="button"
                  class="ui-button danger"
                  phx-click="delete-item"
                  phx-value-item={key}
                  phx-target={@myself}
                >Remove</button>
                <button
                  type="button"
                  class="ui-button secondary"
                  phx-click="cancel-remove"
                  phx-target={@myself}
                >Cancel</button>
              </div>
            </div>
            <.editor
              :if={@placement == {:row, key}}
              id={@id}
              section={@section}
              view={@view}
              draft={@draft}
              dirty={@dirty}
              errors={@errors}
              error={@error}
              impact={@impact}
              conflict={@conflict}
              item_key={@item_key}
              message={@message}
              myself={@myself}
              show_header={@show_header}
              collection?={@collection?}
              noun={@noun}
            />
          </:details>
        </Kit.entity_row>
      </Kit.entity_list>
      <Kit.empty
        :if={@collection? and @rows == [] and !@open? and @section[:empty]}
        title={elem(@section.empty, 0)}
        text={elem(@section.empty, 1)}
      />
      <.editor
        :if={@placement == :below}
        id={@id}
        section={@section}
        view={@view}
        draft={@draft}
        dirty={@dirty}
        errors={@errors}
        error={@error}
        impact={@impact}
        conflict={@conflict}
        item_key={@item_key}
        message={@message}
        myself={@myself}
        show_header={@show_header}
        collection?={@collection?}
        noun={@noun}
      />
    </section>
    """
  end

  attr(:noun, :string, required: true)
  attr(:myself, :any, required: true)

  defp add_button(assigns) do
    ~H"""
    <button
      type="button"
      class="ui-button secondary settings-editor-add"
      phx-click="new-item"
      phx-target={@myself}
    ><Components.icon name={:plus} />Add {@noun}</button>
    """
  end

  defp editor(assigns) do
    assigns = assign(assigns, :groups, groups(assigns.section, assigns.draft, assigns.view))

    ~H"""
    <div class={["settings-editor", @collection? && "settings-editor-collection"]}>
      <h3 :if={@collection?} class="settings-editor-heading">
        {if @item_key, do: "Edit #{@noun}", else: "Add #{@noun}"}
      </h3>
      <p :if={@section[:help]} class="settings-form-help">{@section.help}</p>
      <form
        id={"#{@id}-form"}
        phx-change="edit"
        phx-submit="save"
        phx-target={@myself}
        data-dirty={to_string(@dirty)}
      >
        <input :if={@item_key} type="hidden" name="item_key" value={@item_key} />
        <div
          :for={group <- @groups}
          class={[
            "settings-group",
            Enum.all?(group.fields, &(&1.kind == :decimal)) && "settings-group-row"
          ]}
        >
          <Kit.section_head
            :if={group.name && page_sections?(@show_header, @collection?)}
            title={group.name}
            id={group.id}
            lede={group.lede}
          />
          <h4
            :if={group.name && !page_sections?(@show_header, @collection?)}
            class="settings-group-title"
          >
            {group.name}
          </h4>
          <.field
            :for={field <- group.fields}
            field={field}
            id={input_id(@id, field)}
            value={Map.get(@draft, SettingsSections.field_name(field), "")}
            options={options(field, @view)}
            error={field_error(@errors, field)}
            locked={field[:identity] && not is_nil(@item_key)}
          />
        </div>
        <div :if={@impact} class="settings-impact" role="alert">
          <h3>Shorter limits delete older data</h3>
          <p>
            Records older than the new limits become eligible for cleanup. Live waits, approvals,
            schedules and unpublished work keep their history regardless of age.
          </p>
          <ul :if={impact_lines(@section, @impact) != []}>
            <li :for={{label, counts} <- impact_lines(@section, @impact)}>
              <strong>{label}</strong> <span>{counts}</span>
            </li>
          </ul>
          <p :if={impact_lines(@section, @impact) == []}>
            Nothing is old enough to be deleted yet.
          </p>
          <button type="button" class="ui-button danger" phx-click="confirm" phx-target={@myself}>
            Apply shorter limits
          </button>
        </div>
        <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
        <div :if={@conflict} class="settings-conflict">
          <h3>Saved now</h3>
          <dl>
            <div :for={field <- @section.fields}>
              <dt>{field.label}</dt>
              <dd>{saved_value(@section, @conflict, @item_key, field)}</dd>
            </div>
          </dl>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="review-current"
            phx-target={@myself}
          >Keep my changes and save over this</button>
        </div>
        <div class="settings-actions">
          <button
            type="submit"
            class="ui-button primary"
            disabled={!@dirty or not is_nil(@conflict)}
          >{if @collection? and is_nil(@item_key), do: "Add #{@noun}", else: "Save changes"}</button>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="cancel"
            phx-target={@myself}
            disabled={!@dirty and !@collection?}
          >Cancel</button>
          <span role="status" class="settings-saved">{@message}</span>
        </div>
      </form>
    </div>
    """
  end

  attr(:field, :map, required: true)
  attr(:id, :string, required: true)
  attr(:value, :any, required: true)
  attr(:options, :list, default: [])
  attr(:error, :string, default: nil)
  attr(:locked, :boolean, default: false)

  # An optional composite stays folded until someone needs it.
  defp field(%{field: %{kind: :lifecycle}} = assigns) do
    ~H"""
    <details class="settings-optional-field" open={not is_nil(@error)}>
      <summary>{@field.label} <span>Optional</span></summary>
      <div class="settings-field">
        <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
        <.control field={@field} id={@id} value={@value} help={help_id(@id, @field)} />
        <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
      </div>
    </details>
    """
  end

  # A choice between a few behaviours reads best as the behaviours themselves.
  defp field(%{field: %{kind: :choice}} = assigns) do
    ~H"""
    <fieldset
      class="settings-field settings-choice"
      id={@id}
      aria-describedby={help_id(@id, @field)}
    >
      <legend>{@field.label}</legend>
      <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
      <label :for={{value, label, description} <- @options} class="settings-option">
        <input
          type="radio"
          name={SettingsSections.field_name(@field)}
          value={value}
          checked={@value == value}
        />
        <span><strong>{label}</strong><small>{description}</small></span>
      </label>
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
    </fieldset>
    """
  end

  # Several named paths under one heading: a legend, never a label that
  # points at no single input.
  defp field(%{field: %{kind: :mapping}} = assigns) do
    ~H"""
    <fieldset class="settings-field settings-field-wide" id={@id}>
      <legend>{@field.label}</legend>
      <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
      <.control field={@field} id={@id} value={@value} help={help_id(@id, @field)} />
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
    </fieldset>
    """
  end

  defp field(%{field: %{kind: :boolean}} = assigns) do
    ~H"""
    <div class="settings-field settings-field-boolean">
      <input type="hidden" name={SettingsSections.field_name(@field)} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={SettingsSections.field_name(@field)}
        value="true"
        checked={@value == "true"}
        aria-describedby={help_id(@id, @field)}
      />
      <label for={@id}>{@field.label}</label>
      <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
    </div>
    """
  end

  defp field(assigns) do
    ~H"""
    <div class="settings-field">
      <label for={@id}>{@field.label}</label>
      <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
      <.control
        field={@field}
        id={@id}
        value={@value}
        help={help_id(@id, @field)}
        options={@options}
        invalid={not is_nil(@error)}
        locked={@locked}
      />
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
    </div>
    """
  end

  attr(:field, :map, required: true)
  attr(:id, :string, required: true)
  attr(:help, :string, default: nil)
  attr(:value, :any, required: true)
  attr(:options, :list, default: [])
  attr(:invalid, :boolean, default: false)
  attr(:locked, :boolean, default: false)

  # A mapping and a lifecycle filter are several bounded fields, not free text:
  # the operator names paths and values, and nothing else can be expressed.
  defp control(%{field: %{kind: kind}} = assigns) when kind in [:mapping, :lifecycle] do
    ~H"""
    <div class="settings-composite">
      <div :for={subfield <- SettingsSections.subfields(@field)}>
        <label for={"#{@id}-#{subfield}"}>{SettingsSections.subfield_label(subfield)}</label>
        <input
          type="text"
          id={"#{@id}-#{subfield}"}
          name={"#{SettingsSections.field_name(@field)}[#{subfield}]"}
          value={Map.get(@value, subfield, "")}
          aria-describedby={@help}
          placeholder={if @field.kind == :lifecycle, do: "Comma separated"}
        />
      </div>
    </div>
    """
  end

  # Execution evidence, shown so an operator can compare a pin against the fleet,
  # and deliberately not an input: this value is copied from an advertisement.
  defp control(%{field: %{kind: :evidence}} = assigns) do
    ~H"""
    <output id={@id} class="settings-evidence">
      {if @value == "", do: "Copied from the worker when you save", else: @value}
    </output>
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
      <option :if={!@field[:required]} value="">Not set</option>
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

  defp control(%{field: %{kind: :days}} = assigns) do
    ~H"""
    <span class="settings-days">
      <span>Kept for</span>
      <input
        type="number"
        id={@id}
        name={SettingsSections.field_name(@field)}
        value={@value}
        inputmode="numeric"
        min="1"
        step="1"
        aria-describedby={@help}
        aria-invalid={to_string(@invalid)}
      />
      <span>days</span>
    </span>
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
      min={if @field.kind == :integer, do: "1"}
      step={if @field.kind == :integer, do: "1"}
      aria-describedby={@help}
      aria-invalid={to_string(@invalid)}
      placeholder={@field[:placeholder]}
      readonly={@locked}
    />
    """
  end

  defp input_type(:integer), do: "number"
  defp input_type(:date), do: "date"
  defp input_type(:time), do: "time"
  defp input_type(_kind), do: "text"

  defp input_id(id, field), do: "#{id}-#{SettingsSections.field_name(field)}"
  defp help_id(id, %{help: _help}), do: "#{id}-help"
  defp help_id(_id, _field), do: nil

  # A singleton form that stands alone on its page shows its groups as the
  # page's sections; inside a titled section or a list row they are small
  # group titles.
  defp page_sections?(show_header, collection?), do: not show_header and not collection?

  defp editor_open?(assigns) do
    assigns.editor_visible or not is_nil(assigns.item_key) or assigns.dirty or
      assigns.errors != [] or
      not is_nil(assigns.error) or not is_nil(assigns.conflict) or not is_nil(assigns.impact)
  end

  # A row is edited where it is listed. A new row, or one that disappeared
  # while it was open, is edited below the list.
  defp placement(false, _open?, _item_key, _rows), do: :below
  defp placement(true, false, _item_key, _rows), do: nil

  defp placement(true, true, item_key, rows) do
    if item_key && List.keymember?(rows, item_key, 0), do: {:row, item_key}, else: :below
  end

  defp rows(section, view) do
    for item <- SettingsSections.items(section, view),
        do: {item_key(section, item), SettingsRows.present(section, item, view)}
  end

  defp groups(section, draft, view) do
    section
    |> SettingsSections.field_groups()
    |> Enum.map(fn {group, fields} ->
      details = SettingsSections.group_details(section, group)

      %{
        name: group,
        id: details[:id],
        lede: details[:lede],
        fields:
          for(field <- fields, field_visible?(field, draft), do: with_help(section, field, view))
      }
    end)
    |> Enum.reject(&(&1.fields == []))
  end

  # A source's name is the end of the address its sender posts to, so the
  # form says that address while the name is being chosen.
  defp with_help(%{key: :webhooks}, %{name: :name} = field, view) do
    address = SettingsRows.webhook_address(view, "<source name>")
    Map.put(field, :help, "Senders post to #{address}. The name cannot change later.")
  end

  defp with_help(_section, field, _view), do: field

  defp field_visible?(%{kind: :mapping}, draft),
    do: Map.get(draft, "adapter_kind") == "mapped_json"

  defp field_visible?(_field, _draft), do: true

  defp noun(section), do: Map.get(section, :item_label, collection_item_label(section.key))

  defp collection_item_label(:repositories), do: "repository"
  defp collection_item_label(:github_bindings), do: "GitHub repository binding"
  defp collection_item_label(_key), do: "entry"

  defp count([_one], noun), do: "1 #{noun}"
  defp count(rows, noun), do: "#{length(rows)} #{plural(noun)}"

  defp plural(noun) do
    cond do
      String.ends_with?(noun, ~w(ay ey oy uy)) -> noun <> "s"
      String.ends_with?(noun, "y") -> String.slice(noun, 0..-2//1) <> "ies"
      true -> noun <> "s"
    end
  end

  defp notice(%{key: :webhooks}, %{webhook_secret_names: []}),
    do: %{text: "Create a signing credential above before adding a webhook source."}

  defp notice(%{key: :model} = section, view) do
    unpriced =
      for field <- section.fields,
          not SettingsSections.priced?(Map.fetch!(view.snapshot.work, field.name), view),
          do: field.label

    cond do
      not BundledCoop.distribution?() ->
        %{
          text:
            "This installation runs on separately managed workers. " <>
              "Their own policies choose their models, so these settings are not used."
        }

      unpriced != [] ->
        %{
          text:
            "No price covers the model for #{Enum.join(unpriced, ", ")}, " <>
              "so its cost will show as not priced.",
          link: "Add a price",
          href: "/settings/prices"
        }

      true ->
        nil
    end
  end

  defp notice(_section, _view), do: nil

  defp impact_lines(section, %{impact: impact}) do
    for {field, rows} <- impact,
        Enum.any?(rows, &(&1.count > 0)),
        do:
          {horizon_label(section, field),
           rows
           |> Enum.filter(&(&1.count > 0))
           |> Enum.map_join(" · ", &"#{&1.count} #{Map.get(@impact_words, &1.label, &1.label)}")}
  end

  # What the other writer saved, rendered the same way the rows are: a mapping
  # is "4 fields mapped", not a raw map the template cannot print.
  defp saved_value(%{kind: :collection} = section, view, item_key, field) do
    case SettingsSections.current_item(section, view, item_key) do
      nil -> "not saved"
      item -> SettingsSections.row_value(field, Map.get(item, field.name))
    end
  end

  defp saved_value(section, view, _item_key, field),
    do:
      SettingsSections.row_value(
        field,
        Map.get(Map.fetch!(view.snapshot, section.domain), field.name)
      )

  defp item_key(section, item), do: to_string(Map.get(item, section.item_key))

  defp options(field, view),
    do: if(field[:options], do: SettingsSections.options(field, view), else: [])

  defp field_error(errors, field) do
    case Enum.find(errors, fn {name, _reason} -> name == field.name end) do
      {_name, reason} -> "#{field.label} #{phrase(reason)}"
      nil -> nil
    end
  end

  defp phrase(:required), do: "is required."
  defp phrase(:required_to_enable), do: "is required before this can be turned on."
  defp phrase(:format), do: "is not in the expected format."
  defp phrase(:inclusion), do: "is not one of the supported values."
  defp phrase(:length), do: "is too long or too short."
  defp phrase(:number), do: "is outside the supported range."
  defp phrase(:days), do: "must be a whole number of days."

  defp phrase(:bounds),
    do: "must be between 1 and #{format_days(SettingsSections.longest_days())} days."

  defp phrase(:integer), do: "must be a whole number."
  defp phrase(:decimal), do: "must be a number."
  defp phrase(:date), do: "must be a date."
  defp phrase(:time), do: "must be a time."
  defp phrase(:list), do: "must list different values."
  defp phrase(:slack_ids), do: "must be unique Slack IDs."
  defp phrase(:unknown_repository), do: "names a repository that is not configured."
  defp phrase(:unknown_environment), do: "names an environment that is not configured."
  defp phrase(:unknown_connection), do: "is not a connected account."
  defp phrase(:already_bound), do: "is already taken by another entry."
  defp phrase(:referenced), do: "is still used by another setting."
  defp phrase(:git_ref), do: "must be a safe Git reference."
  defp phrase(:absolute_path), do: "must be an absolute path."
  defp phrase(:timezone), do: "is not a known time zone."
  defp phrase(:github_required), do: "needs a connected GitHub App."
  defp phrase(:slack_required), do: "needs a connected Slack workspace."
  defp phrase(:unregistered_secret), do: "is not a signing credential Ryker has."
  defp phrase(:policy_unavailable), do: "is not offered by any connected worker."
  defp phrase(:policy_ambiguous), do: "is offered in different versions by different workers."
  defp phrase(:mapping_required), do: "needs paths for the event ID, status and title."
  defp phrase(:mapping_fields), do: "names a field Ryker does not know."
  defp phrase(:mapping_values), do: "has a path that is empty or too long."
  defp phrase(:mapping_unsupported), do: "is only used with the custom JSON shape."

  defp phrase(:lifecycle),
    do:
      "needs at least one value for each filter, known repositories, " <>
        "and the kinds deployment or terraform."

  defp phrase(_reason), do: "was refused."

  defp format_days(days) when days >= 1_000,
    do: "#{div(days, 1_000)},#{String.pad_leading(Integer.to_string(rem(days, 1_000)), 3, "0")}"

  defp format_days(days), do: Integer.to_string(days)

  defp horizon_label(section, field) do
    case Enum.find(section.fields, &(&1.name == field)) do
      nil -> to_string(field)
      %{label: label} -> label
    end
  end
end

defmodule Ryker.ControlPlane.SettingsEditor do
  @moduledoc """
  One explicit Save/Cancel editor per settings section, except a section that
  is one choice, such as what new channels do: it saves as it changes and
  says so with `Kit.saved/1` beside it (Andrew, 2026-09-27: "you can save on
  change no need to add button").

  A live refresh never overwrites an unsaved draft, a rejected save keeps the
  draft and says which field was refused, and a revision that moved under the
  editor shows what is saved now instead of quietly overwriting it. Shortening
  a retention limit asks first, over the page, and names what would age out;
  removing a row asks first the same way and says what removing it does.

  Each section is a Kit section card (see `Kit.section_card/1`): a live
  component's root must be a plain tag, so its root section carries the
  card and its first child is the card's head. A page whose only part is the
  section, such as Data retention or Model prices, shows the card without a
  title, under the page's own. A section that is part of another card, or a
  row's form on a page of its own, draws no card (`frame: :none`).

  A list section (`kind: :collection`) is a list: the whole of a row opens
  that row's page, its form, and Add opens the form for a new row the same
  way (`paths`). On its own page the editor is the row's form in its card
  (`form: {:form, key}`, key nil for a new row), then, for a saved row,
  removing it (`Kit.remove_card/1`), which asks first in
  `Kit.confirm_modal/1`. A save or a removal returns to the list and says
  what it did there.
  """

  use Phoenix.LiveComponent

  alias Ryker.ControlPlane.{
    Components,
    Integrations,
    Kit,
    SettingsRows,
    SettingsSections,
    SettingsView
  }

  alias Ryker.Settings.Work
  alias Ryker.Slack.Names
  alias Ryker.Work.ExecutionTarget

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
    # The list and a row's form are one component on two pages: moving from
    # one to the other starts again from what is saved.
    shown = Map.get(socket.assigns, :form, :none)

    socket =
      assign(
        socket,
        assigns
        |> Map.put_new(:show_header, true)
        |> Map.put_new(:frame, :card)
        |> Map.put_new(:form, nil)
        |> Map.put_new(:paths, nil)
      )

    cond do
      not Map.has_key?(socket.assigns, :draft) -> {:ok, reset(socket, form_key(socket))}
      shown != socket.assigns.form -> {:ok, reset(socket, form_key(socket))}
      socket.assigns.saved_revision == assigns.view.revision -> {:ok, socket}
      socket.assigns.dirty -> {:ok, follow(socket)}
      true -> {:ok, reset(socket)}
    end
  end

  # The row a form on its own page edits, nil for a new one; a list edits none.
  defp form_key(%{assigns: %{form: {:form, key}}}), do: key
  defp form_key(_socket), do: nil

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

  def handle_event("cancel", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("review-current", _params, socket),
    do: {:noreply, assign(socket, conflict: nil, expected_revision: socket.assigns.view.revision)}

  def handle_event("save", params, socket) do
    socket = draft(socket, params)
    {:noreply, write(socket, save_command(socket, payload(socket)))}
  end

  # Cancelling the shorter limits' question keeps the draft, so a limit can
  # be changed before saving again.
  def handle_event("cancel-impact", _params, socket),
    do: {:noreply, assign(socket, impact: nil, confirmation: nil)}

  def handle_event("confirm", _params, socket) do
    payload = payload(socket, %{"confirmation" => socket.assigns.confirmation})
    {:noreply, write(socket, save_command(socket, payload))}
  end

  # Adding, removing and moving a model on a kind of work's list changes only
  # the draft; nothing is saved until Save changes, as with every other edit.
  def handle_event("ladder", %{"field" => name, "action" => action} = params, socket) do
    %{section: section, draft: draft} = socket.assigns

    if Enum.any?(
         section.fields,
         &(&1.kind == :ladder and SettingsSections.field_name(&1) == name)
       ) do
      entries =
        draft
        |> Map.get(name, [])
        |> SettingsSections.ladder_step(action, position(params["index"]), socket.assigns.view)

      draft = Map.put(draft, name, entries)

      {:noreply,
       assign(socket, draft: draft, dirty: draft != socket.assigns.baseline, message: "")}
    else
      {:noreply, socket}
    end
  end

  # Adding and removing an account row changes only the draft too. An
  # account a saved model still runs on is not removed: its row stays and
  # says which models run on it.
  def handle_event("accounts", %{"field" => name, "action" => action} = params, socket) do
    %{section: section, draft: draft, view: view} = socket.assigns
    index = position(params["index"])

    if Enum.any?(
         section.fields,
         &(&1.kind == :accounts and SettingsSections.field_name(&1) == name)
       ) do
      case SettingsSections.account_step(Map.get(draft, name, []), action, index, view) do
        {:ok, entries} ->
          draft = Map.put(draft, name, entries)

          {:noreply,
           assign(socket,
             draft: draft,
             dirty: draft != socket.assigns.baseline,
             message: "",
             refusal: nil
           )}

        {:refused, sentence} ->
          {:noreply, assign(socket, message: "", refusal: {name, index, sentence})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss-refusal", _params, socket),
    do: {:noreply, assign(socket, :refusal, nil)}

  def handle_event("ask-remove", %{"item" => key}, socket) when is_binary(key),
    do: {:noreply, assign(socket, removing: key, remove_error: nil, message: "")}

  def handle_event("cancel-remove", _params, socket),
    do: {:noreply, assign(socket, removing: nil, remove_error: nil)}

  # Removing takes two steps: the page's Remove asks, and only the button in
  # that question removes. A remove that arrives without the question having
  # been asked is treated as the asking, so one stray click never deletes.
  def handle_event("delete-item", %{"item" => key}, %{assigns: %{removing: key}} = socket) do
    %{commands: commands, section: section, view: view} = socket.assigns
    name = row_name(section, view, key)
    result = attempt(fn -> commands.delete_item.(section.key, key, expected(socket)) end)
    {:noreply, removed(socket, result, name)}
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

  defp position(value) when is_binary(value) do
    case Integer.parse(value) do
      {position, ""} -> position
      _not_a_position -> nil
    end
  end

  defp position(_absent), do: nil

  # A removed row's page is gone, so the removal returns to the list, which
  # says what was removed, as a save does.
  defp removed(socket, {:ok, snapshot}, name) do
    view = SettingsView.view(snapshot)
    send(self(), {:settings_item_saved, view, socket.assigns.paths.list, "#{name} was removed."})
    assign(socket, view: view, removing: nil)
  end

  # The list moved while the question was open. The row may read differently
  # now, so the question stays open against what is saved now.
  defp removed(socket, {:error, {:settings_conflict, current}}, _name) do
    view = SettingsView.view(current)

    assign(socket,
      view: view,
      expected_revision: view.revision,
      remove_error:
        "This list changed while the question was open. Check the row, then confirm again."
    )
  end

  defp removed(socket, {:error, {:invalid_settings, errors}}, _name) do
    message =
      if Enum.any?(errors, fn {_field, reason} -> reason == :referenced end),
        do: "Another setting still uses it. Change that setting first.",
        else: "It could not be removed. Reload the page and try again."

    assign(socket, :remove_error, message)
  end

  defp removed(socket, {:error, reason}, _name), do: assign(socket, :remove_error, error(reason))

  # Every write lands here so that one place decides what a rejected save does
  # to the draft: it keeps it. Losing typed work to a validation error is the
  # reason operators keep settings in a file.
  #
  # A row's form on its own page returns to the list, which says what was
  # saved; a section that is one form stays where it is and says Saved.
  defp write(socket, {:ok, snapshot}) do
    view = SettingsView.view(snapshot)

    case socket.assigns.form do
      {:form, key} ->
        %{section: section, paths: paths} = socket.assigns
        # A new row is added and an existing one saved, whether or not the
        # list can name it.
        added = key || saved_item_key(socket) || added_key(section, socket.assigns.view, view)

        message =
          case {key, row_name(section, view, added)} do
            {nil, nil} -> "The #{noun(section)} was added."
            {nil, name} -> "#{name} was added."
            {_key, nil} -> "The #{noun(section)} was saved."
            {_key, name} -> "#{name} was saved."
          end

        send(self(), {:settings_item_saved, view, paths.list, message})
        assign(socket, view: view, dirty: false)

      nil ->
        send(self(), {:settings_editor_saved, view})

        socket
        |> assign(:view, view)
        |> reset()
        |> assign(message: "Saved.", saved_key: System.unique_integer([:positive]))
    end
  end

  defp write(socket, {:error, {:settings_conflict, current}}) do
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
  defp write(socket, {:error, {:invalid_settings, errors}}) do
    names = Enum.map(socket.assigns.section.fields, & &1.name)
    {field_errors, section_errors} = Enum.split_with(errors, fn {name, _} -> name in names end)

    assign(socket,
      errors: field_errors,
      impact: nil,
      error: section_error(section_errors),
      message: ""
    )
  end

  defp write(socket, {:error, :retention_impact_confirmation_required}) do
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

  defp write(socket, {:error, reason}),
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
      refusal: nil,
      removing: nil,
      remove_error: nil,
      saved_revision: view.revision
    )
  end

  # The row a form just saved: the one it edited, or a new one by the key its
  # form names. A generated identifier is not in the form, so a new row with
  # one is not found and the page says what kind of row was added instead.
  defp saved_item_key(%{assigns: %{section: section, draft: draft, item_key: item_key}}) do
    case Map.get(draft, Atom.to_string(section.item_key)) do
      value when is_binary(value) and value != "" -> value
      _generated -> item_key
    end
  end

  # A new row whose key Ryker generates, such as a price, is the one row the
  # save added: "The price was added." named nothing while its removal named
  # the model.
  defp added_key(section, before, view) do
    known = MapSet.new(SettingsSections.items(section, before), &item_key(section, &1))

    Enum.find_value(SettingsSections.items(section, view), fn item ->
      key = item_key(section, item)
      if not MapSet.member?(known, key), do: key
    end)
  end

  # A section that is one choice saves as it changes; every other section
  # keeps its draft until Save changes.
  defp autosave?(%{kind: :singleton, fields: [%{kind: kind}]})
       when kind in [:choice, :boolean, :select],
       do: true

  defp autosave?(_section), do: false

  defp draft(socket, params) do
    draft = SettingsSections.submitted(socket.assigns.section, params)
    assign(socket, draft: draft, dirty: draft != socket.assigns.baseline, refusal: nil)
  end

  @impl true
  def render(%{form: {:form, _key}} = assigns) do
    %{section: section, view: view, item_key: key} = assigns

    item =
      key && Enum.find(SettingsSections.items(section, view), &(item_key(section, &1) == key))

    row = item && SettingsRows.present(section, item, view)

    assigns =
      assign(assigns,
        collection?: true,
        notices: notices(section, view),
        noun: noun(section),
        row: row
      )

    ~H"""
    <div id={@id} class="settings-block settings-form-block">
      <Kit.form_card label={@label}>
        <p :for={notice <- @notices} class="settings-notice">
          {notice.text}
          <.link :if={notice[:href]} navigate={notice.href}>{notice.link}</.link>
        </p>
        <p :if={@row && @row.address} class="settings-address">
          <span>Address</span>
          <code>{@row.address}</code>
          <button
            type="button"
            class="copy-value"
            data-copy-value={@row.address}
            aria-label={"Copy the address for #{@row.name}"}
          >
            <Components.icon name={:copy} />
            <span class="sr-only" data-copy-status aria-live="polite"></span>
          </button>
        </p>
        <.editor
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
          saved_key={nil}
          autosave={false}
          myself={@myself}
          collection?={true}
          refusal={@refusal}
          noun={@noun}
          cancel={@paths.list}
        />
      </Kit.form_card>
      <Kit.remove_card
        :if={@row}
        id={"#{@id}-remove-card"}
        title={"Remove #{@noun}"}
        text={SettingsRows.removal(@section)}
        phx-click="ask-remove"
        phx-value-item={@item_key}
        phx-target={@myself}
      />
      <Kit.confirm_modal
        :if={@row && @removing == @item_key}
        id={"#{@id}-remove"}
        title={"Remove #{@row.name}?"}
        text={SettingsRows.removal(@section)}
        label={"Remove #{@noun}"}
        error={@remove_error}
        cancel="cancel-remove"
        target={@myself}
        phx-click="delete-item"
        phx-value-item={@item_key}
        phx-target={@myself}
      />
    </div>
    """
  end

  # A list that is its page's only part, such as Model prices, reads as every
  # list page does: how many it holds above it, then its rows in the page's
  # card, with Add in the page's header (Andrew, 2026-09-28: "Prices table
  # isn't the standard layout").
  def render(%{section: %{kind: :collection}, show_header: false} = assigns) do
    %{section: section, view: view} = assigns
    rows = rows(section, view)
    noun = noun(section)

    assigns =
      assign(assigns,
        rows: rows,
        noun: noun,
        notices: notices(section, view),
        total: Kit.list_total(length(rows), {noun, plural(noun)}, false)
      )

    ~H"""
    <div id={@id} class="settings-block settings-collection settings-list-page">
      <Kit.counts label={@section.title} items={[@total]} />
      <Kit.section_card label={@section.title}>
        <p :for={notice <- @notices} class="settings-notice">
          {notice.text}
          <.link :if={notice[:href]} navigate={notice.href}>{notice.link}</.link>
        </p>
        <.rows_list id={@id} rows={@rows} paths={@paths} label={@section.title} />
        <Kit.empty
          :if={@rows == [] and @section[:empty]}
          variant={:hint}
          icon={elem(@section.empty, 0)}
          title={elem(@section.empty, 1)}
          text={elem(@section.empty, 2)}
        >
          <.add_link noun={@noun} paths={@paths} primary={true} />
        </Kit.empty>
      </Kit.section_card>
    </div>
    """
  end

  def render(assigns) do
    %{section: section, view: view} = assigns
    collection? = section.kind == :collection

    assigns =
      assign(assigns,
        collection?: collection?,
        rows: if(collection?, do: rows(section, view), else: []),
        notices: notices(section, view),
        noun: noun(section),
        autosave: autosave?(section),
        saved_key: Map.get(assigns, :saved_key)
      )

    ~H"""
    <section
      id={@id}
      class={[
        @frame == :card && "kit-card",
        "settings-block",
        @collection? && "settings-collection"
      ]}
      aria-label={@section.title}
    >
      <Kit.section_head
        :if={@show_header}
        id={@section[:anchor]}
        title={@section.title}
        lede={@section.description}
      >
        <:actions :if={@collection?}>
          <.add_link noun={@noun} paths={@paths} />
        </:actions>
      </Kit.section_head>
      <p :for={notice <- @notices} class="settings-notice">
        {notice.text}
        <.link :if={notice[:href]} navigate={notice.href}>{notice.link}</.link>
      </p>
      <.editor
        :if={!@collection?}
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
        saved_key={@saved_key}
        autosave={@autosave}
        myself={@myself}
        collection?={false}
        refusal={@refusal}
        noun={@noun}
        cancel={nil}
      />
      <.rows_list :if={@collection?} id={@id} rows={@rows} paths={@paths} label={@section.title} />
      <Kit.empty
        :if={@collection? and @rows == [] and @section[:empty]}
        variant={if @frame == :card, do: :hint, else: :boxed}
        icon={elem(@section.empty, 0)}
        title={elem(@section.empty, 1)}
        text={elem(@section.empty, 2)}
      />
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:paths, :map, required: true)
  attr(:label, :string, required: true)

  # Each saved row opens its own page, its form, from anywhere on the row.
  defp rows_list(assigns) do
    ~H"""
    <Kit.entity_list :if={@rows != []} label={@label}>
      <Kit.entity_row
        :for={{key, row} <- @rows}
        id={"#{@id}-row-#{row_id(key)}"}
        icon={row.icon}
        name={row.name}
        href={edit_path(@paths, key)}
        navigate={true}
        link_row={true}
        state={row.state}
        text={row.text}
        meta={row.meta}
      />
    </Kit.entity_list>
    """
  end

  attr(:noun, :string, required: true)
  attr(:paths, :map, required: true, doc: "Where the list and its rows' forms are")
  attr(:primary, :boolean, default: false, doc: "The one action of an empty list")

  # Add opens the form for a new row on its own page.
  defp add_link(assigns) do
    ~H"""
    <.link
      patch={@paths.items <> "/new"}
      class={["ui-button settings-editor-add", if(@primary, do: "primary", else: "secondary")]}
    ><Components.icon name={:plus} />Add {@noun}</.link>
    """
  end

  @doc "Where a list section's row is edited, on its own page."
  @spec edit_path(%{items: String.t()}, String.t()) :: String.t()
  def edit_path(%{items: items}, key),
    do: items <> "/" <> URI.encode(key, &URI.char_unreserved?/1) <> "/edit"

  # A row's element id from its key, which may hold characters an id cannot.
  defp row_id(key), do: Base.url_encode64(key, padding: false)

  # `cancel` is the list a row's form returns to on Cancel, nil for a section
  # that is one form, whose Cancel puts the saved values back.
  defp editor(assigns) do
    assigns = assign(assigns, :groups, groups(assigns.section, assigns.draft, assigns.view))

    ~H"""
    <div class={["settings-editor", @collection? && "settings-editor-collection"]}>
      <p :if={@section[:help]} class="settings-form-help">{@section.help}</p>
      <form
        id={"#{@id}-form"}
        phx-change={if @autosave, do: "save", else: "edit"}
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
          <h4 :if={group.name} class="settings-group-title">{group.name}</h4>
          <.field
            :for={field <- group.fields}
            field={field}
            id={input_id(@id, field)}
            value={Map.get(@draft, SettingsSections.field_name(field), "")}
            options={options(field, @view)}
            error={field_error(@errors, field, @draft, @view)}
            locked={field[:identity] && not is_nil(@item_key)}
            view={@view}
            myself={@myself}
            refusal={@refusal}
          />
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
        <Kit.saved :if={@autosave} id={"#{@id}-saved"} key={@saved_key} />
        <div :if={!@autosave} class="settings-actions">
          <button
            type="submit"
            class="ui-button primary"
            disabled={!@dirty or not is_nil(@conflict)}
            phx-disable-with="Saving…"
          >{if @collection? and is_nil(@item_key), do: "Add #{@noun}", else: "Save changes"}</button>
          <.link :if={@cancel} patch={@cancel} class="ui-button secondary">Cancel</.link>
          <button
            :if={!@cancel}
            type="button"
            class="ui-button secondary"
            phx-click="cancel"
            phx-target={@myself}
            disabled={!@dirty}
          >Cancel</button>
          <span role="status" class="settings-saved">{@message}</span>
        </div>
      </form>
      <%!-- Shortening a limit deletes older data, so it asks over the page,
      with how much each shorter limit would delete (Andrew, 2026-09-27:
      removal confirmations are modals). Cancel keeps the draft. --%>
      <Kit.confirm_modal
        :if={@impact}
        id={"#{@id}-impact"}
        title={impact_question(@impact).title}
        text={impact_question(@impact).text}
        label={impact_question(@impact).label}
        cancel="cancel-impact"
        target={@myself}
        phx-click="confirm"
        phx-target={@myself}
      >
        <ul :if={impact_lines(@section, @impact) != []}>
          <li :for={{label, counts} <- impact_lines(@section, @impact)}>
            <strong>{label}</strong> <span>{counts}</span>
          </li>
        </ul>
        <p :if={impact_lines(@section, @impact) == []}>Nothing is old enough to be deleted yet.</p>
      </Kit.confirm_modal>
    </div>
    """
  end

  attr(:field, :map, required: true)
  attr(:id, :string, required: true)
  attr(:value, :any, required: true)
  attr(:options, :list, default: [])
  attr(:error, :string, default: nil)
  attr(:locked, :boolean, default: false)

  attr(:view, :map,
    default: nil,
    doc: "The settings view, for a control that lists what is saved"
  )

  attr(:myself, :any, default: nil, doc: "This editor, for a control's own buttons")

  attr(:refusal, :any,
    default: nil,
    doc: "{field, row, sentence} for a list row whose removal was just refused"
  )

  # A kind of work's models, in the order Coop tries them. Its help, under its
  # title, says where Ryker uses them. Each model is one numbered row of a
  # bordered list under the column names the rows share, with its move and
  # remove buttons at its end, and Add fallback lands a row under the last
  # (Andrew, 2026-09-27: "no need to say "First choice" and "Fallback 1" just
  # design properly so we see where items start and finish"). The buttons
  # change only the draft; the account choice lists the accounts of the chosen
  # model's provider, and says so when there is none yet.
  defp field(%{field: %{kind: :ladder}} = assigns) do
    %{field: field, value: entries, view: view} = assigns
    saved = Map.get(view.snapshot.work, field.name) || []
    models = SettingsSections.ladder_models(view, saved, entries)
    efforts = SettingsSections.ladder_efforts()

    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        accounts = SettingsSections.ladder_accounts(view, entry["model"])

        %{
          index: index,
          entry: entry,
          accounts: accounts,
          model_prompt: not offered?(models, entry["model"]),
          effort_prompt: not List.keymember?(efforts, entry["effort"], 0),
          account_prompt: account_prompt(entry, accounts)
        }
      end)

    assigns =
      assign(assigns,
        name: SettingsSections.field_name(field),
        models: models,
        efforts: efforts,
        rows: rows,
        count: length(entries),
        most: Work.most_models()
      )

    ~H"""
    <fieldset class="settings-field settings-ladder" id={@id} aria-describedby={help_id(@id, @field)}>
      <legend>{@field.label}</legend>
      <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
      <div class="settings-ladder-box">
        <%!-- The column names, once for every row; each choice also keeps
        its own label, shown where the row stacks on a narrow screen. --%>
        <div class="settings-ladder-columns" aria-hidden="true">
          <span>Model</span><span>Reasoning effort</span><span>Account</span>
        </div>
        <ol class="settings-ladder-list">
          <li :for={row <- @rows} id={"#{@id}-#{row.index}"} class="settings-ladder-entry">
            <span class="settings-ladder-order" aria-hidden="true">{row.index + 1}</span>
            <div class="settings-ladder-part">
              <label for={"#{@id}-#{row.index}-model"}>Model</label>
              <select
                id={"#{@id}-#{row.index}-model"}
                name={"#{@name}[#{row.index}][model]"}
                aria-invalid={to_string(not is_nil(@error))}
              >
                <option :if={row.model_prompt} value="" selected>Choose a model</option>
                <optgroup :for={{provider, options} <- @models} label={provider}>
                  <option
                    :for={{value, label} <- options}
                    value={value}
                    selected={row.entry["model"] == value}
                  >
                    {label}
                  </option>
                </optgroup>
              </select>
            </div>
            <div class="settings-ladder-part">
              <label for={"#{@id}-#{row.index}-effort"}>Reasoning effort</label>
              <select
                id={"#{@id}-#{row.index}-effort"}
                name={"#{@name}[#{row.index}][effort]"}
                aria-invalid={to_string(not is_nil(@error))}
              >
                <option :if={row.effort_prompt} value="" selected>Choose an effort</option>
                <option
                  :for={{value, label} <- @efforts}
                  value={value}
                  selected={row.entry["effort"] == value}
                >
                  {label}
                </option>
              </select>
            </div>
            <div class="settings-ladder-part">
              <label for={"#{@id}-#{row.index}-account"}>Account</label>
              <select
                id={"#{@id}-#{row.index}-account"}
                name={"#{@name}[#{row.index}][account]"}
                aria-invalid={to_string(not is_nil(@error))}
              >
                <option :if={row.account_prompt} value="" selected>{row.account_prompt}</option>
                <option
                  :for={account <- row.accounts}
                  value={account}
                  selected={row.entry["account"] == account}
                >
                  {account}
                </option>
              </select>
            </div>
            <%!-- Each button keeps its own slot, so every row's choices line up
            whichever buttons it has. --%>
            <div class="settings-ladder-actions">
              <button
                :if={row.index > 0}
                type="button"
                class="ui-button quiet settings-ladder-up"
                phx-click="ladder"
                phx-value-field={@name}
                phx-value-action="up"
                phx-value-index={row.index}
                phx-target={@myself}
                title="Move up"
                aria-label={"Move model #{row.index + 1} for #{@field.label} up"}
              ><Components.icon name={:arrow_up} /></button>
              <button
                :if={row.index < @count - 1}
                type="button"
                class="ui-button quiet settings-ladder-down"
                phx-click="ladder"
                phx-value-field={@name}
                phx-value-action="down"
                phx-value-index={row.index}
                phx-target={@myself}
                title="Move down"
                aria-label={"Move model #{row.index + 1} for #{@field.label} down"}
              ><Components.icon name={:arrow_down} /></button>
              <button
                :if={@count > 1}
                type="button"
                class="ui-button quiet settings-ladder-remove"
                phx-click="ladder"
                phx-value-field={@name}
                phx-value-action="remove"
                phx-value-index={row.index}
                phx-target={@myself}
                title="Remove"
                aria-label={"Remove model #{row.index + 1} for #{@field.label}"}
              ><Components.icon name={:close} /></button>
            </div>
          </li>
        </ol>
        <%!-- Add sits where the new row lands, as the list's last row. --%>
        <button
          :if={@count < @most}
          type="button"
          class="settings-ladder-add"
          phx-click="ladder"
          phx-value-field={@name}
          phx-value-action="add"
          phx-target={@myself}
          aria-label={"Add fallback for #{@field.label}"}
        ><Components.icon name={:plus} /><span>Add fallback</span></button>
      </div>
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
    </fieldset>
    """
  end

  # The accounts the worker has signed in, one numbered row each in the box
  # the lists of models use, its remove button at its end and Add account as
  # the last row (Andrew, 2026-09-27: "I need a way to add more accounts than
  # one!"). A row says what is wrong with it while it is typed, once it can
  # no longer become an account, and after a refused save also while it is
  # unfinished. A removal that is refused says which models run on the
  # account over the page, so the row that asked never grows (Andrew,
  # 2026-09-27: a row that "extends and design breaks").
  defp field(%{field: %{kind: :accounts}} = assigns) do
    %{field: field, value: entries, error: error, refusal: refusal} = assigns
    name = SettingsSections.field_name(field)

    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {account, index} ->
        problem = SettingsSections.account_problem(entries, index, not is_nil(error))

        %{
          index: index,
          account: account,
          name: if(String.trim(account) == "", do: "account #{index + 1}", else: account),
          problem: problem,
          message: problem
        }
      end)

    refused =
      case refusal do
        {^name, index, sentence} ->
          %{
            account: rows |> Enum.at(index, %{name: "This account"}) |> Map.fetch!(:name),
            sentence: sentence
          }

        _none ->
          nil
      end

    assigns =
      assign(assigns,
        name: name,
        rows: rows,
        refused: refused,
        count: length(entries),
        most: Work.most_accounts(),
        placeholder: SettingsSections.account_placeholder()
      )

    ~H"""
    <fieldset
      class="settings-field settings-ladder settings-accounts"
      id={@id}
      aria-describedby={help_id(@id, @field)}
    >
      <legend>{@field.label}</legend>
      <p :if={@field[:help]} class="settings-help" id={"#{@id}-help"}>{@field.help}</p>
      <div class="settings-ladder-box">
        <ol class="settings-ladder-list">
          <li :for={row <- @rows} id={"#{@id}-#{row.index}"} class="settings-ladder-entry">
            <span class="settings-ladder-order" aria-hidden="true">{row.index + 1}</span>
            <div class="settings-ladder-part">
              <label for={"#{@id}-#{row.index}-account"}>Account {row.index + 1}</label>
              <input
                type="text"
                id={"#{@id}-#{row.index}-account"}
                name={"#{@name}[#{row.index}]"}
                value={row.account}
                placeholder={@placeholder}
                autocomplete="off"
                autocapitalize="none"
                spellcheck="false"
                aria-invalid={to_string(not is_nil(row.problem))}
                aria-describedby={row.message && "#{@id}-#{row.index}-problem"}
              />
              <Components.form_feedback
                :if={row.message}
                id={"#{@id}-#{row.index}-problem"}
                message={row.message}
                tone={:error}
              />
            </div>
            <div class="settings-ladder-actions">
              <button
                :if={@count > 1}
                type="button"
                class="ui-button quiet settings-ladder-remove"
                phx-click="accounts"
                phx-value-field={@name}
                phx-value-action="remove"
                phx-value-index={row.index}
                phx-target={@myself}
                title="Remove"
                aria-label={"Remove #{row.name}"}
              ><Components.icon name={:close} /></button>
            </div>
          </li>
        </ol>
        <button
          :if={@count < @most}
          type="button"
          class="settings-ladder-add"
          phx-click="accounts"
          phx-value-field={@name}
          phx-value-action="add"
          phx-target={@myself}
        ><Components.icon name={:plus} /><span>Add account</span></button>
      </div>
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
      <Kit.confirm_modal
        :if={@refused}
        id={"#{@id}-refused"}
        title={"#{@refused.account} cannot be removed yet"}
        text={@refused.sentence}
        cancel="dismiss-refusal"
        target={@myself}
      />
    </fieldset>
    """
  end

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
          placeholder={SettingsSections.subfield_placeholder(subfield)}
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
      <option :if={@field[:prompt]} value="" selected={@value == ""}>{@field.prompt}</option>
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
      placeholder={@field[:placeholder] || "Comma separated"}
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
      min={if @field.kind == :integer, do: Map.get(@field, :min, 1)}
      max={if @field.kind == :integer, do: @field[:max]}
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

  # The name a row reads as in its list, for what the page says about it;
  # nil for a row that is not saved.
  defp row_name(section, view, key) when is_binary(key) do
    case Enum.find(SettingsSections.items(section, view), &(item_key(section, &1) == key)) do
      nil -> nil
      item -> SettingsRows.present(section, item, view).name
    end
  end

  defp row_name(_section, _view, _key), do: nil

  defp rows(section, view) do
    for item <- SettingsSections.items(section, view),
        do: {item_key(section, item), SettingsRows.present(section, item, view)}
  end

  defp groups(section, draft, view) do
    section
    |> SettingsSections.field_groups()
    |> Enum.map(fn {group, fields} ->
      %{
        name: group,
        fields:
          for(
            field <- fields,
            field_visible?(field, draft),
            do: adapt(section, field, view, draft)
          )
      }
    end)
    |> Enum.reject(&(&1.fields == []))
  end

  # A source's name is the end of the address its sender posts to, so the
  # form says that address while the name is being chosen.
  defp adapt(%{key: :webhooks}, %{name: :name} = field, view, _draft) do
    address = SettingsRows.webhook_address(view, "<source name>")
    Map.put(field, :help, "Senders post to #{address}. The name cannot change later.")
  end

  # Ryker posts about a source's events in a Slack channel, chosen from the
  # channels it is in; a source saved with another destination keeps it on
  # offer, so editing that source cannot lose where it posts. A text box that
  # showed slack:T0123456789:C0123456789 asked for Slack's internal IDs (QA,
  # 2026-09-25).
  defp adapt(%{key: :webhooks}, %{name: :destination_transport} = field, _view, draft) do
    saved = Map.get(draft, "destination_transport", "")
    %{field | options: Enum.filter(field.options, &(elem(&1, 0) in ["slack", saved]))}
  end

  defp adapt(%{key: :webhooks}, %{name: :destination_conversation_ref} = field, view, draft) do
    if Map.get(draft, "destination_transport") == "slack",
      do: slack_channel(field, view, Map.get(draft, "destination_conversation_ref", "")),
      else:
        Map.put(
          field,
          :help,
          "Where this source posts, as it was saved. Choose A Slack channel above to post in " <>
            "a channel instead."
        )
  end

  # The weekly report's channel is chosen the same way, by name, from the
  # channels Ryker is in. A text box asked for "the channel's ID from Slack,
  # under its name's details" (2026-09-28). The report keeps a bare channel
  # ID, so the choices do too.
  defp adapt(%{key: :report}, %{name: :channel_ref} = field, view, draft) do
    channels =
      for {"slack:" <> ref, name} <- SettingsSections.options(%{options: :slack_channels}, view),
          [_workspace, channel] <- [String.split(ref, ":", parts: 2)],
          do: {channel, name}

    chosen = Map.get(draft, "channel_ref") || ""

    saved =
      if chosen == "" or List.keymember?(channels, chosen, 0),
        do: [],
        else: [{chosen, chosen}]

    field
    |> Map.delete(:placeholder)
    |> Map.merge(%{
      kind: :select,
      label: "Slack channel",
      options: channels ++ saved,
      prompt: "Choose a channel",
      help:
        if(channels == [],
          do:
            "Ryker is not in any Slack channel yet. Invite it to one with /invite, then " <>
              "choose it here.",
          else: "One of the Slack channels Ryker is in."
        )
    })
  end

  defp adapt(_section, field, _view, _draft), do: field

  defp slack_channel(field, view, chosen) do
    channels = SettingsSections.options(%{options: :slack_channels}, view)
    slack = Integrations.slack(view)

    saved =
      if chosen == "" or List.keymember?(channels, chosen, 0),
        do: [],
        else: [{chosen, Names.destination(chosen)}]

    Map.merge(field, %{
      kind: :select,
      label: "Slack channel",
      options: channels ++ saved,
      required: true,
      prompt: "Choose a channel",
      help:
        cond do
          channels != [] ->
            "One of the Slack channels Ryker is in."

          # Slack not on yet is why no channel is listed; the reason is the
          # one every page gives.
          slack.status in [:not_set_up, :off] ->
            "Ryker lists the channels it is in once Slack is on. " <> slack.reason

          true ->
            "Ryker is not in any Slack channel yet. Invite it to one with /invite, then " <>
              "choose it here."
        end,
      errors: %{required: "Choose the Slack channel where Ryker posts about these events."}
    })
  end

  defp field_visible?(%{kind: :mapping}, draft),
    do: Map.get(draft, "adapter_kind") == "mapped_json"

  defp field_visible?(_field, _draft), do: true

  defp noun(section), do: Map.get(section, :item_label, collection_item_label(section.key))

  defp collection_item_label(:repositories), do: "repository"
  defp collection_item_label(:github_bindings), do: "GitHub repository binding"
  defp collection_item_label(_key), do: "entry"

  defp plural(noun) do
    cond do
      String.ends_with?(noun, ~w(ay ey oy uy)) -> noun <> "s"
      String.ends_with?(noun, "y") -> String.slice(noun, 0..-2//1) <> "ies"
      true -> noun <> "s"
    end
  end

  # What a webhook source needs that this installation does not have yet,
  # each with where to get it, before anyone fills in the form. A sender needs
  # no repository, so the way to its first environment is adding one, which
  # works whatever state GitHub is in.
  defp notices(%{key: :webhooks}, view) do
    [
      view.webhook_secret_names == [] &&
        %{text: "Create a signing credential above before adding a webhook source."},
      view.snapshot.environments == [] &&
        %{
          text: "Work from a webhook runs in an environment, and there is none yet.",
          link: "Add an environment",
          href: "/environments/new"
        },
      slack_notice(Integrations.slack(view))
    ]
    |> Enum.filter(& &1)
  end

  defp notices(_section, _view), do: []

  # Why Ryker cannot post these events to Slack yet, in the words and with the
  # next step every page gives for Slack's state.
  defp slack_notice(%{status: status} = slack) when status in [:not_set_up, :off] do
    %{
      text:
        slack.reason <>
          " Until then a source that posts to Slack does not take events, and this page says so.",
      link: slack.action.label,
      href: slack.action.href
    }
  end

  defp slack_notice(_slack), do: nil

  # Turning off keeping routing examples is not a shorter limit to the person
  # who unticked it, so it asks in its own words.
  defp impact_question(%{shortened_fields: [:routing_examples_enabled]}),
    do: %{
      title: "Stop keeping routing examples?",
      text:
        "Turning this off deletes every routing example kept for training. They cannot be brought back.",
      label: "Stop keeping them"
    }

  defp impact_question(_impact),
    do: %{
      title: "Apply shorter limits?",
      text:
        "Shorter limits delete older data: records older than the new limits become eligible for cleanup. Live waits, approvals, schedules and unpublished work keep their history regardless of age.",
      label: "Apply shorter limits"
    }

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

  defp offered?(models, model),
    do: Enum.any?(models, fn {_provider, options} -> List.keymember?(options, model, 0) end)

  # What an account choice says while its model has no listed account chosen:
  # that none is listed for the provider yet, or to choose one of those that are.
  defp account_prompt(entry, accounts) do
    cond do
      entry["account"] in accounts ->
        nil

      entry["model"] in [nil, ""] ->
        "Choose a model first"

      accounts == [] ->
        provider = entry["model"] |> String.split(":", parts: 2) |> hd()
        "No #{ExecutionTarget.provider_name(provider)} account yet"

      true ->
        "Choose an account"
    end
  end

  # A field that knows what to ask for says it in its own words (the Slack
  # prefix says what a prefix may hold, a second price for a day names the
  # price already there); any other refusal names the field and the rule.
  defp field_error(errors, field, draft, view) do
    case Enum.find(errors, fn {name, _reason} -> name == field.name end) do
      {_name, reason} ->
        sentence(Map.get(field[:errors] || %{}, reason), field, reason, {draft, view})

      nil ->
        nil
    end
  end

  defp sentence(text, _field, _reason, _values) when is_binary(text), do: text

  defp sentence({module, function}, _field, _reason, {draft, view}),
    do: apply(module, function, [draft, view])

  defp sentence(nil, field, reason, _values), do: "#{field.label} #{phrase(reason)}"

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

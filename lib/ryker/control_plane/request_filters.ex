defmodule Ryker.ControlPlane.RequestFilters do
  @moduledoc """
  The Activity filter bar: one chip per applied filter and a menu to add one.

  Every filter is an exact match, so there is no operator to choose. Choosing a
  value applies it at once as a URL parameter, which keeps the view shareable;
  filters only change this view, never execution state.

  The menu offers the filters a person uses. Usage, the timeline and the
  channel pages link here with a few more, such as an account or a Slack
  thread; each of those still reads as a chip in plain words and can be
  removed. A parameter that only narrows another, such as the workspace of a
  chosen user, is part of that filter's chip and leaves with it.
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components
  alias Phoenix.LiveView.JS

  alias Ryker.ControlPlane.{ShortTime, UsagePage, UsageProjection}
  alias Ryker.Episodes.Words
  alias Ryker.Slack.Names
  alias Ryker.Work.ExecutionTarget

  @efforts ~w(none minimal low medium high xhigh max)

  # Every filter a view can carry, in chip order, with the words its chip shows.
  @fields [
    {"conversation", "Conversation", :conversation},
    {"thread", "Slack thread", :thread},
    {"transport", "Source", ~w(slack github control_plane)},
    {"repository", "Repository", :text},
    {"state", "State", ~w(working waiting_for_input waiting_for_event complete cancelled)},
    {"usage_work_kind", "Work type", UsagePage.work_kinds()},
    {"usage_model", "Model", :text},
    {"usage_effort", "Reasoning effort", @efforts},
    {"usage_profile", "Account", :text},
    {"usage_provider", "Provider", :text},
    {"usage_actor", "User", :user},
    {"usage_channel", "Channel", :channel},
    {"usage_repository", "Repository", :text},
    {"usage_source", "Source", ~w(slack github webhook control_plane)},
    {"usage_actor_kind", "Sender", ~w(user app bot system)},
    {"usage_workspace", "Workspace", :text},
    {"usage_window", "Usage period", ~w(24h 7d 30d all)}
  ]

  # What "+ Filter" offers, by group and in order.
  @menu [
    {"Request", ~w(conversation transport repository state)},
    {"Usage", ~w(usage_model usage_effort usage_work_kind usage_actor)}
  ]

  # Parameters that only narrow another filter: they read as part of its
  # chip and are removed with it, unless another chip still needs them.
  @companions %{
    "usage_actor" => ~w(usage_actor_kind usage_workspace usage_source),
    "usage_model" => ~w(usage_provider),
    "usage_profile" => ~w(usage_provider)
  }

  @keys Enum.map(@fields, &elem(&1, 0))
  def keys, do: @keys

  @doc "The view's parameters with one filter set; an empty value removes it."
  def set(params, key, ""), do: remove(params, key)

  def set(params, key, value)
      when key in @keys and is_binary(value) and byte_size(value) <= 512 do
    params = params |> base() |> Map.put(key, value)
    # The user list holds people only, so a chosen account never also matches
    # a bot that retained the same actor string.
    if key == "usage_actor", do: Map.put(params, "usage_actor_kind", "user"), else: params
  end

  def set(params, _key, _value), do: base(params)

  @doc "The view's parameters without one filter and the parameters that only narrow it."
  def remove(params, key) do
    params = params |> base() |> Map.delete(key)

    claimed =
      for {primary, parts} <- @companions, Map.has_key?(params, primary), part <- parts, do: part

    Map.drop(params, Map.get(@companions, key, []) -- claimed)
  end

  defp base(params), do: params |> UsageProjection.link_params() |> Map.delete("page")

  attr(:params, :map, required: true)

  attr(:values, :list,
    required: true,
    doc: "Recorded rows that name conversations, users and channels"
  )

  attr(:path, :string, required: true)

  attr(:menu, :string,
    default: nil,
    doc: "\"fields\", a filter key, or nil when the menu is closed"
  )

  attr(:disabled, :boolean, default: false)

  def render(assigns) do
    params = UsageProjection.link_params(assigns.params)
    chips = chips(params, assigns.values)

    assigns =
      assign(assigns,
        params: params,
        chips: chips,
        groups: menu_groups(params),
        adding: assigns.menu == "fields",
        cleared: chips != [] or params["q"] not in [nil, ""]
      )

    ~H"""
    <div class="filter-toolbar-controls" id="request-filters">
      <span
        :for={chip <- @chips}
        class="filter-chip-wrap"
        phx-click-away={if @menu == chip.key, do: "filter-menu-close"}
      >
        <span class="filter-chip filter-control" data-filter={chip.key}>
          <button
            type="button"
            class="filter-chip-edit"
            disabled={@disabled}
            phx-click="filter-menu"
            phx-value-key={chip.key}
            aria-expanded={to_string(@menu == chip.key)}
            aria-label={"#{chip.label}: #{chip.value}. Change"}
          ><span class="filter-chip-key">{chip.label}</span><span class="filter-chip-value">{chip.value}</span></button><button
            type="button"
            class="filter-chip-remove"
            disabled={@disabled}
            phx-click="remove-filter"
            phx-value-key={chip.key}
            aria-label={"Remove the #{chip.label} filter"}
          ><.icon name={:close} /></button>
        </span>
        <.popover
          :if={@menu == chip.key && !@disabled}
          field={field(chip.key)}
          current={@params[chip.key]}
          values={@values}
          params={@params}
          return={"[data-filter=#{chip.key}] .filter-chip-edit"}
        />
      </span>
      <span class="filter-add-wrap" phx-click-away={if @adding, do: "filter-menu-close"}>
        <button
          id="filter-add"
          type="button"
          class="filter-add filter-control"
          disabled={@disabled}
          phx-click="filter-menu"
          phx-value-key="fields"
          aria-expanded={to_string(@adding)}
        ><.icon name={:plus} />Filter</button>
        <.menu :if={@adding && !@disabled} groups={@groups} values={@values} params={@params} />
      </span>
      <.link :if={@cleared && !@disabled} class="filter-clear" patch={@path}>Clear</.link>
    </div>
    """
  end

  # The menu's fields not already applied, by group; a group left empty goes.
  defp menu_groups(params) do
    for {group, keys} <- @menu,
        fields = for(key <- keys, not is_binary(params[key]), do: field(key)),
        fields != [],
        do: {group, fields}
  end

  attr(:groups, :list, required: true)
  attr(:values, :list, required: true)
  attr(:params, :map, required: true)

  # The field list stays put; each field's values sit in a hidden panel beside
  # it, which the FilterMenu hook shows on hover, focus or click. Choosing a
  # field never replaces the list without a way back.
  defp menu(assigns) do
    assigns = assign(assigns, :available, Enum.flat_map(assigns.groups, &elem(&1, 1)))

    ~H"""
    <div
      id="filter-popover"
      class="filter-popover filter-cascade"
      role="dialog"
      aria-label="Add a filter"
      phx-hook="FilterMenu"
      phx-window-keydown={JS.push("filter-menu-close") |> JS.focus(to: "#filter-add")}
      phx-key="Escape"
    >
      <div class="filter-fields">
        <section :for={{group, fields} <- @groups}>
          <h3>{group}</h3>
          <button
            :for={{key, label, _type} <- fields}
            type="button"
            class="filter-field"
            data-field={key}
            aria-haspopup="true"
            aria-expanded="false"
            aria-controls={"filter-values-#{key}"}
          ><span>{label}</span><.icon name={:chevron} /></button>
        </section>
      </div>
      <div
        :for={{key, label, _type} = field <- @available}
        id={"filter-values-#{key}"}
        class="filter-values"
        data-field={key}
        role="group"
        aria-label={label}
        hidden
      >
        <button type="button" class="filter-back" data-back><.icon name={:chevron} />{label}</button>
        <.values field={field} current={nil} values={@values} params={@params} />
      </div>
    </div>
    """
  end

  attr(:field, :any, required: true)
  attr(:current, :any, default: nil)
  attr(:values, :list, required: true)
  attr(:params, :map, required: true)
  attr(:return, :string, required: true, doc: "Where focus goes when Escape closes the popover")

  # Editing an applied filter: that field's values alone, the current one marked.
  defp popover(assigns) do
    {_key, label, _type} = assigns.field
    assigns = assign(assigns, :label, label)

    ~H"""
    <div
      id="filter-popover"
      class="filter-popover"
      role="dialog"
      aria-label={"#{@label} filter"}
      phx-mounted={JS.focus_first()}
      phx-window-keydown={JS.push("filter-menu-close") |> JS.focus(to: @return)}
      phx-key="Escape"
    >
      <h3>{@label}</h3>
      <.values field={@field} current={@current} values={@values} params={@params} />
    </div>
    """
  end

  attr(:field, :any, required: true)
  attr(:current, :any, default: nil)
  attr(:values, :list, required: true)
  attr(:params, :map, required: true)

  # A value applies as soon as it is chosen. It travels as "choice": LiveView's
  # client overwrites a clicked button's "value" with the button's own, empty one.
  defp values(assigns) do
    {key, label, type} = assigns.field

    assigns =
      assign(assigns,
        key: key,
        label: label,
        type: type,
        choices:
          if(type == :text,
            do: [],
            else: choices(type, assigns.values, assigns.current, assigns.params)
          )
      )

    ~H"""
    <form :if={@type == :text} class="filter-text" phx-submit="set-filter">
      <input type="hidden" name="key" value={@key} />
      <label class="sr-only" for={"filter-value-#{@key}"}>{@label}</label>
      <input
        id={"filter-value-#{@key}"}
        name="choice"
        value={@current || ""}
        maxlength="512"
        autocomplete="off"
        placeholder={"Exact #{String.downcase(@label)}"}
      />
      <button type="submit" class="ui-button primary">Apply</button>
    </form>
    <div :if={@type != :text} class="filter-choices">
      <button
        :for={{value, name} <- @choices}
        type="button"
        phx-click="set-filter"
        phx-value-key={@key}
        phx-value-choice={value}
        aria-pressed={to_string(value == @current)}
      >
        {name}
      </button>
      <p :if={@choices == []} class="filter-empty">Nothing recorded yet.</p>
    </div>
    """
  end

  defp field(key), do: List.keyfind(@fields, key, 0)

  # One chip per filter; a parameter that only narrows another applied
  # filter is part of that one's chip.
  defp chips(params, values) do
    folded =
      for {primary, parts} <- @companions, is_binary(params[primary]), part <- parts, do: part

    for {key, label, type} <- @fields, is_binary(params[key]), key not in folded do
      %{key: key, label: label, value: value_label(type, params[key], params, values)}
    end
  end

  # A retained link can still carry an empty value for a field that was never
  # recorded; it reads as "none" so the chip can be seen and removed.
  defp value_label(_type, "", _params, _values), do: "none"
  defp value_label(:text, value, _params, _values), do: value

  # A chat is named the way the menu named it, never only "Direct conversation".
  defp value_label(:conversation, value, _params, values) do
    case Enum.find(values, &(Map.get(&1, :conversation_ref) == value)) do
      %{conversation_label: label} when is_binary(label) -> label
      _other -> Names.destination(value)
    end
  end

  defp value_label(:thread, value, _params, _values), do: thread_label(value)
  defp value_label(:channel, value, _params, _values), do: Names.destination(value)
  defp value_label(:user, value, params, values), do: user_label(value, params, values)
  defp value_label(_choices, value, _params, _values), do: choice_label(value)

  # A Slack thread is known by the time its first message was posted.
  defp thread_label(value) do
    with [seconds | _fraction] <- String.split(value, ".", parts: 2),
         {seconds, ""} <- Integer.parse(seconds),
         {:ok, started} <- DateTime.from_unix(seconds) do
      "started " <> ShortTime.full(started)
    else
      _other -> "this thread"
    end
  end

  defp user_label(value, %{"usage_source" => "slack", "usage_workspace" => workspace}, _values),
    do: Names.name(workspace, value)

  # A person the loaded choices no longer list is still a person, never their
  # bare Slack ID (Andrew, 2026-09-26); Ryker serves one workspace.
  defp user_label(value, _params, values) do
    case Enum.find(values, &(Map.get(&1, :actor) == value and Map.get(&1, :source) == "slack")) do
      %{workspace: workspace} ->
        Names.name(workspace, value)

      nil ->
        if Names.person_ref?(value), do: Names.person(Names.workspace(), value).name, else: value
    end
  end

  defp choices(type, rows, selected, params) do
    options =
      case type do
        :conversation ->
          rows
          |> Enum.filter(&Map.has_key?(&1, :conversation_label))
          |> Enum.map(&{&1.conversation_ref, &1.conversation_label})

        :user ->
          rows
          |> Enum.filter(&(&1[:actor_kind] == "user" and &1[:source] != "control_plane"))
          |> Enum.map(fn row ->
            {row.actor,
             if(row.source == "slack",
               do: Names.name(row.workspace, row.actor),
               else: row.actor
             )}
          end)

        :channel ->
          rows
          |> Enum.filter(&(&1[:transport] == "slack"))
          |> Enum.map(&{&1.conversation_ref, Names.destination(&1.conversation_ref)})

        values ->
          Enum.map(values, &{&1, choice_label(&1)})
      end

    options =
      Enum.reject(options, fn {value, _} -> value in [nil, ""] end) |> Enum.uniq_by(&elem(&1, 0))

    if selected in [nil, ""] or Enum.any?(options, &(elem(&1, 0) == selected)),
      do: options,
      else: options ++ [{selected, value_label(type, selected, params, rows)}]
  end

  defp choice_label(value) when value in @efforts, do: ExecutionTarget.effort_name(value)
  defp choice_label("control_plane"), do: "Direct conversation"
  defp choice_label("github"), do: "GitHub"
  defp choice_label("24h"), do: "Last 24 hours"
  defp choice_label("7d"), do: "Last 7 days"
  defp choice_label("30d"), do: "Last 30 days"
  defp choice_label("all"), do: "All time"
  # The filter must offer the same words the breakdown shows, or "Investigation"
  # in the table and "Standard" in the menu look like two different things.
  defp choice_label(value) do
    if value in UsagePage.work_kinds(),
      do: UsagePage.kind_name(value),
      else: Words.label(value)
  end
end

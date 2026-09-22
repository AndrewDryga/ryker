defmodule Ryker.ControlPlane.Components do
  @moduledoc "Shared, accessible primitives for the operator workspace."
  use Phoenix.Component

  import Phoenix.HTML.Form, only: [options_for_select: 2]
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.ExecutionTarget

  @icons %{
    activity: "M3 12h4l3-8 4 16 3-8h4",
    chat: "M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-6 3V6a2 2 0 0 1 2-2Z",
    cards: "M4 7h13v14H4z M8 3h13v14 M4 12h13",
    incident: "M12 3 2 21h20L12 3Z M12 9v5 M12 17v1",
    clock: "M12 8v5l3 2 M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0",
    search: "M20 20l-5-5 M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0",
    code: "M16 18l6-6-6-6 M8 6l-6 6 6 6",
    bell: "M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9 M10.3 21a2 2 0 0 0 3.4 0",
    arrow: "M5 12h14 M13 6l6 6-6 6",
    plus: "M12 5v14 M5 12h14",
    close: "M6 6l12 12 M18 6 6 18",
    check: "m5 12 4 4L19 6",
    usage: "M4 20h17 M6 16v-5 M12 16V4 M18 16V8",
    book: "M12 5v16 M3 3l9 2 9-2v16l-9 2-9-2V3Z",
    settings: "M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6",
    grid: "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z",
    arrow_up: "M12 19V5 M6 11l6-6 6 6",
    arrow_down: "M12 5v14 M18 13l-6 6-6-6",
    copy: "M9 9h10v10H9z M5 5h10v4 M5 5v10h4",
    chevron: "m9 5 7 7-7 7"
  }

  def icon(assigns) do
    assigns = assign(assigns, :path, Map.get(@icons, assigns.name, @icons.activity))

    ~H"""
    <svg
      class="ui-icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    ><path d={@path} /></svg>
    """
  end

  attr(:target, :string, default: nil)
  attr(:compact, :boolean, default: false)
  attr(:class, :any, default: nil)

  @doc "The shared human presentation of a retained co:op execution target."
  def execution_target(assigns) do
    assigns = assign(assigns, :presentation, ExecutionTarget.present(assigns.target))

    ~H"""
    <span
      class={["execution-target", @compact && "execution-target-compact", @class]}
      title={@presentation.canonical}
    >
      <span :if={@compact} class="execution-target-inline">{@presentation.compact}</span>
      <%= if !@compact do %>
        <strong class="execution-target-model">{@presentation.model}</strong>
        <span :if={@presentation.meta} class="execution-target-meta">{@presentation.meta}</span>
      <% end %>
    </span>
    """
  end

  attr(:value, :string, required: true)
  attr(:label, :string, default: "identifier")
  attr(:class, :any, default: nil)
  attr(:copy, :boolean, default: true)

  @doc "A compact technical identifier with its exact value available on hover and copy."
  def identifier(assigns) do
    assigns = assign(assigns, :display, compact_identifier(assigns.value))

    ~H"""
    <span class={["ui-identifier", @class]} title={@value}>
      <code>{@display}</code>
      <button
        :if={@copy}
        type="button"
        class="copy-value"
        data-copy-value={@value}
        aria-label={"Copy #{@label}"}
      >
        <.icon name={:copy} />
        <span class="sr-only" data-copy-status aria-live="polite"></span>
      </button>
    </span>
    """
  end

  def compact_identifier(value, maximum \\ 27)

  def compact_identifier(value, maximum)
      when is_binary(value) and is_integer(maximum) and maximum >= 9 do
    if String.length(value) <= maximum do
      value
    else
      prefix = div(maximum, 2)
      suffix = maximum - prefix - 1
      String.slice(value, 0, prefix) <> "…" <> String.slice(value, -suffix, suffix)
    end
  end

  def compact_identifier(value, _maximum), do: to_string(value)

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:kind, :atom, values: [:details, :diagnostic], default: :details)
  attr(:open, :boolean, default: false)
  attr(:class, :any, default: nil)
  attr(:summary_aria_label, :string, default: nil)
  slot(:inner_block, required: true)

  @doc "The shared disclosure shell for supporting detail and failure diagnostics."
  def disclosure(assigns) do
    ~H"""
    <details
      id={@id}
      class={["ui-disclosure", "ui-disclosure-#{@kind}", @class]}
      open={@open}
    >
      <summary aria-label={@summary_aria_label}>
        <span>{@label}</span><.icon name={:chevron} />
      </summary>
      <div class="ui-disclosure-body">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr(:facts, :list, required: true)
  attr(:class, :any, default: nil)

  @doc "The shared label/value typography for timeline facts and diagnostics."
  def fact_list(assigns) do
    ~H"""
    <dl class={["ui-facts", @class]}>
      <div :for={fact <- @facts}>
        <dt>{fact.label}</dt>
        <dd>
          <.identifier
            :if={fact[:identifier] && is_binary(fact.value)}
            value={fact.value}
            label={fact[:copy_label] || fact.label}
          />
          <.execution_target
            :if={fact[:presentation] == :execution_target}
            target={fact.value}
          />
          <span :if={!fact[:identifier] && fact[:presentation] != :execution_target}>
            {fact.value}
          </span>
        </dd>
      </div>
    </dl>
    """
  end

  attr(:state, :any,
    default: nil,
    doc: "An episode or work state; its label and tone derive from it"
  )

  attr(:lifecycle, :any,
    default: nil,
    doc: "A status from the enabled/paused family that rules, schedules and memories share"
  )

  attr(:label, :string, default: nil, doc: "The word, when the status is in neither vocabulary")
  attr(:tone, :string, default: nil, doc: "attention, active, done or quiet")

  @doc """
  Dot plus word: the state reads without relying on colour.

  An episode state or a lifecycle status supplies both from the shared
  vocabularies below; anything else names its own word and tone, so every
  page's statuses share one markup.
  """
  def status(assigns) do
    {label, tone} =
      cond do
        assigns.lifecycle != nil -> lifecycle(assigns.lifecycle)
        assigns.state != nil -> {label(assigns.state), tone(assigns.state)}
        true -> {nil, nil}
      end

    assigns = assign(assigns, label: assigns.label || label, tone: assigns.tone || tone)

    ~H"""
    <span class={"ui-status status-#{@tone}"}><i aria-hidden="true"></i>{@label}</span>
    """
  end

  def status(label, tone) do
    %{__changed__: nil, state: nil, lifecycle: nil, label: label, tone: tone}
    |> status()
    |> Safe.to_iodata()
  end

  @doc """
  The word and tone of the enabled/paused family: a rule, schedule or memory
  that is active is a settled good state, not work in progress, so it carries
  the done tone; paused and disabled are the same fact and read as Paused.
  """
  def lifecycle(status) do
    case to_string(status) do
      "active" -> {"Active", "done"}
      "paused" -> {"Paused", "quiet"}
      "disabled" -> {"Paused", "quiet"}
      "completed" -> {"Completed", "done"}
      other -> {label(other), "quiet"}
    end
  end

  attr(:page, :integer, required: true)
  attr(:pages, :integer, required: true)
  attr(:path, :any, required: true, doc: "A function from a page number to its href")
  attr(:label, :string, required: true, doc: "Accessible name, e.g. \"Finding pages\"")
  attr(:earlier, :string, default: "← Previous")
  attr(:later, :string, default: "Next →")
  attr(:summary, :string, default: nil, doc: "Words after the page count, e.g. \"40 entries\"")

  @doc """
  The one pager of a paged relation; renders nothing for a single page.

  Plain links keep the URL shareable and back/forward honest, and each link
  is a 44px target. The earlier/later words say what direction means on the
  page in hand ("Newer updates", "Older batches") rather than assuming a list
  reads forwards.
  """
  def pager(assigns) do
    ~H"""
    <nav :if={@pages > 1} class="pagination" aria-label={@label}>
      <a :if={@page > 1} href={@path.(@page - 1)}>{@earlier}</a>
      <span>Page {@page} of {@pages}<span :if={@summary}> · {@summary}</span></span>
      <a :if={@page < @pages} href={@path.(@page + 1)}>{@later}</a>
    </nav>
    """
  end

  attr(:rows, :list, required: true)

  slot :col, required: true do
    attr(:label, :string, required: true)

    attr(:class, :string,
      doc: "row-number or row-action when header and cells share an alignment"
    )
  end

  @doc """
  A comparison table whose every cell names its column, so a narrow screen
  can stack a row into label/value pairs without hiding the row's identity
  (its first column). Unframed: a header row, row lines, no panel.
  """
  def table(assigns) do
    ~H"""
    <table class="data-table">
      <thead>
        <tr>
          <th :for={col <- @col} scope="col" {class_attribute(col[:class])}>{col.label}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <td
            :for={{col, index} <- Enum.with_index(@col)}
            data-label={col.label}
            {class_attribute(cell_class(index, col[:class]))}
          >
            <div class="cell-value">{render_slot(col, row)}</div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp cell_class(0, nil), do: "row-identity"
  defp cell_class(0, class), do: "row-identity " <> class
  defp cell_class(_index, class), do: class

  # An unclassed cell carries no class attribute at all, like the string pages' tables.
  defp class_attribute(nil), do: []
  defp class_attribute(class), do: [class: class]

  attr(:label, :string, default: "Completed")

  @doc """
  An accessible success mark. The icon carries the state; nothing visible
  repeats it, because "✓ Passed" is the same fact twice and crowds out the
  reasons that are not obvious. Assistive technology still gets the name.
  """
  def success_mark(assigns) do
    ~H"""
    <span class="success-mark" role="img" aria-label={@label}></span>
    """
  end

  attr(:path, :string, required: true)
  attr(:label, :string, required: true)
  attr(:tone, :any, default: :secondary)

  def action_button(assigns) do
    ~H"""
    <form class="action-control" method="get" action={@path}>
      <button type="submit" class={"ui-button #{@tone}"}>{@label}</button>
    </form>
    """
  end

  def action_button(path, label, tone \\ :secondary) do
    # GET only opens the existing confirmation; its protected POST performs the action.
    %{path: path, label: label, tone: tone}
    |> action_button()
    |> Safe.to_iodata()
  end

  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  slot(:action, doc: "A real page-level action that already exists; never a placeholder")

  @doc """
  The one heading of a secondary page.

  The title renders once, an existing primary action may sit opposite it,
  and the page's short description sits 8px underneath. Everything the page
  owns follows in one column: optional help, one toolbar, a quiet count, the
  content, then related history. A body never renders a competing heading or
  a second description; the shell that mounts it is the only place a title
  comes from, so outer and inner titles cannot duplicate each other.
  """
  def page_header(assigns) do
    assigns =
      assigns
      |> assign_new(:description, fn -> nil end)
      |> assign_new(:action, fn -> [] end)

    ~H"""
    <header class="page-header">
      <div class="page-heading">
        <h1>{@title}</h1>
        <div :if={@action != []} class="page-action">{render_slot(@action)}</div>
      </div>
      <p :if={@description} class="page-description">{@description}</p>
    </header>
    """
  end

  attr(:label, :string, required: true)
  attr(:facts, :list, default: [])
  attr(:message, :string, default: nil)
  attr(:secondary, :list, default: [])
  attr(:related, :map, default: nil)

  @doc """
  A compact row of page-level facts beneath a page heading.

  Facts stay unboxed and number-first. A related destination remains visible
  when the row wraps, and the optional area breakdown names only meaningful
  nonzero groups supplied by the caller.
  """
  def page_summary(assigns) do
    ~H"""
    <section class="page-summary" aria-label={@label}>
      <div class="page-summary-main">
        <dl class="page-summary-facts">
          <div
            :for={fact <- @facts}
            class={[
              "page-summary-fact",
              fact[:tone] in [:attention, "attention"] && "page-summary-fact-attention"
            ]}
          >
            <dt>
              <a :if={fact[:href]} href={fact.href}>{fact.label}</a>
              <span :if={!fact[:href]}>{fact.label}</span>
            </dt>
            <dd data-active-count={fact[:active_count] && true}>{fact.value}</dd>
          </div>
        </dl>
        <p :if={@message} class="page-summary-message">{@message}</p>
        <a :if={@related} class="page-summary-link" href={@related.href}>{@related.label}</a>
      </div>
      <div :if={length(@secondary) > 0} class="page-summary-secondary">
        <span>By area</span>
        <dl>
          <div :for={fact <- @secondary}>
            <dt>{fact.label}</dt>
            <dd>{fact.value}</dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:one, :string, default: "item")
  attr(:many, :string, default: "items")
  attr(:class, :any, default: nil)
  slot(:navigation)
  slot(:filters, required: true)
  slot(:inner_block, required: true)

  @doc """
  The shared frame for searchable collections.

  Navigation is optional because it is only useful when a collection has real
  alternate views. The toolbar, count, content and empty state keep the same
  hierarchy whether the rows are rendered by a LiveView or a static page.
  """
  def collection_shell(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:navigation, fn -> [] end)

    ~H"""
    <section class={["collection-shell", @class]} aria-label={@label}>
      <header :if={@navigation != []} class="collection-shell-header">
        <div class="collection-shell-navigation">{render_slot(@navigation)}</div>
        <p class={["collection-total", @count > 0 && "result-count"]}>
          {@count} {if @count == 1, do: @one, else: @many}
        </p>
      </header>
      <div class="collection-shell-filter-row">
        <div class="collection-shell-filters">{render_slot(@filters)}</div>
        <p
          :if={@navigation == []}
          class={["collection-total", @count > 0 && "result-count"]}
        >
          {@count} {if @count == 1, do: @one, else: @many}
        </p>
      </div>
      <div class="collection-shell-content">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true, doc: "Specific, e.g. \"How to add and manage rules\"")
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  @doc """
  Longer help that expands below the description, never in a side column.

  It starts closed. The id lets the reading-state hook keep it open across a
  live refresh. Scope or authority warnings that a reader must not miss do
  not belong in here; they stay visible in the description or the content.
  """
  def page_help(assigns) do
    ~H"""
    <details class={["page-help", @class]} id={@id}>
      <summary>{@label}</summary>
      <div class="page-help-body">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr(:message, :string, required: true)
  attr(:tone, :atom, values: [:error, :warning, :success, :info], default: :info)
  attr(:id, :string, default: nil)
  attr(:hidden, :boolean, default: false)
  attr(:class, :any, default: nil)

  @doc "A consistent inline outcome for forms, with a visible state icon and live-region semantics."
  def form_feedback(assigns) do
    ~H"""
    <div
      id={@id}
      class={["form-feedback", "form-feedback-#{@tone}", @class]}
      data-tone={@tone}
      role={if @tone == :error, do: "alert", else: "status"}
      hidden={@hidden}
    >
      <span class="form-feedback-icon" aria-hidden="true">{feedback_icon(@tone)}</span>
      <span class="form-feedback-message">{@message}</span>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:path, :string, required: true)
  attr(:label, :string, required: true, doc: "Accessible name, e.g. \"Filter standing rules\"")
  attr(:placeholder, :string, required: true)
  attr(:query, :string, default: "")
  attr(:filtered, :boolean, default: false)
  attr(:disabled, :boolean, default: false, doc: "The complete searchable collection is empty")

  attr(:selects, :list,
    default: [],
    doc:
      "Dropdowns as %{id, name, label, value, options: [{value, text}]}; each applies on change"
  )

  attr(:name, :string, default: "q", doc: "The search field's parameter name")

  attr(:hidden, :list,
    default: [],
    doc: "[{name, value}] the form must keep, e.g. the memory view it searches within"
  )

  attr(:clear, :string,
    default: nil,
    doc: "Where \"Clear filters\" goes when that is not the bare path"
  )

  @doc """
  The one compact filter toolbar of a page that filters.

  A GET form, so the URL stays shareable and back/forward stay honest. Search
  submits on Enter; a dropdown submits the form as soon as it changes
  (filter-toolbar.mjs), so there is no Apply button. Labels stay bound to
  their controls for assistive technology while the placeholder and the
  chosen option carry the visible meaning.
  """
  def filter_toolbar(assigns) do
    assigns =
      assigns
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:filtered, fn -> false end)
      |> assign_new(:disabled, fn -> false end)
      |> assign_new(:selects, fn -> [] end)
      |> assign_new(:name, fn -> "q" end)
      |> assign_new(:hidden, fn -> [] end)
      |> assign_new(:clear, fn -> nil end)
      |> assign_filter_controls()

    ~H"""
    <form class="filter-toolbar" method="get" action={@path} role="search" aria-label={@label}>
      <input :for={{name, value} <- @hidden} type="hidden" name={name} value={value} />
      <div class="search-field filter-control">
        <.icon name={:search} />
        <label class="sr-only" for={@id}>{@placeholder}</label>
        <input
          type="search"
          id={@id}
          name={@name}
          maxlength="200"
          value={@query || ""}
          placeholder={@placeholder}
          disabled={@disabled}
        />
      </div>
      <%= if @primary do %>
        <label class="sr-only" for={@primary.id}>{@primary.label}</label>
        <select
          class="filter-primary filter-control"
          id={@primary.id}
          name={@primary.name}
          disabled={@disabled}
        >
          {options_for_select(
            Enum.map(@primary.options, fn {value, text} -> {text, value} end),
            @primary.value
          )}
        </select>
      <% end %>
      <%= for chip <- @filter_chips do %>
        <input type="hidden" name={chip.name} value={chip.value} />
        <span
          class={["filter-chip", "filter-control", @disabled && "is-disabled"]}
          data-filter={chip.name}
        >
          <span class="filter-chip-key">{chip.label}</span>
          <span class="filter-chip-value">{chip.display}</span>
          <a
            :if={!@disabled}
            class="filter-chip-remove"
            href={chip.remove_href}
            aria-label={"Remove the #{chip.label} filter"}
          ><.icon name={:close} /></a>
          <span :if={@disabled} class="filter-chip-remove" aria-hidden="true"><.icon name={:close} /></span>
        </span>
      <% end %>
      <button
        :if={@available_filters != [] && @disabled}
        type="button"
        class="filter-add filter-control"
        disabled
      ><.icon name={:plus} />Filter</button>
      <details :if={@available_filters != [] && !@disabled} class="filter-add-menu">
        <summary class="filter-add filter-control"><.icon name={:plus} />Filter</summary>
        <div class="filter-popover">
          <%= for select <- @available_filters do %>
            <label for={select.id}>{select.label}</label>
            <select id={select.id} name={select.name}>
              {options_for_select(
                Enum.map(select.options, fn {value, text} -> {text, value} end),
                select.value
              )}
            </select>
          <% end %>
        </div>
      </details>
      <a :if={@filtered && !@disabled} class="filter-clear" href={@clear || @path}>Clear filters</a>
      <noscript><button type="submit" class="ui-button secondary">Apply</button></noscript>
    </form>
    """
  end

  defp feedback_icon(:error), do: "!"
  defp feedback_icon(:warning), do: "!"
  defp feedback_icon(:success), do: "✓"
  defp feedback_icon(:info), do: "i"

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:placeholder, :string, required: true)
  attr(:query, :string, default: "")
  attr(:disabled, :boolean, default: false)
  attr(:event, :string, required: true)
  attr(:primary, :map, default: nil)
  attr(:class, :any, default: nil)
  slot(:inner_block)

  @doc """
  The LiveView adapter for the shared filter toolbar.

  It deliberately renders the same `filter-toolbar`, `search-field`, primary
  selector and trailing-control contract as the GET adapter above. Only the
  transport differs: search and the primary choice patch the current LiveView,
  while the supplied slot may add domain-specific chips and value menus.
  """
  def live_filter_toolbar(assigns) do
    assigns =
      assigns
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:disabled, fn -> false end)
      |> assign_new(:primary, fn -> nil end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:inner_block, fn -> [] end)

    ~H"""
    <div id={"#{@id}-toolbar"} class={["filter-toolbar", @class]} role="search" aria-label={@label}>
      <form id={@id} class="filter-live-form" phx-change={@event} phx-submit={@event}>
        <div class="search-field filter-control">
          <.icon name={:search} />
          <label class="sr-only" for={"#{@id}-search"}>{@placeholder}</label>
          <input
            id={"#{@id}-search"}
            name="q"
            type="search"
            value={@query || ""}
            phx-debounce="300"
            maxlength="200"
            placeholder={@placeholder}
            autocomplete="off"
            disabled={@disabled}
          />
        </div>
        <%= if @primary do %>
          <label class="sr-only" for={@primary.id}>{@primary.label}</label>
          <select class="filter-control" id={@primary.id} name={@primary.name} disabled={@disabled}>
            {options_for_select(
              Enum.map(@primary.options, fn {value, text} -> {text, value} end),
              @primary.value
            )}
          </select>
        <% end %>
      </form>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:kind, :atom, values: [:empty, :no_match, :unavailable, :actionable], default: :empty)
  attr(:title, :string, required: true)
  attr(:description, :string, required: true)
  slot(:action)

  @doc "One explicit empty/no-match/unavailable surface shared by directory pages."
  def empty_state(assigns) do
    assigns = assign_new(assigns, :action, fn -> [] end)

    ~H"""
    <section class={["empty-state", "empty-state-#{@kind}"]}>
      <h2>{@title}</h2>
      <p>{@description}</p>
      <div :if={@action != []} class="empty-state-action">{render_slot(@action)}</div>
    </section>
    """
  end

  defp assign_filter_controls(assigns) do
    {primary, optional} =
      case assigns.selects do
        [primary | optional] -> {primary, optional}
        [] -> {nil, []}
      end

    active =
      Enum.filter(optional, fn select ->
        to_string(select.value || "") != to_string(select_default(select) || "")
      end)

    chips =
      Enum.map(active, fn select ->
        value = to_string(select.value || "")

        %{
          name: select.name,
          label: select.label,
          value: value,
          display: select_option_label(select, value),
          remove_href:
            filter_href(
              assigns.path,
              assigns.query,
              assigns.name,
              assigns.hidden,
              assigns.selects,
              select.name
            )
        }
      end)

    assign(assigns, primary: primary, filter_chips: chips, available_filters: optional)
  end

  defp select_default(%{options: [{value, _label} | _]}), do: value
  defp select_default(_select), do: nil

  defp select_option_label(select, value) do
    case Enum.find(select.options, &(to_string(elem(&1, 0)) == value)) do
      {_value, label} -> label
      nil -> value
    end
  end

  defp filter_href(path, query, query_name, hidden, selects, reset_name) do
    params =
      [{query_name, query}]
      |> Kernel.++(hidden)
      |> Kernel.++(
        for select <- selects,
            select.name != reset_name,
            value = to_string(select.value || ""),
            value != to_string(select_default(select) || ""),
            do: {select.name, value}
      )
      |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  attr(:count, :integer, required: true)
  attr(:one, :string, required: true, doc: "Noun for exactly one, e.g. \"rule\"")
  attr(:many, :string, required: true, doc: "Noun for any other count, e.g. \"rules\"")

  @doc """
  The quiet count of what the list below actually holds after filtering —
  never a separate statistics area, and never a count computed over a wider
  set than the one on the page.
  """
  def result_count(assigns) do
    ~H"""
    <p :if={@count > 0} class="result-count">{@count} {if @count == 1, do: @one, else: @many}</p>
    """
  end

  # States arrive as the strings the projections cast and as the atoms the
  # schemas hold; both name the same word and tone.
  def label(value) when is_atom(value) and not is_nil(value), do: label(Atom.to_string(value))
  def label("pending"), do: "Queued"
  def label("working"), do: "Working"
  def label("not_started"), do: "Couldn’t start"
  def label("delivery_pending"), do: "Sending reply"
  def label("waiting_for_input"), do: "Needs your input"
  def label("waiting_for_event"), do: "Waiting for an event"
  def label("blocked"), do: "Needs attention"
  def label("complete"), do: "Completed"
  def label("cancelled"), do: "Stopped"
  def label("ignore"), do: "No response needed"
  def label("react"), do: "Reaction selected"
  def label("reply"), do: "Reply selected"
  def label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def tone(value) when is_atom(value) and not is_nil(value), do: tone(Atom.to_string(value))
  def tone(value) when value in ["blocked", "waiting_for_input", "not_started"], do: "attention"
  def tone(value) when value in ["working", "pending", "delivery_pending"], do: "active"
  def tone("complete"), do: "done"
  def tone(_), do: "quiet"

  def timestamp(%DateTime{} = value), do: Calendar.strftime(value, "%d %b, %H:%M UTC")
  def timestamp(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%d %b, %H:%M UTC")
  def timestamp(_), do: "Not recorded"

  def age(value, now) do
    case value do
      %DateTime{} -> duration(max(DateTime.diff(now, value), 0))
      %NaiveDateTime{} -> duration(max(NaiveDateTime.diff(DateTime.to_naive(now), value), 0))
      _ -> "—"
    end
  end

  defp duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  defp duration(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp duration(seconds), do: "#{div(seconds, 86_400)}d"
end

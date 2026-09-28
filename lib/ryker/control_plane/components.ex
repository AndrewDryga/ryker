defmodule Ryker.ControlPlane.Components do
  @moduledoc "Shared, accessible primitives for the operator workspace."
  use Phoenix.Component

  import Phoenix.HTML.Form, only: [options_for_select: 2]
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.JS
  alias Ryker.ControlPlane.Kit
  alias Ryker.Episodes.Words
  alias Ryker.Work.ExecutionTarget

  @icons %{
    activity: "M3 12h4l3-8 4 16 3-8h4",
    chat: "M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-6 3V6a2 2 0 0 1 2-2Z",
    smile:
      "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M8.5 14a4.5 4.5 0 0 0 7 0 M9 9.5h.01 M15 9.5h.01",
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
    help: "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3 M12 17h.01",
    settings: "M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6",
    grid: "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z",
    arrow_up: "M12 19V5 M6 11l6-6 6 6",
    arrow_left: "M19 12H5 M11 18l-6-6 6-6",
    arrow_down: "M12 5v14 M18 13l-6 6-6-6",
    copy: "M9 9h10v10H9z M5 5h10v4 M5 5v10h4",
    chevron: "m9 5 7 7-7 7",
    hash: "M5 9h14 M5 15h14 M10 3 8 21 M16 3l-2 18",
    repository:
      "M6 3v12 M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z M18 9a9 9 0 0 1-9 9",
    bolt: "M13 2 4 14h7l-1 8 9-12h-7l1-8Z",
    pen: "M4 20h4L18.5 9.5a2.1 2.1 0 0 0-3-3L5 17v3Z M13.5 6.5l3 3",
    plug: "M9 2v6 M15 2v6 M6 8h12v4a6 6 0 0 1-12 0V8Z M12 18v4",
    tag: "M3 3h8l10 10-8 8L3 11V3Z M7.5 7.5h.01",
    external: "M14 4h6v6 M20 4l-9 9 M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"
  }

  attr(:class, :any, default: nil)

  @doc """
  Emisar's mark, in its own two colours, for what Emisar did: its chevrons
  and circles in the text colour, the right chevron and the middle circle in
  Emisar green (#36e6a5), as Emisar's own logo draws them.
  """
  def emisar_mark(assigns) do
    ~H"""
    <svg class={["emisar-mark", @class]} viewBox="-18 0 390 390" fill="none" aria-hidden="true">
      <g stroke-linejoin="round" stroke-width="37">
        <path stroke="currentColor" d="M96 50 19.5 195 96 340" />
        <path class="emisar-accent" stroke="#36e6a5" d="m258 50 76.5 145L258 340" />
      </g>
      <path stroke="currentColor" stroke-width="16" d="M177 84v69m0 84v69" />
      <circle cx="177" cy="42.5" r="34.5" stroke="currentColor" stroke-width="14" />
      <circle class="emisar-accent" cx="177" cy="195" r="34.5" stroke="#36e6a5" stroke-width="14" />
      <circle cx="177" cy="347.5" r="34.5" stroke="currentColor" stroke-width="14" />
    </svg>
    """
  end

  attr(:name, :atom, required: true)
  attr(:class, :any, default: nil)

  def icon(assigns) do
    assigns = assign(assigns, :path, Map.get(@icons, assigns.name, @icons.activity))

    ~H"""
    <svg
      class={["ui-icon", @class]}
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

  attr(:label, :string, default: "Copy")
  slot(:inner_block, required: true)

  @doc """
  A block of exact text with a copy button in its top-right corner. The button
  copies what the block shows, so a large JSON document is one click away.
  """
  def copy_block(assigns) do
    ~H"""
    <div class="copy-block">
      <button
        type="button"
        class="copy-block-button"
        data-copy-block
        aria-label={@label}
        title={@label}
      >
        <.icon name={:copy} class="copy-block-idle" />
        <.icon name={:check} class="copy-block-done" />
        <span class="sr-only" data-copy-status aria-live="polite"></span>
      </button>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "`copy_block/1` for renderers that build HTML as iodata."
  def copy_block_html(body, label \\ "Copy") do
    %{__changed__: nil, label: label, inner_block: html_slot(:inner_block, body)}
    |> copy_block()
    |> Safe.to_iodata()
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
  attr(:kind, :atom, values: [:details, :diagnostic, :source], default: :details)
  attr(:open, :boolean, default: false)
  attr(:class, :any, default: nil)
  attr(:summary_aria_label, :string, default: nil)
  attr(:body_class, :any, default: nil)
  attr(:rest, :global)
  slot(:label_content, doc: "Optional title and count, using the same disclosure shell")
  slot(:meta, doc: "Status, type, or size aligned opposite a source title")
  slot(:inner_block, required: true)

  @doc "The shared disclosure shell for supporting detail and failure diagnostics."
  def disclosure(assigns) do
    ~H"""
    <details
      id={@id}
      class={["ui-disclosure", "ui-disclosure-#{@kind}", @class]}
      open={@open}
      {@rest}
    >
      <summary aria-label={@summary_aria_label}>
        <.icon name={:chevron} />
        <span class="ui-disclosure-label">{if @label_content == [],
          do: @label,
          else: render_slot(@label_content)}</span>
        <span :if={@meta != []} class="ui-disclosure-meta">{render_slot(@meta)}</span>
      </summary>
      <div class={["ui-disclosure-body", @body_class]}>{render_slot(@inner_block)}</div>
    </details>
    """
  end

  @doc "The same disclosure for sanitized iodata inspection views; body and slots must already be escaped."
  def disclosure_html(label, body, options \\ []) do
    %{
      __changed__: nil,
      id: options[:id],
      label: label,
      kind: options[:kind] || :details,
      class: options[:class],
      body_class: options[:body_class],
      open: options[:open] || false,
      rest: options[:rest] || %{},
      label_content: html_slot(:label_content, options[:label_content]),
      meta: html_slot(:meta, options[:meta]),
      inner_block: html_slot(:inner_block, body)
    }
    |> disclosure()
    |> Safe.to_iodata()
  end

  attr(:title, :string, default: nil)
  attr(:sender, :string, default: nil)

  attr(:person, :map,
    default: nil,
    doc: "A Slack person who sent it, from `Ryker.Slack.Names.person/2`, shown in place of sender"
  )

  attr(:context, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:meta, doc: "Message timestamp or delivery state, separate from its content")
  slot(:footer, doc: "Supporting details and controls, never the message itself")
  slot(:inner_block, required: true)

  @doc """
  One message, drawn as a message wherever it appears: an optional title, then
  the sender's name and time, the words in a bubble, and details below. A
  Slack person who sent it reads as `Kit.person/1` shows every person.
  """
  def message_block(assigns) do
    assigns = assign(assigns, :author, message_author(assigns.person || assigns.sender))

    ~H"""
    <article class={["ui-message", @class]} data-author={@author} {@rest}>
      <h3 :if={@title} class="ui-message-title">{@title}</h3>
      <header :if={@sender || @person || @context || @meta != []} class="ui-message-header">
        <strong :if={@person}><Kit.person person={@person} /></strong>
        <strong :if={@sender && !@person}>{@sender}</strong>
        <span :if={@context} class="ui-message-context">{@context}</span>
        <span :if={@meta != []} class="ui-message-meta">{render_slot(@meta)}</span>
      </header>
      <div class="ui-message-body markdown-preview">{render_slot(@inner_block)}</div>
      <footer :if={@footer != []} class="ui-message-footer">{render_slot(@footer)}</footer>
    </article>
    """
  end

  defp message_author(nil), do: nil
  defp message_author("Ryker"), do: "ryker"
  defp message_author(_sender), do: "person"

  @doc "The same message block for sanitized iodata views; body and slots must already be escaped."
  def message_block_html(sender, body, options \\ []) do
    %{
      __changed__: nil,
      title: options[:title],
      sender: sender,
      person: options[:person],
      context: options[:context],
      class: options[:class],
      rest: options[:rest] || %{},
      meta: html_slot(:meta, options[:meta]),
      footer: html_slot(:footer, options[:footer]),
      inner_block: html_slot(:inner_block, body)
    }
    |> message_block()
    |> Safe.to_iodata()
  end

  defp html_slot(_name, nil), do: []
  defp html_slot(_name, []), do: []

  defp html_slot(name, content),
    do: [%{__slot__: name, inner_block: fn _, _ -> Phoenix.HTML.raw(content) end}]

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
          <Kit.person :if={fact[:presentation] == :person} person={fact.value} />
          <span :if={!fact[:identifier] && fact[:presentation] not in [:execution_target, :person]}>
            {fact.value}
          </span>
        </dd>
      </div>
    </dl>
    """
  end

  attr(:title, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:meta_layout, :atom, values: [:inline, :stack_on_narrow], default: :inline)
  slot(:leading, doc: "A compact symbol that identifies the card kind")
  slot(:detail, doc: "Short title-adjacent context, never status or timing")
  slot(:description, doc: "A concise explanation that belongs directly to the title")
  slot(:meta, doc: "State, timing, or execution target aligned opposite the title")

  @doc "The shared title-left and metadata-right header for timeline cards."
  def card_heading(assigns) do
    ~H"""
    <header class={[
      "case-card-heading",
      @meta_layout == :stack_on_narrow && "case-card-heading-stack-meta",
      @class
    ]}>
      <div class="case-card-heading-copy">
        <div class="case-card-heading-main">
          <span :if={@leading != []} class="case-card-heading-leading">{render_slot(@leading)}</span>
          <h3>{@title}</h3>
          <span :if={@detail != []} class="case-card-heading-detail">{render_slot(@detail)}</span>
        </div>
        <p :if={@description != []} class="case-card-heading-description">
          {render_slot(@description)}
        </p>
      </div>
      <div :if={@meta != []} class="case-card-heading-meta">{render_slot(@meta)}</div>
    </header>
    """
  end

  attr(:title, :string, required: true)

  @doc """
  The new title an answer gave its request, on the card of that answer.

  Andrew, 2026-09-27, of a card that read "Request title Hello": "what is
  this? updating title of episode? maybe say that?" Only an answer that
  changed the title says so; one that kept it says nothing.
  """
  def title_update(assigns) do
    ~H"""
    <p class="title-update">
      <.icon name={:pen} />
      <span>Title updated to:</span>
      <strong>{@title}</strong>
    </p>
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
        assigns.state != nil -> {Words.label(assigns.state), tone(assigns.state)}
        true -> {nil, nil}
      end

    assigns = assign(assigns, label: assigns.label || label, tone: assigns.tone || tone)

    ~H"""
    <span class={"ui-status status-#{@tone}"}><i aria-hidden="true"></i>{@label}</span>
    """
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
      other -> {Words.label(other), "quiet"}
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

  attr(:path, :string, required: true)
  attr(:label, :string, required: true)
  attr(:tone, :any, default: :secondary)

  @doc """
  A button whose action asks first. In the live page it opens the question
  in `Kit.confirm_modal/1` over the page ("ask-action"); the modal's button
  posts the protected action. Before the page is live, and without
  JavaScript, the same button opens the action's confirmation page instead,
  as a GET form so it reads and works as a button.

  A browser replaces the query of a GET form's action with the form's own
  fields, so the query of `path`, such as `back`, the page the confirmation
  returns to, rides along as hidden fields. Before 2026-09-27 it was dropped,
  and Retry work on a request's timeline returned to Failures.
  """
  def action_button(assigns) do
    uri = URI.parse(assigns.path)

    assigns =
      assign(assigns,
        action: uri.path,
        fields: uri.query |> Kernel.||("") |> URI.decode_query() |> Enum.sort()
      )

    ~H"""
    <form
      class="action-control"
      method="get"
      action={@action}
      phx-submit={JS.push("ask-action", value: %{path: @path, label: @label})}
    >
      <input :for={{name, value} <- @fields} type="hidden" name={name} value={value} />
      <button type="submit" class={"ui-button #{@tone}"}>{@label}</button>
    </form>
    """
  end

  def action_button(path, label, tone \\ :secondary) do
    # GET only opens the existing confirmation; its protected POST performs the action.
    %{__changed__: nil, path: path, label: label, tone: tone}
    |> action_button()
    |> Safe.to_iodata()
  end

  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)

  attr(:back, :any,
    default: nil,
    doc: "{label, href} of the page a sub-page belongs to, such as {\"All topics\", path}"
  )

  attr(:navigate, :boolean,
    default: false,
    doc: "Inside the live shell, the way back opens without reloading"
  )

  attr(:status, :any,
    default: nil,
    doc: "{tone, word} of the page's own record, shown beside the title where it is seen first"
  )

  attr(:title_href, :string,
    default: nil,
    doc: "Where the record lives outside Ryker (a Slack channel); the title opens it"
  )

  slot(:action, doc: "A real page-level action that already exists; never a placeholder")

  @doc """
  The one heading of a secondary page.

  A sub-page's way back to the page it belongs to (`Kit.back/1`) comes
  first, above the title. The title renders once, an existing primary action
  may sit opposite it, and the page's short description sits 8px underneath.
  Everything the page owns follows in one column: optional help, one
  toolbar, a quiet count, the content, then related history. A body never
  renders a competing heading or a second description; the shell that mounts
  it is the only place a title comes from, so outer and inner titles cannot
  duplicate each other.
  """
  def page_header(assigns) do
    assigns =
      assigns
      |> assign_new(:description, fn -> nil end)
      |> assign_new(:back, fn -> nil end)
      |> assign_new(:navigate, fn -> false end)
      |> assign_new(:action, fn -> [] end)
      |> assign_new(:status, fn -> nil end)
      |> assign_new(:title_href, fn -> nil end)

    ~H"""
    <header class="page-header">
      <Kit.back
        :if={@back}
        label={elem(@back, 0)}
        href={elem(@back, 1)}
        navigate={@navigate}
      />
      <div class="page-heading">
        <div class="page-title-line">
          <h1 :if={!@title_href}>{@title}</h1>
          <h1 :if={@title_href}>
            <a
              href={@title_href}
              target="_blank"
              rel="noopener noreferrer"
              class="page-title-link"
            >{@title}<.icon name={:external} class="page-title-external" /></a>
          </h1>
          <Kit.state :if={@status} tone={elem(@status, 0)} word={elem(@status, 1)} />
        </div>
        <div :if={@action != []} class="page-action">{render_slot(@action)}</div>
      </div>
      <p :if={@description} class="page-description">{@description}</p>
    </header>
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

  A GET form, so the URL stays shareable and back/forward stay honest. In
  the live shell it searches as you type, the way Activity does: the shell
  patches the page to the form's own fields as they change ("search-page").
  Before the socket connects, and without JavaScript, it is a plain form: a
  dropdown submits it as soon as it changes (filter-toolbar.mjs) and search
  submits on Enter, so there is no Apply button. Labels stay bound to their
  controls for assistive technology while the placeholder and the chosen
  option carry the visible meaning.
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
    <form
      id={@id <> "-form"}
      class="filter-toolbar"
      method="get"
      action={@path}
      role="search"
      aria-label={@label}
      phx-change={JS.push("search-page", value: %{path: @path})}
      phx-submit={JS.push("search-page", value: %{path: @path})}
    >
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
          phx-debounce="300"
          autocomplete="off"
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

  # States arrive as the strings the projections cast and as the atoms the
  # schemas hold; both name the same tone. Their words are Episodes.Words.
  def tone(value) when is_atom(value) and not is_nil(value), do: tone(Atom.to_string(value))
  def tone(value) when value in ["blocked", "waiting_for_input", "not_started"], do: "attention"

  def tone(value) when value in ["working", "pending", "routing", "delivery_pending"],
    do: "active"

  # What routing did for a message that started no work, as a finished
  # request reads: its answer and its reaction were sent.
  def tone(value) when value in ["complete", "quick_reply", "react"], do: "done"
  def tone(_), do: "quiet"

  def timestamp(%DateTime{} = value), do: Calendar.strftime(value, "%d %b, %H:%M UTC")
  def timestamp(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%d %b, %H:%M UTC")
  def timestamp(_), do: "Not recorded"
end

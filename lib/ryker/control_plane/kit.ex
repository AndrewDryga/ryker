defmodule Ryker.ControlPlane.Kit do
  @moduledoc """
  The shared parts every page is built from, from Activity and Incident rooms
  to Channels, Automations, Memory, Usage and Settings: counts, the toolbar
  row, rows, tables, facts, states, section cards and empty states.

  One list language for all of them: rows sit on the page with faint
  separators, an icon tile for what kind of thing each one is, a name, then
  what it does, then one line of facts; its state, its time and its own
  controls sit at the far edge. A list ordered by time opens each day with a
  heading. State is a dot and a word, and tone lives only there and in the
  tile. A long page of several parts, such as a channel's page or an
  integration's, gives each part its own card, and a list that is one part
  of such a page keeps its rows inside that card. Anything with nothing to
  show says so with `empty/1`. String-rendered pages call these through
  `Phoenix.HTML.Safe.to_iodata/1` with `__changed__: nil`.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, ShortTime}

  attr(:id, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:rest, :global, doc: "Such as phx-update=\"stream\" for a LiveView stream of rows")
  slot(:inner_block, required: true)

  @doc "A list of rows."
  def entity_list(assigns) do
    ~H"""
    <div id={@id} class={["entity-list", @class]} role="list" aria-label={@label} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:id, :string, default: nil)
  attr(:name, :any, required: true, doc: "Text, or a rendered fragment such as a mention")
  attr(:href, :string, default: nil, doc: "Where the name leads, when the item has its own page")

  attr(:navigate, :boolean,
    default: false,
    doc: "Inside a LiveView, open href without reloading the page"
  )

  attr(:link_row, :boolean,
    default: false,
    doc: "The whole row opens href, for lists whose rows are a way into the item"
  )

  attr(:state, :any, default: nil, doc: "{tone, word}, see state/1")

  attr(:tag, :string,
    default: nil,
    doc: "One word that sets the item apart from its neighbours, such as Recommended"
  )

  attr(:text, :string, default: nil, doc: "What the item does or says, in its own words")

  attr(:meta, :list,
    default: [],
    doc:
      "Facts joined by a middle dot; {:strong, text} emphasises, {:link, text, href} opens " <>
        "an outside page in a new tab"
  )

  attr(:icon, :atom,
    default: nil,
    doc: "What kind of thing the row is, as a Components.icon name in a tile"
  )

  attr(:icon_tone, :atom, values: [:accent, :info, :warn, :bad, :off], default: :off)

  attr(:at, :string,
    default: nil,
    doc: "When, at the far edge: a clock time under a day heading, or a short date"
  )

  attr(:at_time, :any, default: nil, doc: "The exact time `at` names, for a pointer or a reader")
  attr(:group, :string, default: nil, doc: "The day heading this row opens, such as Today")
  attr(:class, :any, default: nil)
  slot(:actions)
  slot(:details, doc: "Anything under the facts, such as one disclosure")

  @doc """
  One row: the name, its state, what it does, and one line of facts.

  The name is the one thing always shown; everything else is optional, and
  an empty fact is dropped rather than shown as a placeholder. A row that is
  only a way into its item (`link_row`) opens it from anywhere on the row,
  while the name stays the one link assistive technology announces.
  """
  def entity_row(assigns) do
    assigns = assign(assigns, :meta, Enum.reject(assigns.meta, &(&1 in [nil, "", []])))

    ~H"""
    <article
      id={@id}
      class={[
        "entity-row",
        @link_row && @href && "entity-row-link",
        @group && "entity-row-grouped",
        @class
      ]}
      role="listitem"
    >
      <p :if={@group} class="entity-group" role="heading" aria-level="2">{@group}</p>
      <span :if={@icon} class="entity-icon" data-tone={@icon_tone} aria-hidden="true">
        <Components.icon name={@icon} />
      </span>
      <div class="entity-body">
        <h3 class="entity-name">
          <.link :if={@href && @navigate} navigate={@href}>{@name}</.link><a
            :if={@href && !@navigate}
            href={@href}
          >{@name}</a><span :if={!@href}>{@name}</span>
          <span :if={@tag} class="entity-tag">{@tag}</span>
        </h3>
        <p :if={@text} class="entity-text">{@text}</p>
        <p :if={@meta != []} class="entity-meta">
          <%= for {fact, index} <- Enum.with_index(@meta) do %>
            <span :if={index > 0} aria-hidden="true"> · </span><.fact value={fact} />
          <% end %>
        </p>
        {render_slot(@details)}
      </div>
      <div :if={@state || @at} class="entity-side">
        <.state :if={@state} tone={elem(@state, 0)} word={elem(@state, 1)} />
        <time
          :if={@at}
          class="entity-at"
          datetime={@at_time && iso(@at_time)}
          title={@at_time && ShortTime.full(utc(@at_time))}
        >{@at}</time>
      </div>
      <div :if={@actions != []} class="entity-actions">{render_slot(@actions)}</div>
    </article>
    """
  end

  @doc """
  The day headings of a list ordered newest first: the label of each item's
  day on the first item of that day, nil on the rest. `at` reads an item's
  time; days are UTC, like every time on these pages.
  """
  @spec day_groups([term()], (term() -> DateTime.t() | nil), DateTime.t()) :: [String.t() | nil]
  def day_groups(items, at, %DateTime{} = now) do
    today = DateTime.to_date(now)

    items
    |> Enum.map_reduce(nil, fn item, previous ->
      day = item |> at.() |> day()
      {if(day && day != previous, do: day_label(day, today)), day || previous}
    end)
    |> elem(0)
  end

  @doc "Today, Yesterday, a weekday within the week, then the date."
  @spec day_label(Date.t(), Date.t()) :: String.t()
  def day_label(day, today) do
    case Date.diff(today, day) do
      0 -> "Today"
      1 -> "Yesterday"
      days when days in 2..6 -> Calendar.strftime(day, "%A")
      _older when day.year == today.year -> Calendar.strftime(day, "%-d %B")
      _older -> Calendar.strftime(day, "%-d %B %Y")
    end
  end

  @doc "The clock time a row under a day heading shows: 08:33."
  @spec clock(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def clock(nil), do: nil
  def clock(at), do: at |> utc() |> Calendar.strftime("%H:%M")

  defp iso(at), do: at |> utc() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp day(nil), do: nil
  defp day(at), do: at |> utc() |> DateTime.to_date()

  defp utc(%DateTime{} = at), do: DateTime.shift_zone!(at, "Etc/UTC")
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  attr(:value, :any, required: true)

  defp fact(%{value: {:strong, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"<strong>{@text}</strong>"
  end

  defp fact(%{value: {:link, text, href}} = assigns) do
    assigns = assign(assigns, text: text, href: href)
    ~H'<a href={@href} target="_blank" rel="noopener noreferrer">{@text}</a>'
  end

  defp fact(assigns), do: ~H"{@value}"

  attr(:person, :map, required: true, doc: "A Slack person from `Ryker.Slack.Names.person/2`")
  attr(:class, :any, default: nil)

  @doc """
  A Slack person, the one way every page shows one: their name, opening their
  Slack profile in a new tab. Never a raw ID; until Slack has said the name it
  reads "Slack user", still linked, and the page draws again once it knows.
  """
  def person(assigns) do
    ~H"""
    <a
      :if={@person.href}
      class={["kit-person", @class]}
      href={@person.href}
      target="_blank"
      rel="noopener noreferrer"
    >{@person.name}</a><span :if={!@person.href} class={["kit-person", @class]}>{@person.name}</span>
    """
  end

  @doc "`person/1` for a page built as an HTML string."
  @spec person_html(map(), String.t() | nil) :: iodata()
  def person_html(person, class \\ nil),
    do: Safe.to_iodata(person(%{person: person, class: class, __changed__: nil}))

  attr(:people, :list, required: true, doc: "Slack people from `Ryker.Slack.Names.person/2`")
  attr(:more, :list, default: [], doc: "Words after the people in the same list, such as groups")

  @doc """
  Slack people in one line, each shown as `person/1` shows one, then anything
  else the same list holds: @Ann, @Bo, user group S1.
  """
  def people(assigns) do
    items = Enum.map(assigns.people, &{:person, &1}) ++ Enum.map(assigns.more, &{:words, &1})
    # Each item but the last carries its comma, so no space ever comes before one.
    commas = List.duplicate(",", max(length(items) - 1, 0)) ++ [""]
    assigns = assign(assigns, :items, Enum.zip(items, commas))

    ~H"""
    <%= for {{kind, item}, comma} <- @items do %>
      <.person :if={kind == :person} person={item} /><span :if={kind == :words}>{item}</span>{comma}
    <% end %>
    """
  end

  attr(:tone, :atom, values: [:on, :busy, :off, :warn, :bad], default: :off)
  attr(:word, :string, required: true)

  @doc """
  A dot and a word. `:on` is working as intended, `:busy` is doing something
  right now, `:off` is paused or finished, `:warn` needs a person and `:bad`
  failed. Only warn and bad colour the word itself.
  """
  def state(assigns) do
    ~H"""
    <span class="state-word" data-tone={@tone}>{@word}</span>
    """
  end

  attr(:title, :string, required: true)
  attr(:id, :string, default: nil)
  attr(:lede, :string, default: nil)
  slot(:actions)

  @doc "A section inside a page: a plain title, one sentence under it, optional controls."
  def section_head(assigns) do
    ~H"""
    <header class="section-head" id={@id}>
      <div>
        <h2>{@title}</h2>
        <p :if={@lede}>{@lede}</p>
      </div>
      <div :if={@actions != []} class="section-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr(:label, :string, required: true)
  attr(:options, :list, required: true, doc: "[{label, href, current?}]")

  attr(:patch, :boolean,
    default: false,
    doc: "Inside a LiveView, switch views without reloading the page"
  )

  @doc "A small set of mutually exclusive views, such as Current and Past."
  def segmented(assigns) do
    ~H"""
    <nav class="segmented" aria-label={@label}>
      <%= for {label, href, current} <- @options do %>
        <.link :if={@patch} patch={href} aria-current={if current, do: "page"}>{label}</.link>
        <a :if={!@patch} href={href} aria-current={if current, do: "page"}>{label}</a>
      <% end %>
    </nav>
    """
  end

  attr(:facts, :list, required: true, doc: "[{label, value}]; a missing value drops its line")
  attr(:id, :string, default: nil)
  attr(:class, :any, default: nil)

  @doc """
  A record's facts as label and value pairs, one pair per line: the label
  quiet, the value in text colour. A value may be a rendered fragment, such
  as a link or a state; a missing value is dropped, never shown as a dash.
  """
  def facts(assigns) do
    assigns =
      assign(
        assigns,
        :facts,
        Enum.reject(assigns.facts, fn {_label, value} -> value in [nil, false, "", []] end)
      )

    ~H"""
    <dl :if={@facts != []} id={@id} class={["kit-facts", @class]}>
      <div :for={{label, value} <- @facts}>
        <dt>{label}</dt>
        <dd>{value}</dd>
      </div>
    </dl>
    """
  end

  attr(:state, :any, required: true, doc: "{tone, word}, see state/1")
  attr(:id, :string, default: nil)
  slot(:inner_block, doc: "A few short facts on the same line, such as when it opened")

  @doc """
  One record's state under its page title: the dot and the word, then a
  few short facts on the same line.
  """
  def status_line(assigns) do
    ~H"""
    <p id={@id} class="kit-status-line">
      <.state tone={elem(@state, 0)} word={elem(@state, 1)} />{render_slot(@inner_block)}
    </p>
    """
  end

  attr(:icon, :atom, required: true, doc: "What would be here, as a Components.icon name")
  attr(:title, :string, required: true, doc: "What is missing, in a few words")
  attr(:text, :string, default: nil, doc: "One sentence: why, or what would put something here")

  attr(:variant, :atom,
    values: [:boxed, :hint, :bare],
    default: :boxed,
    doc: "Boxed for an empty page, list or table; hint for an empty part of a longer page"
  )

  attr(:id, :string, default: nil)
  slot(:inner_block, doc: "The one action that would put something here")

  @doc """
  What a page, list, table or section shows when it has nothing to show: an
  icon for what would be there, a title, one sentence and optionally the one
  action that would put something there, centred, so it reads as empty at a
  glance, before anyone reads it (Andrew, 2026-09-26: a bold line and a grey
  line looked like any other text on the page).

  `:boxed` is an empty page, list or table: a dashed box around it. `:hint`
  is an empty part of a longer page, such as one section of a channel's page:
  a smaller dashed box. `:bare` draws no box, for a place that already frames
  it, such as a raised panel.
  """
  def empty(assigns) do
    ~H"""
    <div id={@id} class="kit-empty" data-variant={@variant}>
      <span class="kit-empty-icon" aria-hidden="true"><Components.icon name={@icon} /></span>
      <p class="kit-empty-title">{@title}</p>
      <p :if={@text} class="kit-empty-text">{@text}</p>
      <div :if={@inner_block != []} class="kit-empty-actions">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "`empty/1` for a page built as an HTML string: icon, title, text and variant."
  @spec empty_html(keyword()) :: iodata()
  def empty_html(options) do
    %{__changed__: nil, id: nil, text: nil, variant: :boxed, inner_block: []}
    |> Map.merge(Map.new(options))
    |> empty()
    |> Safe.to_iodata()
  end

  attr(:title, :string, default: nil, doc: "Nil only for a page's one card, under the page title")
  attr(:lede, :string, default: nil, doc: "One sentence on what the part is for")
  attr(:id, :string, default: nil)
  attr(:anchor, :string, default: nil, doc: "The id other pages link to, on the title")
  attr(:label, :string, default: nil, doc: "What the part is, for a card without a title")
  attr(:class, :any, default: nil)
  slot(:actions, doc: "Controls for the whole part, such as Add, beside the title")
  slot(:inner_block, required: true, doc: "Its controls and their actions")

  @doc """
  One part of a long page in its own card: its title, one sentence, then its
  controls and their actions, with the same space between every card (Andrew,
  2026-09-26: Integrations › Slack and a channel's page read as "a huge blob
  of text"). A form's closing actions sit under a hairline.
  """
  def section_card(assigns) do
    ~H"""
    <section id={@id} class={["kit-card", @class]} aria-label={@label || @title}>
      <.section_head :if={@title} id={@anchor} title={@title} lede={@lede}>
        <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
      </.section_head>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr(:items, :list,
    required: true,
    doc: "[%{value: number or text, label: text, tone: :warn | :bad | nil, href: path or nil}]"
  )

  attr(:label, :string, default: "Summary")

  attr(:patch, :boolean,
    default: false,
    doc: "Inside a LiveView, a count that links to a path opens it without reloading"
  )

  attr(:secondary, :boolean,
    default: false,
    doc: "Figures that break down the counts above them, in smaller type"
  )

  @doc """
  The few numbers a page leads with, each a count and what it counts: "2
  failures · 2 affected requests". A count that needs a person takes the warn
  tone; a count can link to the list it summarises. A list page says how many
  things it lists here and nowhere else, first, as `list_total/3` words it.
  """
  def counts(assigns) do
    ~H"""
    <p class={["kit-counts", @secondary && "kit-counts-secondary"]} aria-label={@label}>
      <%= for item <- @items do %>
        <.link
          :if={@patch && patch?(item[:href])}
          class="kit-count"
          patch={item.href}
          data-tone={item[:tone]}
        >
          <b>{item.value}</b> {item.label}
        </.link>
        <a
          :if={item[:href] && !(@patch && patch?(item.href))}
          class="kit-count"
          href={item.href}
          data-tone={item[:tone]}
        >
          <b>{item.value}</b> {item.label}
        </a>
        <span :if={!item[:href]} class="kit-count" data-tone={item[:tone]}>
          <b>{item.value}</b> {item.label}
        </span>
      <% end %>
    </p>
    """
  end

  # Only a path is a view of the same LiveView; "#section" stays an anchor.
  defp patch?("/" <> _path), do: true
  defp patch?(_href), do: false

  @doc """
  A list page's first count: how many things the list holds, with their noun
  ("18 requests"), or how many match once a search or a filter narrows it ("5
  matching"), so a narrowed list never reads as everything there is.
  """
  @spec list_total(non_neg_integer(), {String.t(), String.t()}, boolean()) :: map()
  def list_total(count, _nouns, true = _narrowed), do: %{value: count, label: "matching"}
  def list_total(1, {one, _many}, false), do: %{value: 1, label: one}
  def list_total(count, {_one, many}, false), do: %{value: count, label: many}

  attr(:id, :string, default: nil)
  slot(:inner_block, required: true, doc: "The page's filter_toolbar and segmented controls")

  @doc """
  One row above a list: its search, its view switch, then any custom
  filters. Every list page uses this row, so they line up. It holds no
  numbers: how many things the list holds is the first of the page's
  `counts/1`, said once.
  """
  def toolbar(assigns) do
    ~H"""
    <div id={@id} class="kit-toolbar">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:id, :string, default: nil)
  attr(:label, :string, required: true, doc: "What the table lists, for assistive technology")
  attr(:class, :any, default: nil)

  slot :col, required: true do
    attr(:label, :string, required: true)
    attr(:numeric, :boolean, doc: "Right-aligned, tabular figures")
  end

  @doc """
  Data that is compared across rows, such as usage by model, and only that:
  a list of things uses entity rows instead. No frame; a quiet header; figures
  right-aligned in tabular numerals; the first column names the row.
  """
  def table(assigns) do
    ~H"""
    <div class={["kit-table-wrap", @class]}>
      <table class="kit-table" id={@id} aria-label={@label}>
        <thead>
          <tr>
            <th :for={col <- @col} scope="col" data-numeric={col[:numeric] && "true"}>
              {col.label}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td :for={col <- @col} data-numeric={col[:numeric] && "true"}>
              {render_slot(col, row)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:id, :string, required: true, doc: "The status region's id, one per setting")

  attr(:key, :any,
    default: nil,
    doc:
      "Which save it confirms, new for every save, so a second save shows it again; nil says nothing"
  )

  attr(:note, :string,
    default: nil,
    doc: "What else to know about the save, such as a copy in Slack it could not update; it stays"
  )

  @doc """
  What a setting that saves as it changes says once it saved: a small check
  and "Saved" beside it that fades by itself (Andrew, 2026-09-27: "you can
  save on change no need to add button, and edit confirmation can be way more
  subtle"). The region stays in the page so a reader hears each save. A save
  with a note, such as Slack's copy of the setting left behind, says both on
  one quiet line of its own that stays. A refusal is never this: it is
  `Components.form_feedback/1` in the error tone, and it stays.
  """
  def saved(assigns) do
    ~H"""
    <span id={@id} class="kit-saved" role="status"><span
      :if={@key}
      id={"#{@id}-#{@key}"}
      class={["kit-saved-mark", @note && "kit-saved-noted"]}
    ><Components.icon name={:check} />Saved<span :if={@note} class="kit-saved-note">. {@note}</span></span></span>
    """
  end

  @doc "`saved/1` for a page built as an HTML string."
  @spec saved_html(keyword()) :: iodata()
  def saved_html(options) do
    %{__changed__: nil, key: nil, note: nil}
    |> Map.merge(Map.new(options))
    |> saved()
    |> Safe.to_iodata()
  end
end

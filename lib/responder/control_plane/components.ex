defmodule Responder.ControlPlane.Components do
  @moduledoc "Shared, accessible primitives for the operator workspace."
  use Phoenix.Component

  import Phoenix.HTML.Form, only: [options_for_select: 2]
  alias Phoenix.HTML.Safe

  @icons %{
    activity: "M3 12h4l3-8 4 16 3-8h4",
    chat: "M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-6 3V6a2 2 0 0 1 2-2Z",
    cards: "M4 7h13v14H4z M8 3h13v14 M4 12h13",
    incident: "M12 3 2 21h20L12 3Z M12 9v5 M12 17v1",
    clock: "M12 8v5l3 2 M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0",
    search: "M20 20l-5-5 M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0",
    arrow: "M5 12h14 M13 6l6 6-6 6",
    plus: "M12 5v14 M5 12h14",
    check: "m5 12 4 4L19 6",
    usage: "M4 20h17 M6 16v-5 M12 16V4 M18 16V8",
    book: "M12 5v16 M3 3l9 2 9-2v16l-9 2-9-2V3Z",
    settings: "M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6",
    grid: "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z",
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

  def status(assigns) do
    ~H"""
    <span class={"ui-status status-#{tone(@state)}"}><i aria-hidden="true"></i>{label(@state)}</span>
    """
  end

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

  attr(:id, :string, required: true)
  attr(:label, :string, required: true, doc: "Specific, e.g. \"How to add and manage rules\"")
  slot(:inner_block, required: true)

  @doc """
  Longer help that expands below the description, never in a side column.

  It starts closed. The id lets the reading-state hook keep it open across a
  live refresh. Scope or authority warnings that a reader must not miss do
  not belong in here; they stay visible in the description or the content.
  """
  def page_help(assigns) do
    ~H"""
    <details class="page-help" id={@id}>
      <summary>{@label}</summary>
      <div class="page-help-body">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr(:id, :string, required: true)
  attr(:path, :string, required: true)
  attr(:label, :string, required: true, doc: "Accessible name, e.g. \"Filter standing rules\"")
  attr(:placeholder, :string, required: true)
  attr(:query, :string, default: "")
  attr(:filtered, :boolean, default: false)

  attr(:selects, :list,
    default: [],
    doc:
      "Dropdowns as %{id, name, label, value, options: [{value, text}]}; each applies on change"
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
      |> assign_new(:selects, fn -> [] end)

    ~H"""
    <form class="filter-toolbar" method="get" action={@path} role="search" aria-label={@label}>
      <label class="sr-only" for={@id}>{@placeholder}</label>
      <input
        type="search"
        id={@id}
        name="q"
        maxlength="200"
        value={@query || ""}
        placeholder={@placeholder}
      />
      <%= for select <- @selects do %>
        <label class="sr-only" for={select.id}>{select.label}</label>
        <select id={select.id} name={select.name}>
          {options_for_select(
            Enum.map(select.options, fn {value, text} -> {text, value} end),
            select.value
          )}
        </select>
      <% end %>
      <a :if={@filtered} class="filter-clear" href={@path}>Clear filters</a>
      <noscript><button type="submit" class="ui-button secondary">Apply</button></noscript>
    </form>
    """
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
    <p class="result-count">{@count} {if @count == 1, do: @one, else: @many}</p>
    """
  end

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

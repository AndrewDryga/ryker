defmodule Ryker.ControlPlane.MemoryFormat do
  @moduledoc """
  The small words and rows the four Memory pages share: counts, short times
  with the exact instant a hover away, links inside a row's facts, a readable
  excerpt of a learned text, its Markdown view, and a list row whose body can
  hold more than one line of text.

  A fact in a row is plain text, `{:strong, text}`, or safe HTML built here,
  so a link or a time inside the facts line is escaped once, in one place.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, ShortTime, SlackMarkdown}

  @excerpt_limit 280
  @protected ~r/(```[\s\S]*?```|`[^`\n]+`|<[^>\n]+>|\[[^\]\n]+\]\([^\s)]+\)|https?:\/\/[^\s<>]+)/u

  @doc ~s(A count with its noun: "1 message" or "3 messages".)
  @spec count(integer(), String.t(), String.t()) :: String.t()
  def count(1, one, _many), do: "1 " <> one
  def count(count, _one, many), do: "#{count} #{many}"

  @doc "A short time with its exact UTC instant in `datetime` and `title`; nil without one."
  def time(at, prefix \\ nil)
  def time(nil, _prefix), do: nil

  def time(at, prefix) do
    {:safe, Safe.to_iodata(ShortTime.time(%{__changed__: nil, at: at, prefix: prefix}))}
  end

  @doc "How long something has waited, e.g. \"3 days\", exact instant in its title."
  def waited(nil), do: nil

  def waited(%DateTime{} = at) do
    seconds = max(0, DateTime.diff(DateTime.utc_now(), at))

    words =
      cond do
        seconds < 60 -> "under a minute"
        seconds < 3_600 -> count(div(seconds, 60), "minute", "minutes")
        seconds < 86_400 -> count(div(seconds, 3_600), "hour", "hours")
        true -> count(div(seconds, 86_400), "day", "days")
      end

    {:safe,
     [
       "<time datetime=\"",
       DateTime.to_iso8601(at),
       "\" title=\"",
       escape(ShortTime.full(at)),
       "\">",
       escape(words),
       "</time>"
     ]}
  end

  @doc "A link inside a facts line; nil when there is nowhere to go."
  def link(_label, nil), do: nil
  def link(label, href), do: {:safe, ["<a href=\"", escape(href), "\">", escape(label), "</a>"]}

  @doc "A link that leaves Ryker, such as the original Slack message, in a new tab."
  def external(_label, nil), do: nil

  def external(label, "/" <> _ = href), do: link(label, href)

  def external(label, href),
    do:
      {:safe,
       [
         "<a href=\"",
         escape(href),
         "\" target=\"_blank\" rel=\"noopener noreferrer\">",
         escape(label),
         " ↗</a>"
       ]}

  @doc "Words with one reference emphasised, e.g. \"In <strong>#payments</strong>\"."
  def with_ref(prefix, ref), do: {:safe, [escape(prefix), "<strong>", escape(ref), "</strong>"]}

  @doc "Slack Markdown as safe block HTML, resolving bare Slack people IDs in a known workspace."
  def markdown(nil, _workspace), do: nil

  def markdown(text, workspace),
    do: {:safe, text |> people(workspace) |> SlackMarkdown.preview(workspace)}

  @doc """
  One line of Slack Markdown as safe inline HTML, for a name or a single
  sentence. Without a workspace it reads mentions in the connected one.
  """
  def inline(text), do: if(is_binary(text), do: {:safe, SlackMarkdown.render(text)})

  def inline(nil, _workspace), do: nil

  def inline(text, workspace),
    do: {:safe, text |> people(workspace) |> SlackMarkdown.render(workspace)}

  @doc """
  The opening words of a learned text as plain text for a clamped row line:
  mentions become names, Markdown marks and list bullets are dropped, and a
  long text ends at a word with an ellipsis. The full text is one click away.
  """
  def excerpt(nil, _workspace), do: nil

  def excerpt(text, workspace) do
    text
    |> people(workspace)
    |> plain(workspace)
    |> String.replace(~r/```[a-z]*/u, "")
    |> String.replace(~r/\[([^\]\n]+)\]\(https?:\/\/[^\s)]+\)/u, "\\1")
    |> String.replace(~r/<(https?:\/\/[^|>\s]+)\|([^>\n]+)>/u, "\\2")
    |> String.replace(~r/<(https?:\/\/[^>\s]+)>/u, "\\1")
    |> String.split("\n")
    |> Enum.map(&line/1)
    |> Enum.reject(fn {_kind, words} -> words == "" end)
    |> Enum.reduce({"", nil}, &join_line/2)
    |> elem(0)
    |> clip()
    |> case do
      "" -> nil
      excerpt -> excerpt
    end
  end

  defp plain(text, nil), do: text
  defp plain(text, workspace), do: SlackMarkdown.plain(text, workspace)

  # One line of the text without its Markdown marks, and whether it was a
  # list item: two items must not read as one run-on sentence.
  defp line(text) do
    {kind, text} =
      case Regex.run(~r/\A\s*(?:[-*•]|\d+\.)\s+(.*)\z/u, text) do
        [_, item] -> {:item, item}
        nil -> {:line, text}
      end

    words =
      text
      |> String.replace(~r/\*{1,2}([^*\n]+)\*{1,2}/u, "\\1")
      |> String.replace(~r/~([^~\n]+)~/u, "\\1")
      |> String.replace("`", "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    {kind, words}
  end

  defp join_line({kind, words}, {"", _previous}), do: {words, kind}

  defp join_line({kind, words}, {text, previous}) do
    separator =
      if :item in [kind, previous] and not Regex.match?(~r/[.!?:;]\z/u, text),
        do: ". ",
        else: " "

    {text <> separator <> words, kind}
  end

  defp clip(text) do
    if String.length(text) <= @excerpt_limit do
      text
    else
      clipped = String.slice(text, 0, @excerpt_limit)

      case Regex.run(~r/\A(.*\S)\s+\S*\z/su, clipped) do
        [_, words] -> words <> "…"
        nil -> clipped <> "…"
      end
    end
  end

  # Model summaries often attribute a message by a bare Slack user ID. In a
  # known workspace it becomes a mention; code, links and existing mentions
  # keep their exact bytes.
  defp people(text, nil), do: text

  defp people(text, _workspace) do
    @protected
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      if Regex.match?(@protected, part),
        do: part,
        else: Regex.replace(~r/\b[UW][A-Z0-9]{8,}\b/, part, &"<@#{&1}>")
    end)
  end

  attr(:id, :string, default: nil)
  attr(:name, :any, required: true, doc: "The row's name: text or safe inline HTML")
  attr(:href, :string, default: nil)
  attr(:state, :any, default: nil, doc: "{tone, word}, as Kit.state/1")
  attr(:icon, :atom, default: nil, doc: "What kind of thing the row is, as Kit.entity_row/1")
  attr(:meta, :list, default: [])
  attr(:class, :any, default: nil)
  slot(:inner_block, doc: "What the item says, between its name and its facts")
  slot(:notes, doc: "Anything under the facts")
  slot(:actions)

  @doc """
  A Kit row whose body is more than one line: a Markdown text, a summary's
  short lists. It renders the Kit's own classes, so it reads and spaces
  exactly like `Kit.entity_row/1` beside it.
  """
  def row(assigns) do
    assigns = assign(assigns, :meta, Enum.reject(assigns.meta, &(&1 in [nil, "", []])))

    ~H"""
    <article id={@id} class={["entity-row", @class]} role="listitem">
      <span :if={@icon} class="entity-icon" aria-hidden="true">
        <Ryker.ControlPlane.Components.icon name={@icon} />
      </span>
      <div class="entity-body">
        <h3 class="entity-name">
          <a :if={@href} href={@href}>{@name}</a><span :if={!@href}>{@name}</span>
        </h3>
        {render_slot(@inner_block)}
        <.facts :if={@meta != []} facts={@meta} />
        {render_slot(@notes)}
      </div>
      <div :if={@state} class="entity-side">
        <Kit.state tone={elem(@state, 0)} word={elem(@state, 1)} />
      </div>
      <div :if={@actions != []} class="entity-actions">{render_slot(@actions)}</div>
    </article>
    """
  end

  attr(:facts, :list, required: true)
  attr(:class, :any, default: nil)

  @doc "One line of facts joined by a middle dot; an empty fact is dropped."
  def facts(assigns) do
    assigns = assign(assigns, :facts, Enum.reject(assigns.facts, &(&1 in [nil, "", []])))

    ~H"""
    <p :if={@facts != []} class={["entity-meta", @class]}>
      <%= for {fact, index} <- Enum.with_index(@facts) do %>
        <span :if={index > 0} aria-hidden="true"> · </span>{fact_html(fact)}
      <% end %>
    </p>
    """
  end

  defp fact_html({:strong, text}), do: {:safe, ["<strong>", escape(text), "</strong>"]}
  defp fact_html(value), do: value

  defp escape(value), do: value |> to_string() |> Plug.HTML.html_escape()
end

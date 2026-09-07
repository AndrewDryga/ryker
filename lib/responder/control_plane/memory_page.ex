defmodule Responder.ControlPlane.MemoryPage do
  @moduledoc false
  use Phoenix.Component
  alias Responder.ControlPlane.SlackMarkdown

  def render(assigns) do
    ~H"""
    <section class="conversation-memory" aria-label="Learned from conversations">
      <nav class="memory-totals" aria-label="Conversation memory views">
        <a
          :for={
            {kind, label} <- [
              {"knowledge", "Current knowledge"},
              {"notes", "Conversation notes"},
              {"summaries", "Conversation summaries"}
            ]
          }
          href={path(@view, kind, 1)}
          aria-current={if @view.kind == kind, do: "page"}
        >
          <span>{label}</span><strong>{Map.fetch!(@view.counts, String.to_existing_atom(kind))}</strong>
        </a>
      </nav>
      <form class="search-form" method="get" action="/memory">
        <input type="hidden" name="kind" value={@view.kind} />
        <div class="filter-field filter-search">
          <label for="memory-search">Search</label>
          <input
            id="memory-search"
            type="search"
            name="q"
            value={@view.q}
            maxlength="200"
            placeholder="Topics, decisions or context"
          />
        </div>
        <button type="submit" class="ui-button primary">Search</button>
        <a
          :if={@view.q != ""}
          class="ui-button secondary"
          href={path(%{@view | q: ""}, @view.kind, 1)}
        >Clear search</a>
      </form>
      <p :if={@view.selected}><a href={path(@view, "knowledge", 1)}>← All knowledge</a></p>
      <p :if={@view.total == 0} class="empty-state">
        {if @view.q != "", do: "No matching conversation memory.", else: "Nothing learned here yet."}
      </p>
      <div class="memory-cards">
        <article :for={item <- @view.items} class="memory-card" id={"memory-#{item.id}"}>
          <header>
            <h2>{if item.title == "", do: item.conversation, else: item.title}</h2>
            <time datetime={DateTime.to_iso8601(item.at)}>{Calendar.strftime(
              item.at,
              "%d %b, %H:%M UTC"
            )}</time>
          </header>
          <p class="memory-source"><a href={item.conversation_path}>{item.conversation}</a>
            <span :if={item.repository}>{item.repository}</span></p>
          <p :if={Map.get(item, :available) == false} class="memory-unavailable">
            Not used for recall · a supporting source changed, was removed, or expired.
            A new source can rebuild this topic; its history remains below.
          </p>
          <div class="markdown-preview">{Phoenix.HTML.raw(preview(item.text, item.workspace))}</div>
          <div :for={{label, values} <- item.groups} class="memory-facts">
            <h3>{label}</h3><ul>
              <li :for={value <- values}>{Phoenix.HTML.raw(preview(value, item.workspace))}</li>
            </ul>
          </div>
          <footer>
            <span :if={Map.has_key?(item, :source_count)}>{item.source_count} sources</span>
            <a
              :if={Map.has_key?(item, :version)}
              href={"/memory?" <> URI.encode_query(%{"kind" => "knowledge", "item" => item.id})}
            >
              Update history · {item.version} {if item.version == 1, do: "revision", else: "revisions"} →
            </a>
            <a :if={item.source} href={item.source} rel="noopener noreferrer">Source message →</a>
            <a :if={item.request_path} href={item.request_path}>Source request →</a>
            <span class="memory-expiry">Retention: {if item.expires_at,
              do: "until " <> Calendar.strftime(item.expires_at, "%d %b %Y"),
              else: "automatic expiry is not configured"}</span>
          </footer>
        </article>
      </div>
      <section :if={@view.history != []} class="knowledge-history" aria-label="Update history">
        <h2>Update history</h2>
        <p>
          Each update preserves what was known then. Source times are separate from when Responder learned it.
        </p>
        <ol>
          <li :for={revision <- @view.history}>
            <header>
              <strong>Update {revision.version}</strong>
              <time datetime={DateTime.to_iso8601(revision.at)}>{Calendar.strftime(
                revision.at,
                "%d %b, %H:%M UTC"
              )}</time>
            </header>
            <div class="markdown-preview">{Phoenix.HTML.raw(preview(revision.text, nil))}</div>
            <small>Source message · {Calendar.strftime(revision.source_at, "%d %b %Y, %H:%M UTC")}</small>
            <a :if={revision.source} href={revision.source} rel="noopener noreferrer">Open source →</a>
            <a :if={revision.learning_path} href={revision.learning_path}>How this was learned →</a>
          </li>
        </ol>
        <nav :if={@view.history_pages > 1} class="pagination" aria-label="Update history pages">
          <a :if={@view.history_page > 1} href={history_path(@view, @view.history_page - 1)}>← Newer updates</a>
          <span>Page {@view.history_page} of {@view.history_pages}</span>
          <a
            :if={@view.history_page < @view.history_pages}
            href={history_path(@view, @view.history_page + 1)}
          >Older updates →</a>
        </nav>
      </section>
      <Responder.ControlPlane.LearningReceipt.render :if={@view.learning} receipt={@view.learning} />
      <nav :if={@view.pages > 1} class="pagination" aria-label="Memory pages">
        <a :if={@view.page > 1} href={path(@view, @view.kind, @view.page - 1)}>← Previous</a>
        <span>Page {@view.page} of {@view.pages}</span>
        <a :if={@view.page < @view.pages} href={path(@view, @view.kind, @view.page + 1)}>Next →</a>
      </nav>
    </section>
    """
  end

  defp path(view, kind, page),
    do: "/memory?" <> URI.encode_query(%{"kind" => kind, "q" => view.q, "page" => page})

  defp history_path(view, page),
    do:
      "/memory?" <>
        URI.encode_query(%{
          "kind" => "knowledge",
          "item" => view.selected,
          "history_page" => page
        })

  defp preview(text, workspace) do
    # Attribution commonly arrives as a bare Slack user ID in model summaries.
    text =
      if workspace,
        do: resolve_bare_people(text),
        else: text

    SlackMarkdown.preview(text, workspace)
  end

  defp resolve_bare_people(text) do
    # Code and existing Slack/Markdown links must retain their exact source bytes.
    protected =
      ~r/(```[\s\S]*?```|`[^`\n]+`|<[^>\n]+>|\[[^\]\n]+\]\([^\s)]+\)|https?:\/\/[^\s<>]+)/u

    protected
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      if Regex.match?(protected, part),
        do: part,
        else: Regex.replace(~r/\b[UW][A-Z0-9]{8,}\b/, part, &mention/1)
    end)
  end

  defp mention(id), do: "<@#{id}>"
end

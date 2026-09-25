defmodule Ryker.ControlPlane.LearnedPage do
  @moduledoc """
  Learned (`/memory/learned`): the topics Ryker keeps current by reading
  conversations, and the summaries it saves when work in a conversation ends,
  each with the messages it learned from.

  One topic opens in place with its full text, its update history, how each
  update was learned and, when its sources are gone, the picker that relearns
  it from messages a person chooses. A record's source messages open the same
  way, under the record they support.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [filter_toolbar: 1, pager: 1]

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    ConversationMemory,
    Kit,
    LearningReceipt,
    MemoryFormat,
    RelearnPanel
  }

  @unused "Ryker stopped using this in answers because a message it learned from changed, was removed or expired."

  @doc "The query keys the Learned page reads."
  def query_keys, do: ConversationMemory.query_keys()

  @doc "The Learned body for a `ConversationMemory` view."
  @spec html(map(), String.t() | nil) :: iodata()
  def html(view, csrf_secret) do
    %{__changed__: nil, view: view, csrf_secret: csrf_secret}
    |> render()
    |> Safe.to_iodata()
  end

  def render(assigns) do
    ~H"""
    <div class="memory-view memory-learned">
      <.sources :if={@view.kind == "sources"} view={@view} />
      <.topic
        :if={@view.kind == "knowledge" and not is_nil(@view.selected)}
        view={@view}
        csrf_secret={@csrf_secret}
      />
      <.topics :if={@view.kind == "knowledge" and is_nil(@view.selected)} view={@view} />
      <.summaries :if={@view.kind == "context"} view={@view} />
    </div>
    """
  end

  defp topics(assigns) do
    assigns = assign(assigns, :unused, @unused)

    ~H"""
    <.tools view={@view} />
    <Kit.entity_list :if={@view.items != []} class="memory-excerpts" label="Topics">
      <Kit.entity_row
        :for={item <- @view.items}
        id={"topic-" <> item.id}
        icon={:book}
        name={item.title}
        href={ConversationMemory.topic_path(item.id)}
        state={if item.available == false, do: {:warn, "Not used"}}
        text={MemoryFormat.excerpt(item.text, item.workspace)}
        meta={topic_facts(item, :list)}
      >
        <:details :if={item.available == false}>
          <p class="memory-note">
            {@unused}
            <a href={ConversationMemory.topic_path(item.id) <> "#relearn"}>Relearn it</a>
          </p>
        </:details>
      </Kit.entity_row>
    </Kit.entity_list>
    <.nothing view={@view} />
    <.pager
      page={@view.page}
      pages={@view.pages}
      path={&list_path(@view, "knowledge", &1)}
      label="Topic pages"
    />
    """
  end

  defp summaries(assigns) do
    ~H"""
    <.tools view={@view} />
    <div
      :if={@view.items != []}
      class="entity-list memory-excerpts"
      role="list"
      aria-label="Conversation summaries"
    >
      <MemoryFormat.row
        :for={item <- @view.items}
        id={"summary-" <> item.id}
        name={item.title}
        state={if summary_warning(item), do: {:warn, "Not used"}}
        meta={[
          MemoryFormat.link(item.conversation, item.conversation_path),
          item.repository,
          MemoryFormat.time(item.changed_at, "Updated "),
          MemoryFormat.time(item.source_at, "Latest message "),
          retention(item),
          source_link(item),
          MemoryFormat.link("Open request", item.request_path)
        ]}
      >
        <p :if={item.text not in [nil, ""]} class="entity-text">
          {MemoryFormat.excerpt(item.text, item.workspace)}
        </p>
        <div :if={item.groups != []} class="memory-summary-groups">
          <div :for={{label, values} <- item.groups}>
            <p class="memory-summary-label">{label}</p>
            <ul>
              <li :for={value <- values}>{MemoryFormat.inline(value, item.workspace)}</li>
            </ul>
          </div>
        </div>
        <:notes>
          <p :if={summary_warning(item)} class="memory-note">{summary_warning(item)}</p>
          <p :if={item[:maintenance_error]} class="memory-note">
            Ryker could not update this summary: {item.maintenance_error}
            <span :if={item[:maintenance_retry_at]}>
              {MemoryFormat.time(item.maintenance_retry_at, "Next try ")}.
            </span>
          </p>
        </:notes>
      </MemoryFormat.row>
    </div>
    <.nothing view={@view} />
    <.pager
      page={@view.page}
      pages={@view.pages}
      path={&list_path(@view, "context", &1)}
      label="Summary pages"
    />
    """
  end

  defp topic(assigns) do
    assigns = assign(assigns, item: List.first(assigns.view.items), unused: @unused)

    ~H"""
    <p class="memory-back"><a href={list_path(@view, "knowledge", 1)}>← All topics</a></p>
    <%= if @item do %>
      <article class="memory-record" id={"topic-" <> @item.id}>
        <h2 class="memory-record-title">
          <span>{@item.title}</span>
          <Kit.state :if={@item.available == false} tone={:warn} word="Not used" />
        </h2>
        <div class="memory-record-text markdown-preview">
          {MemoryFormat.markdown(@item.text, @item.workspace)}
        </div>
        <MemoryFormat.facts facts={topic_facts(@item, :record)} />
        <p :if={@item.available == false} class="memory-note">
          {@unused} Relearn it below from the messages that still exist.
        </p>
      </article>
      <RelearnPanel.render :if={@view.rebuild} preview={@view.rebuild} csrf_secret={@csrf_secret} />
      <section :if={@view.history != []} id="history" class="memory-section">
        <Kit.section_head
          title="Update history"
          lede="Each update keeps what Ryker knew at that time. A message’s time is when it was said, not when Ryker read it."
        />
        <div class="entity-list" role="list" aria-label="Updates">
          <MemoryFormat.row
            :for={revision <- @view.history}
            id={"update-#{revision.version}"}
            name={"Update #{revision.version}"}
            meta={[
              MemoryFormat.time(revision.at, "Learned "),
              MemoryFormat.time(revision.source_at, "From a message "),
              MemoryFormat.external("Open message", revision.source),
              MemoryFormat.link("How this was learned", revision.learning_path)
            ]}
          >
            <div class="entity-text markdown-preview">
              {MemoryFormat.markdown(revision.text, @item.workspace)}
            </div>
          </MemoryFormat.row>
        </div>
        <.pager
          page={@view.history_page}
          pages={@view.history_pages}
          path={&history_path(@view, &1)}
          label="Update history pages"
          earlier="← Newer updates"
          later="Older updates →"
        />
      </section>
      <LearningReceipt.render :if={@view.learning} receipt={@view.learning} />
    <% else %>
      <Kit.empty
        title="This topic is not available"
        text="It may have been removed when the messages it came from expired. All topics shows what Ryker knows now."
      />
    <% end %>
    """
  end

  defp sources(assigns) do
    ~H"""
    <p class="memory-back">
      <a href={@view.source_parent.back_path}>← {@view.source_parent.back_label}</a>
    </p>
    <Kit.section_head
      title={"Messages behind “#{@view.source_parent.title}”"}
      lede="What Ryker learned this from. Each message opens where it was said."
    />
    <Kit.toolbar>
      <.filter_toolbar
        id="learned-search"
        path="/memory/learned"
        label="Search these messages"
        placeholder="Search these messages"
        query={@view.q}
        filtered={@view.q != ""}
        hidden={[{"kind", "sources"}, {"related_to", @view.related_to}]}
        clear={sources_path(@view.related_to, "")}
      />
    </Kit.toolbar>
    <div :if={@view.items != []} class="entity-list" role="list" aria-label="Source messages">
      <MemoryFormat.row
        :for={item <- @view.items}
        id={"source-" <> item.id}
        name={item.conversation}
        href={item.conversation_path}
        meta={[
          MemoryFormat.time(item.at),
          MemoryFormat.external("Open message", item.source),
          MemoryFormat.link("Open request", item.request_path),
          retention(item)
        ]}
      >
        <div class="entity-text markdown-preview">
          {MemoryFormat.markdown(item.text, item.workspace)}
        </div>
      </MemoryFormat.row>
    </div>
    <.nothing view={@view} />
    <.pager
      page={@view.page}
      pages={@view.pages}
      path={&sources_path(@view.related_to, @view.q, &1)}
      label="Source message pages"
    />
    """
  end

  # The one search box and the two views, on one line above the list.
  defp tools(assigns) do
    ~H"""
    <Kit.toolbar>
      <.filter_toolbar
        id="learned-search"
        path="/memory/learned"
        label="Search what Ryker learned"
        placeholder={if @view.kind == "context", do: "Search summaries", else: "Search topics"}
        query={@view.q}
        filtered={@view.q != ""}
        disabled={Enum.sum(Map.values(@view.counts)) == 0}
        hidden={if @view.kind == "context", do: [{"kind", "context"}], else: []}
        clear={list_path(%{@view | q: ""}, @view.kind, 1)}
      />
      <Kit.segmented
        label="What Ryker learned"
        options={[
          {"Topics", list_path(@view, "knowledge", 1), @view.kind == "knowledge"},
          {"Conversation summaries", list_path(@view, "context", 1), @view.kind == "context"}
        ]}
      />
    </Kit.toolbar>
    """
  end

  defp nothing(assigns) do
    ~H"""
    <Kit.empty
      :if={@view.items == [] and @view.q != ""}
      title={"Nothing matches “#{@view.q}”"}
      text="Try other words, or clear the search."
    />
    <Kit.empty
      :if={@view.items == [] and @view.q == ""}
      title={empty_title(@view.kind)}
      text={empty_text(@view.kind)}
    />
    """
  end

  defp empty_title("knowledge"), do: "Nothing learned yet"
  defp empty_title("context"), do: "No conversation summaries yet"
  defp empty_title("sources"), do: "No source messages are left"

  defp empty_text("knowledge"),
    do:
      "Ryker reads conversations in the background and keeps topics here once it has learned something useful."

  defp empty_text("context"),
    do:
      "When Ryker finishes work in a conversation, it saves a short summary so the next request can pick up where it stopped."

  defp empty_text("sources"),
    do:
      "The messages behind this were removed or have expired. What Ryker learned stays readable."

  # A topic's facts: where it came from, when it changed and what backs it.
  # Its own page adds the dates and the request it came from.
  defp topic_facts(item, form) do
    [
      MemoryFormat.link(item.conversation, item.conversation_path),
      item.repository,
      MemoryFormat.time(item.changed_at, "Updated "),
      if(form == :record, do: MemoryFormat.time(item.source_at, "Latest message ")),
      if(form == :record, do: retention(item)),
      source_link(item),
      if(form == :list,
        do:
          MemoryFormat.link(
            MemoryFormat.count(item.version, "update", "updates"),
            ConversationMemory.topic_path(item.id) <> "#history"
          )
      ),
      if(form == :record, do: MemoryFormat.link("Open request", item.request_path))
    ]
  end

  defp source_link(%{source_path: path, source_count: count}) when is_binary(path),
    do: MemoryFormat.link(MemoryFormat.count(count, "source", "sources"), path)

  defp source_link(_item), do: nil

  defp summary_warning(%{recall_warning: :missing_source_history}),
    do:
      "Not used in answers: no complete record of the messages behind it was saved. It is kept so you can read it."

  defp summary_warning(%{recall_warning: :invalid_source_history}),
    do: "Not used in answers: the record of the messages behind it is invalid."

  defp summary_warning(_item), do: nil

  # Retention is only stated when it is known: a summary without a valid
  # source record has no expiry to promise.
  defp retention(%{recall_warning: :missing_source_history}), do: "No automatic expiry"
  defp retention(%{recall_warning: :invalid_source_history}), do: "Expiry unknown"
  defp retention(%{expires_at: %DateTime{} = at}), do: MemoryFormat.time(at, "Kept until ")
  defp retention(_item), do: "No automatic expiry"

  defp list_path(view, kind, page) do
    query =
      [{"kind", if(kind == "context", do: "context")}, {"q", view.q}, {"page", page}]
      |> Enum.reject(fn {key, value} -> value in [nil, ""] or {key, value} == {"page", 1} end)

    case URI.encode_query(query) do
      "" -> "/memory/learned"
      encoded -> "/memory/learned?" <> encoded
    end
  end

  defp sources_path(related_to, q, page \\ 1) do
    query =
      [{"kind", "sources"}, {"related_to", related_to}, {"q", q}, {"page", page}]
      |> Enum.reject(fn {key, value} -> value in [nil, ""] or {key, value} == {"page", 1} end)

    "/memory/learned?" <> URI.encode_query(query)
  end

  defp history_path(view, page),
    do:
      "/memory/learned?" <>
        URI.encode_query(%{"item" => view.selected, "history_page" => page}) <> "#history"
end

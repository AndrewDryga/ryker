defmodule Ryker.ControlPlane.LearnedPage do
  @moduledoc """
  Learned (`/memory/learned`): the topics Ryker keeps current by reading
  conversations, and the summaries it saves when work in a conversation ends,
  each with the messages it learned from.

  One topic is a sub-page of its own (`heading/1` gives the shell its title,
  the way back to all topics and Forget opposite the title): whether Ryker
  uses it, its full text, its facts, the picker that relearns it from
  messages a person chooses when its own messages are gone, and its update
  history, each update with the message it came from and the learning card on
  the Timeline that wrote it. A record's source messages are a sub-page the
  same way, leading back to the record they support. An open page redraws
  when a topic, a summary or what they were learned from changes
  (`subscriptions/0`).
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components,
    only: [action_button: 1, action_button: 2, filter_toolbar: 1, pager: 1]

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    ConversationMemory,
    Kit,
    MemoryFormat,
    RelearnPanel
  }

  @doc """
  The topics an open Learned page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the topics, the
  summaries, the learning notes and relearning behind them, and the facts
  forgetting a message takes with it.
  """
  def subscriptions do
    [
      {Ryker.Knowledge, :subscribe_knowledge, []},
      {Ryker.Continuity, :subscribe_continuity, []},
      {Ryker.Learning, :subscribe_learning, []},
      {Ryker.Memories, :subscribe_memories, []}
    ]
  end

  @unused "Ryker stopped using this in answers because a message it learned from changed, was removed or expired."
  @in_use "Ryker uses this topic as context when it answers in this conversation."
  @forgotten "Someone chose to forget it: its text and history are erased, and Ryker never learns from its messages again."

  @doc "The query keys the Learned page reads."
  def query_keys, do: ConversationMemory.query_keys()

  @doc """
  The shell's heading for a sub-page of Learned, or nil for the lists, which
  keep the page's own title. One topic is titled by its name, leads back to
  all topics and, until it is forgotten, has Forget opposite its title; the
  messages behind a record lead back to that record. A topic that does not
  exist is `:not_found`.
  """
  @spec heading(map()) :: map() | :not_found | nil
  def heading(%{kind: "knowledge", selected: id, items: [item | _]}) when is_binary(id) do
    %{
      title: item.title,
      description: nil,
      back: {"All topics", "/memory/learned"},
      action:
        if(is_nil(item[:forgotten_at]),
          do: forget_path(item.id) |> action_button("Forget") |> IO.iodata_to_binary()
        )
    }
  end

  def heading(%{kind: "knowledge", selected: id}) when is_binary(id), do: :not_found

  def heading(%{kind: "sources", source_parent: %{} = parent}) do
    %{
      title: "Messages behind “#{parent.title}”",
      description: "What Ryker learned this from. Each message opens where it was said.",
      back: {parent.back_label, parent.back_path},
      action: nil
    }
  end

  def heading(_view), do: nil

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

  # A topic's row: its name and whether Ryker uses it, then its words and
  # facts, and its buttons at the far edge. Andrew, 2026-09-27: why Ryker
  # stopped using a topic was a sentence under the row with "Relearn it" as a
  # link in it, and "Not used" sat against the Forget button. The reason is
  # the state's hint now, Relearn is a button beside Forget, and the state
  # sits beside the name.
  defp topics(assigns) do
    ~H"""
    <.tools view={@view} />
    <Kit.entity_list :if={@view.items != []} class="memory-excerpts" label="Topics">
      <Kit.entity_row
        :for={item <- @view.items}
        id={"topic-" <> item.id}
        icon={:book}
        name={item.title}
        href={ConversationMemory.topic_path(item.id)}
        state={topic_state(item)}
        state_by_name
        text={MemoryFormat.excerpt(item.text, item.workspace)}
        meta={topic_facts(item)}
      >
        <:actions :if={is_nil(item[:forgotten_at])}>
          <a
            :if={item.available == false}
            class="ui-button secondary"
            href={ConversationMemory.topic_path(item.id) <> "#relearn"}
          >Relearn</a>
          <.action_button path={forget_path(item.id)} label="Forget" />
        </:actions>
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

  # One topic's page under the shell's heading (`heading/1`): whether Ryker
  # uses it, its text, its facts, the way to relearn it when its messages are
  # gone, then its update history. Andrew, 2026-09-27: "this page is not
  # properly designed" — it opened under the list's title with its own
  # smaller heading, and Forget and the reason it was not used sat between
  # its facts and a collapsed relearning form.
  defp topic(assigns) do
    assigns = assign(assigns, :item, List.first(assigns.view.items))

    ~H"""
    <%= if @item do %>
      <article class="memory-topic" id={"topic-" <> @item.id}>
        <Kit.status_line id="topic-status" state={topic_status(@item)}>
          <span>{MemoryFormat.time(@item.changed_at, "updated ")}</span>
          <a :if={@view.history != []} href="#history">
            {MemoryFormat.count(@item.version, "update", "updates")}
          </a>
        </Kit.status_line>
        <div class="memory-topic-text markdown-preview">
          {MemoryFormat.markdown(@item.text, @item.workspace)}
        </div>
        <Kit.facts id="topic-facts" facts={topic_page_facts(@item)} />
      </article>
      <RelearnPanel.render :if={@view.rebuild} preview={@view.rebuild} csrf_secret={@csrf_secret} />
      <section :if={@view.history != []} id="history" class="memory-section">
        <Kit.section_head
          title="Update history"
          lede="Newest first. Each update keeps what Ryker knew then, the message it learned it from, and how it was learned."
        />
        <div class="entity-list" role="list" aria-label="Updates">
          <MemoryFormat.row
            :for={revision <- @view.history}
            id={"update-#{revision.version}"}
            name={"Update #{revision.version}"}
            meta={[
              MemoryFormat.time(revision.at, "Learned "),
              MemoryFormat.time(revision.source_at, "From a message sent "),
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
    <% end %>
    """
  end

  # A forgotten topic says so; one whose messages changed says it is not used.
  # A topic in use carries no state in the list, where that is the rule, and
  # says so on its own page.
  defp topic_state(%{forgotten_at: %DateTime{}}), do: {:off, "Forgotten", @forgotten}
  defp topic_state(%{available: false}), do: {:warn, "Not used", @unused}
  defp topic_state(_item), do: nil

  defp topic_status(item), do: topic_state(item) || {:on, "In use", @in_use}

  defp forget_path(id), do: "/actions/knowledge/#{id}/forget"

  # The messages behind a topic or a summary, under the shell's heading
  # (`heading/1`), which leads back to the record they support.
  defp sources(assigns) do
    ~H"""
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
      icon={:search}
      title={"Nothing matches “#{@view.q}”"}
      text="Try other words, or clear the search."
    />
    <Kit.empty
      :if={@view.items == [] and @view.q == ""}
      icon={:book}
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

  # A topic's facts in its row: where it came from, when it changed and what
  # backs it.
  defp topic_facts(item) do
    [
      MemoryFormat.link(item.conversation, item.conversation_path),
      item.repository,
      MemoryFormat.time(item.changed_at, "Updated "),
      source_link(item),
      MemoryFormat.link(
        MemoryFormat.count(item.version, "update", "updates"),
        ConversationMemory.topic_path(item.id) <> "#history"
      )
    ]
  end

  # A topic's facts on its own page, one per line. A forgotten topic keeps
  # only where it was learned: what backed it is erased.
  defp topic_page_facts(%{forgotten_at: %DateTime{}} = item),
    do: [{"Learned in", MemoryFormat.link(item.conversation, item.conversation_path)}]

  defp topic_page_facts(item) do
    [
      {"Learned in", MemoryFormat.link(item.conversation, item.conversation_path)},
      {"Repository", item.repository},
      {"Latest message", MemoryFormat.time(item.source_at)},
      {"Kept until", kept_until(item)},
      {"Learned from", messages_link(item)},
      {"Request", MemoryFormat.link("Open request", item.request_path)}
    ]
  end

  defp kept_until(%{expires_at: %DateTime{} = at}), do: MemoryFormat.time(at)
  defp kept_until(_item), do: "No automatic expiry"

  defp source_link(%{source_path: path, source_count: count}) when is_binary(path),
    do: MemoryFormat.link(MemoryFormat.count(count, "source", "sources"), path)

  defp source_link(_item), do: nil

  defp messages_link(%{source_path: path, source_count: count}) when is_binary(path),
    do: MemoryFormat.link(MemoryFormat.count(count, "message", "messages"), path)

  defp messages_link(_item), do: nil

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

defmodule Ryker.ControlPlane.ConversationMemory do
  @moduledoc """
  The Learned page's read model: searchable, source-linked topics and
  conversation summaries, one topic's update history with each update linked
  to the learning card on the Timeline that wrote it, the source messages
  behind a record, and the relearning picker for a topic whose sources are
  gone.
  """
  alias Ryker.Continuity
  alias Ryker.ControlPlane.{Activity, Learned, LearningActivity, LearningRequests, Search}
  alias Ryker.ControlPlane.{PagedRelation, Paths, RepositoryNames}
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.Memories
  alias Ryker.Repo
  alias Ryker.Slack

  @page_size 30
  @history_size 50
  @expired_text "Saved text expired under the conversation memory retention policy."
  @forgotten_text "Forgotten. Ryker no longer uses it and does not learn from the messages it came from."
  @query_keys ~w(kind q page item history_page related_to rebuild_q rebuild_page)

  @doc "The query keys the Learned page reads."
  def query_keys, do: @query_keys

  @doc """
  What forgetting a topic (`{:knowledge, id}`) or a fact (`{:memory, ref}`)
  would take with it, by topic title: the topics forgotten with it and those
  that stop being used until they are relearned. A topic's own title comes
  with it; a missing or already forgotten one is `:error`.
  """
  @spec forgetting({:knowledge, String.t()} | {:memory, String.t()}) ::
          {:ok, %{optional(:title) => String.t(), forgotten: [String.t()], relearn: [String.t()]}}
          | :error
  def forgetting({:knowledge, id}) do
    secrets = InspectionRedactor.configured_secrets()

    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Knowledge.ConversationKnowledge{forgotten_at: nil} = topic} <-
           Repo.fetch(Knowledge.ConversationKnowledge.Query.by_id(id)) do
      outcome = Memories.Forgetting.preview_topic(id)

      {:ok,
       %{
         title: knowledge_title(topic, secrets),
         forgotten: topic_titles(outcome.forgotten, secrets),
         relearn: topic_titles(outcome.relearn, secrets)
       }}
    else
      _missing_or_forgotten -> :error
    end
  end

  def forgetting({:memory, ref}) when is_binary(ref) do
    secrets = InspectionRedactor.configured_secrets()

    active =
      ref
      |> Memories.MemoryEntry.Query.by_ref()
      |> Memories.MemoryEntry.Query.active()
      |> Repo.fetch()

    case active do
      {:ok, %Memories.MemoryEntry{} = fact} ->
        outcome = Memories.Forgetting.preview_fact(fact)

        {:ok,
         %{
           forgotten: topic_titles(outcome.forgotten, secrets),
           relearn: topic_titles(outcome.relearn, secrets)
         }}

      {:error, :not_found} ->
        :error
    end
  end

  def forgetting(_subject), do: :error

  defp topic_titles([], _secrets), do: []

  defp topic_titles(ids, secrets) do
    ids
    |> Knowledge.ConversationKnowledge.Query.by_ids()
    |> Knowledge.ConversationKnowledge.Query.ordered_by_recently_updated()
    |> Repo.all()
    |> Enum.map(&knowledge_title(&1, secrets))
  end

  def project(params) do
    secrets = InspectionRedactor.configured_secrets()
    source_parent = source_parent(params["related_to"], secrets)

    counts = %{
      context: Repo.aggregate(Continuity.ConversationSummary.Query.all(), :count),
      knowledge: Repo.aggregate(Knowledge.ConversationKnowledge.Query.all(), :count)
    }

    kind = selected_kind(params["kind"], source_parent)
    search = Search.term(params["q"]) || ""
    selected = selected_id(params["item"])
    query = listed(kind, source_parent, search, selected)

    page =
      PagedRelation.read(
        query,
        [desc: :updated_at, desc: :id],
        "page",
        params,
        page_size: @page_size
      )

    items = page.items
    ids = items |> Enum.map(& &1.source_episode_id) |> Enum.reject(&is_nil/1)
    lookup = lookup(items, ids)
    knowledge_ids = if kind == "knowledge", do: Enum.map(items, & &1.id), else: []

    available_ids = if kind == "knowledge", do: available_ids(items), else: MapSet.new()
    source_counts = source_counts(knowledge_ids)
    history = history(selected, kind, secrets, params)

    %{
      counts: counts,
      kind: kind,
      q: search,
      related_to: if(source_parent, do: source_parent.ref),
      source_parent: source_parent,
      page: page.page,
      pages: page.pages,
      total: page.total,
      selected: selected,
      rebuild: rebuild(selected, kind, available_ids, params),
      history: history.items,
      history_page: history.page,
      history_pages: history.pages,
      items:
        Enum.map(items, fn row ->
          rendered = item(row, lookup, secrets)

          case kind do
            "knowledge" ->
              {count, direct, oldest} = Map.get(source_counts, row.id, {0, 0, nil})

              expiry =
                row.source_dependencies
                |> Learning.LearningSources.oldest(oldest)
                |> expires_at()

              Map.merge(rendered, %{
                available: MapSet.member?(available_ids, row.id),
                source_count: count,
                source_path: source_path("knowledge", row.id, count),
                direct_source_count: direct,
                inherited_source_count: count - direct,
                version: row.version,
                expires_at: expiry
              })

            "context" ->
              count = row.source_dependencies |> source_ids() |> length()

              Map.merge(rendered, %{
                source_count: count,
                source_path: source_path("context", row.id, count)
              })

            "sources" ->
              rendered
          end
        end)
    }
  end

  @doc """
  Presents learned rows the way `/memory/learned` does: sanitized state, safe
  titles, source links and retention, never a raw payload or dependency list.
  """
  @spec present([struct()]) :: [map()]
  def present(rows) when is_list(rows) do
    ids = rows |> Enum.map(& &1.source_episode_id) |> Enum.reject(&is_nil/1)
    lookup = lookup(rows, ids)
    secrets = InspectionRedactor.configured_secrets()
    Enum.map(rows, &item(&1, lookup, secrets))
  end

  # The human-readable heading, text and fact groups of one continuity state.
  @spec continuity_state(term(), [String.t()]) :: %{
          title: String.t(),
          text: String.t(),
          groups: [{String.t(), [String.t()]}]
        }
  defp continuity_state(state, secrets) do
    state = InspectionRedactor.document(state, secrets)

    %{
      title:
        List.first(state["active_topics"] || []) || state["purpose"] || "Conversation summary",
      text: state["situation"] || state["goal"] || "",
      groups: summary_groups(state)
    }
  end

  defp episode_keys([]), do: %{}

  defp episode_keys(ids) do
    ids
    |> Episodes.Episode.Query.by_ids()
    |> Episodes.Episode.Query.select_id_keys()
    |> Repo.all()
    |> Map.new()
  end

  # A forgotten topic is not offered for relearning: the person asked Ryker to
  # stop knowing it.
  defp rebuild(id, "knowledge", available_ids, params) when is_binary(id) do
    if not MapSet.member?(available_ids, id) and not forgotten?(id) do
      options = %{
        page: PagedRelation.requested(params, "rebuild_page"),
        q: Search.term(params["rebuild_q"]) || ""
      }

      case Learning.Rebuilds.preview(id, options) do
        {:ok, preview} -> preview
        {:error, _} -> nil
      end
    end
  end

  defp rebuild(_, _, _, _), do: nil

  defp forgotten?(id) do
    id
    |> Knowledge.ConversationKnowledge.Query.by_id()
    |> Knowledge.ConversationKnowledge.Query.forgotten()
    |> Repo.exists?()
  end

  # The operator can inspect withdrawn history, but its recall label must apply
  # the same inherited-source visibility and retention fences as model recall.
  @doc false
  def available_ids(items) do
    items
    |> Enum.reject(&(&1.state["retention"] == "pruned"))
    |> Enum.group_by(&{&1.transport, &1.conversation_ref, &1.repository_ref})
    |> Enum.flat_map(&available_group/1)
    |> MapSet.new()
  end

  defp available_group({{transport, conversation, repository}, items}) do
    destination = %{
      destination_transport: transport,
      destination_conversation_ref: conversation,
      destination_thread_ref: nil
    }

    ids = Enum.map(items, & &1.id)

    case Continuity.destination_context(destination, repository) do
      {:ok, scope} ->
        scope |> Knowledge.availability_query(ids) |> Repo.all()

      _ ->
        []
    end
  end

  defp source_parent("knowledge:" <> id, secrets) do
    with id when is_binary(id) <- selected_id(id),
         {:ok, %Knowledge.ConversationKnowledge{} = knowledge} <-
           Repo.fetch(Knowledge.ConversationKnowledge.Query.by_id(id)) do
      title = knowledge_title(knowledge, secrets)

      %{
        back_label: title,
        back_path: topic_path(id),
        ref: "knowledge:#{id}",
        source_ids: source_ids(knowledge.source_dependencies),
        title: title
      }
    else
      _ -> nil
    end
  end

  defp source_parent("context:" <> id, secrets) do
    with id when is_binary(id) <- selected_id(id),
         {:ok, %Continuity.ConversationSummary{} = summary} <-
           Repo.fetch(Continuity.ConversationSummary.Query.by_id(id)) do
      %{
        back_label: "Conversation summaries",
        back_path: "/memory/learned?kind=context#summary-#{id}",
        ref: "context:#{id}",
        source_ids: source_ids(summary.source_dependencies),
        title: continuity_state(summary.state, secrets).title
      }
    else
      _ -> nil
    end
  end

  defp source_parent(_, _), do: nil

  defp source_ids(dependencies) do
    case Learning.LearningSources.expand(dependencies) do
      roots when is_list(roots) ->
        roots
        |> Enum.map(&selected_id(&1["observation_id"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc "Where one learned topic opens: its full text, history and sources."
  def topic_path(id), do: Paths.query("/memory/learned", %{"item" => id})

  @doc "Where the topic a `knowledge:<id>` source ref names opens; nil for any other ref."
  @spec knowledge_path(term()) :: String.t() | nil
  def knowledge_path("knowledge:" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> topic_path(id)
      :error -> nil
    end
  end

  def knowledge_path(_ref), do: nil

  @doc "Where one conversation summary's page is."
  @spec summary_path(String.t()) :: String.t()
  def summary_path(id),
    do: Paths.query("/memory/learned", %{"kind" => "context", "item" => id})

  defp source_path(_kind, _id, 0), do: nil

  defp source_path(kind, id, _count) do
    "/memory/learned?" <>
      Paths.encode_query(%{"kind" => "sources", "related_to" => "#{kind}:#{id}"})
  end

  defp selected_kind(value, _) when value in ["knowledge", "context"], do: value
  defp selected_kind("sources", %{}), do: "sources"
  defp selected_kind(_, _), do: "knowledge"

  # The rows the page lists: one kind, searched, or only the selected item
  # when one is open.
  defp listed(kind, source_parent, search, selected) do
    query = kind |> kind_query(source_parent) |> search(kind, search)

    if selected && kind in ["knowledge", "context"],
      do: Learned.Query.only(query, selected),
      else: query
  end

  defp kind_query("sources", %{source_ids: ids}), do: Learned.Query.notes(ids)
  defp kind_query(kind, _parent), do: Learned.Query.items(kind)

  defp search(query, _kind, ""), do: query
  defp search(query, kind, text), do: Learned.Query.matching(query, kind, text)

  # The requests rows came from, and the names of the repositories they used.
  defp lookup(rows, episode_ids),
    do: %{
      episodes: episode_keys(episode_ids),
      names: if(Enum.any?(rows, & &1.repository_ref), do: RepositoryNames.all(), else: %{})
    }

  defp item(%Learning.ConversationObservation{} = note, lookup, secrets) do
    state = InspectionRedactor.document(note.note, secrets)

    base(note, lookup)
    |> Map.merge(%{
      title: Enum.join(state["topics"] || [], " · "),
      text:
        String.trim_trailing(state["summary"] || "", " Source: message #{note.source_input_id}."),
      at: note.occurred_at,
      source_at: note.occurred_at,
      groups: [],
      source: source_message(note)
    })
  end

  defp item(%Knowledge.ConversationKnowledge{} = knowledge, lookup, secrets) do
    state = InspectionRedactor.document(knowledge.state, secrets)

    base(knowledge, lookup)
    |> Map.merge(%{
      title: knowledge_title(knowledge, secrets),
      text: if(knowledge.forgotten_at, do: @forgotten_text, else: knowledge_text(state)),
      forgotten_at: knowledge.forgotten_at,
      groups: [],
      source: nil,
      at: knowledge.updated_at,
      source_at: knowledge.latest_source_at
    })
  end

  defp item(%Continuity.ConversationSummary{} = summary, lookup, secrets) do
    warning = summary_history_warning(summary.source_dependencies)
    view = base(summary, lookup)

    view
    |> Map.merge(continuity_state(summary.state, secrets))
    |> Map.merge(%{
      source: nil,
      expires_at: if(is_nil(warning), do: view.expires_at),
      recall_warning: warning,
      maintenance_error: LearningActivity.error(summary.compaction_error_code),
      maintenance_retry_at: summary.compaction_retry_at,
      source_at: if(is_nil(warning), do: summary_source_at(summary.source_dependencies))
    })
  end

  defp knowledge_title(%Knowledge.ConversationKnowledge{forgotten_at: %DateTime{}}, _secrets),
    do: "Forgotten knowledge"

  defp knowledge_title(%Knowledge.ConversationKnowledge{} = knowledge, secrets),
    do: knowledge.state |> InspectionRedactor.document(secrets) |> knowledge_title()

  defp knowledge_title(state) do
    if state["retention"] == "pruned",
      do: "Expired knowledge",
      else: state["title"] || "Conversation knowledge"
  end

  defp summary_source_at(dependencies) do
    # Read original event time only from the exact retained revision. A source
    # edited since the handover must not substitute today's message timestamp.
    dependencies
    |> Ryker.CanonicalJSON.encode!()
    |> Learned.Query.latest_source_at()
    |> Repo.one()
  end

  defp summary_groups(state) do
    for {key, label} <- [
          {"decisions", "Decisions"},
          {"open_loops", "Open work"},
          {"unresolved_questions", "Open questions"}
        ],
        values = state[key],
        is_list(values) and values != [],
        do: {label, values}
  end

  defp summary_history_warning(sources) do
    cond do
      not Learning.LearningSources.sourced?(sources) -> :missing_source_history
      Learning.LearningSources.merge([sources]) != sources -> :invalid_source_history
      true -> nil
    end
  end

  defp source_counts([]), do: %{}

  defp source_counts(ids), do: ids |> Learned.Query.source_counts() |> Repo.all() |> Map.new()

  defp selected_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> value
      _ -> nil
    end
  end

  defp selected_id(_), do: nil

  defp history(nil, _, _, _), do: %{items: [], page: 1, pages: 1}

  defp history(id, "knowledge", secrets, params) do
    erased_text = if forgotten?(id), do: @forgotten_text, else: @expired_text

    page =
      PagedRelation.read(
        Learned.Query.history(id),
        [desc: :version],
        "history_page",
        params,
        page_size: @history_size
      )

    learned = learning_paths(Enum.map(page.items, &elem(&1, 0)))

    items =
      Enum.map(page.items, fn {revision, transport, conversation, message} ->
        state = InspectionRedactor.document(revision.state, secrets)

        %{
          version: revision.version,
          at: revision.inserted_at,
          source_at: revision.source_at,
          text: knowledge_text(state, erased_text),
          source_input_id: revision.source_input_id,
          learning_path: Map.get(learned, revision.source_result_ref),
          source:
            source_message(%{
              transport: transport,
              conversation_ref: conversation,
              source_message_ref: message
            })
        }
      end)

    %{items: items, page: page.page, pages: page.pages}
  end

  defp history(_, _, _, _), do: %{items: [], page: 1, pages: 1}

  # How each update was learned: the learning card of the attempt whose exact
  # applied response wrote it, by the reference the update recorded. A
  # reference to any other attempt, or to a response that is not the one
  # applied, links nowhere.
  defp learning_paths(revisions) do
    references =
      for %{source_result_ref: ref} <- revisions,
          [_, id, digest] <- [learning_reference(ref)],
          into: %{},
          do: {ref, {id, digest}}

    ids = references |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    runs =
      if ids == [],
        do: [],
        else:
          ids
          |> Learning.LearningRun.Query.by_ids()
          |> Learning.LearningRun.Query.by_status(:applied)
          |> Learning.LearningRun.Query.select_result_digests()
          |> Repo.all()

    paths = LearningRequests.paths(runs)
    digests = Map.new(runs, &{&1.id, &1.result_sha256})

    for {ref, {id, digest}} <- references,
        digests[id] == digest,
        path = paths[id],
        is_binary(path),
        into: %{},
        do: {ref, path}
  end

  defp learning_reference(value) when is_binary(value) do
    Regex.run(
      ~r/\Alearning:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([0-9a-f]{64})\z/,
      value
    )
  end

  defp learning_reference(_value), do: nil

  defp knowledge_text(state, erased_text \\ @expired_text)
  defp knowledge_text(%{"retention" => "pruned"}, erased_text), do: erased_text
  defp knowledge_text(state, _erased_text), do: state["summary"] || ""

  defp base(item, lookup) do
    %{
      id: item.id,
      conversation: Slack.Names.destination(item.conversation_ref),
      workspace: Slack.Names.workspace_from_destination(item.conversation_ref),
      conversation_path: Activity.conversation_path(item.transport, item.conversation_ref),
      at: item.updated_at,
      changed_at: item.updated_at,
      source_at: nil,
      expires_at:
        item.source_dependencies
        |> Learning.LearningSources.oldest(item.updated_at)
        |> expires_at(),
      repository: RepositoryNames.name(lookup.names, item.repository_ref),
      request_path:
        if(Map.has_key?(lookup.episodes, item.source_episode_id),
          do: Paths.request(item.source_episode_id)
        )
    }
  end

  defp expires_at(nil), do: nil

  defp expires_at(updated_at) do
    case Learning.LearningSources.retention_seconds() do
      seconds when is_integer(seconds) -> DateTime.add(updated_at, seconds)
      nil -> nil
    end
  end

  @doc false
  def source_message(%{
        transport: "slack",
        conversation_ref: conversation,
        source_message_ref: ref
      })
      when is_binary(conversation) and is_binary(ref) do
    case ConversationRef.parse_slack(conversation) do
      {:ok, _workspace, channel} -> Slack.archive_url(channel, ref)
      :error -> nil
    end
  end

  def source_message(%{
        transport: "control_plane",
        conversation_ref: "control-plane:lab:" <> id
      }),
      do: Paths.conversation(id)

  def source_message(_), do: nil
end

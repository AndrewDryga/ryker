defmodule Responder.ControlPlane.ConversationMemory do
  @moduledoc "Searchable, source-linked operator view of learned conversation context."
  import Ecto.Query
  alias Responder.ControlPlane.{Activity, InspectionRedactor, LearningReceipt, SlackNames}
  alias Responder.Episodes.Episode
  alias Responder.Repo

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    ConversationSummary,
    Knowledge,
    KnowledgeRevision,
    KnowledgeSource,
    LearningSources,
    Observations
  }

  @page_size 30
  @history_size 50
  @expired_text "Saved text expired under the conversation memory retention policy."

  def project(params) do
    notes = from(note in ConversationObservation, where: not is_nil(note.note))

    counts = %{
      knowledge: Repo.aggregate(ConversationKnowledge, :count),
      notes: Repo.aggregate(notes, :count),
      summaries: Repo.aggregate(ConversationSummary, :count)
    }

    kind = selected_kind(params["kind"], counts)
    search = search_text(params["q"])
    page = page_number(params["page"])
    query = kind_query(kind, notes) |> search(kind, search)
    selected = selected_id(params["item"])

    query =
      if selected && kind == "knowledge",
        do: from(item in query, where: item.id == ^selected),
        else: query

    total = Repo.aggregate(query, :count)
    pages = max(div(total + @page_size - 1, @page_size), 1)
    page = min(page, pages)
    offset = (page - 1) * @page_size

    items =
      Repo.all(
        from(item in query,
          order_by: [desc: item.updated_at, desc: item.id],
          limit: @page_size,
          offset: ^offset
        )
      )

    ids = items |> Enum.map(& &1.source_episode_id) |> Enum.reject(&is_nil/1)

    episodes =
      Repo.all(
        from(episode in Episode,
          where: episode.id in ^ids,
          select: {episode.id, episode.key}
        )
      )
      |> Map.new()

    secrets = InspectionRedactor.configured_secrets()
    knowledge_ids = if kind == "knowledge", do: Enum.map(items, & &1.id), else: []

    available_ids = if kind == "knowledge", do: available_ids(items), else: MapSet.new()
    sources = source_counts(knowledge_ids)
    history = history(selected, kind, secrets, page_number(params["history_page"]))

    %{
      counts: counts,
      kind: kind,
      q: search,
      page: page,
      pages: pages,
      total: total,
      selected: selected,
      history: history.items,
      history_page: history.page,
      history_pages: history.pages,
      learning:
        if(kind == "knowledge", do: LearningReceipt.project(selected, params["update"], secrets)),
      items:
        Enum.map(items, fn row ->
          rendered = item(row, episodes, secrets)

          if kind == "knowledge" do
            {count, oldest} = Map.get(sources, row.id, {0, nil})

            Map.merge(rendered, %{
              available: MapSet.member?(available_ids, row.id),
              source_count: count,
              version: row.version,
              expires_at:
                row.source_dependencies |> LearningSources.oldest(oldest) |> expires_at()
            })
          else
            rendered
          end
        end)
    }
  end

  # The operator can inspect withdrawn history, but its recall label must apply
  # the same inherited-source visibility and retention fences as model recall.
  defp available_ids(items) do
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

    case Repo.transaction(fn -> available_in_scope(destination, repository, ids) end) do
      {:ok, ids} -> ids
      _ -> []
    end
  end

  defp available_in_scope(destination, repository, ids) do
    case Observations.locked_scope(destination, repository) do
      {:ok, scope} ->
        Knowledge.valid_query()
        |> LearningSources.eligible(scope)
        |> where([item], item.id in ^ids)
        |> select([item], item.id)
        |> Repo.all()

      _ ->
        []
    end
  end

  defp selected_kind(value, _) when value in ["knowledge", "notes", "summaries"], do: value

  defp selected_kind(_, counts) do
    cond do
      counts.knowledge > 0 -> "knowledge"
      counts.notes > 0 -> "notes"
      counts.summaries > 0 -> "summaries"
      true -> "knowledge"
    end
  end

  defp search_text(value) when is_binary(value), do: String.slice(String.trim(value), 0, 200)
  defp search_text(_), do: ""

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page in 1..10_000 -> page
      _ -> 1
    end
  end

  defp page_number(_), do: 1

  defp kind_query("knowledge", _), do: from(item in ConversationKnowledge)
  defp kind_query("notes", notes), do: notes
  defp kind_query("summaries", _), do: from(summary in ConversationSummary)

  defp search(query, _, ""), do: query

  defp search(query, "knowledge", text),
    do:
      from(item in query,
        where: fragment("position(lower(?) in lower(?)) > 0", ^text, item.state)
      )

  defp search(query, "notes", text),
    do:
      from(note in query, where: fragment("position(lower(?) in lower(?)) > 0", ^text, note.note))

  defp search(query, "summaries", text),
    do:
      from(summary in query,
        where: fragment("position(lower(?) in lower(?)) > 0", ^text, summary.state)
      )

  defp item(%ConversationObservation{} = note, episodes, secrets) do
    state = sanitized(note.note, secrets)

    base(note, episodes)
    |> Map.merge(%{
      title: Enum.join(state["topics"] || [], " · "),
      text:
        String.trim_trailing(state["summary"] || "", " Source: message #{note.source_input_id}."),
      at: note.occurred_at,
      groups: [],
      source: source_message(note)
    })
  end

  defp item(%ConversationKnowledge{} = knowledge, episodes, secrets) do
    state = sanitized(knowledge.state, secrets)

    base(knowledge, episodes)
    |> Map.merge(%{
      title:
        if(state["retention"] == "pruned",
          do: "Expired knowledge",
          else: state["title"] || "Conversation knowledge"
        ),
      text: knowledge_text(state),
      groups: [],
      source: nil,
      at: knowledge.latest_source_at
    })
  end

  defp item(%ConversationSummary{} = summary, episodes, secrets) do
    state = sanitized(summary.state, secrets)
    title = List.first(state["active_topics"] || []) || state["purpose"] || "Conversation summary"

    groups =
      for {key, label} <- [
            {"decisions", "Decisions"},
            {"open_loops", "Open work"},
            {"unresolved_questions", "Open questions"}
          ],
          values = state[key],
          is_list(values) and values != [],
          do: {label, values}

    base(summary, episodes)
    |> Map.merge(%{
      title: title,
      text: state["situation"] || state["goal"] || "",
      groups: groups,
      source: nil
    })
  end

  defp source_counts([]), do: %{}

  defp source_counts(ids) do
    Repo.all(
      from(s in KnowledgeSource,
        join: k in ConversationKnowledge,
        on: k.id == s.knowledge_id and k.source_generation == s.generation,
        left_join: o in ConversationObservation,
        on: o.id == s.observation_id,
        where: k.id in ^ids,
        group_by: k.id,
        select: {k.id, {count(s.observation_id), min(o.updated_at)}}
      )
    )
    |> Map.new()
  end

  defp selected_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> value
      _ -> nil
    end
  end

  defp selected_id(_), do: nil

  defp history(nil, _, _, _), do: %{items: [], page: 1, pages: 1}

  defp history(id, "knowledge", secrets, page) do
    total = Repo.aggregate(from(r in KnowledgeRevision, where: r.knowledge_id == ^id), :count)
    pages = max(div(total + @history_size - 1, @history_size), 1)
    page = min(page, pages)
    offset = (page - 1) * @history_size

    items =
      Repo.all(
        from(r in KnowledgeRevision,
          left_join: entry in Responder.Ingress.Inbox.Entry,
          on: entry.id == r.source_input_id,
          where: r.knowledge_id == ^id,
          order_by: [desc: r.version],
          limit: @history_size,
          offset: ^offset,
          select:
            {r, entry.destination_transport, entry.destination_conversation_ref,
             entry.source_item_ref}
        )
      )
      |> Enum.map(fn {revision, transport, conversation, message} ->
        state = sanitized(revision.state, secrets)

        %{
          version: revision.version,
          at: revision.inserted_at,
          source_at: revision.source_at,
          text: knowledge_text(state),
          source_input_id: revision.source_input_id,
          learning_path: LearningReceipt.path(revision),
          source:
            source_message(%{
              transport: transport,
              conversation_ref: conversation,
              source_message_ref: message
            })
        }
      end)

    %{items: items, page: page, pages: pages}
  end

  defp history(_, _, _, _), do: %{items: [], page: 1, pages: 1}

  defp knowledge_text(%{"retention" => "pruned"}), do: @expired_text
  defp knowledge_text(state), do: state["summary"] || ""

  defp base(item, episodes) do
    %{
      id: item.id,
      conversation: SlackNames.destination(item.conversation_ref),
      workspace: SlackNames.workspace_from_destination(item.conversation_ref),
      conversation_path: Activity.conversation_path(item.transport, item.conversation_ref),
      at: item.updated_at,
      expires_at:
        item.source_dependencies |> LearningSources.oldest(item.updated_at) |> expires_at(),
      repository: item.repository_ref,
      request_path:
        case episodes[item.source_episode_id] do
          nil -> nil
          key -> "/episodes/" <> URI.encode(key, &URI.char_unreserved?/1)
        end
    }
  end

  defp expires_at(nil), do: nil

  defp expires_at(updated_at) do
    settings = Application.get_env(:responder, :retention) || %{}

    case if(is_list(settings),
           do: Keyword.get(settings, :conversation_memory_seconds),
           else: Map.get(settings, :conversation_memory_seconds)
         ) do
      seconds when is_integer(seconds) and seconds > 0 -> DateTime.add(updated_at, seconds)
      _ -> nil
    end
  end

  defp source_message(%{
         transport: "slack",
         conversation_ref: conversation,
         source_message_ref: ref
       })
       when is_binary(conversation) and is_binary(ref) do
    case String.split(conversation, ":", parts: 3) do
      ["slack", _, channel] ->
        if Regex.match?(~r/\A[CDG][A-Z0-9]+\z/, channel) and Regex.match?(~r/\A\d+\.\d+\z/, ref),
          do: "https://slack.com/archives/#{channel}/p#{String.replace(ref, ".", "")}",
          else: nil

      _ ->
        nil
    end
  end

  defp source_message(%{
         transport: "control_plane",
         conversation_ref: "control-plane:lab:" <> id
       }),
       do: "/lab/" <> URI.encode(id, &URI.char_unreserved?/1)

  defp source_message(_), do: nil

  defp sanitized(value, secrets) do
    case Jason.decode(InspectionRedactor.artifact(value, secrets: secrets).text || "{}") do
      {:ok, %{} = document} -> document
      _ -> %{}
    end
  end
end

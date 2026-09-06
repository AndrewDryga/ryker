defmodule Responder.ControlPlane.ConversationMemory do
  @moduledoc "Searchable, source-linked operator view of learned conversation context."
  import Ecto.Query
  alias Responder.ControlPlane.{Activity, InspectionRedactor, SlackNames}
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.State.{ConversationObservation, ConversationSummary}
  @page_size 30

  def project(params) do
    notes = from(note in ConversationObservation, where: not is_nil(note.note))

    counts = %{
      notes: Repo.aggregate(notes, :count),
      summaries: Repo.aggregate(ConversationSummary, :count)
    }

    kind =
      case params["kind"] do
        value when value in ["notes", "summaries"] -> value
        _ -> if counts.notes > 0, do: "notes", else: "summaries"
      end

    search =
      if is_binary(params["q"]), do: String.slice(String.trim(params["q"]), 0, 200), else: ""

    page_value = if is_binary(params["page"]), do: params["page"], else: "1"

    page =
      case Integer.parse(page_value) do
        {value, ""} when value in 1..10_000 -> value
        _ -> 1
      end

    query = if kind == "notes", do: notes, else: from(summary in ConversationSummary)
    query = search(query, kind, search)
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

    %{
      counts: counts,
      kind: kind,
      q: search,
      page: page,
      pages: pages,
      total: total,
      items: Enum.map(items, &item(&1, episodes, secrets))
    }
  end

  defp search(query, _, ""), do: query

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

  defp base(item, episodes) do
    %{
      id: item.id,
      conversation: SlackNames.destination(item.conversation_ref),
      workspace: SlackNames.workspace_from_destination(item.conversation_ref),
      conversation_path: Activity.conversation_path(item.transport, item.conversation_ref),
      at: item.updated_at,
      expires_at: expires_at(item.updated_at),
      repository: item.repository_ref,
      request_path:
        case episodes[item.source_episode_id] do
          nil -> nil
          key -> "/episodes/" <> URI.encode(key, &URI.char_unreserved?/1)
        end
    }
  end

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
       }) do
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

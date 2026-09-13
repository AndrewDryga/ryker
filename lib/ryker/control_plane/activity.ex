defmodule Ryker.ControlPlane.Activity do
  @moduledoc "A bounded conversation-first inbox, including work not yet admitted."
  import Ecto.Query

  alias Ryker.ControlPlane.{
    CurrentInputs,
    InspectionRedactor,
    SlackMarkdown,
    SlackNames,
    UsageProjection
  }

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Turn

  @page_size 30

  def conversation_path(transport, conversation, thread \\ nil) do
    params = %{"transport" => transport, "conversation" => conversation, "mode" => "all"}
    params = if thread in [nil, ""], do: params, else: Map.put(params, "thread", thread)
    "/activity?" <> URI.encode_query(params)
  end

  def conversation_filter_options do
    secrets = InspectionRedactor.configured_secrets()

    from(row in subquery(rows()),
      distinct: [row.source, row.conversation],
      order_by: [row.source, row.conversation, desc: row.updated_at],
      limit: 500
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      label =
        if row.source == "control_plane",
          do: "Direct conversation · " <> present(row, secrets).title,
          else: SlackNames.destination(row.conversation)

      %{
        source: row.source,
        transport: row.source,
        conversation_ref: row.conversation,
        conversation_label: label,
        actor: nil,
        actor_kind: nil,
        workspace: nil
      }
    end)
  end

  def request_titles([]), do: %{}

  def request_titles(refs) do
    refs = refs |> Enum.uniq() |> Enum.take(100)
    secrets = InspectionRedactor.configured_secrets()

    Repo.all(from(row in subquery(rows()), where: row.kind == "episode" and row.ref in ^refs))
    |> Map.new(fn row -> {row.ref, present(row, secrets)} end)
  end

  def list(params) do
    mode = if params["mode"] in ~w(shadow all), do: params["mode"], else: "live"
    page = page(params["page"])
    query = from(row in subquery(rows()))
    query = if mode == "all", do: query, else: from(row in query, where: row.mode == ^mode)

    query =
      filter(query, params["filter"])
      |> criteria_filters(params)
      |> conversation_filters(params)
      |> UsageProjection.filter_activity(params)
      |> search(params["q"])

    total = Repo.aggregate(query, :count)
    pages = max(1, ceil(total / @page_size))
    page = min(page, pages)
    secrets = InspectionRedactor.configured_secrets()

    items =
      Repo.all(
        from(row in query,
          order_by: [desc: row.updated_at, desc: row.id],
          limit: @page_size,
          offset: ^((page - 1) * @page_size)
        )
      )
      |> Enum.map(&present(&1, secrets))

    %{items: items, total: total, page: page, pages: pages, mode: mode}
  end

  defp rows do
    first_inputs =
      from(entry in Entry,
        join: current in subquery(CurrentInputs.latest()),
        on:
          current.native_input_id == entry.native_input_id and
            current.execution_mode == entry.execution_mode,
        where: not is_nil(entry.episode_id),
        distinct: entry.episode_id,
        order_by: [asc: entry.episode_id, asc: entry.inserted_at, asc: entry.id],
        select: %{
          episode_id: entry.episode_id,
          content: current.content,
          event_kind: current.event_kind,
          pruned_at: current.operational_pruned_at,
          repository: entry.repository_ref,
          inserted_at: entry.inserted_at
        }
      )

    episodes =
      from(episode in Episode,
        left_join: input in subquery(first_inputs),
        on: input.episode_id == episode.id,
        left_join: turn in Turn,
        on:
          turn.episode_id == episode.id and turn.turn_ref == episode.owner_ref and
            episode.owner_kind == :turn,
        select: %{
          id: episode.id,
          kind: type(^"episode", :string),
          ref: episode.key,
          conversation: episode.destination_conversation_ref,
          thread: episode.destination_thread_ref,
          episode_state: fragment("?::text", episode.state),
          mode: fragment("?::text", episode.execution_mode),
          state:
            fragment(
              "CASE WHEN ? = 'blocked' THEN 'blocked' WHEN ? = 'delivery' THEN 'delivery_pending' ELSE ?::text END",
              turn.status,
              episode.owner_kind,
              episode.state
            ),
          bucket:
            fragment(
              "CASE WHEN ? = 'blocked' OR ? = 'waiting_for_input' THEN 'attention' WHEN ? IN ('complete','cancelled') THEN 'done' ELSE 'running' END",
              turn.status,
              episode.state,
              episode.state
            ),
          source: episode.destination_transport,
          repository: input.repository,
          source_available:
            not is_nil(input.content) and is_nil(input.pruned_at) and input.event_kind != :delete,
          text:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN NULL WHEN ? = 'delete' THEN 'Message deleted' ELSE (SELECT left(COALESCE(NULLIF(source ->> 'text', ''), source #>> '{payload,comment,body}', source #>> '{payload,review,body}', source #>> '{attachments,0,title}', source #>> '{attachments,0,pretext}', source #>> '{attachments,0,text}', source #>> '{attachments,0,fallback}', source #>> '{blocks,0,text,text}', source #>> '{files,0,name}'), 12000) FROM (SELECT ?::jsonb AS source) AS payload) END",
              input.pruned_at,
              input.event_kind,
              input.content
            ),
          started_at: fragment("LEAST(?, ?)", episode.inserted_at, input.inserted_at),
          updated_at: episode.updated_at,
          target: turn.execution_target
        }
      )

    admissions =
      from(entry in Entry,
        join: current in subquery(CurrentInputs.latest()),
        on:
          current.native_input_id == entry.native_input_id and
            current.execution_mode == entry.execution_mode,
        where: is_nil(entry.episode_id),
        select: %{
          id: entry.id,
          kind: type(^"admission", :string),
          ref: fragment("?::text", entry.id),
          conversation: entry.destination_conversation_ref,
          thread: entry.destination_thread_ref,
          episode_state: type(^nil, :string),
          mode: fragment("?::text", entry.execution_mode),
          state:
            fragment(
              "CASE WHEN ? = 'decided' THEN COALESCE(?::text, 'decided') ELSE ?::text END",
              entry.status,
              entry.decision_action,
              entry.status
            ),
          bucket:
            fragment(
              "CASE WHEN ? = 'blocked' THEN 'attention' WHEN ? = 'pending' THEN 'running' ELSE 'done' END",
              entry.status,
              entry.status
            ),
          source: entry.destination_transport,
          repository: entry.repository_ref,
          source_available:
            not is_nil(current.content) and is_nil(current.operational_pruned_at) and
              current.event_kind != :delete,
          text:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN NULL WHEN ? = 'delete' THEN 'Message deleted' ELSE (SELECT left(COALESCE(NULLIF(source ->> 'text', ''), source #>> '{payload,comment,body}', source #>> '{payload,review,body}', source #>> '{attachments,0,title}', source #>> '{attachments,0,pretext}', source #>> '{attachments,0,text}', source #>> '{attachments,0,fallback}', source #>> '{blocks,0,text,text}', source #>> '{files,0,name}'), 12000) FROM (SELECT ?::jsonb AS source) AS payload) END",
              current.operational_pruned_at,
              current.event_kind,
              current.content
            ),
          started_at: entry.inserted_at,
          updated_at: entry.updated_at,
          target: type(^nil, :string)
        }
      )

    union_all(episodes, ^admissions)
  end

  defp present(row, secrets) do
    artifact = InspectionRedactor.artifact(row.text, secrets: secrets, max_bytes: 12_000)
    text = if artifact.text, do: String.trim(artifact.text)
    source = source(row.source)

    title =
      if text in [nil, ""],
        do: "#{source} conversation · source content unavailable",
        else:
          text
          |> SlackMarkdown.plain(SlackNames.workspace_from_destination(row.conversation))
          |> String.slice(0, 200)

    row
    |> Map.drop([:text, :ref, :conversation, :episode_state])
    |> Map.merge(%{
      conversation: row.conversation,
      title: title,
      source: source,
      href:
        "/timeline/#{URI.encode_www_form(if row.kind == "episode", do: row.ref, else: "ingress-input:#{row.ref}")}"
    })
  end

  defp source("control_plane"), do: "Direct conversation"
  defp source("slack"), do: "Slack"
  defp source("github"), do: "GitHub"
  defp source(_), do: "Integration"

  defp filter(query, value) when value in ~w(attention running done),
    do: from(row in query, where: row.bucket == ^value)

  defp filter(query, _), do: query

  defp conversation_filters(query, params) do
    Enum.reduce(
      [{"conversation", :conversation}, {"thread", :thread}, {"transport", :source}],
      query,
      fn
        {key, column}, query ->
          case params[key] do
            value when is_binary(value) and byte_size(value) in 1..512 ->
              from(row in query, where: field(row, ^column) == ^value)

            _ ->
              query
          end
      end
    )
  end

  defp criteria_filters(query, params) do
    Enum.reduce(~w(state target repository), query, fn key, query ->
      case params[key] do
        value when is_binary(value) and value != "" -> criteria_filter(query, key, value)
        _ -> query
      end
    end)
  end

  defp criteria_filter(query, "state", value),
    do: from(row in query, where: row.episode_state == ^value)

  defp criteria_filter(query, "target", value) do
    ids = from(turn in Turn, where: turn.execution_target == ^value, select: turn.episode_id)
    from(row in query, where: row.kind == "episode" and row.id in subquery(ids))
  end

  defp criteria_filter(query, "repository", value) do
    ids =
      from(session in Ryker.Work.Session,
        where: session.repository_ref == ^value,
        select: session.episode_id
      )

    from(row in query, where: row.kind == "episode" and row.id in subquery(ids))
  end

  defp search(query, text) when is_binary(text) and byte_size(text) > 0 do
    pattern =
      "%" <>
        (text
         |> String.slice(0, 200)
         |> String.replace("\\", "\\\\")
         |> String.replace("%", "\\%")
         |> String.replace("_", "\\_")) <> "%"

    from(row in query,
      where:
        ilike(row.text, ^pattern) or ilike(row.repository, ^pattern) or ilike(row.ref, ^pattern) or
          ilike(row.conversation, ^pattern)
    )
  end

  defp search(query, _), do: query

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> min(number, 10_000)
      _ -> 1
    end
  end

  defp page(_), do: 1
end

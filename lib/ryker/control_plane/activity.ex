defmodule Ryker.ControlPlane.Activity do
  @moduledoc "A bounded conversation-first inbox, including work not yet admitted."
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputs

  alias Ryker.ControlPlane.{
    CurrentInputs,
    InspectionRedactor,
    PagedRelation,
    Search,
    SlackMarkdown,
    SlackNames,
    UsageProjection
  }

  alias Ryker.Episodes.{Episode, RoutingDigest}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Turn

  @page_size 30

  @doc """
  Where a page's "this conversation" link leads: the chat itself for a direct
  conversation, or the Activity list for a conversation that holds more than
  one request. A conversation with one request has nowhere else to lead; the
  list would show only the page the reader came from.
  """
  @spec conversation_link(String.t() | nil, String.t() | nil, atom()) ::
          %{href: String.t(), label: String.t()} | nil
  def conversation_link(transport, conversation_ref, execution_mode \\ :live)

  def conversation_link(_transport, "control-plane:lab:" <> id, _execution_mode),
    do: %{href: "/conversations/" <> id, label: "Open in Chat"}

  def conversation_link(transport, conversation_ref, execution_mode)
      when is_binary(transport) and is_binary(conversation_ref) do
    count =
      Repo.aggregate(
        from(episode in Episode,
          where:
            episode.destination_transport == ^transport and
              episode.destination_conversation_ref == ^conversation_ref and
              episode.execution_mode == ^execution_mode
        ),
        :count
      )

    if count > 1,
      do: %{
        href: conversation_path(transport, conversation_ref),
        label: "All #{count} requests in this conversation"
      }
  end

  def conversation_link(_transport, _conversation_ref, _execution_mode), do: nil

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

  @doc """
  Names each row's episode the way the Activity page names it.

  A row with an `episode_ref` gains `request_title` and `request_conversation`
  when that episode is still on file; rows without one are returned as they are.
  """
  @spec with_request_titles([map()]) :: [map()]
  def with_request_titles(rows) do
    titles =
      rows
      |> Enum.map(&Map.get(&1, :episode_ref))
      |> Enum.reject(&is_nil/1)
      |> request_titles()

    Enum.map(rows, fn row ->
      case Map.get(titles, row[:episode_ref]) do
        nil ->
          row

        title ->
          Map.merge(row, %{request_title: title.title, request_conversation: title.conversation})
      end
    end)
  end

  def list(params) do
    mode = if params["mode"] in ~w(shadow all), do: params["mode"], else: "live"
    base_query = from(row in subquery(rows()))
    searchable = Repo.exists?(base_query)
    query = base_query
    query = if mode == "all", do: query, else: from(row in query, where: row.mode == ^mode)

    query =
      filter(query, params["filter"])
      |> criteria_filters(params)
      |> conversation_filters(params)
      |> UsageProjection.filter_activity(params)
      |> search(params["q"])

    page =
      PagedRelation.read(
        query,
        [desc: :updated_at, desc: :id],
        "page",
        params,
        page_size: @page_size
      )

    secrets = InspectionRedactor.configured_secrets()

    %{
      items: Enum.map(page.items, &present(&1, secrets)),
      total: page.total,
      page: page.page,
      pages: page.pages,
      mode: mode,
      searchable: searchable
    }
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
        left_join: digest in RoutingDigest,
        on: digest.episode_id == episode.id,
        select: %{
          id: episode.id,
          kind: type(^"episode", :string),
          episode_title: digest.title,
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
          text: CurrentInputs.visible_preview(input.pruned_at, input.event_kind, input.content),
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
          episode_title: type(^nil, :string),
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
            CurrentInputs.visible_preview(
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

  # An episode reads as the name Work gave it; before any turn has named it,
  # as its first message.
  defp present(%{episode_title: title} = row, secrets) when is_binary(title) do
    %{present(%{row | episode_title: nil}, secrets) | title: redacted(title, secrets, 240)}
  end

  defp present(row, secrets) do
    text = redacted(row.text, secrets, 12_000)
    source = source(row.source)

    title =
      if text in [nil, ""],
        do: "Message text no longer available",
        else:
          text
          |> SlackMarkdown.plain(SlackNames.workspace_from_destination(row.conversation))
          |> String.slice(0, 200)

    row
    |> Map.drop([:text, :ref, :conversation, :episode_state, :episode_title])
    |> Map.merge(%{
      conversation: row.conversation,
      title: title,
      source: source,
      href:
        "/timeline/#{URI.encode_www_form(if row.kind == "episode", do: row.ref, else: "ingress-input:#{row.ref}")}"
    })
  end

  defp redacted(text, secrets, max_bytes) do
    artifact = InspectionRedactor.artifact(text, secrets: secrets, max_bytes: max_bytes)
    if artifact.text, do: String.trim(artifact.text)
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
    pattern = Search.contains(text)

    from(row in query,
      where:
        ilike(row.text, ^pattern) or ilike(row.repository, ^pattern) or ilike(row.ref, ^pattern) or
          ilike(row.conversation, ^pattern)
    )
  end

  defp search(query, _), do: query
end

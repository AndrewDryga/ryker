defmodule Ryker.ControlPlane.Activity do
  @moduledoc "A bounded conversation-first inbox, including work not yet admitted."
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputs

  alias Ryker.ControlPlane.{
    ConversationProjection,
    CurrentInputs,
    PagedRelation,
    Paths,
    RepositoryNames,
    Search,
    SlackMarkdown,
    UsageProjection
  }

  alias Ryker.Episodes.{Episode, RoutingDigest}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Schedules.Schedule
  alias Ryker.Schedules.ScheduleOccurrence
  alias Ryker.Slack.Names
  alias Ryker.Work.{Session, Turn}

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
    do: %{href: Paths.conversation(id), label: "Open in Chat"}

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
    Paths.query("/activity", Map.put(params, "thread", thread))
  end

  @doc """
  The conversations the Conversation filter offers, each named the way Chat
  and Slack name it: a chat by its title, a channel by its name. The most
  recently active come first within each source.
  """
  def conversation_filter_options do
    secrets = InspectionRedactor.configured_secrets()

    rows =
      from(row in subquery(rows()),
        distinct: [row.source, row.conversation],
        order_by: [row.source, row.conversation, desc: row.updated_at],
        limit: 500
      )
      |> Repo.all()
      |> Enum.sort_by(&{&1.source, -DateTime.to_unix(&1.updated_at, :microsecond)})

    chats =
      rows
      |> Enum.filter(&(&1.source == "control_plane"))
      |> Enum.map(& &1.conversation)
      |> ConversationProjection.titles()

    rows
    |> Enum.map(fn row ->
      label =
        if row.source == "control_plane",
          do:
            "Direct conversation · " <> (chats[row.conversation] || present(row, secrets).title),
          else: Names.destination(row.conversation)

      {row, label}
    end)
    |> distinguish_repeats()
    |> Enum.map(fn {row, label} ->
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

  # Chats often share a title ("What Ryker does"), and four identical entries
  # could not be told apart; each repeat carries the time of its latest
  # message, in UTC like every time in the workspace.
  defp distinguish_repeats(labelled) do
    counts = Enum.frequencies_by(labelled, &elem(&1, 1))

    Enum.map(labelled, fn {row, label} ->
      if counts[label] > 1,
        do: {row, label <> " · " <> Calendar.strftime(row.updated_at, "%-d %b, %H:%M UTC")},
        else: {row, label}
    end)
  end

  def request_titles([]), do: %{}

  def request_titles(refs) do
    refs = refs |> Enum.uniq() |> Enum.take(100)
    secrets = InspectionRedactor.configured_secrets()

    rows =
      Repo.all(from(row in subquery(rows()), where: row.kind == "episode" and row.ref in ^refs))

    names = repository_names(rows)
    Map.new(rows, fn row -> {row.ref, row |> present(secrets) |> named(names)} end)
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

  @doc """
  One page of requests for the Activity list, and how many requests each of
  its views holds under the same search and filters.

  `views` counts the rows the Needs you (`"attention"`), In progress
  (`"running"`) and Finished (`"done"`) views list, so a count that links to a
  view always equals what that view shows.
  """
  def list(params) do
    mode = if params["mode"] in ~w(shadow all), do: params["mode"], else: "live"
    base_query = from(row in subquery(rows()))
    searchable = Repo.exists?(base_query)
    query = base_query
    query = if mode == "all", do: query, else: from(row in query, where: row.mode == ^mode)

    query =
      query
      |> criteria_filters(params)
      |> conversation_filters(params)
      |> UsageProjection.filter_activity(params)
      |> search(params["q"])

    page =
      PagedRelation.read(
        filter(query, params["filter"]),
        [desc: :updated_at, desc: :id],
        "page",
        params,
        page_size: @page_size
      )

    secrets = InspectionRedactor.configured_secrets()
    names = repository_names(page.items)

    %{
      items: Enum.map(page.items, &(&1 |> present(secrets) |> named(names))),
      total: page.total,
      page: page.page,
      pages: page.pages,
      mode: mode,
      searchable: searchable,
      views: view_counts(query)
    }
  end

  defp view_counts(query) do
    counted =
      from(row in query, group_by: row.bucket, select: {row.bucket, count()})
      |> Repo.all()
      |> Map.new()

    Map.merge(%{"attention" => 0, "running" => 0, "done" => 0}, counted)
  end

  defp rows do
    now = DateTime.utc_now()

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
        left_join: checkout in subquery(checkouts()),
        on: checkout.episode_id == episode.id,
        left_join: scheduled in subquery(scheduled_runs()),
        on: scheduled.episode_id == episode.id,
        left_join: turn in Turn,
        on:
          turn.episode_id == episode.id and turn.turn_ref == episode.owner_ref and
            episode.owner_kind == :turn,
        left_join: digest in RoutingDigest,
        on: digest.episode_id == episode.id,
        left_join: task in subquery(confirmed_tasks()),
        on: task.episode_id == episode.id,
        select: %{
          id: episode.id,
          kind: type(^"episode", :string),
          episode_title: fragment("COALESCE(?, ?)", task.title, digest.title),
          task_kind: task.kind,
          schedule_title: scheduled.title,
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
          repository: fragment("COALESCE(?, ?)", input.repository, checkout.repository),
          source_available:
            not is_nil(input.content) and is_nil(input.pruned_at) and input.event_kind != :delete,
          text: CurrentInputs.visible_preview(input.pruned_at, input.event_kind, input.content),
          started_at: fragment("LEAST(?, ?)", episode.inserted_at, input.inserted_at),
          updated_at: episode.updated_at
        }
      )

    # A deletion is a revision of a message that already has its row, which
    # reads "Message deleted" from then on; as a row of its own it was a
    # second "Message deleted" counted as one more request (manual testing,
    # 2026-09-26). Routing settles deletions without a model, so no spend
    # loses its row.
    admissions =
      from(entry in Entry,
        join: current in subquery(CurrentInputs.latest()),
        on:
          current.native_input_id == entry.native_input_id and
            current.execution_mode == entry.execution_mode,
        where: is_nil(entry.episode_id),
        where: entry.event_kind != :delete,
        select: %{
          id: entry.id,
          kind: type(^"admission", :string),
          episode_title: type(^nil, :string),
          task_kind: type(^nil, :string),
          schedule_title: type(^nil, :string),
          ref: fragment("?::text", entry.id),
          conversation: entry.destination_conversation_ref,
          thread: entry.destination_thread_ref,
          episode_state: type(^nil, :string),
          mode: fragment("?::text", entry.execution_mode),
          state: CurrentInputs.input_state(entry, ^now),
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
          updated_at: entry.updated_at
        }
      )

    union_all(episodes, ^admissions)
  end

  # The repository the latest working copy checked out, for work whose
  # message named none.
  defp checkouts do
    from(session in Session,
      where: not is_nil(session.episode_id) and not is_nil(session.repository_ref),
      distinct: session.episode_id,
      order_by: [asc: session.episode_id, desc: session.generation],
      select: %{episode_id: session.episode_id, repository: session.repository_ref}
    )
  end

  # A task starts from its confirmation, not from a message: its row reads as the task, and says
  # what kind of task it is (Andrew, 2026-10-01).
  defp confirmed_tasks do
    from(record in Record,
      where:
        record.kind == "task_offer" and record.status == :confirmed and
          not is_nil(record.confirmed_episode_id),
      select: %{
        episode_id: record.confirmed_episode_id,
        title: fragment("(?::jsonb)->>'title'", record.payload),
        kind: fragment("(?::jsonb)->>'kind'", record.payload)
      }
    )
  end

  # A scheduled run starts from its schedule, not from a message.
  defp scheduled_runs do
    from(occurrence in ScheduleOccurrence,
      join: schedule in Schedule,
      on: schedule.id == occurrence.schedule_id,
      where: not is_nil(occurrence.child_episode_id),
      distinct: occurrence.child_episode_id,
      order_by: [asc: occurrence.child_episode_id, asc: occurrence.scheduled_for],
      select: %{episode_id: occurrence.child_episode_id, title: schedule.title}
    )
  end

  # An episode reads as the name Work gave it; before any turn has named it,
  # a scheduled run as its schedule and anything else as its first message.
  defp present(%{episode_title: title} = row, secrets) when is_binary(title) do
    %{present(%{row | episode_title: nil}, secrets) | title: redacted(title, secrets, 240)}
  end

  defp present(%{schedule_title: title} = row, secrets) when is_binary(title) do
    %{present(%{row | schedule_title: nil}, secrets) | title: redacted(title, secrets, 240)}
  end

  defp present(row, secrets) do
    text = redacted(row.text, secrets, 12_000)
    source = source(row.source)

    title =
      if text in [nil, ""],
        do: "Message text no longer available",
        else:
          text
          |> SlackMarkdown.plain(Names.workspace_from_destination(row.conversation))
          |> String.slice(0, 200)

    row
    |> Map.drop([
      :text,
      :ref,
      :conversation,
      :episode_state,
      :episode_title,
      :schedule_title,
      :task_kind
    ])
    |> Map.merge(%{
      conversation: row.conversation,
      kind_label: kind_label(row[:task_kind]),
      title: title,
      source: source,
      href: Paths.request(row.id)
    })
  end

  # Rows carry a repository's ref; a person reads its owner/repo name.
  defp repository_names(rows),
    do: if(Enum.any?(rows, & &1.repository), do: RepositoryNames.all(), else: %{})

  defp named(item, names), do: %{item | repository: RepositoryNames.name(names, item.repository)}

  defp redacted(text, secrets, max_bytes) do
    artifact = InspectionRedactor.artifact(text, secrets: secrets, max_bytes: max_bytes)
    if artifact.text, do: String.trim(artifact.text)
  end

  defp kind_label("engineering"), do: "Engineering task"
  defp kind_label("incident"), do: "Incident task"
  defp kind_label(_kind), do: nil

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
    Enum.reduce(~w(state repository), query, fn key, query ->
      case params[key] do
        value when is_binary(value) and value != "" -> criteria_filter(query, key, value)
        _ -> query
      end
    end)
  end

  defp criteria_filter(query, "state", value),
    do: from(row in query, where: row.episode_state == ^value)

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
          ilike(row.conversation, ^pattern) or ilike(row.schedule_title, ^pattern)
    )
  end

  defp search(query, _), do: query
end

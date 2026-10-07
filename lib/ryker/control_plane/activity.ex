defmodule Ryker.ControlPlane.Activity do
  @moduledoc "A bounded conversation-first inbox, including work not yet admitted."
  alias Ryker.ControlPlane.{Activity, ConversationProjection, PagedRelation, Paths}
  alias Ryker.ControlPlane.{RepositoryNames, Search, ShortTime, SlackMarkdown, UsageProjection}
  alias Ryker.Episodes.{Episode, Words}
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Slack.Names

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
      transport
      |> Episode.Query.by_conversation(conversation_ref)
      |> Episode.Query.by_execution_mode(execution_mode)
      |> Repo.aggregate(:count)

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
  The conversations the Conversation filter offers, most recently active
  first, each named the way Chat and Slack name it: a chat by its title, a
  channel by its name. `conversation_name` is that name and
  `conversation_source` the word for where it is, which the filter's list
  shows side by side; `conversation_label` is both in one phrase, for the
  chip of a chosen one.
  """
  def conversation_filter_options do
    secrets = InspectionRedactor.configured_secrets()

    rows = DateTime.utc_now() |> Activity.Query.latest_per_conversation(500) |> Repo.all()

    chats =
      rows
      |> Enum.filter(&(&1.source == "control_plane"))
      |> Enum.map(& &1.conversation)
      |> ConversationProjection.titles()

    rows
    |> Enum.map(fn row ->
      name =
        if row.source == "control_plane",
          do: chats[row.conversation] || present(row, secrets).title,
          else: Names.destination(row.conversation)

      {row, name}
    end)
    |> distinguish_repeats()
    |> Enum.map(fn {row, name} ->
      %{
        source: row.source,
        transport: row.source,
        conversation_ref: row.conversation,
        conversation_label:
          if(row.source == "control_plane", do: "Direct conversation · " <> name, else: name),
        conversation_name: name,
        conversation_source: source_word(row.source),
        actor: nil,
        actor_kind: nil,
        workspace: nil
      }
    end)
  end

  defp source_word("control_plane"), do: "Chat"
  defp source_word("slack"), do: "Slack"
  defp source_word("github"), do: "GitHub"
  defp source_word(source), do: Words.label(source)

  # Chats often share a title ("What Ryker does"), and four identical entries
  # could not be told apart; each repeat carries the time of its latest
  # message, in UTC like every time in the workspace.
  defp distinguish_repeats(labelled) do
    counts = Enum.frequencies_by(labelled, &elem(&1, 1))

    Enum.map(labelled, fn {row, label} ->
      if counts[label] > 1,
        do: {row, label <> " · " <> ShortTime.stamp(row.updated_at, DateTime.utc_now())},
        else: {row, label}
    end)
  end

  def request_titles([]), do: %{}

  def request_titles(refs) do
    refs = refs |> Enum.uniq() |> Enum.take(100)
    secrets = InspectionRedactor.configured_secrets()

    rows = DateTime.utc_now() |> Activity.Query.requests(refs) |> Repo.all()

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
    base_query = Activity.Query.rows(DateTime.utc_now())
    searchable = Repo.exists?(base_query)
    query = if mode == "all", do: base_query, else: Activity.Query.by_mode(base_query, mode)

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
    counted = query |> Activity.Query.bucket_counts() |> Repo.all() |> Map.new()

    Map.merge(%{"attention" => 0, "running" => 0, "done" => 0}, counted)
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
    do: Activity.Query.by_bucket(query, value)

  defp filter(query, _), do: query

  defp conversation_filters(query, params) do
    Enum.reduce(
      [{"conversation", :conversation}, {"thread", :thread}, {"transport", :source}],
      query,
      fn
        {key, column}, query ->
          case params[key] do
            value when is_binary(value) and byte_size(value) in 1..512 ->
              Activity.Query.by_column(query, column, value)

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

  defp criteria_filter(query, "state", value), do: Activity.Query.by_episode_state(query, value)

  # The repository the row shows; the filter matched the one the work checked
  # out, though the row showed the one its message came with (2026-10-04
  # review).
  defp criteria_filter(query, "repository", value),
    do: Activity.Query.by_repository(query, value)

  # What a row shows, as it shows it: the name Work gave the request, the
  # repository as owner/repo and the channel by its name. Refs alone missed
  # all three (2026-10-04 review).
  defp search(query, text) when is_binary(text) and byte_size(text) > 0 do
    Activity.Query.matching(
      query,
      Search.contains(text),
      repositories_named(text),
      Names.conversations_named(text)
    )
  end

  defp search(query, _), do: query

  # The names a row shows for its refs: a repository as owner/repo, a channel by its name.
  defp repositories_named(text) do
    needle = String.downcase(text)

    for {ref, name} <- RepositoryNames.all(),
        String.contains?(String.downcase(name), needle),
        do: ref
  end
end

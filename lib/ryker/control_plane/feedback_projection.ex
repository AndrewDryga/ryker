defmodule Ryker.ControlPlane.FeedbackProjection do
  @moduledoc """
  The Feedback page (`/feedback`) and a request's Feedback chapter on
  its Timeline: what people told Ryker about its answers (`Ryker.Feedback`),
  by category, frustrated first, and over time.

  The page opens on every category at once: how many of each, what there is
  to fix (`Ryker.ControlPlane.ImprovementProjection.summary/0`), a table of
  the latest days, and the newest few of each category with the way to all
  of them. One category (`?category=frustrated`) is a sub-page of its own: every
  signal of that kind, newest first under day headings, a page at a time.
  Negative and Positive (`?tone=negative`) narrow the page to the feedback
  that went that way (`Ryker.ControlPlane.FeedbackChart.tones/0`).
  Search narrows both by what a signal says (a reason, a note, an emoji) and
  by the request it is about. Each row names its request as Activity names
  it and opens its Timeline.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{
    Activity,
    ConsolePeople,
    CurrentInputs,
    FeedbackChart,
    ImprovementProjection,
    PagedRelation,
    Paths,
    Search,
    SlackMarkdown
  }

  alias Ryker.Episodes.{Episode, RoutingDigest}
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Slack.Names

  require CurrentInputs

  @overview_rows 5
  @page_size 50
  @days 14

  @doc "The query keys the Feedback page reads."
  def query_keys, do: ["category", "page", "q", "tone"]

  @doc "The categories, frustrated first (`Ryker.Feedback.Signal.categories/0`)."
  def categories, do: Signal.categories()

  @doc "The category a query names, or nil for every category."
  @spec category(term()) :: atom() | nil
  def category(value) when is_binary(value),
    do: Enum.find(Signal.categories(), &(Atom.to_string(&1) == value))

  def category(_value), do: nil

  @doc "Which way the feedback a query asks for went, or nil for all of it."
  @spec tone(term()) :: :negative | :positive | nil
  def tone("negative"), do: :negative
  def tone("positive"), do: :positive
  def tone(_value), do: nil

  @doc """
  One read of the Feedback page for `params`: the counts by category, the
  latest days, and either the newest of each category or one category's page.
  """
  @spec page(map()) :: map()
  def page(params) when is_map(params) do
    text = Search.term(params["q"]) || ""
    category = category(params["category"])
    # One kind's page lists that kind, whichever way it went.
    tone = if category, do: nil, else: tone(params["tone"])
    matching = from(signal in Signal, as: :signal) |> search(text) |> going(tone)
    counts = counts(matching)

    view = %{
      category: category,
      counts: counts,
      # By day is all feedback, whatever the search or Negative and Positive.
      days: days(from(signal in Signal, as: :signal)),
      q: text,
      tone: tone,
      total: counts |> Map.values() |> Enum.sum()
    }

    case category do
      nil ->
        view
        |> Map.put(:groups, groups(matching, counts))
        # What to fix is about the requests people were unhappy with.
        |> Map.put(:improvement, if(tone != :positive, do: ImprovementProjection.summary()))

      category ->
        Map.merge(view, category_page(matching, category, params))
    end
  end

  @doc """
  A request's feedback for its Timeline, oldest first: an episode's
  (`{:episode, id}`), with how people rated it, or a message's routing
  answered by itself (`{:input, id}`).
  """
  @spec for_request(Ryker.Feedback.request()) :: [map()]
  def for_request({:episode, id}) when is_binary(id),
    do: from(signal in Signal, where: signal.episode_id == ^id) |> timeline_rows()

  def for_request({:input, id}) when is_binary(id),
    do: from(signal in Signal, where: signal.input_id == ^id) |> timeline_rows()

  def for_request(_request), do: []

  defp timeline_rows(query) do
    from(signal in query,
      order_by: [desc: signal.occurred_at, desc: signal.inserted_at, desc: signal.id],
      limit: 100
    )
    |> Repo.all()
    |> Enum.reverse()
    |> present()
  end

  # -- Reading ---------------------------------------------------------------------

  # A search matches what a signal says (its note or its emoji) and the name
  # of the request it is about: the title Ryker gave it, or the message routing
  # answered by itself.
  defp search(query, ""), do: query

  defp search(query, text) do
    pattern = Search.contains(text)

    from([signal: signal] in query,
      left_join: digest in RoutingDigest,
      on: digest.episode_id == signal.episode_id,
      left_join: input in Entry,
      on: input.id == signal.input_id,
      where:
        ilike(signal.note, ^pattern) or ilike(signal.value, ^pattern) or
          ilike(digest.title, ^pattern) or
          fragment("(?::jsonb ->> 'text') ILIKE ?", input.content, ^pattern)
    )
  end

  defp going(query, nil), do: query

  defp going(query, tone) do
    categories = Keyword.fetch!(FeedbackChart.tones(), tone)
    from([signal: signal] in query, where: signal.category in ^categories)
  end

  defp counts(query) do
    from([signal: signal] in query, group_by: signal.category, select: {signal.category, count()})
    |> Repo.all()
    |> Map.new()
  end

  # The latest days that have any feedback, newest first, with how many of
  # each category came in on each. Days are UTC, like every time here.
  defp days(query) do
    rows =
      from([signal: signal] in query,
        group_by: [fragment("date(?)", signal.occurred_at), signal.category],
        select: {fragment("date(?)", signal.occurred_at), signal.category, count()}
      )
      |> Repo.all()

    rows
    |> Enum.group_by(&elem(&1, 0), fn {_day, category, count} -> {category, count} end)
    |> Enum.map(fn {day, counts} -> %{day: day, counts: Map.new(counts)} end)
    |> Enum.sort_by(& &1.day, {:desc, Date})
    |> Enum.take(@days)
  end

  # The newest few of each category that has any, frustrated first.
  defp groups(query, counts) do
    ranked =
      from([signal: signal] in query,
        select: %{
          id: signal.id,
          rank:
            over(row_number(),
              partition_by: signal.category,
              order_by: [desc: signal.occurred_at, desc: signal.inserted_at, desc: signal.id]
            )
        }
      )

    newest =
      from(signal in Signal,
        join: ranked in subquery(ranked),
        on: ranked.id == signal.id,
        where: ranked.rank <= @overview_rows,
        order_by: [desc: signal.occurred_at, desc: signal.inserted_at, desc: signal.id]
      )
      |> Repo.all()
      |> present()
      |> Enum.group_by(& &1.category)

    for category <- Signal.categories(), Map.get(counts, category, 0) > 0 do
      %{
        category: category,
        items: Map.get(newest, category, []),
        total: Map.fetch!(counts, category)
      }
    end
  end

  defp category_page(query, category, params) do
    page =
      PagedRelation.read(
        from([signal: signal] in query, where: signal.category == ^category),
        [desc: :occurred_at, desc: :inserted_at, desc: :id],
        "page",
        params,
        page_size: @page_size
      )

    %{items: present(page.items), page: page.page, pages: page.pages, listed: page.total}
  end

  # -- Presenting --------------------------------------------------------------------

  # Each signal with the request it is about, named as Activity names it, and
  # the person who gave it.
  defp present([]), do: []

  defp present(signals) do
    requests = requests(signals)

    Enum.map(signals, fn %Signal{} = signal ->
      request = request(requests, signal)

      %{
        id: signal.id,
        at: signal.occurred_at,
        category: signal.category,
        kind: signal.kind,
        note: redacted(signal.note, 2_048),
        value: signal.value,
        request: request,
        who: who(signal, request),
        message_href: message_href(signal.source_ref)
      }
    end)
  end

  @doc """
  The requests `records` are about, named as Activity names them, each with
  its Timeline link and where it happened: every record carries an
  `episode_id` or an `input_id`, as feedback and improvement candidates do.
  Read it with `request/2`.
  """
  @spec requests([map()]) :: %{episodes: map(), inputs: map()}
  def requests(records),
    do: %{episodes: episode_requests(records), inputs: input_requests(records)}

  @doc "The request one record is about, from `requests/1`, or the words for one that is gone."
  @spec request(map(), map()) :: map()
  def request(%{episodes: episodes, inputs: inputs}, record) do
    found =
      if record.episode_id,
        do: Map.get(episodes, record.episode_id),
        else: Map.get(inputs, record.input_id)

    found || gone_request()
  end

  defp episode_requests(signals) do
    ids = signals |> Enum.map(& &1.episode_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    keys =
      Repo.all(
        from(episode in Episode,
          where: episode.id in ^ids,
          select: {episode.id, episode.key, episode.destination_conversation_ref}
        )
      )

    titles = keys |> Enum.map(&elem(&1, 1)) |> Activity.request_titles()

    Map.new(keys, fn {id, key, conversation} ->
      title = Map.get(titles, key, %{})

      {id,
       %{
         title: title[:title] || "Request",
         href: Paths.request(id),
         conversation: conversation,
         where: place(title[:source], conversation)
       }}
    end)
  end

  defp input_requests(signals) do
    ids = signals |> Enum.map(& &1.input_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(
      from(entry in Entry,
        where: entry.id in ^ids,
        select:
          {entry.id, entry.destination_transport, entry.destination_conversation_ref,
           CurrentInputs.visible_preview(
             entry.operational_pruned_at,
             entry.event_kind,
             entry.content
           )}
      )
    )
    |> Map.new(fn {id, transport, conversation, preview} ->
      {id,
       %{
         title: message_title(preview, conversation),
         href: Paths.request(id),
         conversation: conversation,
         where: place(source(transport), conversation)
       }}
    end)
  end

  defp gone_request,
    do: %{title: "Request no longer on file", href: nil, conversation: nil, where: nil}

  defp message_title(preview, conversation) do
    case redacted(preview, 12_000) do
      text when is_binary(text) and text != "" ->
        text
        |> SlackMarkdown.plain(Names.workspace_from_destination(conversation))
        |> String.slice(0, 200)

      _gone ->
        "Message text no longer available"
    end
  end

  defp source("slack"), do: "Slack"
  defp source("control_plane"), do: "Direct conversation"
  defp source(_transport), do: "Integration"

  defp place("Slack", conversation) when is_binary(conversation),
    do: Names.destination(conversation)

  defp place(source, _conversation), do: source

  # A Slack person is named from the names cache, someone in Chat by the name
  # their sign-in gave them, and the console reached without one is "You".
  defp who(%Signal{source: "slack", actor_ref: actor}, request) do
    case Names.person(Names.workspace_from_destination(request.conversation), actor) do
      %{name: name, href: href} -> %{name: name, href: href}
      _nobody -> %{name: "Slack user", href: nil}
    end
  end

  defp who(%Signal{actor_ref: actor}, _request),
    do: ConsolePeople.person(actor) || %{name: "You", href: nil}

  defp message_href("ingress-input:" <> _id = ref), do: Paths.request(ref)

  defp message_href(_source_ref), do: nil

  defp redacted(nil, _max_bytes), do: nil

  defp redacted(text, max_bytes) do
    artifact = InspectionRedactor.artifact(text, max_bytes: max_bytes)
    if artifact.text, do: String.trim(artifact.text)
  end
end

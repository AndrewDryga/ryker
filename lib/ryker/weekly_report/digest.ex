defmodule Ryker.WeeklyReport.Digest do
  @moduledoc """
  The weekly report's words, from its facts (`Ryker.WeeklyReport.Facts`) and
  nothing else, said the way a teammate says it at a weekly standup
  (Andrew, 2026-09-28: "make it more like a human would say on weekly
  standup, what work it did, how much work handled, not going too deep into
  metrics that are not about value delivered"):

      **Weekly update**
      Mon 21 Sep to Mon 28 Sep

      This week I worked on 12 requests and finished 9 of them. I also
      answered 30 messages on the spot and opened 1 draft PR.

      **Done**
      - Fix the checkout alert in #ops · draft PR #4
      - and 8 more

      **Still open**
      - Track Terraform run 42 in #infra, watching for an update

      **Stuck**
      Nothing is stuck.

      Feedback this week: 4 positive and 1 negative. I learned 6 new
      things, most recently about “Deploy freeze”.

  Done, Still open and Stuck are always there, saying Nothing when there is
  nothing, because a part that disappears reads as a good week. The closing
  line says only what there is.

  The text is the Markdown Slack's `markdown` block reads, and the control
  plane's preview renders the same text (`Ryker.ControlPlane.SlackMarkdown`),
  so what the page shows is what the channel gets. A request's title is
  kept to one bounded line and cannot become a link or a mention.
  """

  @title_characters 160

  @type section :: %{key: atom(), title: String.t(), lines: [String.t()]}
  @type t :: %{
          title: String.t(),
          period: String.t(),
          summary: String.t(),
          sections: [section()],
          closing: String.t() | nil,
          text: String.t()
        }

  @doc """
  The report for `facts`. `options`: `:base_url`, the console's address the
  links start with, `:time_zone_database`, which reads the week's zone, and
  `:preview`, true for a preview a person sent from Settings.
  """
  @spec render(map(), keyword()) :: t()
  def render(facts, options) do
    base = options |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")
    database = Keyword.get(options, :time_zone_database, Calendar.get_time_zone_database())

    title =
      if Keyword.get(options, :preview, false),
        do: "Weekly update (preview)",
        else: "Weekly update"

    period = period(facts.week, database)
    summary = summary(facts)

    sections = [
      section(:done, "Done", done(facts.done, base)),
      section(:open, "Still open", open(facts.open, base)),
      section(:stuck, "Stuck", stuck(facts.stuck, base))
    ]

    closing = closing(facts)

    %{
      title: title,
      period: period,
      summary: summary,
      sections: sections,
      closing: closing,
      text: text(title, period, summary, sections, closing)
    }
  end

  defp text(title, period, summary, sections, closing) do
    (["**#{title}**\n#{period}", summary] ++
       Enum.map(sections, &Enum.join(["**#{&1.title}**" | &1.lines], "\n")) ++
       List.wrap(closing))
    |> Enum.join("\n\n")
  end

  # "Mon 21 Sep to Mon 28 Sep", each day in the report's zone.
  defp period(%{from: from, to: to, timezone: zone}, database),
    do: "#{day(from, zone, database)} to #{day(to, zone, database)}"

  defp day(moment, zone, database) do
    local =
      case DateTime.shift_zone(moment, zone, database) do
        {:ok, local} -> local
        {:error, _reason} -> moment
      end

    Calendar.strftime(local, "%a %-d %b")
  end

  # -- How much work -------------------------------------------------------------------

  defp summary(%{requests: %{total: 0}, replied: 0, pull_requests: 0}),
    do: "It was a quiet week: nobody asked me for anything."

  defp summary(facts) do
    also =
      phrases([
        {facts.replied, "answered #{count(facts.replied, "message")} on the spot"},
        {facts.pull_requests, "opened #{count(facts.pull_requests, "draft PR")}"}
      ])

    case {worked(facts.requests), also} do
      {worked, ""} -> worked
      {nil, also} -> "This week I #{also}."
      {worked, also} -> "#{worked} I also #{also}."
    end
  end

  defp worked(%{total: 0}), do: nil

  defp worked(%{total: 1, finished: 1}), do: "This week I worked on 1 request and finished it."
  defp worked(%{total: 1}), do: "This week I worked on 1 request; it isn't finished yet."

  defp worked(%{total: total, finished: total}),
    do: "This week I worked on #{total} requests and finished all of them."

  defp worked(%{total: total, finished: 0}),
    do: "This week I worked on #{total} requests; none is finished yet."

  defp worked(%{total: total, finished: finished}),
    do: "This week I worked on #{total} requests and finished #{finished} of them."

  # -- Done and still open -------------------------------------------------------------

  defp done(%{total: 0}, _base), do: ["Nothing."]
  defp done(done, base), do: requests(done, base, &pull_request/1)

  defp open(%{total: 0}, _base), do: ["Nothing."]
  defp open(open, base), do: requests(open, base, &standing/1)

  # The named requests, one line each, then how many more there are; when
  # none may be named, only how many.
  defp requests(%{named: [], total: total, private: total}, _base, _detail),
    do: ["#{count(total, "request")} in private conversations."]

  defp requests(%{named: [], total: total}, _base, _detail), do: ["#{count(total, "request")}."]

  defp requests(%{named: named, total: total}, base, detail) do
    Enum.map(named, &request_line(&1, base, detail)) ++ more(total - length(named))
  end

  defp request_line(request, base, detail),
    do:
      "- [#{plain(request.title)}](#{base}#{request.href}) in #{plain(request.where)}" <>
        detail.(request)

  defp pull_request(%{pull_request: %{number: number, url: url}}),
    do: " · [draft PR ##{number}](#{url})"

  defp pull_request(_request), do: ""

  defp standing(%{standing: :waiting}), do: ", waiting for an answer"
  defp standing(%{standing: :watching}), do: ", watching for an update"
  defp standing(%{standing: :stuck}), do: ", stuck"
  defp standing(%{standing: :going}), do: ", in progress"

  defp more(0), do: []
  defp more(count), do: ["- and #{count} more"]

  # -- Stuck ---------------------------------------------------------------------------

  defp stuck(:unavailable, base),
    do: ["I couldn't check [Failures](#{base}/failures) while writing this."]

  defp stuck(%{total: 0}, _base), do: ["Nothing is stuck."]

  defp stuck(stuck, base) do
    how_many = if stuck.partial, do: "At least #{stuck.total}", else: "#{stuck.total}"

    things =
      if stuck.total == 1,
        do: "thing needs someone to look at it",
        else: "things need someone to look at them"

    ["#{how_many} #{things}:"] ++
      Enum.map(stuck.named, &"- [#{plain(&1.title)}](#{base}#{&1.href})") ++
      case stuck.total - length(stuck.named) do
        0 -> []
        more -> ["- and #{more} more on [Failures](#{base}/failures)"]
      end
  end

  # -- Feedback and what Ryker learned -------------------------------------------------

  defp closing(facts) do
    [feedback(facts.feedback), learned(facts.learned)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp feedback(%{positive: 0, negative: 0}), do: nil

  defp feedback(%{positive: positive, negative: negative}),
    do:
      "Feedback this week: " <>
        phrases([{positive, "#{positive} positive"}, {negative, "#{negative} negative"}]) <> "."

  defp learned(%{count: 0}), do: nil
  defp learned(%{count: 1, newest: nil}), do: "I learned 1 new thing."
  defp learned(%{count: count, newest: nil}), do: "I learned #{count} new things."
  defp learned(%{count: 1, newest: name}), do: "I learned 1 new thing, about “#{plain(name)}”."

  defp learned(%{count: count, newest: name}),
    do: "I learned #{count} new things, most recently about “#{plain(name)}”."

  # -- Words ---------------------------------------------------------------------------

  defp section(key, title, lines), do: %{key: key, title: title, lines: lines}

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{count} #{noun}s"

  # The parts with anything to say, as one list: "a, b and c".
  defp phrases(parts) do
    case for({count, phrase} <- parts, count > 0, do: phrase) do
      [] -> ""
      [only] -> only
      several -> Enum.join(Enum.drop(several, -1), ", ") <> " and " <> List.last(several)
    end
  end

  # Words from a request or a topic as the report shows them: on one line,
  # bounded, with the brackets that would make Markdown a link turned into
  # plain ones, so a title can name a link or a person but never become one.
  # The publisher escapes the rest, so no title becomes a mention either.
  defp plain(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(["[", "]"], fn
      "[" -> "("
      "]" -> ")"
    end)
    |> String.replace("“", "\"")
    |> String.replace("”", "\"")
    |> String.trim()
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) <= @title_characters,
      do: text,
      else: String.slice(text, 0, @title_characters - 1) <> "…"
  end
end

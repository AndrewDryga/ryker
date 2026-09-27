defmodule Ryker.WeeklyReport.Digest do
  @moduledoc """
  The weekly report's words, from its facts (`Ryker.WeeklyReport.Facts`) and
  nothing else: a title and the week it covers, then Requests, Feedback, What
  to fix, Corrections, Learned, Needs a person and Cost, each a colonless
  heading over a few plain sentences and a link to the page that holds the
  rest.

  A section with nothing to say says None instead of leaving itself out,
  because a section that disappears reads as a good week. Last week's number
  sits beside this week's where the two compare.

  The text is the Markdown Slack's `markdown` block reads, and the control
  plane's preview renders the same text (`Ryker.ControlPlane.SlackMarkdown`),
  so what the page shows is what the channel gets. Quoted words are kept to
  one bounded line and cannot become a link or a mention.
  """

  alias Ryker.ControlPlane.ImprovementPage

  @quote_characters 240

  @type section :: %{key: atom(), title: String.t(), lines: [String.t()]}
  @type t :: %{title: String.t(), period: String.t(), sections: [section()], text: String.t()}

  @doc """
  The report for `facts`. `options`: `:base_url`, the console's address the
  links start with, and `:time_zone_database`, which reads the week's zone.
  """
  @spec render(map(), keyword()) :: t()
  def render(facts, options) do
    base = options |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")
    database = Keyword.get(options, :time_zone_database, Calendar.get_time_zone_database())

    sections = [
      requests(facts.requests, base),
      feedback(facts.feedback, base),
      fix(facts.improvement, base),
      corrections(facts.corrections, base),
      learned(facts.learned, base),
      people(facts.failures, base),
      cost(facts.cost, base)
    ]

    title = "Weekly report"
    period = period(facts.week, database)

    %{
      title: title,
      period: period,
      sections: sections,
      text: text(title, period, sections)
    }
  end

  defp text(title, period, sections) do
    [
      "**#{title}**\n#{period}"
      | Enum.map(sections, fn section ->
          Enum.join(["**#{section.title}**" | section.lines], "\n")
        end)
    ]
    |> Enum.join("\n\n")
  end

  # "How my week went, from Mon 21 Sep 09:00 to Mon 28 Sep 09:00 UTC." Each
  # end names its own zone when a clock change falls inside the week.
  defp period(%{from: from, to: to, timezone: zone}, database) do
    from = local(from, zone, database)
    to = local(to, zone, database)

    if from.zone_abbr == to.zone_abbr,
      do: "How my week went, from #{moment(from)} to #{moment(to)} #{to.zone_abbr}.",
      else:
        "How my week went, from #{moment(from)} #{from.zone_abbr} to #{moment(to)} #{to.zone_abbr}."
  end

  defp local(moment, zone, database) do
    case DateTime.shift_zone(moment, zone, database) do
      {:ok, local} -> local
      {:error, _reason} -> moment
    end
  end

  defp moment(local), do: Calendar.strftime(local, "%a %-d %b %H:%M")

  # -- Requests ----------------------------------------------------------------------

  defp requests(%{messages: messages, work: work} = facts, base) do
    lines =
      if messages.total == 0 and work.total == 0 do
        [none(last_counts(facts.previous_messages, "message", facts.previous_work, "request"))]
      else
        [read(messages, facts.previous_messages), took_on(work, facts.previous_work)]
        |> Enum.reject(&is_nil/1)
      end

    section(:requests, "Requests", lines ++ [open(base, "Activity", "/activity")])
  end

  defp read(messages, previous) do
    outcomes =
      phrases([
        {messages.answered, "#{messages.answered} answered right away"},
        {messages.no_answer, "#{messages.no_answer} needed no response"},
        {messages.work, "#{messages.work} started or continued a request"},
        {messages.blocked, "#{messages.blocked} #{are(messages.blocked)} blocked before routing"},
        {messages.reading, "#{messages.reading} #{are(messages.reading)} still being read"}
      ])

    "I read #{count(messages.total, "message")}#{last(previous)}" <>
      if(outcomes == "", do: ".", else: ": #{outcomes}.")
  end

  defp took_on(%{total: 0}, 0), do: nil

  defp took_on(%{total: 0}, previous),
    do: "I took on no new requests (last week #{previous})."

  defp took_on(work, previous) do
    outcomes =
      phrases([
        {work.finished, "#{work.finished} #{are(work.finished)} done"},
        {work.waiting, "#{work.waiting} #{are(work.waiting)} waiting for a person"},
        {work.blocked, "#{work.blocked} #{are(work.blocked)} blocked"},
        {work.stopped, "#{work.stopped} #{was(work.stopped)} stopped"},
        {work.going, "#{work.going} #{are(work.going)} still going"}
      ])

    "I took on #{count(work.total, "request")}#{last(previous)}: #{outcomes}."
  end

  # -- Feedback ----------------------------------------------------------------------

  defp feedback(%{counts: counts, previous: previous, frustrated: frustrated}, base) do
    total = counts |> Map.drop([:positive, :negative]) |> Map.values() |> Enum.sum()

    lines =
      if total == 0 do
        [none(last_feedback(previous))]
      else
        [
          "#{counts.positive} positive and #{counts.negative} negative" <>
            " (last week #{previous.positive} and #{previous.negative}).",
          negative(counts),
          others(counts)
        ] ++ frustrated_lines(frustrated, base)
      end

    section(
      :feedback,
      "Feedback",
      Enum.reject(lines, &is_nil/1) ++ [open(base, "Feedback", "/memory/feedback")]
    )
  end

  defp last_feedback(%{positive: 0, negative: 0}), do: nil

  defp last_feedback(previous),
    do: "#{previous.positive} positive and #{previous.negative} negative"

  defp negative(%{negative: 0}), do: nil

  defp negative(counts) do
    "Negative: " <>
      phrases([
        {counts.frustrated, "#{counts.frustrated} frustrated"},
        {counts.asked_again, "#{counts.asked_again} asked again"},
        {counts.edited, "#{counts.edited} edited or deleted their message"}
      ]) <> "."
  end

  defp others(%{neutral: 0, reviewed: 0}), do: nil

  defp others(counts) do
    "Also " <>
      phrases([
        {counts.neutral, "#{counts.neutral} neutral"},
        {counts.reviewed, count(counts.reviewed, "review")}
      ]) <> "."
  end

  defp frustrated_lines([], _base), do: []

  defp frustrated_lines(requests, base),
    do: ["Frustrated:" | Enum.map(requests, &frustrated_line(&1, base))]

  defp frustrated_line(%{href: nil}, _base), do: "- A request no longer on file"

  defp frustrated_line(%{title: nil, href: href}, base),
    do: "- A request in a private conversation · [Timeline](#{base}#{href})"

  defp frustrated_line(request, base),
    do:
      "- #{quoted(request.title)} in #{plain(request.where)} · [Timeline](#{base}#{request.href})"

  # -- What to fix -------------------------------------------------------------------

  defp fix(%{found: 0, accepted: 0, dismissed: 0, sure: nil}, base),
    do:
      section(:fix, "What to fix", [none(nil), open(base, "What to fix", "/memory/feedback/fix")])

  defp fix(week, base) do
    lines = [ImprovementPage.week_words(week), sure(week.sure)]
    section(:fix, "What to fix", lines ++ [open(base, "What to fix", "/memory/feedback/fix")])
  end

  defp sure(nil), do: "Newest sure diagnosis: none."

  defp sure(%{text: text}) when is_binary(text) and text != "",
    do: "Newest sure diagnosis: #{quoted(text)}"

  defp sure(_private),
    do: "The newest sure diagnosis is about a private conversation; What to fix has it."

  # -- Corrections -------------------------------------------------------------------

  defp corrections(%{routing: %{answers: 0}, work: %{answers: 0}} = facts, base) do
    previous =
      last_counts(
        facts.previous_routing.answers,
        "routing answer",
        facts.previous_work.answers,
        "Work answer"
      )

    section(:corrections, "Corrections", [none(previous), open(base, "Usage & cost", "/usage")])
  end

  defp corrections(facts, base) do
    lines = [
      checked("Routing", facts.routing, facts.previous_routing, "needed a correction"),
      checked("Work", facts.work, facts.previous_work, "were sent back to be fixed"),
      repeated(facts.repeated)
    ]

    section(
      :corrections,
      "Corrections",
      Enum.reject(lines, &is_nil/1) ++ [open(base, "Usage & cost", "/usage")]
    )
  end

  defp checked(_lane, %{answers: 0}, %{answers: 0}, _words), do: nil

  defp checked(lane, this, previous, words) do
    "#{lane}: #{this.corrected} of #{count(this.answers, "answer")} #{words}" <>
      if(previous.answers == 0,
        do: " (none last week).",
        else: " (last week #{previous.corrected} of #{previous.answers})."
      )
  end

  defp repeated(nil), do: "Most repeated: none."

  defp repeated(%{text: text, times: times}),
    do: "Most repeated: #{quoted(text)} (#{times(times)})."

  # -- Learned -----------------------------------------------------------------------

  defp learned(%{facts: 0, topics: 0} = facts, base) do
    previous = last_counts(facts.previous_facts, "fact", facts.previous_topics, "topic")
    section(:learned, "Learned", [none(previous), learned_links(base)])
  end

  defp learned(facts, base) do
    lines = [
      "#{count(facts.facts, "new fact")} (last week #{facts.previous_facts}) and " <>
        "#{count(facts.topics, "new topic")} (last week #{facts.previous_topics})."
      | newest(facts.newest, base)
    ]

    section(:learned, "Learned", lines ++ [learned_links(base)])
  end

  defp newest([], _base), do: ["The newest are from private conversations."]

  defp newest(items, base) do
    ["Newest:" | Enum.map(items, &newest_line(&1, base))]
  end

  defp newest_line(%{kind: :fact, name: name}, _base), do: "- Fact: #{quoted(name)}"

  defp newest_line(%{kind: :topic, name: name, path: path}, base),
    do: "- Topic: #{quoted(name)} · [Open](#{base}#{path})"

  defp learned_links(base),
    do: "Open [Facts](#{base}/memory) or [Learned](#{base}/memory/learned)."

  # -- Needs a person ----------------------------------------------------------------

  defp people(:unavailable, base) do
    section(:people, "Needs a person", [
      "I could not read Failures while writing this report.",
      open(base, "Failures", "/failures")
    ])
  end

  defp people(%{people: 0}, base),
    do: section(:people, "Needs a person", [none(nil), open(base, "Failures", "/failures")])

  defp people(failures, base) do
    how_many = if failures.partial, do: "At least #{failures.people}", else: "#{failures.people}"

    lines =
      [
        "#{how_many} #{if failures.people == 1, do: "failure leaves", else: "failures leave"} " <>
          "someone without a reply, an update or a result:"
        | Enum.map(failures.newest, &"- [#{&1.title}](#{base}#{&1.path})")
      ] ++ more(failures.people - length(failures.newest))

    section(:people, "Needs a person", lines ++ [open(base, "Failures", "/failures")])
  end

  defp more(0), do: []
  defp more(count), do: ["- and #{count} more"]

  # -- Cost --------------------------------------------------------------------------

  defp cost(%{this: nil, previous: nil}, base),
    do: section(:cost, "Cost", [none(nil), open(base, "Usage & cost", "/usage")])

  defp cost(%{this: nil, previous: previous}, base),
    do: section(:cost, "Cost", [none(money(previous)), open(base, "Usage & cost", "/usage")])

  defp cost(%{this: this, previous: previous}, base) do
    line =
      "Model calls cost #{money(this)} (last week #{money(previous) || "none"})" <>
        if(this.estimated, do: ", partly estimated from Model prices.", else: ".")

    section(:cost, "Cost", [line, open(base, "Usage & cost", "/usage")])
  end

  # Cents, and a smaller amount at four places, as Usage & cost shows it.
  defp money(nil), do: nil

  defp money(%{amount: amount}) do
    places =
      if Decimal.compare(amount, 0) == :gt and
           Decimal.compare(amount, Decimal.new("0.01")) == :lt,
         do: 4,
         else: 2

    "$" <> (amount |> Decimal.round(places) |> Decimal.to_string(:normal))
  end

  # -- Words -------------------------------------------------------------------------

  defp section(key, title, lines), do: %{key: key, title: title, lines: lines}

  defp open(base, label, path), do: "Open [#{label}](#{base}#{path})."

  defp none(nil), do: "None."
  defp none(previous), do: "None (last week #{previous})."

  defp last(previous), do: " (last week #{previous})"

  defp last_counts(0, _first, 0, _second), do: nil

  defp last_counts(first, first_noun, second, second_noun),
    do: "#{count(first, first_noun)} and #{count(second, second_noun)}"

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{count} #{noun}s"

  defp times(1), do: "once"
  defp times(2), do: "twice"
  defp times(count), do: "#{count} times"

  defp are(1), do: "is"
  defp are(_count), do: "are"

  defp was(1), do: "was"
  defp was(_count), do: "were"

  # The parts with anything to say, as one list: "a, b and c".
  defp phrases(parts) do
    case for({count, phrase} <- parts, count > 0, do: phrase) do
      [] -> ""
      [only] -> only
      several -> Enum.join(Enum.drop(several, -1), ", ") <> " and " <> List.last(several)
    end
  end

  # Words from a request, a topic or a diagnosis as the report quotes them:
  # on one line, bounded, in curly quotes, with the brackets that would make
  # Markdown a link turned into plain ones, so a quote can name a link or a
  # person but never become one. The publisher escapes the rest, so no quote
  # becomes a mention either.
  defp quoted(text), do: "“" <> plain(text) <> "”"

  defp plain(nil), do: ""

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
    if String.length(text) <= @quote_characters,
      do: text,
      else: String.slice(text, 0, @quote_characters - 1) <> "…"
  end
end

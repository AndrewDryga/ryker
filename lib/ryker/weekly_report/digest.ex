defmodule Ryker.WeeklyReport.Digest do
  @moduledoc """
  The weekly report's words, from its facts (`Ryker.WeeklyReport.Facts`) and
  nothing else, written the way a teammate posts a weekly update in Slack,
  with the pull requests first (Andrew, 2026-09-30, of a report that listed
  the Slack requests Ryker finished: "those are random tasks in slack, they
  are irrelevant compared to value that PRs deliver"):

      Hey everyone 👋 Here's my weekly report for 23–30 Sep.

      I opened 3 PRs this week, and 2 are already merged:
      - VA1: prevent VictoriaLogs cgroup OOM recurrence · tenant-infra#555
      - Add website worker OOM diagnostics and containment · tenant-app-svelte#617

      Still waiting for review:
      - Overlay: stop stranding the Flutter render-method query · tenant-overlay#51, open for 2 days

      I also handled 214 messages, and a typical reply took about 40 seconds.
      150 were quick answers; the other 64 needed deeper work.

      I'm waiting for an answer to 1 question:
      - Verify README smoke test change in #test

      1 thing is stuck and needs someone to look at it: Failures

      Feedback I have received was mostly positive: 9 positive and 1 negative.
      I also learned 6 new things, most recently about \"VictoriaLogs retention\".
      In total, this week's work cost about $41.20 at API prices.

  A part with nothing to say is left out, except that a report that could
  not check what is stuck says so: nothing stuck is a good week, not knowing
  is not. It lists no request Ryker merely answered and states no completion
  rate: "I worked on 45 requests and finished 35 of them" read as ten
  failures (Andrew, 2026-09-30: "why we need this? it should not fail at
  all") when six had been closed by a person as no longer needed and four
  were waiting.

  The text is the Markdown Slack's `markdown` block reads, and the control
  plane's preview renders the same text (`Ryker.ControlPlane.SlackMarkdown`),
  so what the page shows is what the channel gets. A request's or a pull
  request's title is kept to one bounded line and cannot become a link or a
  mention.
  """
  alias Ryker.Wording

  @title_characters 160
  @day_seconds 86_400

  @type part :: %{key: atom(), lines: [String.t()]}
  @type t :: %{parts: [part()], text: String.t()}

  @doc """
  The report for `facts`. `options`: `:base_url`, the console's address the
  links start with, `:time_zone_database`, which reads the week's zone, and
  `:preview`, true for a preview a person sent from Settings.
  """
  @spec render(map(), keyword()) :: t()
  def render(facts, options) do
    base = options |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")
    database = Keyword.get(options, :time_zone_database, Calendar.get_time_zone_database())
    pull_requests = pull_requests(facts.pull_requests, facts.week.to)

    parts =
      [
        greeting: [greeting(facts.week, database, Keyword.get(options, :preview, false))],
        pull_requests: pull_requests,
        work: work(facts, pull_requests != []),
        questions: questions(facts.questions, base),
        stuck: stuck(facts.stuck, base),
        closing: closing(facts)
      ]
      |> Enum.reject(fn {_key, lines} -> lines == [] end)
      |> Enum.map(fn {key, lines} -> %{key: key, lines: lines} end)

    %{parts: parts, text: Enum.map_join(parts, "\n\n", &Enum.join(&1.lines, "\n"))}
  end

  defp greeting(week, database, preview) do
    report = if preview, do: "a preview of my weekly report", else: "my weekly report"
    "Hey everyone 👋 Here's #{report} for #{period(week, database)}."
  end

  # "23–30 Sep", or "28 Sep – 5 Oct" across two months, each day in the
  # report's zone.
  defp period(%{from: from, to: to, timezone: zone}, database) do
    {first, last} = {local(from, zone, database), local(to, zone, database)}

    if {first.year, first.month} == {last.year, last.month},
      do: "#{first.day}–#{Calendar.strftime(last, "%-d %b")}",
      else: "#{Calendar.strftime(first, "%-d %b")} – #{Calendar.strftime(last, "%-d %b")}"
  end

  defp local(moment, zone, database) do
    case DateTime.shift_zone(moment, zone, database) do
      {:ok, local} -> local
      {:error, _reason} -> moment
    end
  end

  # -- Pull requests -------------------------------------------------------------------

  # The week's pull requests and the merged ones among them, then every pull
  # request still waiting for review. When the week's are exactly the ones
  # waiting, one sentence says both.
  defp pull_requests(%{opened: 0, waiting: %{total: 0}}, _now), do: []

  defp pull_requests(%{opened: 0, waiting: waiting}, now) do
    header =
      if waiting.total == 1,
        do: "This PR is still waiting for review:",
        else: "These PRs are still waiting for review:"

    [header | waiting_lines(waiting, now)]
  end

  defp pull_requests(
         %{opened: opened, merged: %{total: 0}, waiting: %{total: opened, this_week: opened}} =
           pull_requests,
         now
       ) do
    they = if opened == 1, do: "it's", else: "they're"

    ["I opened #{Wording.count(opened, "PR")} this week, and #{they} waiting for review:"] ++
      waiting_lines(pull_requests.waiting, now)
  end

  defp pull_requests(%{opened: opened, merged: merged, waiting: waiting}, now) do
    opened_lines =
      case merged.total do
        0 -> ["I opened #{Wording.count(opened, "PR")} this week."]
        _merged -> [merged_sentence(opened, merged.total) | merged_lines(merged)]
      end

    case waiting.total do
      0 -> opened_lines
      _waiting -> opened_lines ++ ["", "Still waiting for review:" | waiting_lines(waiting, now)]
    end
  end

  defp merged_sentence(1, 1), do: "I opened 1 PR this week, and it's already merged:"
  defp merged_sentence(2, 2), do: "I opened 2 PRs this week, and both are already merged:"
  defp merged_sentence(all, all), do: "I opened #{all} PRs this week, and all are already merged:"

  defp merged_sentence(opened, 1),
    do: "I opened #{opened} PRs this week, and 1 is already merged:"

  defp merged_sentence(opened, merged),
    do: "I opened #{opened} PRs this week, and #{merged} are already merged:"

  defp merged_lines(merged),
    do: Enum.map(merged.named, &pull_request_line/1) ++ more(merged.total - length(merged.named))

  defp waiting_lines(waiting, now) do
    Enum.map(waiting.named, &(pull_request_line(&1) <> ", open for #{age(&1.opened_at, now)}")) ++
      more(waiting.total - length(waiting.named))
  end

  defp pull_request_line(pull_request) do
    where = if pull_request.repository, do: plain(pull_request.repository), else: ""
    "- [#{plain(pull_request.title)}](#{pull_request.url}) · #{where}##{pull_request.number}"
  end

  defp age(opened_at, now) do
    case div(max(DateTime.diff(now, opened_at, :second), 0), @day_seconds) do
      0 -> "less than a day"
      days -> Wording.count(days, "day")
    end
  end

  # -- How much work -------------------------------------------------------------------

  defp work(facts, also) do
    case messages(facts, also) do
      nil -> []
      sentence -> [sentence]
    end
  end

  defp messages(
         %{messages: %{handled: 0}, requests: %{total: 0}, pull_requests: %{opened: 0}},
         _also
       ),
       do: "It was a quiet week: nobody asked me for anything."

  defp messages(%{messages: %{handled: 0}}, _also), do: nil

  defp messages(facts, also),
    do: handled(facts.messages, facts.reply_ms, also) <> " " <> answered(facts.messages)

  defp handled(%{handled: handled}, reply_ms, also) do
    opening = if also, do: "I also handled", else: "This past week I handled"

    case {handled, reply_ms} do
      {1, nil} ->
        "#{opening} 1 message."

      {1, reply_ms} ->
        "#{opening} 1 message, and my reply took #{duration(reply_ms)}."

      {handled, nil} ->
        "#{opening} #{handled} messages."

      {handled, reply_ms} ->
        "#{opening} #{handled} messages, and a typical reply took #{duration(reply_ms)}."
    end
  end

  defp answered(%{handled: 1, on_the_spot: 1}), do: "It was a quick answer."
  defp answered(%{handled: 1}), do: "It needed deeper work."
  defp answered(%{handled: all, on_the_spot: all}), do: "All of them were quick answers."
  defp answered(%{on_the_spot: 0}), do: "All of them needed deeper work."

  defp answered(%{handled: handled, on_the_spot: spot}) do
    quick = if spot == 1, do: "1 was a quick answer", else: "#{spot} were quick answers"
    rest = if handled - spot == 1, do: "the other one", else: "the other #{handled - spot}"
    "#{quick}; #{rest} needed deeper work."
  end

  # Andrew, 2026-09-30: "can we add total cost of work for the week too?" An
  # estimate says it is one: a ChatGPT sign-in reports no price, so Ryker's
  # figure is what the calls would cost at API prices, not a bill.
  defp cost(%{calls: 0}), do: nil
  defp cost(%{usd: nil}), do: "I couldn't work out what this week's work cost."

  defp cost(%{usd: usd, estimated: true}),
    do: "In total, this week's work cost about #{money(usd)} at API prices."

  defp cost(%{usd: usd}), do: "In total, this week's work cost #{money(usd)}."

  # Dollars to the cent, with thousands grouped: "$1,234.50".
  defp money(usd) do
    cents = usd |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()

    if cents == 0 and Decimal.gt?(usd, 0) do
      "less than a cent"
    else
      dollars =
        cents
        |> div(100)
        |> Integer.to_string()
        |> String.reverse()
        |> String.graphemes()
        |> Enum.chunk_every(3)
        |> Enum.map_join(",", &Enum.join/1)
        |> String.reverse()

      "$#{dollars}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
    end
  end

  # How long, rounded the way a person says it.
  defp duration(milliseconds) do
    seconds = round(milliseconds / 1000)

    cond do
      seconds < 1 -> "under a second"
      seconds < 10 -> "about #{Wording.count(seconds, "second")}"
      seconds < 58 -> "about #{round(seconds / 5) * 5} seconds"
      seconds < 55 * 60 -> minutes(round(seconds / 60))
      true -> hours(round(seconds / 3600))
    end
  end

  defp minutes(1), do: "about a minute"
  defp minutes(minutes), do: "about #{minutes} minutes"
  defp hours(1), do: "about an hour"
  defp hours(hours), do: "about #{hours} hours"

  # -- What needs people ---------------------------------------------------------------

  defp questions(%{total: 0}, _base), do: []

  defp questions(%{named: [], total: 1, private: 1}, _base),
    do: ["I'm waiting for an answer to 1 question, in a private conversation."]

  defp questions(%{named: [], total: total, private: total}, _base),
    do: ["I'm waiting for answers to #{total} questions, all in private conversations."]

  defp questions(%{named: [], total: 1}, _base), do: ["I'm waiting for an answer to 1 question."]

  defp questions(%{named: [], total: total}, _base),
    do: ["I'm waiting for answers to #{total} questions."]

  defp questions(%{named: named, total: total, private: private}, base) do
    header =
      if total == 1,
        do: "I'm waiting for an answer to 1 question:",
        else: "I'm waiting for answers to #{total} questions:"

    rest =
      case {total - length(named), private} do
        {0, _private} -> []
        {1, 1} -> ["- and 1 more in a private conversation"]
        {more, more} -> ["- and #{more} more in private conversations"]
        {more, _private} -> more(more)
      end

    [header] ++
      Enum.map(named, &"- [#{plain(&1.title)}](#{base}#{&1.href}) in #{plain(&1.where)}") ++
      rest
  end

  defp stuck(:unavailable, base),
    do: ["I couldn't check [Failures](#{base}/failures) while writing this."]

  defp stuck(%{total: 0}, _base), do: []

  defp stuck(%{total: 1, partial: false}, base),
    do: ["1 thing is stuck and needs someone to look at it: [Failures](#{base}/failures)"]

  defp stuck(%{total: total, partial: partial}, base) do
    how_many = if partial, do: "At least #{total}", else: "#{total}"

    [
      "#{how_many} things are stuck and need someone to look at them: " <>
        "[Failures](#{base}/failures)"
    ]
  end

  # -- Feedback and what Ryker learned -------------------------------------------------

  # How people took the answers, what Ryker learned and what the week's work
  # cost, in one closing line (Andrew, 2026-09-30, of the cost on a line of
  # its own: "add it to end not as a separare pragraph").
  defp closing(facts) do
    feedback = feedback(facts.feedback)

    [feedback, learned(facts.learned, feedback != nil), cost(facts.cost)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> []
      sentences -> [Enum.join(sentences, " ")]
    end
  end

  # Andrew, 2026-09-30, of "Feedback was": "Feedback I have received was".
  defp feedback(%{positive: 0, negative: 0}), do: nil
  defp feedback(%{positive: 1, negative: 0}), do: "Feedback I have received was positive."
  defp feedback(%{positive: 0, negative: 1}), do: "Feedback I have received was negative."

  defp feedback(%{positive: 2, negative: 0}),
    do: "Both pieces of feedback I have received were positive."

  defp feedback(%{positive: 0, negative: 2}),
    do: "Both pieces of feedback I have received were negative."

  defp feedback(%{positive: positive, negative: 0}),
    do: "All #{positive} pieces of feedback I have received were positive."

  defp feedback(%{positive: 0, negative: negative}),
    do: "All #{negative} pieces of feedback I have received were negative."

  defp feedback(%{positive: positive, negative: negative}) when positive > negative do
    "Feedback I have received was mostly positive: " <>
      "#{positive} positive and #{negative} negative."
  end

  defp feedback(%{positive: positive, negative: negative}) when positive < negative do
    "Feedback I have received was mostly negative: " <>
      "#{positive} positive and #{negative} negative."
  end

  defp feedback(%{positive: positive, negative: negative}),
    do: "Feedback I have received was mixed: #{positive} positive and #{negative} negative."

  defp learned(%{count: 0}, _also), do: nil

  defp learned(learned, also),
    do: if(also, do: "I also learned ", else: "I learned ") <> things(learned)

  defp things(%{count: 1, newest: nil}), do: "1 new thing."
  defp things(%{count: count, newest: nil}), do: "#{count} new things."
  defp things(%{count: 1, newest: name}), do: "1 new thing, about \"#{plain(name)}\"."

  defp things(%{count: count, newest: name}),
    do: "#{count} new things, most recently about \"#{plain(name)}\"."

  # -- Words ---------------------------------------------------------------------------

  defp more(0), do: []
  defp more(count), do: ["- and #{count} more"]

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
    |> String.trim()
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) <= @title_characters,
      do: text,
      else: String.slice(text, 0, @title_characters - 1) <> "…"
  end
end

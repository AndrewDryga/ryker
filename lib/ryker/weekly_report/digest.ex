defmodule Ryker.WeeklyReport.Digest do
  @moduledoc """
  The weekly report's words, from its facts (`Ryker.WeeklyReport.Facts`) and
  nothing else, written the way a teammate posts a weekly update in Slack
  (Andrew, 2026-09-30, of the Done / Still open / Stuck report this
  replaced: "how a real human would send something like this to Slack?"):

      Hey everyone 👋 Here's my weekly report for 23–30 Sep.

      This past week I handled 121 messages, and a typical reply took about
      30 seconds. I answered 69 of them on the spot; the rest needed deeper
      work. I worked on 45 requests and finished 35 of them.

      Here's what I got done:
      - Fix the checkout alert in #ops · PR #4
      - Check Emisar infrastructure health in #test

      You can see the other 33 here.

      I also opened 2 PRs, and 1 is already merged. Still waiting for review:
      - #2 README workflow smoke test in #test

      2 requests are still open:
      - Add a smoke test in #test, waiting for an answer
      - Track Terraform run 42 in #infra, watching for an update

      Overall, feedback was mostly positive: 2 positive and 1 negative. I also
      learned 10 new things, most recently about “Livebook is parked”.

  A part with nothing to say is left out, except that a report that could
  not check what is stuck says so: nothing stuck is a good week, not knowing
  is not.

  The text is the Markdown Slack's `markdown` block reads, and the control
  plane's preview renders the same text (`Ryker.ControlPlane.SlackMarkdown`),
  so what the page shows is what the channel gets. A request's or a pull
  request's title is kept to one bounded line and cannot become a link or a
  mention.
  """

  @title_characters 160

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
    work = work(facts)

    parts =
      [
        greeting: [greeting(facts.week, database, Keyword.get(options, :preview, false))],
        work: work,
        done: done(facts.done, base),
        pull_requests: pull_requests(facts.pull_requests, work != []),
        open: open(facts.open, base),
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

  # -- How much work -------------------------------------------------------------------

  defp work(%{messages: %{handled: 0}, requests: %{total: 0}, pull_requests: %{opened: 0}}),
    do: ["It was a quiet week: nobody asked me for anything."]

  defp work(facts) do
    [
      handled(facts.messages, facts.reply_ms),
      on_the_spot(facts.messages),
      worked(facts.messages, facts.requests)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> []
      sentences -> [Enum.join(sentences, " ")]
    end
  end

  defp handled(%{handled: 0}, _reply_ms), do: nil
  defp handled(%{handled: 1}, nil), do: "This past week I handled 1 message."

  defp handled(%{handled: 1}, reply_ms),
    do: "This past week I handled 1 message, and my reply took #{duration(reply_ms)}."

  defp handled(%{handled: handled}, nil), do: "This past week I handled #{handled} messages."

  defp handled(%{handled: handled}, reply_ms),
    do:
      "This past week I handled #{handled} messages, and a typical reply took " <>
        "#{duration(reply_ms)}."

  defp on_the_spot(%{handled: 0}), do: nil
  defp on_the_spot(%{handled: 1, on_the_spot: 1}), do: "I answered it on the spot."
  defp on_the_spot(%{handled: 1}), do: "It needed deeper work."
  defp on_the_spot(%{handled: all, on_the_spot: all}), do: "I answered all of them on the spot."
  defp on_the_spot(%{on_the_spot: 0}), do: "All of them needed deeper work."

  defp on_the_spot(%{on_the_spot: spot}),
    do: "I answered #{spot} of them on the spot; the rest needed deeper work."

  defp worked(_messages, %{total: 0}), do: nil
  defp worked(%{handled: 0}, requests), do: "This past week I " <> requests_worked(requests)
  defp worked(_messages, requests), do: "I " <> requests_worked(requests)

  defp requests_worked(%{total: 1, finished: 1}), do: "worked on 1 request and finished it."
  defp requests_worked(%{total: 1}), do: "worked on 1 request; it isn't finished yet."

  defp requests_worked(%{total: total, finished: total}),
    do: "worked on #{total} requests and finished all of them."

  defp requests_worked(%{total: total, finished: 0}),
    do: "worked on #{total} requests; none is finished yet."

  defp requests_worked(%{total: total, finished: finished}),
    do: "worked on #{total} requests and finished #{finished} of them."

  # How long, rounded the way a person says it.
  defp duration(milliseconds) do
    seconds = round(milliseconds / 1000)

    cond do
      seconds < 1 -> "under a second"
      seconds < 10 -> "about #{count(seconds, "second")}"
      seconds < 58 -> "about #{round(seconds / 5) * 5} seconds"
      seconds < 55 * 60 -> minutes(round(seconds / 60))
      true -> hours(round(seconds / 3600))
    end
  end

  defp minutes(1), do: "about a minute"
  defp minutes(minutes), do: "about #{minutes} minutes"
  defp hours(1), do: "about an hour"
  defp hours(hours), do: "about #{hours} hours"

  # -- What got done -------------------------------------------------------------------

  defp done(%{total: 0}, _base), do: []

  defp done(%{named: [], total: 1, private: 1}, _base),
    do: ["The request I finished was in a private conversation, so I'm not naming it here."]

  defp done(%{named: [], total: total, private: total}, _base),
    do: [
      "The #{total} requests I finished were all in private conversations, " <>
        "so I'm not naming them here."
    ]

  defp done(%{named: []}, base), do: ["You can see what I finished [here](#{finished(base)})."]

  # The rest are a sentence of their own after a blank line, so Slack does
  # not read it as more of the last item.
  defp done(%{named: named, total: total}, base) do
    ["Here's what I got done:"] ++
      Enum.map(named, fn request -> request_line(request, base, &pull_request/1) end) ++
      case total - length(named) do
        0 -> []
        1 -> ["", "You can see the other one [here](#{finished(base)})."]
        more -> ["", "You can see the other #{more} [here](#{finished(base)})."]
      end
  end

  defp finished(base), do: base <> "/activity?filter=done"

  defp pull_request(%{pull_request: %{number: number, url: url}}),
    do: " · [PR ##{number}](#{url})"

  defp pull_request(_request), do: ""

  # -- Pull requests -------------------------------------------------------------------

  defp pull_requests(%{opened: 0, waiting: %{total: 0}}, _also), do: []

  defp pull_requests(%{opened: 0, waiting: waiting}, _also), do: waiting(waiting, true)

  defp pull_requests(%{opened: opened, merged: merged, waiting: waiting}, also) do
    sentence = if(also, do: "I also opened ", else: "I opened ") <> merged(opened, merged)

    case waiting(waiting, false) do
      [] -> [sentence]
      [first | rest] -> [sentence <> " " <> first | rest]
    end
  end

  defp merged(1, 1), do: "1 PR, and it's already merged."
  defp merged(1, 0), do: "1 PR; it isn't merged yet."
  defp merged(all, all), do: "#{all} PRs, and all of them are already merged."
  defp merged(opened, 0), do: "#{opened} PRs; none is merged yet."
  defp merged(opened, 1), do: "#{opened} PRs, and 1 is already merged."
  defp merged(opened, merged), do: "#{opened} PRs, and #{merged} are already merged."

  # The pull requests still open, whenever they were opened: after the
  # week's own, "Still waiting for review", and on their own, which ones.
  defp waiting(%{total: 0}, _alone), do: []

  defp waiting(%{named: [], total: 1}, _alone),
    do: ["1 PR is still waiting for review, from a private conversation."]

  defp waiting(%{named: [], total: total}, _alone),
    do: ["#{total} PRs are still waiting for review, all from private conversations."]

  defp waiting(%{named: named, total: total}, alone) do
    header =
      cond do
        not alone -> "Still waiting for review:"
        total == 1 -> "This PR is still waiting for review:"
        true -> "These PRs are still waiting for review:"
      end

    [header] ++
      Enum.map(named, &"- [##{&1.number} #{plain(&1.title)}](#{&1.url}) in #{plain(&1.where)}") ++
      more(total - length(named))
  end

  # -- Still open ----------------------------------------------------------------------

  defp open(%{total: 0}, _base), do: []

  defp open(%{named: [], total: 1, private: 1}, _base),
    do: ["1 request is still open, in a private conversation."]

  defp open(%{named: [], total: total, private: total}, _base),
    do: ["#{total} requests are still open, all in private conversations."]

  defp open(%{named: [], total: 1}, _base), do: ["1 request is still open."]
  defp open(%{named: [], total: total}, _base), do: ["#{total} requests are still open."]

  defp open(%{named: named, total: total}, base) do
    header =
      if total == 1,
        do: "1 request is still open:",
        else: "#{total} requests are still open:"

    [header] ++
      Enum.map(named, fn request -> request_line(request, base, &standing/1) end) ++
      more(total - length(named))
  end

  defp standing(%{standing: :waiting}), do: ", waiting for an answer"
  defp standing(%{standing: :watching}), do: ", watching for an update"
  defp standing(%{standing: :stuck}), do: ", stuck"
  defp standing(%{standing: :going}), do: ", in progress"

  defp request_line(request, base, detail),
    do:
      "- [#{plain(request.title)}](#{base}#{request.href}) in #{plain(request.where)}" <>
        detail.(request)

  defp more(0), do: []
  defp more(count), do: ["- and #{count} more"]

  # -- Stuck ---------------------------------------------------------------------------

  defp stuck(:unavailable, base),
    do: ["I couldn't check [Failures](#{base}/failures) while writing this."]

  defp stuck(%{total: 0}, _base), do: []

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
    feedback = feedback(facts.feedback)

    case Enum.reject([feedback, learned(facts.learned, feedback != nil)], &is_nil/1) do
      [] -> []
      sentences -> [Enum.join(sentences, " ")]
    end
  end

  defp feedback(%{positive: 0, negative: 0}), do: nil
  defp feedback(%{positive: 1, negative: 0}), do: "The one piece of feedback I got was positive."

  defp feedback(%{positive: positive, negative: 0}),
    do: "All #{positive} pieces of feedback I got were positive."

  defp feedback(%{positive: 0, negative: 1}), do: "The one piece of feedback I got was negative."

  defp feedback(%{positive: 0, negative: negative}),
    do: "All #{negative} pieces of feedback I got were negative."

  defp feedback(%{positive: positive, negative: negative}) when positive > negative,
    do: "Overall, feedback was mostly positive: #{positive} positive and #{negative} negative."

  defp feedback(%{positive: positive, negative: negative}) when positive < negative,
    do: "Overall, feedback was mostly negative: #{positive} positive and #{negative} negative."

  defp feedback(%{positive: positive, negative: negative}),
    do: "Feedback was mixed: #{positive} positive and #{negative} negative."

  defp learned(%{count: 0}, _also), do: nil

  defp learned(learned, also),
    do: if(also, do: "I also learned ", else: "I learned ") <> things(learned)

  defp things(%{count: 1, newest: nil}), do: "1 new thing."
  defp things(%{count: count, newest: nil}), do: "#{count} new things."
  defp things(%{count: 1, newest: name}), do: "1 new thing, about “#{plain(name)}”."

  defp things(%{count: count, newest: name}),
    do: "#{count} new things, most recently about “#{plain(name)}”."

  # -- Words ---------------------------------------------------------------------------

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{count} #{noun}s"

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

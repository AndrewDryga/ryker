defmodule Ryker.ControlPlane.SubscriptionPresentation do
  @moduledoc """
  Read-only, allowlisted words for a follow-up: what it waits for, which
  request it continues, where, and when. Never predicts a provider's outcome;
  every label comes from the saved matcher or the host's own timestamps.
  """

  alias Ryker.ControlPlane.{InspectionRedactor, SlackNames}
  alias Ryker.Slack.ReplyRecords

  @doc """
  The follow-up's presentation fields: `title` (what it waits for),
  `condition` (the exact matching filters, for Details), a safe `target_url`,
  the request it continues, and where that request lives (`place`,
  `repository`).
  """
  def project(item, episode, secrets) do
    source = source_label(item.source_kind)
    retained? = episode && episode.source_available
    matcher = if retained?, do: item.matcher, else: %{}
    {target, url} = target(matcher)
    target = text(target, secrets)
    timer? = timer?(item)
    {place, repository} = context(episode, retained?, secrets)

    Map.merge(item, %{
      title: if(timer?, do: "Timer", else: waits_for(target, matcher, source, secrets)),
      condition: if(timer?, do: nil, else: condition(matcher, secrets)),
      target_url: safe_url(url, secrets),
      source_label: if(timer?, do: "Timer", else: source),
      episode_title: episode && episode.title,
      episode_href: episode && episode.href,
      place: place,
      repository: repository
    })
  end

  defp target(%{"attachments" => [%{"title" => title} = attachment | _]}),
    do: {title, attachment["title_link"]}

  defp target(%{"pull_request" => %{"number" => number} = pr}) when is_integer(number),
    do: {"Pull request ##{number}", pr["html_url"]}

  defp target(matcher) do
    {matcher["run_id"] || matcher["project_id"] || matcher["deployment"], nil}
  end

  # What the follow-up waits for, as a person would say it: "Pull request #42
  # is merged", "portal is healthy", "An update on Run run-k9…", "A matching
  # GitHub update".
  defp waits_for("Pull request " <> _number = target, matcher, _source, _secrets) do
    pull_request = matcher["pull_request"]

    cond do
      pull_request["merged"] == true -> target <> " is merged"
      "closed" in [pull_request["state"], matcher["action"]] -> target <> " is closed"
      true -> "An update on " <> String.downcase(target, :ascii)
    end
  end

  defp waits_for(nil, _matcher, source, _secrets), do: "A matching #{source} update"

  defp waits_for(target, matcher, _source, secrets) do
    case text(matcher["status"] || matcher["state"], secrets) do
      nil -> "An update on " <> target
      value -> "#{target} is #{value}"
    end
  end

  # The exact filters a matching update must carry, for Details.
  defp condition(matcher, secrets) do
    ([
       {"status", matcher["status"]},
       {"action", matcher["action"]},
       {"state", matcher["state"]},
       {"pull request state", pull_request_state(matcher)}
     ] ++ attachment_conditions(matcher))
    |> Enum.flat_map(fn {label, value} ->
      if value = text(value, secrets), do: ["#{label}: #{value}"], else: []
    end)
    |> case do
      [] -> nil
      values -> Enum.join(values, " · ")
    end
  end

  defp pull_request_state(%{"pull_request" => %{"state" => state}}), do: state
  defp pull_request_state(_), do: nil

  defp attachment_conditions(%{"attachments" => [_target | conditions]}) do
    for %{"title" => title} <- Enum.take(conditions, 5), do: {"attachment title", title}
  end

  defp attachment_conditions(_), do: []

  # Where the request lives: a channel name or a direct conversation, and
  # its repository. Withheld once the source is no longer retained.
  defp context(nil, _retained?, _secrets), do: {nil, nil}
  defp context(_episode, false, _secrets), do: {nil, nil}

  defp context(episode, true, secrets) do
    place =
      case episode.source do
        "Slack" -> SlackNames.destination(episode.conversation)
        "Direct conversation" -> :direct
        _other -> nil
      end

    {place, text(episode.repository, secrets)}
  end

  defp text(value, secrets) when is_binary(value) and value != "",
    do: InspectionRedactor.artifact(value, secrets: secrets, max_bytes: 256).text

  defp text(_, _), do: nil

  defp safe_url(value, secrets) do
    if ReplyRecords.safe_url?(value) do
      sanitized = InspectionRedactor.artifact(value, secrets: secrets, max_bytes: 2_000).text

      if ReplyRecords.safe_url?(sanitized) && not String.contains?(sanitized, "[redacted]"),
        do: sanitized
    end
  end

  defp source_label("slack"), do: "Slack"
  defp source_label("github"), do: "GitHub"
  defp source_label("emisar"), do: "Emisar"
  defp source_label(_), do: "external"

  defp timer?(item), do: item.trigger_type in ["after", "at"]

  @doc "The follow-up's state as a dot tone and a word."
  def status(%{status: :active}), do: {:busy, "Waiting"}
  def status(%{status: :resolved}), do: {:off, "Resumed"}
  def status(%{status: :timed_out}), do: {:warn, "Deadline passed"}
  def status(%{status: :cancelled}), do: {:off, "Cancelled"}

  @doc """
  When, in words: `{text, at}` facts, `at` being the exact time the words
  describe, or nil when they describe none.

  A current follow-up says when it continues and when it stops waiting; a past one
  says what ended it and how long ago.
  """
  def timing(%{status: :active} = item, now) do
    facts =
      if timer?(item) do
        [item.poll_after && {relative(item.poll_after, now, :due), item.poll_after}]
      else
        [
          {"when a matching update arrives", nil},
          scheduled_check?(item) &&
            {"next check " <> relative(item.poll_after, now, :due), item.poll_after},
          deadline(item.deadline_at, now)
        ]
      end

    Enum.filter(facts, & &1)
  end

  def timing(item, now) do
    outcome = outcome(item)

    case item.last_observed_at do
      %DateTime{} = at -> [{outcome <> " " <> relative(at, now), at}]
      nil -> [{outcome, nil}]
    end
  end

  # An event follow-up saves its deadline as the next wake-up when no earlier
  # check was asked for; calling that a check would promise work that only
  # ends it.
  defp scheduled_check?(%{poll_after: nil}), do: false
  defp scheduled_check?(%{deadline_at: nil}), do: true

  defp scheduled_check?(item),
    do: DateTime.compare(item.poll_after, item.deadline_at) == :lt

  defp deadline(nil, _now), do: {"no deadline", nil}

  defp deadline(at, now) do
    seconds = DateTime.diff(at, now)

    cond do
      seconds <= 0 -> {"stops waiting now", at}
      seconds < 86_400 -> {"stops waiting " <> relative(at, now), at}
      at.year == now.year -> {"stops waiting " <> Calendar.strftime(at, "%-d %b"), at}
      true -> {"stops waiting " <> Calendar.strftime(at, "%-d %b %Y"), at}
    end
  end

  defp outcome(%{status: :cancelled}), do: "cancelled"
  defp outcome(%{status: :timed_out}), do: "gave up"
  defp outcome(%{resolution_kind: :timer}), do: "timer fired"
  defp outcome(%{resolution_kind: :input}), do: "update arrived"
  defp outcome(%{resolution_kind: :poll_fallback}), do: "checked again"
  defp outcome(_item), do: "resumed"

  def relative(at, now, mode \\ :past)
  def relative(nil, _, _), do: "Time not recorded"

  def relative(%DateTime{} = at, %DateTime{} = now, mode) do
    seconds = DateTime.diff(at, now)

    cond do
      seconds > 0 -> "in " <> duration(seconds)
      seconds > -60 && mode == :due -> "due now"
      seconds > -60 -> "just now"
      mode == :due -> "overdue by " <> duration(-seconds)
      true -> duration(-seconds) <> " ago"
    end
  end

  defp duration(seconds) when seconds < 60, do: "less than a minute"
  defp duration(seconds) when seconds < 3_600, do: units(div(seconds, 60), "minute")
  defp duration(seconds) when seconds < 86_400, do: units(div(seconds, 3_600), "hour")
  defp duration(seconds), do: units(div(seconds, 86_400), "day")
  defp units(1, unit), do: "1 #{unit}"
  defp units(count, unit), do: "#{count} #{unit}s"
end

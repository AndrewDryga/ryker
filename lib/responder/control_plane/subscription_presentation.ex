defmodule Responder.ControlPlane.SubscriptionPresentation do
  @moduledoc "Read-only, allowlisted descriptions of saved waits; never predicts provider outcomes."

  alias Responder.ControlPlane.{InspectionRedactor, SlackNames}
  alias Responder.Slack.ReplyRecords

  def project(item, episode, secrets) do
    source = source_label(item.source_kind)
    retained? = episode && episode.source_available
    matcher = if retained?, do: item.matcher, else: %{}
    {target, url} = target(matcher)
    target = text(target, secrets)
    timer? = item.trigger_type in ["after", "at"]

    Map.merge(item, %{
      title: if(timer?, do: "Timed follow-up", else: target || "Matching #{source} update"),
      condition: condition(matcher, source, timer?, secrets),
      target_url: safe_url(url, secrets),
      source_label: if(timer?, do: "Timer", else: source),
      episode_title: if(episode, do: episode.title, else: "Request unavailable"),
      episode_href: episode && episode.href,
      context_label: context(episode, retained?, secrets)
    })
  end

  defp target(%{"attachments" => [%{"title" => title} = attachment | _]}),
    do: {title, attachment["title_link"]}

  defp target(%{"pull_request" => %{"number" => number} = pr}) when is_integer(number),
    do: {"Pull request ##{number}", pr["html_url"]}

  defp target(matcher) do
    {matcher["run_id"] || matcher["project_id"] || matcher["deployment"], nil}
  end

  defp condition(_matcher, _source, true, _secrets), do: "Resume work at the scheduled time"

  defp condition(matcher, source, false, secrets) do
    filters =
      [
        {"status", matcher["status"]},
        {"action", matcher["action"]},
        {"state", matcher["state"]},
        {"pull request state", pull_request_state(matcher)}
      ] ++ attachment_conditions(matcher)

    filters =
      filters
      |> Enum.flat_map(fn {label, value} ->
        if value = text(value, secrets), do: ["#{label}: #{value}"], else: []
      end)

    case filters do
      [] -> "Next matching #{source} update"
      values -> "Matching #{source} update · " <> Enum.join(values, " · ")
    end
  end

  defp pull_request_state(%{"pull_request" => %{"state" => state}}), do: state
  defp pull_request_state(_), do: nil

  defp attachment_conditions(%{"attachments" => [_target | conditions]}) do
    for %{"title" => title} <- Enum.take(conditions, 5), do: {"attachment title", title}
  end

  defp attachment_conditions(_), do: []

  defp context(nil, _, _), do: "Source context unavailable"
  defp context(_episode, false, _), do: "Source context unavailable"

  defp context(episode, true, secrets) do
    destination =
      if episode.source == "Slack", do: SlackNames.destination(episode.conversation)

    # "Slack · Slack channel" says Slack twice; the word is only worth keeping
    # once the destination resolved to a name of its own.
    source =
      if destination && not SlackNames.named?(episode.conversation), do: nil, else: episode.source

    [source, destination, text(episode.repository, secrets)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" · ")
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

  def status(%{status: :active}), do: {"Waiting", "active"}
  def status(%{status: :timed_out}), do: {"Timed out", "attention"}
  def status(%{status: :cancelled}), do: {"Cancelled", "quiet"}
  def status(%{status: :resolved}), do: {"Resumed", "done"}

  def timing(%{status: :active} = item, now) do
    timer? = item.trigger_type in ["after", "at"]

    wake =
      cond do
        scheduled_check?(item, timer?) ->
          {if(timer?, do: "Follow-up", else: "Next check"), relative(item.poll_after, now, :due),
           item.poll_after}

        timer? ->
          {"Follow-up", "Time not recorded", nil}

        true ->
          {"Next update", "When a matching update arrives", nil}
      end

    deadline =
      if item.deadline_at,
        do: {"Deadline", relative(item.deadline_at, now, :due), item.deadline_at},
        else: {"Deadline", "No deadline", nil}

    [wake, deadline]
  end

  def timing(item, now) do
    [{outcome(item), relative(item.last_observed_at, now), item.last_observed_at}]
  end

  defp scheduled_check?(%{poll_after: nil}, _timer?), do: false
  defp scheduled_check?(_item, true), do: true
  defp scheduled_check?(%{deadline_at: nil}, false), do: true

  defp scheduled_check?(item, false),
    do: DateTime.compare(item.poll_after, item.deadline_at) == :lt

  defp outcome(%{status: :cancelled}), do: "Wait cancelled"
  defp outcome(%{status: :timed_out}), do: "Deadline reached"
  defp outcome(%{resolution_kind: :timer}), do: "Timer fired"
  defp outcome(%{resolution_kind: :input}), do: "Matching update arrived"
  defp outcome(%{resolution_kind: :poll_fallback}), do: "Resumed for a status check"
  defp outcome(_), do: "Wait resolved"

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

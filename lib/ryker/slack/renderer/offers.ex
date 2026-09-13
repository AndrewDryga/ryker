defmodule Ryker.Slack.Renderer.Offers do
  @moduledoc """
  The offer cards: what a task, publication, schedule, automation change,
  memory, preference, guidance or additional Slack post would do, and the one
  button that lets a person authorize exactly that.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  @doc "The blocks of an open offer of `kind`, from its prepared payload."
  @spec blocks(String.t(), String.t(), map()) :: [map()]
  def blocks("task_offer", ref, offer), do: task_offer(ref, offer)
  def blocks("publication_offer", ref, offer), do: publication_offer(ref, offer)
  def blocks("schedule_offer", ref, offer), do: schedule_offer(ref, offer)
  def blocks("automation_change_offer", ref, offer), do: automation_change_offer(ref, offer)
  def blocks("memory_offer", ref, offer), do: memory_offer(ref, offer)
  def blocks(kind, ref, offer), do: behavior_offer(kind, ref, offer)

  defp task_offer(ref, %{"kind" => "engineering", "repository" => repository} = offer),
    do: [section(offer_summary(offer)), actions(ref, engineering_button(ref, repository))]

  # One offer owns both incident paths; the host starts exactly one of them.
  defp task_offer(ref, %{"kind" => "incident", "repository" => _repository} = offer),
    do: [
      section(offer_summary(offer)),
      actions(ref, [investigate_button(ref), incident_button(ref)])
    ]

  # Both the open and the confirmed card render this. An operator returning to
  # the thread reads the confirmed card to find out what was authorized, and
  # repainting it down to a title and a check mark answered nothing.
  defp offer_summary(%{"kind" => "engineering", "repository" => repository} = offer),
    do:
      offer_lines(
        "*#{escape(offer["title"])}*\nRepository: `#{escape(repository)}`#{offer_source(offer)}",
        offer
      )

  defp offer_summary(%{"repository" => nil, "title" => title} = offer),
    do: offer_lines("*#{escape(title)}*", offer)

  defp offer_summary(%{"repository" => repository, "title" => title} = offer),
    do: offer_lines("*#{escape(title)}*\nRepository: `#{escape(repository)}`", offer)

  defp offer_lines(head, offer), do: Enum.join([head | offer_brief(offer)], "\n")

  # What the task will do, from the fields the host validated. The offer's
  # `prompt` is the worker's own instruction and never appears here: this card
  # carries a button that grants authority, and d98b1d9f keeps model-authored
  # instructions off that surface. Checks, limits and the exact source say what
  # is being authorized without quoting what the worker was told.
  defp offer_brief(%{"success_checks" => checks, "authority_limits" => limits} = offer)
       when is_list(checks) and is_list(limits) do
    [
      offer_list("Checks", checks, 4),
      offer_list("Will not", limits, 4),
      offer_sources(offer["source_refs"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp offer_brief(_offer), do: []

  defp offer_list(_label, [], _limit), do: nil

  defp offer_list(label, values, limit) do
    shown = values |> Enum.take(limit) |> Enum.map_join("; ", &truncate(escape(&1), 200))
    remainder = length(values) - min(length(values), limit)
    more = if remainder > 0, do: " · #{remainder} more", else: ""
    "*#{label}:* #{shown}#{more}"
  end

  defp offer_sources(refs) when is_list(refs) and refs != [],
    do: "*Evidence:* #{length(refs)} sources"

  defp offer_sources(_refs), do: nil

  defp offer_source(%{"repository_source" => %{"kind" => kind, "name" => name}})
       when is_binary(kind) and is_binary(name),
       do: " · #{escape(kind)} `#{escape(name)}`"

  defp offer_source(_offer), do: ""

  @doc "The confirmed task offer, with the incident room it opened once the host knows it."
  @spec confirmed_task_offer(map(), map()) :: [map()]
  def confirmed_task_offer(%{"kind" => "engineering"} = offer, _presentation),
    do: [section(offer_outcome(offer, "✓ Task started in this thread."))]

  def confirmed_task_offer(offer, %{"incident_room" => %{"url" => url}})
      when is_binary(url) do
    [
      section(offer_outcome(offer, "✓ Incident room created.")),
      actions(
        "incident-room-link",
        url_button("ryker_open_incident_room", "Open incident room", "room", url)
      )
    ]
  end

  def confirmed_task_offer(offer, %{"incident_room" => _room}),
    do: [section(offer_outcome(offer, "◷ Incident room requested · creating the channel"))]

  def confirmed_task_offer(offer, _presentation),
    do: [section(offer_outcome(offer, "✓ Investigating in this thread."))]

  defp offer_outcome(offer, outcome), do: offer_summary(offer) <> "\n\n" <> outcome

  @spec incident_room_presentation(map()) :: :ok | {:error, term()}
  def incident_room_presentation(presentation) when map_size(presentation) == 0, do: :ok

  def incident_room_presentation(%{"incident_room" => %{"url" => url} = room} = presentation)
      when map_size(presentation) == 1 and map_size(room) == 1,
      do: optional_https_url(url)

  def incident_room_presentation(_presentation),
    do: {:error, :invalid_incident_room_presentation}

  defp engineering_button(ref, repository) do
    confirmation =
      "Start this task for #{repository} in an isolated working copy where Ryker can edit, test, and commit?"

    button(
      "ryker_start_engineering_task",
      "Start task",
      ref,
      "primary",
      "Start engineering task",
      confirmation,
      "Start task"
    )
  end

  defp investigate_button(ref) do
    button(
      "ryker_investigate_incident",
      "Investigate",
      ref,
      "primary",
      "Investigate in this thread",
      "Start read-only investigation work in this thread. No incident room is created and nobody is invited.",
      "Investigate"
    )
  end

  defp incident_button(ref) do
    button(
      "ryker_open_incident",
      "Create incident room",
      ref,
      "danger",
      "Create incident room",
      "Create a coordinated incident room for this work and invite the configured responders?",
      "Create room"
    )
  end

  defp publication_offer(ref, %{"body" => body, "title" => title}) do
    summary =
      "*#{escape(title)}*\n#{escape(body)}\n_No branch or pull request has been published._"

    [
      section(summary),
      actions(
        ref,
        button(
          "ryker_review_publication",
          "Review changes",
          ref,
          "primary",
          "Review committed changes",
          "Run the trusted read-only Coop review for this exact committed workspace? This does not publish a branch or pull request.",
          "Run review"
        )
      )
    ]
  end

  defp schedule_offer(ref, payload) do
    scope =
      case payload["repository"] do
        nil -> payload["authority"]
        repository -> "#{payload["authority"]} · #{repository}"
      end

    expiry = payload["expires_at"] || "no expiry"

    summary =
      [
        "*#{escape(payload["title"])}*",
        escape(payload["task"]),
        "When: `#{escape(schedule_description(payload["recurrence"]))}`",
        "Timezone: `#{escape(payload["timezone"])}`",
        "Scope: `#{escape(scope)}` · Expires: `#{escape(expiry)}`",
        "_This is only an offer; no schedule exists yet._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        button(
          "ryker_confirm_schedule",
          "Schedule this",
          ref,
          "primary",
          "Create recurring work",
          "Create this exact schedule at the shown destination and authority ceiling? Each occurrence rechecks current policy.",
          "Schedule this"
        )
      )
    ]
  end

  defp automation_change_offer(ref, payload) do
    review =
      [
        "Automation #{payload["action"]} · #{payload["automation_id"]} · revision #{payload["revision"]}",
        "",
        "Before",
        Jason.encode!(payload["before"], pretty: true),
        "",
        "After",
        Jason.encode!(payload["after"], pretty: true),
        "",
        "Nothing changes until an operator confirms this exact revision."
      ]
      |> Enum.join("\n")

    plain_message_blocks(review) ++
      [
        actions(
          ref,
          button(
            "ryker_confirm_automation",
            automation_change_label(payload["action"]),
            ref,
            automation_change_style(payload["action"]),
            "Confirm automation change",
            "Apply this exact before/after change? The host will reject it if the automation revision or destination changed.",
            "Apply change"
          )
        )
      ]
  end

  defp automation_change_label("update"), do: "Update automation"
  defp automation_change_label("pause"), do: "Pause automation"
  defp automation_change_label("resume"), do: "Resume automation"
  defp automation_change_label("delete"), do: "Delete automation"

  defp automation_change_style(action) when action in ~w(pause delete), do: "danger"
  defp automation_change_style(_action), do: "primary"

  defp schedule_description(%{"kind" => "once", "at" => at}), do: "once at #{at}"

  defp schedule_description(%{
         "kind" => "interval",
         "every_seconds" => seconds,
         "starts_at" => starts_at
       }),
       do: "every #{seconds}s" <> if(starts_at, do: " from #{starts_at}", else: "")

  defp schedule_description(%{"kind" => "daily", "time" => time}), do: "daily at #{time}"

  defp schedule_description(%{"kind" => "weekly", "weekday" => weekday, "time" => time}),
    do: "every #{weekday} at #{time}"

  defp schedule_description(%{"kind" => "monthly", "day" => day, "time" => time}),
    do: "monthly on day #{day} at #{time}"

  @spec slack_post_offer(String.t(), map(), String.t()) :: [map()]
  def slack_post_offer(ref, payload, "open") do
    destination = payload["destination_ref"]

    summary =
      [
        "*Additional Slack post requires confirmation*",
        "Destination: `#{escape(destination)}`",
        escape(payload["message"]),
        "_No message has been posted. Only the original requester can authorize this exact destination and message._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        button(
          "ryker_confirm_slack_post",
          "Post this message",
          ref,
          "primary",
          "Confirm additional Slack post",
          "Post this exact message to #{destination}?",
          "Post message"
        )
      )
    ]
  end

  def slack_post_offer(_ref, payload, "confirmed") do
    [section(confirmed_slack_post_summary(payload))]
  end

  # Until the host could build a message link this card said the worker was
  # "sending or reconciling" the post forever, even long after it had landed.
  # The link is the only honest way to say it is sent.
  defp confirmed_slack_post_summary(%{"message_url" => url} = payload) when is_binary(url) do
    "*Additional Slack post sent*\nDestination: `#{escape(payload["destination_ref"])}` · <#{url}|Open message>"
  end

  defp confirmed_slack_post_summary(payload) do
    "*Additional Slack post confirmed*\nDestination: `#{escape(payload["destination_ref"])}`\n_The durable delivery worker is sending or reconciling this exact message._"
  end

  defp behavior_offer("preference_offer", ref, payload) do
    repository = if payload["repository"], do: " · `#{escape(payload["repository"])}`", else: ""

    summary =
      [
        "*Behavior preference*",
        "`#{payload["key"]}=#{payload["value"]}`",
        "Scope: `#{payload["scope"]}`#{repository} · Expires: `#{payload["expires_in"]}`",
        "_This is only an offer; behavior has not changed._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Confirm preference")]
  end

  defp behavior_offer("guidance_offer", ref, payload) do
    repository = if payload["repository"], do: " · `#{escape(payload["repository"])}`", else: ""

    summary =
      [
        "*Remember guidance · #{escape(payload["subject"])}*",
        escape(payload["text"]),
        "Scope: `#{payload["scope"]}`#{repository} · Visibility: `#{payload["visibility"]}` · Expires: `#{payload["expires_in"]}`",
        "_Advisory only: this cannot trigger work, prove a fact, or grant authority._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Remember this")]
  end

  defp behavior_offer(
         "standing_assignment_offer",
         ref,
         %{"source_kind" => source_kind} = payload
       ) do
    repository = payload["repository"] || "no repository binding"
    expiry = payload["expires_at"] || "until disabled"

    summary =
      [
        "*Source-event automation · #{escape(payload["title"])}*",
        escape(payload["task"]),
        "Source event: `#{escape(source_kind)}` · Filter: `#{escape(Jason.encode!(payload["filter"]))}`",
        "Context/delivery: `#{escape(payload["context_channel"])}` · Repository: `#{escape(repository)}`",
        "Expires: `#{escape(expiry)}`",
        "_Read-only initiative in this channel; it cannot approve, publish, deploy, or mutate infrastructure._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Enable automation")]
  end

  defp behavior_offer("standing_assignment_offer", ref, payload) do
    repository = payload["repository"] || "no repository binding"

    summary =
      [
        "*Standing assignment*",
        escape(payload["task"]),
        "Trigger: `#{payload["trigger"]}` → `#{payload["action"]}`",
        "Source: `#{payload["source_filter"]}` · Repository: `#{escape(repository)}` · Expires: `#{payload["expires_in"]}`",
        "_Read-only initiative in this channel; it cannot approve, publish, deploy, or mutate infrastructure._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Enable assignment")]
  end

  defp memory_offer(ref, payload) do
    repository = if payload["repository"], do: " · `#{escape(payload["repository"])}`", else: ""

    summary =
      [
        "*Remember operational mapping · #{escape(payload["subject"])}*",
        escape(payload["value"]),
        "Kind: `#{payload["kind"]}` · Scope: `#{payload["scope"]}`#{repository}",
        "Visibility: `#{payload["visibility"]}` · Expires: `#{payload["expires_in"]}`",
        "_Potentially stale hint only: live evidence, current repositories, and host policy take precedence._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        button(
          "ryker_confirm_memory",
          "Remember this",
          ref,
          "primary",
          "Remember operational mapping",
          "Store this exact scoped mapping with its shown visibility, provenance, and expiry?",
          "Remember this"
        )
      )
    ]
  end

  defp behavior_actions(ref, label) do
    actions(
      ref,
      button(
        "ryker_confirm_behavior",
        label,
        ref,
        "primary",
        label,
        "Confirm this exact bounded behavior, scope, and expiry?",
        label
      )
    )
  end
end

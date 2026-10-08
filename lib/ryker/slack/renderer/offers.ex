defmodule Ryker.Slack.Renderer.Offers do
  @moduledoc """
  The offer cards: what a task, publication, schedule, automation change,
  memory, preference, guidance or additional Slack post would do, and the one
  button that lets a person authorize exactly that.
  """
  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields
  alias Ryker.ConversationRef
  alias Ryker.Delivery
  alias Ryker.Schedules
  alias Ryker.Text
  alias Ryker.Wording

  # A task brief shows this many checks and limits, each cut to this length,
  # and counts the rest.
  @brief_items 4
  @brief_item_characters 200

  @doc "The blocks of an open offer of `kind`, from its prepared payload."
  @spec blocks(String.t(), String.t(), map()) :: [map()]
  def blocks("task_offer", ref, offer), do: task_offer(ref, offer)
  def blocks("publication_offer", ref, offer), do: publication_offer(ref, offer)
  def blocks("schedule_offer", ref, offer), do: schedule_offer(ref, offer)
  def blocks("automation_change_offer", ref, offer), do: automation_change_offer(ref, offer)
  def blocks("memory_offer", ref, offer), do: memory_offer(ref, offer)

  def blocks(kind, ref, offer)
      when kind in ~w(preference_offer guidance_offer standing_assignment_offer),
      do: behavior_offer(kind, ref, offer)

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
  defp offer_summary(%{"kind" => "engineering", "repository" => repository} = offer) do
    offer_lines(
      "*#{escape(offer["title"])}*\nRepository: `#{escape(repository)}`#{offer_source(offer)}",
      offer
    )
  end

  defp offer_summary(%{"repository" => nil, "title" => title} = offer),
    do: offer_lines("*#{escape(title)}*", offer)

  defp offer_summary(%{"repository" => repository, "title" => title} = offer),
    do: offer_lines("*#{escape(title)}*\nRepository: `#{escape(repository)}`", offer)

  defp offer_lines(head, offer), do: Enum.join([head | offer_brief(offer)], "\n\n")

  # What the task will do, from the fields the host validated. The offer's
  # `prompt` is the worker's own instruction and never appears here: this card
  # carries a button that grants authority, so model-authored instructions stay
  # off it. Checks and limits say what is being authorized without quoting what
  # the worker was told, each on a line of its own: joined with semicolons under
  # "Will not:" they read as one run-on sentence, and "Will not: Change only …"
  # said the opposite of what it meant (Andrew, 2026-10-01).
  defp offer_brief(%{"success_checks" => checks, "authority_limits" => limits})
       when is_list(checks) and is_list(limits) do
    [offer_list("Done when", checks), offer_list("Limits", limits)]
    |> Enum.reject(&is_nil/1)
  end

  defp offer_list(_label, []), do: nil

  defp offer_list(label, values) do
    shown =
      values
      |> Enum.take(@brief_items)
      |> Enum.map(&("• " <> (&1 |> Text.shorten(@brief_item_characters) |> escape())))

    hidden = length(values) - @brief_items
    more = if hidden > 0, do: ["• and #{hidden} more"], else: []
    Enum.join(["*#{label}:*" | shown ++ more], "\n")
  end

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
    # The repository last, where a name too long for the dialog loses only its end.
    confirmation =
      "Start this task? Ryker edits, tests and commits in an isolated working copy of #{repository}."

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

    sections(summary) ++
      [
        actions(
          ref,
          button(
            "ryker_review_publication",
            "Review changes",
            ref,
            "primary",
            "Review these changes",
            "Ryker checks the committed changes without changing anything. Nothing is published.",
            "Review"
          )
        )
      ]
  end

  defp schedule_offer(ref, payload) do
    # The recurrence the confirmation saves, in the words every surface uses,
    # never the title or task the model wrote over it.
    cadence = Schedules.ScheduleCadence.describe(payload["recurrence"], payload["timezone"])

    limits =
      [
        Schedules.ScheduleCadence.access(payload["authority"], payload["repository"]),
        Schedules.ScheduleCadence.ends(payload["expires_at"])
      ]
      |> Enum.reject(&is_nil/1)

    summary =
      [
        "*#{escape(payload["title"])}*",
        escape(payload["task"]),
        "When: #{escape(cadence)}",
        if(limits != [], do: escape(Enum.join(limits, " · "))),
        "_This is only an offer; no schedule exists yet._"
      ]
      |> compact_lines()

    sections(summary) ++
      [
        actions(
          ref,
          button(
            "ryker_confirm_schedule",
            "Schedule this",
            ref,
            "primary",
            "Create this schedule",
            "Ryker starts each run on its own, where and with the access this card shows. You can pause or delete it later.",
            "Schedule this"
          )
        )
      ]
  end

  # A change is said in words: what it changes, with what it was, and the
  # whole new instructions when those change. The JSON before and after it
  # used to show meant nothing to the person confirming it.
  defp automation_change_offer(ref, payload) do
    before = payload["before"] || %{}
    changed = payload["after"] || %{}

    summary =
      [
        "*#{automation_change_label(payload["action"])} · #{escape(changed["title"] || before["title"] || "Automation")}*",
        "_Nothing changes until you confirm._"
      ]
      |> compact_lines()

    facts = automation_facts(payload["action"], before, changed)

    [section(summary)] ++
      if(facts == [], do: [], else: [fact_fields(facts)]) ++
      automation_instructions(before, changed) ++
      [
        actions(
          ref,
          button(
            "ryker_confirm_automation",
            automation_change_label(payload["action"]),
            ref,
            automation_change_style(payload["action"]),
            "Confirm this change",
            "Ryker makes this change only if the automation is still as this card shows it.",
            "Apply change"
          )
        )
      ]
  end

  # Each fact the change touches, as it will be and as it was; a fact the
  # change leaves alone is shown once, for context, when it is how often.
  defp automation_facts(action, before, changed) do
    [
      change(
        "How often",
        Delivery.OfferWords.cadence(changed["trigger"]),
        Delivery.OfferWords.cadence(before["trigger"]),
        :always
      ),
      change("Name", changed["title"], before["title"], :changed),
      change(
        "Posts in",
        channel(changed["delivery_channel"]),
        channel(before["delivery_channel"]),
        :changed
      ),
      change("Repository", changed["repository"], before["repository"], :changed),
      change("Stops", stops(changed["expires_at"]), stops(before["expires_at"]), :changed),
      if(action == "delete", do: {"After this", "It stops for good; its past runs stay listed."})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp change(_label, nil, _was, _show), do: nil
  defp change(label, value, value, :always), do: {label, value}
  defp change(_label, value, value, :changed), do: nil
  defp change(label, value, nil, _show), do: {label, value}
  defp change(label, %{} = value, %{} = was, _show), do: {label, [value, {:markup, "_was_"}, was]}
  defp change(label, value, was, _show) when is_map(value), do: {label, [value, "was " <> was]}
  defp change(label, value, %{} = was, _show), do: {label, [value, {:markup, "_was_"}, was]}

  defp change("How often" = label, value, was, _show),
    do: {label, value <> " (was " <> Wording.lowercase_first(was) <> ")"}

  defp change(label, value, was, _show), do: {label, value <> " (was " <> was <> ")"}

  defp channel("slack:" <> _rest = conversation_ref) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, _workspace, channel} -> %{"channel_ref" => channel}
      :error -> nil
    end
  end

  defp channel(_conversation), do: nil

  defp stops(value) when is_binary(value), do: Delivery.OfferWords.stamp(value)
  defp stops(_never), do: "Never"

  # New instructions are shown whole, and the old ones under them, so a
  # person confirms the words the automation will act on.
  defp automation_instructions(%{"prompt" => was}, %{"prompt" => now})
       when is_binary(now) and now != was do
    [section("*What it will do*")] ++
      plain_message_blocks(now) ++
      if(is_binary(was),
        do: [section("*What it did before*")] ++ plain_message_blocks(was),
        else: []
      )
  end

  defp automation_instructions(_before, %{"prompt" => now}) when is_binary(now),
    do: [section("*What it does*")] ++ plain_message_blocks(now)

  defp automation_instructions(_before, _changed), do: []

  defp automation_change_label("update"), do: "Update automation"
  defp automation_change_label("pause"), do: "Pause automation"
  defp automation_change_label("resume"), do: "Resume automation"
  defp automation_change_label("delete"), do: "Delete automation"

  defp automation_change_style(action) when action in ~w(pause delete), do: "danger"
  defp automation_change_style(_action), do: "primary"

  @spec slack_post_offer(String.t(), map(), String.t()) :: [map()]
  def slack_post_offer(ref, payload, "open") do
    summary =
      [
        "*Post another message*",
        escape(payload["message"]),
        "_Nothing is posted until the person who asked confirms._"
      ]
      |> compact_lines()

    sections(summary) ++
      [
        fact_fields([{"Where", post_place(payload)}]),
        actions(
          ref,
          button(
            "ryker_confirm_slack_post",
            "Post this message",
            ref,
            "primary",
            "Post this message",
            "Ryker posts this message as written, where this card says.",
            "Post message"
          )
        )
      ]
  end

  def slack_post_offer(_ref, payload, "confirmed") do
    [
      section(confirmed_slack_post_summary(payload)),
      fact_fields([{"Where", post_place(payload)}])
    ]
  end

  # The channel by Slack's own mention, which Slack shows as its name, and
  # whether the message goes in a thread there.
  defp post_place(%{"conversation_ref" => conversation} = payload) do
    thread? = is_binary(payload["thread_ref"])

    case channel(conversation) do
      nil -> "The conversation Ryker was asked about"
      place when thread? -> [place, "in a thread"]
      place -> place
    end
  end

  defp post_place(_payload), do: "The conversation Ryker was asked about"

  # Until the host could build a message link this card said the worker was
  # "sending or reconciling" the post forever, even long after it had landed.
  # The link is the only honest way to say it is sent.
  defp confirmed_slack_post_summary(%{"message_url" => url}) when is_binary(url),
    do: "*Message posted* · #{link(url, "Open message")}"

  defp confirmed_slack_post_summary(_payload),
    do: "*Message confirmed*\n_Ryker is posting it._"

  defp behavior_offer("preference_offer", ref, payload) do
    summary =
      [
        "*Preference · #{escape(Delivery.OfferWords.humanize(payload["key"]))}*",
        escape(Delivery.OfferWords.humanize(payload["value"])),
        "_Nothing changes until you confirm._"
      ]
      |> compact_lines()

    (sections(summary) ++
       [
         facts([
           {"Applies to",
            Delivery.OfferWords.applies_to(payload["scope"], payload["repository"])},
           {"Expires", Delivery.OfferWords.duration(payload["expires_in"])}
         ]),
         behavior_actions(ref, "Confirm preference")
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp behavior_offer("guidance_offer", ref, payload) do
    summary =
      [
        "*Guidance · #{escape(payload["subject"])}*",
        escape(payload["text"]),
        "_Guidance only: it cannot start work, prove a fact or give Ryker more access._"
      ]
      |> compact_lines()

    (sections(summary) ++
       [
         facts([
           {"Applies to",
            Delivery.OfferWords.applies_to(payload["scope"], payload["repository"])},
           {"Shown to", Delivery.OfferWords.shown_to(payload["scope"], payload["visibility"])},
           {"Expires", Delivery.OfferWords.duration(payload["expires_in"])}
         ]),
         behavior_actions(ref, "Remember this")
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp behavior_offer("standing_assignment_offer", ref, payload) do
    summary =
      [
        "*Automation · #{escape(payload["title"])}*",
        escape(payload["task"]),
        "_It only reads and replies here; it cannot approve, publish, deploy or change systems._"
      ]
      |> compact_lines()

    (sections(summary) ++
       [
         facts([
           {"Listens to", Delivery.OfferWords.listens_to(payload)},
           {"Takes", Delivery.OfferWords.only_when(payload["filter"])},
           {"Posts in", channel(payload["delivery_channel"])},
           {"Repository", payload["repository"]},
           {"Stops", Delivery.OfferWords.stamp(payload["expires_at"]) || "When you turn it off"}
         ]),
         behavior_actions(ref, "Enable automation")
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp memory_offer(ref, payload) do
    summary =
      [
        "*Remember · #{escape(payload["subject"])}*",
        escape(payload["value"]),
        "_A hint for later: Ryker still checks live evidence and your repositories first._"
      ]
      |> compact_lines()

    (sections(summary) ++
       [
         facts([
           {"Applies to",
            Delivery.OfferWords.applies_to(payload["scope"], payload["repository"])},
           {"Shown to", Delivery.OfferWords.shown_to(payload["scope"], payload["visibility"])},
           {"Expires", Delivery.OfferWords.duration(payload["expires_in"])}
         ]),
         actions(
           ref,
           button(
             "ryker_confirm_memory",
             "Remember this",
             ref,
             "primary",
             "Remember this",
             "Ryker saves it as written, for the people and the time this card shows.",
             "Remember this"
           )
         )
       ])
    |> Enum.reject(&is_nil/1)
  end

  # The facts a card has, as one fields section, or nothing when it has none.
  defp facts(pairs) do
    case Enum.reject(pairs, fn {_label, value} -> value in [nil, ""] end) do
      [] -> nil
      present -> fact_fields(present)
    end
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
        "Ryker saves this as the card shows it, for the people and the time it names.",
        label
      )
    )
  end
end

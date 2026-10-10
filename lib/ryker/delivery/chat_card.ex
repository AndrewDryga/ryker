defmodule Ryker.Delivery.ChatCard do
  @moduledoc false
  alias Ryker.Behaviors
  alias Ryker.ControlPlane
  alias Ryker.Delivery.OfferWords
  alias Ryker.Emisar
  alias Ryker.InspectionRedactor
  alias Ryker.Memories
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Schedules
  alias Ryker.Settings
  alias Ryker.Slack
  alias Ryker.UTCDateTime
  alias Ryker.Wording

  @doc "Only a lifecycle state that changes the card's meaning is shown."
  def display_status(%{status: status})
      when status in [nil, :open, :confirmed, "open", "confirmed"],
      do: nil

  def display_status(%{kind: kind})
      when kind in ~w(evidence coverage finding progress goal goal_state alert_assessment),
      do: nil

  # The stored status in words: "superseded" and "dismissed" mean nothing to
  # the person reading the card.
  def display_status(%{kind: "input_request", status: status})
      when status in [:superseded, "superseded"],
      do: "Replaced by your edit"

  def display_status(%{status: status}) when status in [:answered, "answered"], do: "Answered"
  def display_status(%{status: status}) when status in [:dismissed, "dismissed"], do: "Closed"

  def display_status(%{status: status}) when status in [:superseded, "superseded"],
    do: "Replaced by a newer one"

  def display_status(%{status: status}),
    do: Wording.label(status)

  @doc """
  The card a record shows in Chat: `{:ok, card}`, `:none` when it shows none
  by design (a question answered by typing, which the reply asks), or
  `:ignore` when it cannot be drawn.
  """
  @spec project(Records.Record.t()) :: {:ok, map()} | :none | :ignore
  def project(%Records.Record{} = record) do
    case Records.RecordPayload.prepare(record.kind, record.payload, record.ref) do
      {:ok, %{payload: payload}} ->
        case card(record, payload) do
          %{} = card -> {:ok, card}
          :none -> :none
          nil -> :ignore
        end

      {:error, _reason} ->
        diagnostic_card(record)
    end
  end

  defp diagnostic_card(%Records.Record{kind: "event_wait", wait_error: error} = record)
       when error in ~w(deadline poll_after timer_deadline source_kind cursor schedule_failed
                        resume_failed) do
    deadline = diagnostic_deadline(record.payload)

    card =
      record
      |> common(
        "Wait",
        "Scheduling failed",
        nil,
        optional_detail([], "Hard deadline", deadline),
        nil
      )
      |> Map.put(:wait_warning, wait_warning(record))

    {:ok, card}
  end

  defp diagnostic_card(_record), do: :ignore

  defp diagnostic_deadline(%{"deadline_at" => value}) when is_binary(value) do
    case UTCDateTime.parse(value) do
      {:ok, deadline} -> DateTime.to_iso8601(deadline)
      _invalid -> nil
    end
  end

  defp diagnostic_deadline(_payload), do: nil

  @spec project_publication(Publication.Publication.t(), String.t()) :: {:ok, map()} | :ignore
  # Only a candidate nobody granted a draft for rests in `:reviewed` or
  # `:blocked`; an authorized one is already publishing. So this surface always
  # projects the unauthorized verdict, and offers the same approval the Slack
  # card and publication custody agree on.
  def project_publication(%Publication.Publication{status: status} = publication, record_ref)
      when status in [:reviewed, :blocked] and is_binary(record_ref) do
    publication
    |> Publication.Card.review(false)
    |> Publication.Card.prepare_record()
    |> project_publication_review(
      status,
      record_ref,
      Publication.Custody.approvable?(publication)
    )
  end

  def project_publication(%Publication.Publication{status: :published} = publication, record_ref)
      when is_binary(record_ref) do
    record = Publication.Card.published(publication)

    case Publication.Card.prepare_record(record) do
      {:ok, payload} ->
        {:ok,
         %{
           action: nil,
           choices: [],
           # What a person reads: the branch as GitHub names it, and no commit
           # hash, which the pull request shows (manual test, 2026-10-09).
           details: [
             {"Repository", Settings.repository_name(payload["repository"])},
             {"Branch", String.replace_prefix(payload["branch_ref"], "refs/heads/", "")},
             {"Pull request", "##{payload["pull_request_number"]}"}
           ],
           kind: "publication_result",
           label: "Published draft",
           ref: record_ref,
           status: :published,
           summary: "The reviewed change is open as a draft pull request.",
           title: payload["title"],
           url: safe_https_url(payload["pull_request_url"])
         }}

      {:error, _reason} ->
        :ignore
    end
  end

  def project_publication(_publication, _record_ref), do: :ignore

  defp project_publication_review({:ok, payload}, status, record_ref, approvable?) do
    {:ok,
     %{
       action: if(approvable?, do: :approve_publication),
       choices: [],
       details: [
         {"Repository", Settings.repository_name(payload["repository"])},
         {"Gate", payload["gate"]},
         {"Rebase", payload["rebase"]},
         {"Candidate tree", payload["candidate_tree"]}
       ],
       kind: "publication_review",
       label: "Publication review",
       ref: record_ref,
       status: status,
       summary: publication_review_summary(payload),
       title: payload["title"],
       url: nil
     }}
  end

  defp project_publication_review({:error, _reason}, _status, _record_ref, _approvable?),
    do: :ignore

  # Merge readiness releases the ordinary publish path; a blocked candidate is
  # releasable only on the separate draft-shareability verdict. Publication
  # custody re-decides both, so this only keeps the surface from offering an
  # approval the host would refuse.
  defp publication_review_summary(%{"publishable" => true}) do
    "The exact candidate passed trusted review and is ready for explicit publication approval."
  end

  defp publication_review_summary(%{"reasons" => []}), do: "The candidate is not publishable."
  defp publication_review_summary(%{"reasons" => reasons}), do: Enum.join(reasons, "\n")

  defp card(%Records.Record{kind: "task_offer", status: :confirmed} = record, _payload) do
    case Slack.TaskCardProjection.build(record) do
      {:ok, %{document: %{"task_card" => task}}} -> confirmed_task(record, task)
      {:error, _reason} -> nil
    end
  end

  defp card(%Records.Record{kind: "task_offer"} = record, payload) do
    details = optional_detail([], "Repository", Settings.repository_name(payload["repository"]))

    if payload["kind"] == "engineering" do
      common(
        record,
        "Engineering task",
        payload["title"],
        "Starts only after local confirmation in an isolated working copy.",
        details,
        :confirm_task
      )
    else
      common(
        record,
        "Local incident",
        payload["title"],
        "Starts a linked incident investigation in this conversation without creating a Slack channel.",
        details,
        :open_incident
      )
    end
  end

  defp card(%Records.Record{kind: "publication_offer"} = record, payload) do
    common(
      record,
      "Publication review",
      payload["title"],
      payload["body"],
      [],
      :review_publication
    )
  end

  # The conversation it posts in is this one, which the title already says; its
  # stored reference is nothing a person can read.
  defp card(
         %Records.Record{kind: "slack_post_offer"} = record,
         %{"transport" => "control_plane"} = payload
       ) do
    common(
      record,
      "Additional message",
      "Post this in the conversation",
      payload["message"],
      [],
      :confirm_post
    )
  end

  # How often comes from the recurrence the confirmation will save, never from
  # the title or task the model wrote: a card whose task said "Every weekday at
  # 09:00 UTC" offered, and on confirmation created, a Monday-only schedule.
  defp card(%Records.Record{kind: "schedule_offer"} = record, payload) do
    details =
      [
        {"How often",
         Schedules.ScheduleCadence.describe(payload["recurrence"], payload["timezone"])},
        {"What it may do",
         Schedules.ScheduleCadence.access(
           payload["authority"],
           Settings.repository_name(payload["repository"])
         )}
      ]
      |> optional_detail("Stops", OfferWords.stamp(payload["expires_at"]))

    common(record, "Schedule", payload["title"], payload["task"], details, :confirm_schedule)
  end

  defp card(%Records.Record{kind: "automation_change_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Automation", get_in(payload, ["after", "title"]))
      |> optional_detail("How often", changed_cadence(payload))

    common(
      record,
      "Automation change",
      OfferWords.humanize(payload["action"]) <> " automation",
      "Nothing changes until you confirm it.",
      details,
      :confirm_automation
    )
  end

  defp card(%Records.Record{kind: "memory_offer"} = record, payload) do
    details =
      []
      |> optional_detail(
        "Applies to",
        OfferWords.applies_to(
          chat_scope(payload["scope"]),
          Settings.repository_name(payload["repository"])
        )
      )
      |> optional_detail(
        "Shown to",
        OfferWords.shown_to(chat_scope(payload["scope"]), chat_scope(payload["visibility"]))
      )
      |> optional_detail("Expires", OfferWords.duration(payload["expires_in"]))

    common(
      record,
      "Memory proposal",
      payload["subject"],
      payload["value"],
      details,
      :confirm_memory
    )
  end

  defp card(%Records.Record{kind: "preference_offer"} = record, payload) do
    details =
      []
      |> optional_detail(
        "Applies to",
        OfferWords.applies_to(
          chat_scope(payload["scope"]),
          Settings.repository_name(payload["repository"])
        )
      )
      |> optional_detail("Expires", OfferWords.duration(payload["expires_in"]))

    common(
      record,
      "Behavior preference",
      OfferWords.humanize(payload["key"]),
      OfferWords.humanize(payload["value"]),
      details,
      :confirm_behavior
    )
  end

  defp card(%Records.Record{kind: "guidance_offer"} = record, payload) do
    details =
      []
      |> optional_detail(
        "Applies to",
        OfferWords.applies_to(
          chat_scope(payload["scope"]),
          Settings.repository_name(payload["repository"])
        )
      )
      |> optional_detail(
        "Shown to",
        OfferWords.shown_to(chat_scope(payload["scope"]), chat_scope(payload["visibility"]))
      )
      |> optional_detail("Expires", OfferWords.duration(payload["expires_in"]))

    common(
      record,
      "Guidance",
      payload["subject"],
      payload["text"],
      details,
      :confirm_behavior
    )
  end

  defp card(%Records.Record{kind: "standing_assignment_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Listens to", OfferWords.listens_to(payload))
      |> optional_detail("Repository", Settings.repository_name(payload["repository"]))
      |> optional_detail("Expires", OfferWords.stamp(payload["expires_at"]))

    common(
      record,
      "Standing assignment",
      payload["title"] || "Standing assignment",
      payload["task"],
      details,
      :confirm_behavior
    )
  end

  # The reply asks the question (Andrew, 2026-10-04, of a question asked in the reply and
  # again on its card: "in the reply"). A question answered by typing gets no card; one with
  # answers gets a card holding only them. Every question card once said "Reply below or
  # choose one of the offered answers." whether it offered any or not, and went on saying it
  # after the answer came. An answered question asks for nothing.
  # Having no card is the design here, not a card that could not be drawn: the reply
  # check refused every typed question as unrenderable, so Chat could not ask one
  # (2026-10-09).
  defp card(%Records.Record{kind: "input_request"}, %{"choices" => []}), do: :none

  defp card(%Records.Record{kind: "input_request"} = record, payload) do
    record
    |> common(
      "Input needed",
      nil,
      reply_prompt(record.status),
      [],
      :answer_input,
      payload["choices"]
    )
    |> Map.put(:chosen, chosen(record, payload["choices"]))
  end

  defp card(%Records.Record{kind: "event_wait"} = record, payload) do
    common(
      record,
      "Waiting for event",
      payload["verification"],
      if(is_nil(record.wait_error),
        do: "Ryker will resume when the exact trigger matches or the deadline elapses."
      ),
      [{"Deadline", payload["deadline_at"]}, {"Trigger", payload["kind"]}],
      nil
    )
    |> Map.put(:wait_warning, wait_warning(record))
  end

  defp card(%Records.Record{kind: "emisar_approval"} = record, payload) do
    record
    |> common(
      "Governed action",
      payload["action_id"],
      "Paused before execution. Approval remains authoritative in Emisar.",
      [
        {"Runner", Emisar.ApprovalStatus.runner_name(payload["runner_ref"])},
        {"Pack", Emisar.ApprovalStatus.pack_name(payload["pack_ref"])},
        {"Expires", payload["expires_at"]}
      ],
      nil
    )
    |> Map.put(:url, payload["approval_url"])
  end

  defp card(%Records.Record{kind: "evidence"} = record, payload) do
    common(
      record,
      "Evidence",
      payload["claim"] || source_name(payload),
      payload["observation"],
      optional_detail([], "Source", source_name(payload)),
      nil
    )
  end

  defp card(%Records.Record{kind: "coverage"} = record, payload) do
    common(
      record,
      "Coverage",
      OfferWords.humanize(payload["layer"]),
      payload["detail"],
      [{"Status", OfferWords.humanize(payload["status"])}, {"Source", payload["source"]}],
      nil
    )
  end

  defp card(%Records.Record{kind: "finding"} = record, payload) do
    secrets = InspectionRedactor.configured_secrets()

    prose = &InspectionRedactor.artifact(&1, secrets: secrets).text

    details =
      []
      |> optional_detail("Why", prose.(payload["reason"]))
      |> optional_detail("Scope", prose.(payload["scope"]))

    common(
      record,
      "Finding",
      OfferWords.humanize(payload["status"]),
      prose.(payload["what"]),
      details,
      nil
    )
  end

  defp card(%Records.Record{kind: "progress"} = record, payload) do
    common(
      record,
      "Progress",
      payload["phase"],
      payload["summary"],
      optional_detail([], "Next update", payload["next_due_at"]),
      nil
    )
  end

  defp card(%Records.Record{kind: "goal"} = record, payload) do
    details =
      [
        {"Kind", OfferWords.humanize(payload["kind"])},
        {"Authority", OfferWords.humanize(payload["authority"])},
        {"Required", if(payload["required"], do: "Yes", else: "No")}
      ]
      |> optional_detail("Stage", payload["stage"] && OfferWords.humanize(payload["stage"]))
      |> optional_detail("Replaces attempt", payload["successor_of"])

    common(
      record,
      "Goal",
      payload["requested_outcome"],
      payload["completion_contract"],
      details,
      nil
    )
  end

  defp card(%Records.Record{kind: "goal_state"} = record, payload) do
    evidence = evidence_refs(payload["evidence_refs"])
    details = optional_detail([{"Goal", payload["goal_id"]}], "Evidence", evidence)

    common(
      record,
      "Goal updated",
      OfferWords.humanize(payload["state"]),
      payload["detail"] || "Goal #{payload["goal_id"]}",
      details,
      nil
    )
  end

  defp card(%Records.Record{kind: "alert_assessment"} = record, payload) do
    details =
      []
      |> optional_detail("Impact", payload["impact"])
      |> optional_detail("Immediate action", payload["immediate_action"])
      |> optional_detail("Verification", payload["verification"])

    common(
      record,
      "Alert assessment",
      OfferWords.humanize(payload["verdict"]),
      payload["cause"] || payload["impact"],
      details,
      nil
    )
  end

  defp card(_record, _payload), do: nil

  @doc false
  def wait_warning(%Records.Record{kind: "event_wait", wait_error: "deadline"}),
    do: "Wait scheduling failed: its saved deadline is invalid."

  def wait_warning(%Records.Record{kind: "event_wait", wait_error: "source_kind"}),
    do: "Wait scheduling failed: the saved source identifier is invalid or exceeds 120 bytes."

  def wait_warning(%Records.Record{kind: "event_wait", wait_error: "cursor"}),
    do: "Wait scheduling failed: the saved cursor is invalid or exceeds 16 KiB."

  def wait_warning(%Records.Record{kind: "event_wait", wait_error: error} = record)
      when error in ~w(timer_deadline poll_after) do
    case diagnostic_deadline(record.payload) do
      nil -> wait_warning(%{record | wait_error: "deadline"})
      deadline -> wait_time_warning(error, deadline)
    end
  end

  # Ryker's own failures, which it tries again (`Ryker.Waits.EventSubscriptions.fail/2`); a
  # closed wait is no longer tried.
  def wait_warning(%Records.Record{
        kind: "event_wait",
        status: :open,
        wait_error: "schedule_failed"
      }),
      do: "Ryker could not schedule this wait. It tries again every 10 minutes."

  def wait_warning(%Records.Record{
        kind: "event_wait",
        status: :open,
        wait_error: "resume_failed"
      }),
      do: "Ryker could not resume this wait. It tries again every 10 minutes."

  def wait_warning(_record), do: nil

  defp wait_time_warning("timer_deadline", deadline),
    do: "Timer scheduling failed: the saved timer cannot run before its deadline (#{deadline})."

  defp wait_time_warning("poll_after", deadline),
    do: "Wait scheduling failed: the saved polling time is invalid. Hard deadline: #{deadline}."

  # What the Slack card says, and no more: "Work settled" and "Session 1" were Ryker's own
  # states, which a person cannot act on (manual test, 2026-10-01).
  defp confirmed_task(record, task) do
    details =
      []
      |> optional_detail("Repository", task["repository"])
      |> optional_detail("Action needed", task["action_needed"])

    card = %{
      action: nil,
      actions: task_actions(task["controls"], task["publication"]),
      choices: [],
      details: details,
      kind: "task",
      label: task_label(record),
      recovery_generation: get_in(task, ["publication", "recovery_generation"]),
      ref: record.ref,
      status: task["status"],
      summary: task["summary"],
      title: task["title"],
      url: get_in(task, ["publication", "pull_request_url"])
    }

    card
    |> optional_card_ref(:publication_ref, get_in(task, ["publication", "publication_ref"]))
  end

  defp optional_card_ref(card, key, value) when is_binary(value), do: Map.put(card, key, value)
  defp optional_card_ref(card, _key, _value), do: card

  defp task_label(%Records.Record{payload: %{"kind" => "incident"}}), do: "Local incident"
  defp task_label(%Records.Record{}), do: "Engineering task"

  defp task_actions(controls, publication) when is_list(controls) do
    work_actions =
      Enum.flat_map(controls, fn
        "stop" -> [:stop_task]
        "view_diff" -> [:view_diff]
        "close" -> [:close_task]
        "timeline" -> [:view_timeline]
        "evidence" -> [:view_evidence]
        "handoff" -> [:view_handoff]
        "postmortem" -> [:view_postmortem]
        _unknown -> []
      end)

    (work_actions ++ task_publication_actions(publication))
    |> Enum.uniq()
  end

  defp task_actions(_controls, _publication), do: []

  defp task_publication_actions(%{"controls" => controls}) when is_list(controls) do
    Enum.flat_map(controls, fn
      "publish" -> [:approve_task_publication]
      "retry" -> [:retry_task_publication]
      "update" -> [:update_task_publication]
      "discard" -> [:discard_task_publication]
      _open_or_unknown -> []
    end)
  end

  defp task_publication_actions(_publication), do: []

  defp common(record, label, title, summary, details, action, choices \\ []) do
    {outcome, confirmed} = split_outcome(outcome(record))

    %{
      action: if(record.status == :open, do: action, else: nil),
      choices: choices,
      details: confirmed_details(details, confirmed),
      kind: record.kind,
      label: label,
      outcome: outcome,
      ref: record.ref,
      status: record.status,
      summary: summary,
      title: title,
      url: nil
    }
  end

  # What a confirmed offer did, read from the row its confirmation saved. After
  # "Schedule this" or "Remember this" the button went away and nothing said
  # it had worked, and a schedule card kept its offer's words over a schedule
  # that ran on a different day. The saved row says what is true now.
  defp outcome(%Records.Record{status: :confirmed, id: id} = record) when is_binary(id),
    do: confirmed_outcome(record)

  defp outcome(_record), do: nil

  # What the saved row says about a fact the offer also stated, how often a schedule runs, takes
  # that fact's place among the details rather than repeating it beside the confirmed state
  # (Andrew, 2026-10-01: "● Scheduled · runs once on … · Open schedule" under "How often: Once on
  # …" was "messy").
  defp split_outcome(%{details: details} = outcome), do: {Map.delete(outcome, :details), details}
  defp split_outcome(outcome), do: {outcome, []}

  defp confirmed_details(details, []), do: details

  defp confirmed_details(details, confirmed) do
    Enum.map(details, fn {label, value} ->
      {label, List.keyfind(confirmed, label, 0, {label, value}) |> elem(1)}
    end)
  end

  defp confirmed_outcome(%Records.Record{kind: "schedule_offer", id: id}) do
    case Repo.fetch(Schedules.Schedule.Query.by_offer_record_id(id)) do
      {:ok, %Schedules.Schedule{} = schedule} -> schedule_outcome(schedule)
      {:error, :not_found} -> nil
    end
  end

  defp confirmed_outcome(%Records.Record{kind: "memory_offer", id: id}) do
    case Repo.fetch(Memories.MemoryEntry.Query.by_offer_record_id(id)) do
      {:ok, %Memories.MemoryEntry{} = memory} -> memory_outcome(memory)
      {:error, :not_found} -> nil
    end
  end

  defp confirmed_outcome(%Records.Record{kind: kind, id: id})
       when kind in ~w(preference_offer guidance_offer standing_assignment_offer) do
    case Repo.fetch(Behaviors.Behavior.Query.by_offer_record_id(id)) do
      {:ok, %Behaviors.Behavior{} = behavior} -> behavior_outcome(behavior)
      {:error, :not_found} -> nil
    end
  end

  defp confirmed_outcome(%Records.Record{kind: "automation_change_offer", payload: payload}) do
    {link, href} = automation_link(payload["automation_id"])
    outcome_line(:on, "Change applied", link, href)
  end

  defp confirmed_outcome(_record), do: nil

  defp schedule_outcome(%Schedules.Schedule{status: :active} = schedule) do
    cadence = Schedules.ScheduleCadence.describe(schedule.recurrence, schedule.timezone)
    {link, href} = automation_link(schedule.ref)

    :on
    |> outcome_line("Scheduled", link, href)
    |> Map.put(:details, [{"How often", cadence}])
  end

  defp schedule_outcome(%Schedules.Schedule{status: status} = schedule) do
    {link, href} = automation_link(schedule.ref)
    outcome_line(:off, "Schedule " <> schedule_state(status), link, href)
  end

  defp schedule_state(:paused), do: "paused"
  defp schedule_state(:completed), do: "done"
  defp schedule_state(:expired), do: "expired"
  defp schedule_state(:deleted), do: "deleted"

  defp memory_outcome(%Memories.MemoryEntry{status: :active, ref: ref}),
    do: outcome_line(:on, "Saved to memory", "Open facts", "/memory#" <> fact_id(ref))

  defp memory_outcome(%Memories.MemoryEntry{status: :superseded}),
    do: outcome_line(:off, "Memory replaced by a newer version", nil, nil)

  defp memory_outcome(%Memories.MemoryEntry{status: :deleted}),
    do: outcome_line(:off, "Memory forgotten", nil, nil)

  defp memory_outcome(%Memories.MemoryEntry{status: :expired}),
    do: outcome_line(:off, "Memory expired", nil, nil)

  defp behavior_outcome(%Behaviors.Behavior{kind: kind, status: status, ref: ref}) do
    name = behavior_name(kind)
    {link, href} = behavior_link(kind, ref)

    case status do
      :active -> outcome_line(:on, name <> " saved", link, href)
      :disabled -> outcome_line(:off, name <> " paused", link, href)
      :deleted -> outcome_line(:off, name <> " deleted", nil, nil)
      :expired -> outcome_line(:off, name <> " expired", nil, nil)
      :superseded -> outcome_line(:off, name <> " replaced by a newer version", nil, nil)
    end
  end

  defp behavior_name(:preference), do: "Preference"
  defp behavior_name(:guidance), do: "Guidance"
  defp behavior_name(:standing_assignment), do: "Rule"

  defp behavior_link(:standing_assignment, ref), do: {"Open rules", "/rules#behavior-" <> ref}
  defp behavior_link(_kind, ref), do: {"Open instructions", "/instructions#behavior-" <> ref}

  defp automation_link("schedule:" <> _rest = ref),
    do: {"Open schedule", ControlPlane.Paths.schedule(ref)}

  defp automation_link("behavior:" <> _rest = ref), do: {"Open rules", "/rules#behavior-" <> ref}
  defp automation_link(_ref), do: {nil, nil}

  defp outcome_line(tone, word, link, href),
    do: %{href: href, link: link, tone: tone, word: word}

  # The Facts page names each row by its reference with every character outside
  # letters, digits, "_" and "-" replaced.
  defp fact_id(ref), do: "fact-" <> String.replace(ref, ~r/[^A-Za-z0-9_-]/, "-")

  # A time automation's change names the cadence it leaves the schedule on, in
  # the same words as the schedule itself.
  defp changed_cadence(%{"automation_kind" => "time", "after" => %{"trigger" => trigger}}),
    do: OfferWords.cadence(trigger)

  defp changed_cadence(_payload), do: nil

  # Which offered answer the person chose, so the answered card can show it
  # (Andrew, 2026-10-01: "we need to highlight selected option"). A typed
  # reply that matched no option chose none.
  defp chosen(%Records.Record{status: :answered, id: id}, choices)
       when is_binary(id) and is_list(choices) do
    id
    |> Records.Response.Query.latest_choice()
    |> Repo.peek()
    |> case do
      {index, _choice} when is_integer(index) -> index
      {nil, choice} when is_binary(choice) -> Enum.find_index(choices, &(&1 == choice))
      _none -> nil
    end
  end

  defp chosen(_record, _choices), do: nil

  defp reply_prompt(:open), do: "Reply below or choose an answer."
  defp reply_prompt(_status), do: nil

  # A citation names its source by the reference a tool issued, which nobody can
  # open or read; only a source written as a name says something here. The
  # timeline keeps the reference.
  defp source_name(%{"source_name" => name, "source_id" => name}), do: nil
  defp source_name(%{"source_name" => name}), do: name
  defp source_name(_payload), do: nil

  # An empty evidence list is honest for qualitative review work, so it stays absent
  # rather than rendering a row with nothing in it.
  defp evidence_refs(refs) when is_list(refs) and refs != [], do: Enum.join(refs, ", ")
  defp evidence_refs(_refs), do: nil

  # A Chat conversation is its own workspace (`Ryker.Episodes.Scope`), so what is saved for
  # the workspace holds in this conversation alone: the card said "Everyone in this
  # workspace" of a fact no other chat could recall (2026-10-09).
  defp chat_scope("workspace"), do: "conversation"
  defp chat_scope(scope), do: scope

  defp optional_detail(details, _label, nil), do: details
  defp optional_detail(details, label, value), do: details ++ [{label, to_string(value)}]

  defp safe_https_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and host != "" ->
        value

      _unsafe ->
        nil
    end
  end

  defp safe_https_url(_value), do: nil
end

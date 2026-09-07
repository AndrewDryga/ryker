defmodule Responder.ControlPlane.Card do
  @moduledoc false

  alias Responder.ControlPlane.InspectionRedactor
  alias Responder.Publication.Card, as: PublicationCard
  alias Responder.Publication.Publication
  alias Responder.Slack.TaskCardProjection
  alias Responder.State.{Record, RecordPayload}

  @doc "Only actionable cards expose their custody status; facts and transitions have no open lifecycle."
  def display_status(%{kind: kind})
      when kind in ~w(evidence coverage finding progress goal goal_state alert_assessment),
      do: nil

  def display_status(card), do: card.status

  @spec project(Record.t()) :: {:ok, map()} | :ignore
  def project(%Record{} = record) do
    case RecordPayload.prepare(record.kind, record.payload, record.ref) do
      {:ok, %{payload: payload}} ->
        case card(record, payload) do
          %{} = card -> {:ok, card}
          nil -> :ignore
        end

      {:error, _reason} ->
        diagnostic_card(record)
    end
  end

  defp diagnostic_card(%Record{kind: "event_wait", wait_error: error} = record)
       when error in ~w(deadline poll_after timer_deadline source_kind cursor) do
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
    case DateTime.from_iso8601(value) do
      {:ok, deadline, 0} -> DateTime.to_iso8601(deadline)
      _invalid -> nil
    end
  end

  defp diagnostic_deadline(_payload), do: nil

  @spec project_publication(Publication.t(), String.t()) :: {:ok, map()} | :ignore
  def project_publication(%Publication{status: status} = publication, record_ref)
      when status in [:reviewed, :blocked] and is_binary(record_ref) do
    publication
    |> PublicationCard.review()
    |> PublicationCard.prepare_record()
    |> project_publication_review(status, record_ref)
  end

  def project_publication(%Publication{status: :published} = publication, record_ref)
      when is_binary(record_ref) do
    record = PublicationCard.published(publication)

    case PublicationCard.prepare_record(record) do
      {:ok, payload} ->
        {:ok,
         %{
           action: :check_publication,
           choices: [],
           details: [
             {"Repository", payload["repository"]},
             {"Branch", payload["branch_ref"]},
             {"Commit", payload["commit_sha"]},
             {"Pull request", "##{payload["pull_request_number"]}"}
           ],
           kind: "publication_result",
           label: "Published draft",
           ref: record_ref,
           status: :published,
           summary: "The exact reviewed candidate was published as a draft pull request.",
           title: payload["title"],
           url: safe_https_url(payload["pull_request_url"])
         }}

      {:error, _reason} ->
        :ignore
    end
  end

  def project_publication(_publication, _record_ref), do: :ignore

  defp project_publication_review({:ok, payload}, status, record_ref) do
    {:ok,
     %{
       action: if(status == :reviewed and payload["publishable"], do: :approve_publication),
       choices: [],
       details: [
         {"Repository", payload["repository"]},
         {"Gate", payload["gate"]},
         {"Rebase", payload["rebase"]},
         {"Patch", "#{payload["patch_bytes"]} bytes"},
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

  defp project_publication_review({:error, _reason}, _status, _record_ref), do: :ignore

  defp publication_review_summary(%{"publishable" => true}) do
    "The exact candidate passed trusted review and is ready for explicit publication approval."
  end

  defp publication_review_summary(%{"reasons" => []}), do: "The candidate is not publishable."
  defp publication_review_summary(%{"reasons" => reasons}), do: Enum.join(reasons, "\n")

  defp card(%Record{kind: "task_offer", status: :confirmed} = record, _payload) do
    case TaskCardProjection.build(record) do
      {:ok, %{document: %{"task_card" => task}}} -> confirmed_task(record, task)
      {:error, _reason} -> nil
    end
  end

  defp card(%Record{kind: "task_offer"} = record, payload) do
    details = optional_detail([], "Repository", payload["repository"])

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
        "Starts a linked incident investigation in this Lab without creating a Slack channel.",
        details,
        :open_incident
      )
    end
  end

  defp card(%Record{kind: "publication_offer"} = record, payload) do
    common(
      record,
      "Publication review",
      payload["title"],
      payload["body"],
      [],
      :review_publication
    )
  end

  defp card(
         %Record{kind: "slack_post_offer"} = record,
         %{"transport" => "control_plane"} = payload
       ) do
    common(
      record,
      "Additional message",
      "Post this in Conversation Lab",
      payload["message"],
      [{"Destination", payload["conversation_ref"]}],
      :confirm_post
    )
  end

  defp card(%Record{kind: "schedule_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Authority", payload["authority"])
      |> optional_detail("Repository", payload["repository"])
      |> optional_detail("Timezone", payload["timezone"])
      |> optional_detail("Catch-up", payload["catch_up"])

    common(record, "Schedule", payload["title"], payload["task"], details, :confirm_schedule)
  end

  defp card(%Record{kind: "automation_change_offer"} = record, payload) do
    details = [
      {"Automation", payload["automation_id"]},
      {"Revision", Integer.to_string(payload["revision"])}
    ]

    common(
      record,
      "Automation change",
      humanize(payload["action"]) <> " automation",
      "Nothing changes until this exact durable revision is confirmed.",
      details,
      :confirm_automation
    )
  end

  defp card(%Record{kind: "memory_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Kind", payload["kind"])
      |> optional_detail("Scope", payload["scope"])
      |> optional_detail("Visibility", payload["visibility"])
      |> optional_detail("Expires", payload["expires_in"])
      |> optional_detail("Repository", payload["repository"])

    common(
      record,
      "Memory proposal",
      payload["subject"],
      payload["value"],
      details,
      :confirm_memory
    )
  end

  defp card(%Record{kind: "preference_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Scope", payload["scope"])
      |> optional_detail("Expires", payload["expires_in"])
      |> optional_detail("Repository", payload["repository"])

    common(
      record,
      "Behavior preference",
      humanize(payload["key"]),
      payload["value"],
      details,
      :confirm_behavior
    )
  end

  defp card(%Record{kind: "guidance_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Scope", payload["scope"])
      |> optional_detail("Visibility", payload["visibility"])
      |> optional_detail("Expires", payload["expires_in"])
      |> optional_detail("Repository", payload["repository"])

    common(
      record,
      "Guidance",
      payload["subject"],
      payload["text"],
      details,
      :confirm_behavior
    )
  end

  defp card(%Record{kind: "standing_assignment_offer"} = record, payload) do
    details =
      []
      |> optional_detail("Source", payload["source_kind"] || payload["source_filter"])
      |> optional_detail("Repository", payload["repository"])
      |> optional_detail("Expires", payload["expires_at"] || payload["expires_in"])

    common(
      record,
      "Standing assignment",
      payload["title"] || "Standing assignment",
      payload["task"],
      details,
      :confirm_behavior
    )
  end

  defp card(%Record{kind: "input_request"} = record, payload) do
    common(
      record,
      "Input needed",
      payload["question"],
      "Reply below or choose one of the offered answers.",
      [],
      if(payload["choices"] == [], do: nil, else: :answer_input),
      payload["choices"]
    )
  end

  defp card(%Record{kind: "event_wait"} = record, payload) do
    common(
      record,
      "Waiting for event",
      payload["verification"],
      if(is_nil(record.wait_error),
        do: "Responder will resume when the exact trigger matches or the deadline elapses."
      ),
      [{"Deadline", payload["deadline_at"]}, {"Trigger", payload["kind"]}],
      nil
    )
    |> Map.put(:wait_warning, wait_warning(record))
  end

  defp card(%Record{kind: "emisar_approval"} = record, payload) do
    record
    |> common(
      "Governed action",
      payload["action_id"],
      "Paused before execution. Approval remains authoritative in Emisar.",
      [
        {"Runner", payload["runner_ref"]},
        {"Pack", payload["pack_ref"]},
        {"Expires", payload["expires_at"]}
      ],
      nil
    )
    |> Map.put(:url, payload["approval_url"])
  end

  defp card(%Record{kind: "evidence"} = record, payload) do
    common(
      record,
      "Evidence",
      payload["claim"] || payload["source_name"],
      payload["observation"],
      [{"Source", payload["source_name"]}],
      nil
    )
  end

  defp card(%Record{kind: "coverage"} = record, payload) do
    common(
      record,
      "Coverage",
      humanize(payload["layer"]),
      payload["detail"],
      [{"Status", humanize(payload["status"])}, {"Source", payload["source"]}],
      nil
    )
  end

  defp card(%Record{kind: "finding"} = record, payload) do
    secrets = InspectionRedactor.configured_secrets()

    prose = fn value ->
      InspectionRedactor.artifact(value, secrets: secrets).text
    end

    common(
      record,
      "Finding",
      humanize(payload["status"]),
      prose.(payload["what"]),
      []
      |> optional_detail("Why", prose.(payload["reason"]))
      |> optional_detail("Scope", prose.(payload["scope"])),
      nil
    )
  end

  defp card(%Record{kind: "progress"} = record, payload) do
    common(
      record,
      "Progress",
      payload["phase"],
      payload["summary"],
      optional_detail([], "Next update", payload["next_due_at"]),
      nil
    )
  end

  defp card(%Record{kind: "goal"} = record, payload) do
    common(
      record,
      "Goal",
      payload["requested_outcome"],
      payload["completion_contract"],
      [
        {"Kind", humanize(payload["kind"])},
        {"Authority", humanize(payload["authority"])},
        {"Required", if(payload["required"], do: "Yes", else: "No")}
      ],
      nil
    )
  end

  defp card(%Record{kind: "goal_state"} = record, payload) do
    common(
      record,
      "Goal updated",
      humanize(payload["state"]),
      payload["detail"] || "Goal #{payload["goal_id"]}",
      [{"Goal", payload["goal_id"]}],
      nil
    )
  end

  defp card(%Record{kind: "alert_assessment"} = record, payload) do
    details =
      []
      |> optional_detail("Impact", payload["impact"])
      |> optional_detail("Immediate action", payload["immediate_action"])
      |> optional_detail("Verification", payload["verification"])

    common(
      record,
      "Alert assessment",
      humanize(payload["verdict"]),
      payload["cause"] || payload["impact"],
      details,
      nil
    )
  end

  defp card(_record, _payload), do: nil

  @doc false
  def wait_warning(%Record{kind: "event_wait", wait_error: "deadline"}),
    do: "Wait scheduling failed: its saved deadline is invalid."

  def wait_warning(%Record{kind: "event_wait", wait_error: "source_kind"}),
    do: "Wait scheduling failed: the saved source identifier is invalid or exceeds 120 bytes."

  def wait_warning(%Record{kind: "event_wait", wait_error: "cursor"}),
    do: "Wait scheduling failed: the saved cursor is invalid or exceeds 16 KiB."

  def wait_warning(%Record{kind: "event_wait", wait_error: error} = record)
      when error in ~w(timer_deadline poll_after) do
    case diagnostic_deadline(record.payload) do
      nil -> wait_warning(%{record | wait_error: "deadline"})
      deadline -> wait_time_warning(error, deadline)
    end
  end

  def wait_warning(_record), do: nil

  defp wait_time_warning("timer_deadline", deadline),
    do: "Timer scheduling failed: the saved timer cannot run before its deadline (#{deadline})."

  defp wait_time_warning("poll_after", deadline),
    do: "Wait scheduling failed: the saved polling time is invalid. Hard deadline: #{deadline}."

  defp confirmed_task(record, task) do
    details =
      []
      |> optional_detail("Repository", task["repository"])
      |> optional_detail("Work", task["work_state"])
      |> optional_detail("Action needed", task["action_needed"])
      |> optional_detail("Session", task["session_generation"])

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
    |> optional_card_ref(:review_offer_ref, get_in(task, ["publication", "review_offer_ref"]))
  end

  defp optional_card_ref(card, key, value) when is_binary(value), do: Map.put(card, key, value)
  defp optional_card_ref(card, _key, _value), do: card

  defp task_label(%Record{payload: %{"kind" => "incident"}}), do: "Local incident"
  defp task_label(%Record{}), do: "Engineering task"

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
      "readiness" -> [:request_task_readiness]
      "publish" -> [:approve_task_publication]
      "check" -> [:check_task_publication]
      "retry" -> [:retry_task_publication]
      "update" -> [:update_task_publication]
      "discard" -> [:discard_task_publication]
      _open_or_unknown -> []
    end)
  end

  defp task_publication_actions(_publication), do: []

  defp common(record, label, title, summary, details, action, choices \\ []) do
    %{
      action: if(record.status == :open, do: action, else: nil),
      choices: choices,
      details: details,
      kind: record.kind,
      label: label,
      ref: record.ref,
      status: record.status,
      summary: summary,
      title: title,
      url: nil
    }
  end

  defp optional_detail(details, _label, nil), do: details
  defp optional_detail(details, label, value), do: details ++ [{label, to_string(value)}]

  defp humanize(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp humanize(value), do: to_string(value)

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

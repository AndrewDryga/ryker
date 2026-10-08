defmodule Ryker.Slack.WorkRecord do
  @moduledoc """
  Bounded, host-rendered views over one task or incident's canonical record.

  These views summarize durable episode events, typed state records, and
  publication custody. They never ask a model to reconstruct history or fill
  missing impact, cause, ownership, or corrective-action facts.
  """
  alias Ryker.Episodes
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, TaskCard, TaskCardDetails, WorkTarget}
  alias Ryker.Slack.Renderer.Blocks
  alias Ryker.Work

  @maximum_events 60
  @maximum_records 80
  @maximum_publications 10
  @maximum_message_characters 18_000

  @type kind :: :timeline | :evidence | :handoff | :recovery | :postmortem

  @spec build(String.t(), map(), kind()) :: {:ok, map()} | {:error, term()}
  def build(work_ref, target, kind)
      when kind in [:timeline, :evidence, :handoff, :recovery, :postmortem] do
    with {:ok, resolved} <- WorkTarget.resolve(work_ref, target),
         :ok <- kind_available(resolved.kind, kind) do
      snapshot = resolved |> snapshot() |> shown_in_channel()

      case render(kind, snapshot) do
        nil -> {:error, :work_record_not_available}
        message -> {:ok, %{"message" => compact_message(message)}}
      end
    end
  end

  def build(_work_ref, _target, _kind), do: {:error, :work_record_not_available}

  @doc false
  @spec build_episode(Records.Record.t(), Episodes.Episode.t(), kind()) ::
          {:ok, map()} | {:error, term()}
  def build_episode(
        %Records.Record{kind: "task_offer", payload: %{"kind" => offered_kind}, ref: work_ref},
        %Episodes.Episode{} = episode,
        kind
      )
      when offered_kind in ["engineering", "incident"] and
             kind in [:timeline, :evidence, :handoff, :recovery, :postmortem] and
             is_binary(work_ref) do
    work_kind = if offered_kind == "incident", do: :incident, else: :task

    with true <- Regex.match?(~r/\Arecord:task_offer:[A-Za-z0-9_.:-]{1,220}\z/, work_ref),
         :ok <- kind_available(work_kind, kind),
         message when is_binary(message) <-
           render(kind, snapshot(%{episode: episode, kind: work_kind, work_ref: work_ref})) do
      {:ok, %{"message" => compact_message(message)}}
    else
      _unavailable -> {:error, :work_record_not_available}
    end
  end

  def build_episode(_record, _episode, _kind), do: {:error, :work_record_not_available}

  defp snapshot(resolved) do
    episode_id = resolved.episode.id

    events =
      episode_id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.ordered_by_sequence_desc()
      |> Episodes.Event.Query.limit_to(@maximum_events)
      |> Repo.all()
      |> Enum.reverse()

    records =
      episode_id
      |> Records.Record.Query.by_episode_id()
      |> Records.Record.Query.ordered_by_sequence_desc()
      |> Records.Record.Query.limit_to(@maximum_records)
      |> Repo.all()
      |> Enum.reverse()

    publications =
      episode_id
      |> Publication.Publication.Query.by_episode_id()
      |> Publication.Publication.Query.ordered_by_recent()
      |> Publication.Publication.Query.limit_to(@maximum_publications)
      |> Repo.all()
      |> Enum.reverse()

    # What GitHub last said of each pull request: the views said "open" for one
    # a person had merged (2026-10-04 review).
    pull_request_states =
      publications
      |> Enum.map(& &1.id)
      |> Publication.Followup.Query.by_publication_ids()
      |> Publication.Followup.Query.select_states()
      |> Repo.all()
      |> Map.new()

    %{
      episode: resolved.episode,
      events: events,
      kind: resolved.kind,
      publications: publications,
      pull_request_states: pull_request_states,
      records: records,
      title: work_title(resolved.work_ref),
      turn: Repo.one(Work.Turn.Query.current(resolved.episode)),
      work_ref: resolved.work_ref
    }
  end

  # The card shows a record only while every source behind it may still be
  # shown in its channel (`Ryker.Slack.TaskCardProjection`). These views, which
  # anyone there can open, showed every record regardless (2026-10-04 review).
  # The control plane's copy (`build_episode/3`) is the operator's and keeps
  # them all, as the task's page does.
  defp shown_in_channel(%{turn: %Work.Turn{session_id: session_id}} = snapshot)
       when is_binary(session_id) do
    repository =
      session_id
      |> Work.Session.Query.by_id()
      |> Work.Session.Query.select_repository_refs()
      |> Repo.one()

    shown =
      snapshot.records
      |> Enum.map(
        &Records.DerivedContext.record(%{
          "kind" => &1.kind,
          "payload" => &1.payload,
          "ref" => &1.ref
        })
      )
      |> Records.DerivedContext.filter(snapshot.episode, repository)
      |> MapSet.new(& &1["document"]["ref"])

    %{snapshot | records: Enum.filter(snapshot.records, &MapSet.member?(shown, &1.ref))}
  end

  defp shown_in_channel(snapshot), do: %{snapshot | records: []}

  # The task or incident by its own title; the card's reference is Ryker's (Andrew, 2026-10-01:
  # "Timeline for task-card:c00814ba-…").
  defp work_title("task-card:" <> _rest = ref), do: Repo.one(TaskCard.Query.task_title(ref))

  defp work_title("record:task_offer:" <> _rest = ref),
    do: ref |> Records.Record.Query.by_ref() |> Records.Record.Query.select_titles() |> Repo.one()

  defp work_title("incident-room:" <> _rest = ref),
    do: ref |> IncidentRoom.Query.by_ref() |> IncidentRoom.Query.select_titles() |> Repo.one()

  defp work_title(_ref), do: nil

  # A person's account of the task, in Slack's own dates that each reader sees in their time
  # zone. Andrew, 2026-10-01, of what these said before: "overall all this is simply useless in
  # slack for humans to see".
  defp render(:timeline, snapshot) do
    goals = goal_outcomes(snapshot.records)

    entries =
      (Enum.map(snapshot.events, &event_entry/1) ++
         Enum.flat_map(snapshot.records, &record_entry(&1, goals)) ++
         Enum.map(snapshot.publications, &publication_entry(&1, snapshot.pull_request_states)))
      |> Enum.sort_by(& &1.sort)
      |> Enum.map(& &1.text)

    [
      heading("Timeline", snapshot),
      "Now: #{Episodes.Words.label(snapshot.episode.state)}",
      if(entries == [], do: "Nothing has happened yet.", else: Enum.join(entries, "\n"))
    ]
    |> Enum.join("\n")
  end

  defp render(:evidence, snapshot) do
    evidence = Enum.filter(snapshot.records, &(&1.kind == "evidence"))
    coverage = Enum.filter(snapshot.records, &(&1.kind == "coverage"))
    findings = Enum.filter(snapshot.records, &(&1.kind == "finding"))

    evidence_lines =
      Enum.map(evidence, fn record ->
        payload = record.payload

        confidence =
          if payload["confidence"], do: " (#{text(payload["confidence"])} confidence)", else: ""

        "• *#{text(payload["source_name"])}*#{confidence}: " <>
          compact(payload["observation"], 900)
      end)

    gaps =
      for %{payload: %{"status" => "unknown"} = payload} <- coverage,
          do: "• Not checked yet: #{text(payload["layer"])} · #{compact(payload["detail"], 600)}"

    unexplained =
      for %{payload: %{"status" => "unexplained"} = payload} <- findings,
          do: "• Unexplained: #{compact(payload["what"], 600)}"

    lines = evidence_lines ++ gaps ++ unexplained ++ incident_unknowns(snapshot, findings)

    [
      heading("Evidence", snapshot),
      if(lines == [], do: "No evidence recorded yet.", else: Enum.join(lines, "\n"))
    ]
    |> Enum.join("\n")
  end

  defp render(:handoff, snapshot) do
    progress = latest(snapshot.records, "progress")

    waits =
      Enum.filter(
        snapshot.records,
        &(&1.kind in ["input_request", "event_wait"] and &1.status == :open)
      )

    steps = current_goals(snapshot.records)

    [
      heading("Where this stands", snapshot),
      "#{Episodes.Words.label(snapshot.episode.state)}. " <> progress_line(progress),
      if(steps != [], do: "Steps:\n" <> Enum.join(steps, "\n")),
      Enum.map(waits, &wait_line/1),
      if(snapshot.kind == :task,
        do: publication_line(List.last(snapshot.publications), snapshot.pull_request_states)
      ),
      for("• " <> unknown <- incident_unknowns(snapshot, []), do: "Unknown: " <> unknown)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # The recovery view exists only while the host is holding a finished worker's
  # working copy or its reply. It is the same brief the recovery page shows, so
  # an operator reading Slack and an operator reading the control plane act on
  # one set of facts, and the worker's own retained answer is attributed to it
  # rather than read as a check result.
  defp render(:recovery, %{turn: %Work.Turn{} = turn} = snapshot) do
    case Work.Recovery.workspace_hold(turn) do
      nil ->
        nil

      _held ->
        brief = Work.Recovery.brief(turn)

        [
          "Recovery for #{snapshot.work_ref}",
          text(brief.headline),
          text(brief.cause),
          "What you need to do:\n#{text(brief.next_step)}",
          "Workspace: #{text(brief.workspace)}",
          "Reply: #{text(brief.delivery)}",
          worker_report(brief.model_output)
        ]
        |> Enum.join("\n")
    end
  end

  defp render(:recovery, _snapshot), do: nil

  defp render(:postmortem, snapshot) do
    assessment = latest(snapshot.records, "alert_assessment")

    explained =
      snapshot.records
      |> Enum.filter(&(&1.kind == "finding" and &1.payload["status"] == "explained"))
      |> List.last()

    impact =
      if assessment,
        do: compact(assessment.payload["impact"], 1_200),
        else: "Unknown: no alert impact assessment is recorded."

    cause =
      cond do
        assessment && is_binary(assessment.payload["cause"]) ->
          compact(assessment.payload["cause"], 1_200)

        explained ->
          compact(explained.payload["what"], 1_200)

        true ->
          "Unknown: no evidence-backed root cause is recorded."
      end

    actions = corrective_actions(snapshot.records)

    [
      "Postmortem draft for #{snapshot.work_ref}",
      "Status: draft generated from the durable record; human review is required.",
      "Impact: #{impact}",
      "Cause: #{cause}",
      section(
        "Chronology",
        snapshot.events |> Enum.take(-20) |> Enum.map(&event_entry(&1).text),
        nil
      ),
      section(
        "Corrective actions",
        actions,
        "Unknown: no durable corrective-action goals are recorded."
      ),
      section("Material unknowns", material_unknowns(snapshot, [], []), nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp heading(view, %{title: title}) when is_binary(title) and title != "",
    do: "*#{view}* · #{compact(title, 200)}"

  defp heading(view, %{kind: :incident}), do: "*#{view}* · this incident"
  defp heading(view, _snapshot), do: "*#{view}* · this task"

  # The same words the request's timeline uses for each transition.
  defp event_entry(event) do
    %{
      sort: {DateTime.to_unix(event.occurred_at, :microsecond), 0, event.sequence},
      text: "• #{slack_time(event.occurred_at)}  #{Episodes.Words.lifecycle_title(event.kind)}"
    }
  end

  defp record_entry(record, goals) do
    case record_words(record.kind, record.payload, goals) do
      nil ->
        []

      words ->
        [
          %{
            sort: {DateTime.to_unix(record.inserted_at, :microsecond), 1, record.sequence},
            text: "• #{slack_time(record.inserted_at)}  #{words}"
          }
        ]
    end
  end

  defp record_words("evidence", payload, _goals),
    do: "Evidence from #{text(payload["source_name"])}: #{compact(payload["observation"], 300)}"

  defp record_words("progress", payload, _goals),
    do: "Update: #{compact(String.trim(payload["summary"] || ""), 300)}"

  defp record_words("finding", payload, _goals), do: "Finding: #{compact(payload["what"], 300)}"

  defp record_words("goal", payload, _goals),
    do: "Step planned: #{compact(payload["requested_outcome"], 300)}"

  defp record_words("goal_state", %{"goal_id" => id, "state" => state}, goals),
    do: "Step #{goal_state_words(state)}: " <> Map.get(goals, id, "a step of the plan")

  defp record_words("alert_assessment", payload, _goals),
    do: "Assessment: #{compact(payload["impact"], 300)}"

  defp record_words("input_request", payload, _goals),
    do: "Asked: #{compact(payload["question"], 300)}"

  defp record_words("event_wait", payload, _goals),
    do: "Waiting for: #{compact(payload["verification"], 300)}"

  defp record_words(_kind, _payload, _goals), do: nil

  defp goal_state_words("working"), do: "started"
  defp goal_state_words("completed"), do: "done"
  defp goal_state_words("excluded"), do: "dropped"
  defp goal_state_words("blocked"), do: "blocked"
  defp goal_state_words(state), do: state |> Episodes.Words.label() |> String.downcase()

  defp goal_outcomes(records) do
    for %{kind: "goal", payload: %{"id" => id} = payload} <- records,
        into: %{},
        do: {id, compact(payload["requested_outcome"], 300)}
  end

  defp publication_entry(publication, states) do
    %{
      sort: {DateTime.to_unix(publication.updated_at, :microsecond), 2, 0},
      text:
        "• #{slack_time(publication.updated_at)}  " <>
          publication_words(publication, states[publication.id])
    }
  end

  # Whether the root cause is known matters to an incident; a task never claimed one.
  defp incident_unknowns(%{kind: :incident} = snapshot, findings) do
    for "- " <> line <- material_unknowns(snapshot, findings, []), do: "• " <> line
  end

  defp incident_unknowns(_snapshot, _findings), do: []

  defp material_unknowns(snapshot, findings, coverage) do
    findings =
      if findings == [],
        do: Enum.filter(snapshot.records, &(&1.kind == "finding")),
        else: findings

    coverage =
      if coverage == [],
        do: Enum.filter(snapshot.records, &(&1.kind == "coverage")),
        else: coverage

    unknowns =
      []
      |> maybe_unknown(
        not Enum.any?(findings, &(&1.payload["status"] == "explained")),
        "Root cause is not established by the recorded evidence."
      )
      |> maybe_unknown(
        Enum.any?(findings, &(&1.payload["status"] == "unexplained")),
        "One or more findings remain unexplained."
      )
      |> maybe_unknown(
        Enum.any?(coverage, &(&1.payload["status"] == "unknown")),
        "One or more assessed system layers remain unknown."
      )

    if unknowns == [], do: ["No material unknown is explicitly recorded."], else: unknowns
  end

  # Each step of the plan by what it is meant to achieve, and where it stands; the plan's own ids,
  # stages and repositories are Ryker's bookkeeping.
  defp current_goals(records) do
    states =
      records
      |> Enum.filter(&(&1.kind == "goal_state"))
      |> Map.new(&{&1.payload["goal_id"], &1.payload})

    records
    |> Enum.filter(&(&1.kind == "goal"))
    |> Enum.map(fn goal ->
      state = get_in(states, [goal.payload["id"], "state"]) || "ready"

      "#{TaskCardDetails.goal_glyph(state)} #{compact(goal.payload["requested_outcome"], 500)} · " <>
        goal_state_label(state)
    end)
  end

  defp goal_state_label("ready"), do: "not started"
  defp goal_state_label("working"), do: "in progress"
  defp goal_state_label("blocked"), do: "blocked"
  defp goal_state_label(state), do: state |> Episodes.Words.label() |> String.downcase()

  defp corrective_actions(records) do
    records
    |> Enum.filter(&(&1.kind == "goal"))
    |> Enum.map(fn goal ->
      "- #{text(goal.payload["id"])}: #{compact(goal.payload["requested_outcome"], 700)}"
    end)
  end

  defp latest(records, kind), do: records |> Enum.filter(&(&1.kind == kind)) |> List.last()

  defp progress_line(nil), do: "No update yet."

  defp progress_line(record),
    do: "Latest update: #{compact(String.trim(record.payload["summary"] || ""), 900)}"

  defp wait_line(%Records.Record{kind: "input_request", payload: payload}),
    do: "Waiting for an answer: #{compact(payload["question"], 700)}"

  defp wait_line(%Records.Record{kind: "event_wait", payload: payload}),
    do: "Waiting for: #{compact(payload["verification"], 700)}"

  defp publication_line(nil, _states), do: "No draft PR yet."

  defp publication_line(publication, states),
    do: publication_words(publication, states[publication.id])

  # Only a person merges or closes a pull request on GitHub, and that is the news.
  defp publication_words(
         %Publication.Publication{pull_request_url: url, pull_request_number: number},
         state
       )
       when is_binary(url) and is_integer(number) and state in [:merged, :closed],
       do: "PR <#{url}|##{number}> · #{settled_words(state)}"

  defp publication_words(
         %Publication.Publication{pull_request_url: url, pull_request_number: number} =
           publication,
         _state
       )
       when is_binary(url) and is_integer(number),
       do: "Draft PR <#{url}|##{number}> · #{publication_state(publication.status)}"

  defp publication_words(publication, _state),
    do: "Draft PR · #{publication_state(publication.status)}"

  defp settled_words(:merged), do: "merged"
  defp settled_words(:closed), do: "closed without merging"

  defp publication_state(:published), do: "open"
  defp publication_state(:discarded), do: "discarded"
  defp publication_state(:blocked), do: "stopped"

  defp publication_state(status) when status in [:review_pending, :review_ready],
    do: "being checked"

  defp publication_state(:reviewed), do: "checked, waiting for approval"
  defp publication_state(_status), do: "being published"

  # Slack writes the time in each reader's own time zone; the fallback is UTC.
  defp slack_time(%DateTime{} = at) do
    fallback = Calendar.strftime(at, "%-d %b %H:%M")
    "<!date^#{DateTime.to_unix(at)}^{date_short} {time}|#{fallback} UTC>"
  end

  # The request's state in the words its timeline header uses; which internal
  # owner holds it is not something a reader can act on.

  defp section(_title, [], nil), do: nil
  defp section(title, [], fallback), do: "#{title}:\n#{fallback}"
  defp section(title, lines, _fallback), do: "#{title}:\n#{Enum.join(lines, "\n")}"

  defp maybe_unknown(lines, true, line), do: lines ++ ["- #{line}"]
  defp maybe_unknown(lines, false, _line), do: lines

  defp worker_report(nil),
    do: "Worker's saved response:\nNo retained response is available."

  defp worker_report(output) do
    "Worker's saved response, which is its own report and not a check result:\n#{text(output)}"
  end

  defp kind_available(:task, :postmortem), do: {:error, :work_record_not_available}
  defp kind_available(_work_kind, _record_kind), do: :ok

  # Model and source text is shown as text: unescaped, an observation could
  # mention the whole channel, put a link under any label or add a date token
  # (2026-10-04 review). Only Ryker's own dates and links are markup here.
  defp compact(value, maximum) when is_binary(value),
    do: value |> Blocks.truncate(maximum) |> Blocks.escape()

  defp compact(_value, _maximum), do: "not recorded"

  defp text(value) when is_binary(value), do: Blocks.escape(value)
  defp text(_value), do: ""

  defp compact_message(message), do: Blocks.truncate(message, @maximum_message_characters)
end

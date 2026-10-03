defmodule Ryker.Slack.WorkRecord do
  @moduledoc """
  Bounded, host-rendered views over one task or incident's canonical record.

  These views summarize durable episode events, typed state records, and
  publication custody. They never ask a model to reconstruct history or fill
  missing impact, cause, ownership, or corrective-action facts.
  """

  import Ecto.Query

  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Episodes.Words
  alias Ryker.Publication.Publication
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, TaskCard, TaskCardDetails, WorkTarget}
  alias Ryker.Work.Recovery
  alias Ryker.Work.Turn

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
      snapshot = snapshot(resolved)

      case render(kind, snapshot) do
        nil -> {:error, :work_record_not_available}
        message -> {:ok, %{"message" => compact_message(message)}}
      end
    end
  end

  def build(_work_ref, _target, _kind), do: {:error, :work_record_not_available}

  @doc false
  @spec build_episode(Record.t(), Episode.t(), kind()) :: {:ok, map()} | {:error, term()}
  def build_episode(
        %Record{kind: "task_offer", payload: %{"kind" => offered_kind}, ref: work_ref},
        %Episode{} = episode,
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
      Repo.all(
        from(event in Event,
          where: event.episode_id == ^episode_id,
          order_by: [desc: event.sequence],
          limit: @maximum_events
        )
      )
      |> Enum.reverse()

    records =
      Repo.all(
        from(record in Record,
          where: record.episode_id == ^episode_id,
          order_by: [desc: record.sequence],
          limit: @maximum_records
        )
      )
      |> Enum.reverse()

    publications =
      Repo.all(
        from(publication in Publication,
          where: publication.episode_id == ^episode_id,
          order_by: [desc: publication.inserted_at],
          limit: @maximum_publications
        )
      )
      |> Enum.reverse()

    %{
      episode: resolved.episode,
      events: events,
      kind: resolved.kind,
      publications: publications,
      records: records,
      title: work_title(resolved.work_ref),
      turn: current_turn(resolved.episode),
      work_ref: resolved.work_ref
    }
  end

  # The task or incident by its own title; the card's reference is Ryker's (Andrew, 2026-10-01:
  # "Timeline for task-card:c00814ba-…").
  defp work_title("task-card:" <> _rest = ref) do
    Repo.one(
      from(card in TaskCard,
        join: record in Record,
        on: record.id == card.record_id,
        where: card.ref == ^ref,
        select: fragment("(?::jsonb)->>'title'", record.payload)
      )
    )
  end

  defp work_title("record:task_offer:" <> _rest = ref) do
    Repo.one(
      from(record in Record,
        where: record.ref == ^ref,
        select: fragment("(?::jsonb)->>'title'", record.payload)
      )
    )
  end

  defp work_title("incident-room:" <> _rest = ref),
    do: Repo.one(from(room in IncidentRoom, where: room.ref == ^ref, select: room.title))

  defp work_title(_ref), do: nil

  defp current_turn(%Episode{owner_kind: :turn, owner_ref: turn_ref} = episode),
    do: Repo.get_by(Turn, episode_id: episode.id, turn_ref: turn_ref)

  defp current_turn(episode) do
    Repo.one(
      from(turn in Turn,
        where: turn.episode_id == ^episode.id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
  end

  # A person's account of the task, in Slack's own dates that each reader sees in their time
  # zone. Andrew, 2026-10-01, of what these said before: "overall all this is simply useless in
  # slack for humans to see".
  defp render(:timeline, snapshot) do
    goals = goal_outcomes(snapshot.records)

    entries =
      (Enum.map(snapshot.events, &event_entry/1) ++
         Enum.flat_map(snapshot.records, &record_entry(&1, goals)) ++
         Enum.map(snapshot.publications, &publication_entry/1))
      |> Enum.sort_by(& &1.sort)
      |> Enum.map(& &1.text)

    [
      heading("Timeline", snapshot),
      "Now: #{state_words(snapshot.episode.state)}",
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
          if payload["confidence"], do: " (#{payload["confidence"]} confidence)", else: ""

        "• *#{payload["source_name"]}*#{confidence}: " <> compact(payload["observation"], 900)
      end)

    gaps =
      for %{payload: %{"status" => "unknown"} = payload} <- coverage,
          do: "• Not checked yet: #{payload["layer"]} — #{compact(payload["detail"], 600)}"

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
      "#{state_words(snapshot.episode.state)}. " <> progress_line(progress),
      if(steps != [], do: "Steps:\n" <> Enum.join(steps, "\n")),
      Enum.map(waits, &wait_line/1),
      if(snapshot.kind == :task, do: publication_line(List.last(snapshot.publications))),
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
  defp render(:recovery, %{turn: %Turn{} = turn} = snapshot) do
    case Recovery.workspace_hold(turn) do
      nil ->
        nil

      _held ->
        brief = Recovery.brief(turn)

        [
          "Recovery for #{snapshot.work_ref}",
          brief.headline,
          brief.cause,
          "What you need to do:\n#{brief.next_step}",
          "Workspace: #{brief.workspace}",
          "Reply: #{brief.delivery}",
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
    do: "*#{view}* — #{compact(title, 200)}"

  defp heading(view, %{kind: :incident}), do: "*#{view}* — this incident"
  defp heading(view, _snapshot), do: "*#{view}* — this task"

  # The same words the request's timeline uses for each transition.
  defp event_entry(event) do
    %{
      sort: {DateTime.to_unix(event.occurred_at, :microsecond), 0, event.sequence},
      text: "• #{slack_time(event.occurred_at)}  #{Words.lifecycle_title(event.kind)}"
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
    do: "Evidence: #{payload["source_name"]} — #{compact(payload["observation"], 300)}"

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
  defp goal_state_words(state), do: state |> Words.label() |> String.downcase()

  defp goal_outcomes(records) do
    for %{kind: "goal", payload: %{"id" => id} = payload} <- records,
        into: %{},
        do: {id, compact(payload["requested_outcome"], 300)}
  end

  defp publication_entry(publication) do
    %{
      sort: {DateTime.to_unix(publication.updated_at, :microsecond), 2, 0},
      text: "• #{slack_time(publication.updated_at)}  " <> publication_words(publication)
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
  defp goal_state_label(state), do: state |> Words.label() |> String.downcase()

  defp corrective_actions(records) do
    records
    |> Enum.filter(&(&1.kind == "goal"))
    |> Enum.map(fn goal ->
      "- #{goal.payload["id"]}: #{compact(goal.payload["requested_outcome"], 700)}"
    end)
  end

  defp latest(records, kind), do: records |> Enum.filter(&(&1.kind == kind)) |> List.last()

  defp progress_line(nil), do: "No update yet."

  defp progress_line(record),
    do: "Latest update: #{compact(String.trim(record.payload["summary"] || ""), 900)}"

  defp wait_line(%Record{kind: "input_request", payload: payload}),
    do: "Waiting for an answer: #{compact(payload["question"], 700)}"

  defp wait_line(%Record{kind: "event_wait", payload: payload}),
    do: "Waiting for: #{compact(payload["verification"], 700)}"

  defp publication_line(nil), do: "No draft PR yet."
  defp publication_line(publication), do: publication_words(publication)

  defp publication_words(%Publication{pull_request_url: url, pull_request_number: number} = p)
       when is_binary(url) and is_integer(number),
       do: "Draft PR <#{url}|##{number}> · #{publication_state(p.status)}"

  defp publication_words(publication), do: "Draft PR · #{publication_state(publication.status)}"

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
  defp state_words(state), do: Words.label(state)

  defp section(_title, [], nil), do: nil
  defp section(title, [], fallback), do: "#{title}:\n#{fallback}"
  defp section(title, lines, _fallback), do: "#{title}:\n#{Enum.join(lines, "\n")}"

  defp maybe_unknown(lines, true, line), do: lines ++ ["- #{line}"]
  defp maybe_unknown(lines, false, _line), do: lines

  defp worker_report(nil),
    do: "Worker's saved response:\nNo retained response is available."

  defp worker_report(output),
    do: "Worker's saved response, which is its own report and not a check result:\n#{output}"

  defp kind_available(:task, :postmortem), do: {:error, :work_record_not_available}
  defp kind_available(_work_kind, _record_kind), do: :ok

  defp compact(value, maximum) when is_binary(value) do
    graphemes = String.graphemes(value)

    if length(graphemes) <= maximum,
      do: value,
      else: graphemes |> Enum.take(maximum - 1) |> Enum.join() |> Kernel.<>("…")
  end

  defp compact(_value, _maximum), do: "not recorded"

  defp compact_message(message), do: compact(message, @maximum_message_characters)
end

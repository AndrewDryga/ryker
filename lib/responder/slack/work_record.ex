defmodule Responder.Slack.WorkRecord do
  @moduledoc """
  Bounded, host-rendered views over one task or incident's canonical record.

  These views summarize durable episode events, typed state records, and
  publication custody. They never ask a model to reconstruct history or fill
  missing impact, cause, ownership, or corrective-action facts.
  """

  import Ecto.Query

  alias Responder.ControlPlane.WorkRecovery
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Slack.WorkTarget
  alias Responder.State.Record
  alias Responder.Work.{Custody, Turn}

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
      turn: current_turn(resolved.episode),
      work_ref: resolved.work_ref
    }
  end

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

  defp render(:timeline, snapshot) do
    episode_entries = Enum.map(snapshot.events, &event_entry/1)
    record_entries = Enum.map(snapshot.records, &record_entry/1)
    publication_entries = Enum.map(snapshot.publications, &publication_entry/1)

    entries =
      (episode_entries ++ record_entries ++ publication_entries)
      |> Enum.sort_by(& &1.sort)
      |> Enum.map(& &1.text)

    [
      "Timeline for #{snapshot.work_ref}",
      "Current state: #{snapshot.episode.state}",
      if(entries == [],
        do: "No durable timeline entries are recorded.",
        else: Enum.join(entries, "\n")
      )
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

        "- #{payload["source_name"]} · #{payload["confidence"] || "confidence not recorded"}: " <>
          compact(payload["observation"], 900)
      end)

    coverage_lines =
      Enum.map(coverage, fn record ->
        payload = record.payload
        "- #{payload["layer"]}: #{payload["status"]} — #{compact(payload["detail"], 600)}"
      end)

    [
      "Evidence for #{snapshot.work_ref}",
      section("Source ledger", evidence_lines, "No evidence has been recorded."),
      section("Coverage", coverage_lines, "No bounded coverage assessment has been recorded."),
      section("Material unknowns", material_unknowns(snapshot, findings, coverage), nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render(:handoff, snapshot) do
    progress = latest(snapshot.records, "progress")

    waits =
      Enum.filter(
        snapshot.records,
        &(&1.kind in ["input_request", "event_wait"] and &1.status == :open)
      )

    goals = current_goals(snapshot.records)
    publication = List.last(snapshot.publications)

    [
      "Handoff summary for #{snapshot.work_ref}",
      "State: #{snapshot.episode.state} · owner: #{owner(snapshot.episode)}",
      progress_line(progress),
      section("Open waits", Enum.map(waits, &wait_line/1), "None recorded."),
      section("Goals", goals, "No durable goals are recorded."),
      publication_line(publication),
      section("Material unknowns", material_unknowns(snapshot, [], []), nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # The recovery view exists only while the host is holding a finished worker's
  # working copy or its reply. It is the same brief the recovery page shows, so
  # an operator reading Slack and an operator reading the control plane act on
  # one set of facts, and the worker's own retained answer is attributed to it
  # rather than read as a check result.
  defp render(:recovery, %{turn: %Turn{} = turn} = snapshot) do
    case WorkRecovery.workspace_hold(turn) do
      nil ->
        nil

      _held ->
        brief = WorkRecovery.project(turn, Custody.completed_workspace_recoverable(turn))

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
        else: "Unknown — no alert impact assessment is recorded."

    cause =
      cond do
        assessment && is_binary(assessment.payload["cause"]) ->
          compact(assessment.payload["cause"], 1_200)

        explained ->
          compact(explained.payload["what"], 1_200)

        true ->
          "Unknown — no evidence-backed root cause is recorded."
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
        "Unknown — no durable corrective-action goals are recorded."
      ),
      section("Material unknowns", material_unknowns(snapshot, [], []), nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp event_entry(event) do
    label =
      case event.kind do
        :input_admitted -> "Input admitted"
        :owner_transferred -> "Work owner transferred"
        :input_wait_started -> "Operator input requested"
        :event_wait_started -> "Verification wait started"
        :wait_resumed -> "Wait resumed"
        :result_accepted -> "Result accepted"
        :delivery_confirmed -> "Delivery confirmed"
        :episode_cancelled -> "Episode closed"
      end

    %{
      sort: {DateTime.to_unix(event.occurred_at, :microsecond), 0, event.sequence},
      text: "- #{timestamp(event.occurred_at)} · #{label}"
    }
  end

  defp record_entry(record) do
    detail = record_detail(record.kind, record.payload)

    label = record.kind |> String.replace("_", " ") |> String.capitalize()
    suffix = if detail, do: " · #{detail}", else: ""

    %{
      sort: {DateTime.to_unix(record.inserted_at, :microsecond), 1, record.sequence},
      text: "- #{timestamp(record.inserted_at)} · #{label} recorded#{suffix}"
    }
  end

  defp record_detail("evidence", payload),
    do: "#{payload["source_name"]}: #{compact(payload["observation"], 300)}"

  defp record_detail("progress", payload), do: compact(payload["summary"], 300)
  defp record_detail("finding", payload), do: compact(payload["what"], 300)
  defp record_detail("goal", payload), do: compact(payload["requested_outcome"], 300)
  defp record_detail("goal_state", payload), do: "#{payload["goal_id"]} → #{payload["state"]}"

  defp record_detail("alert_assessment", payload),
    do: "#{payload["verdict"]}: #{compact(payload["impact"], 300)}"

  defp record_detail("input_request", payload), do: compact(payload["question"], 300)
  defp record_detail("event_wait", payload), do: compact(payload["verification"], 300)
  defp record_detail(_kind, _payload), do: nil

  defp publication_entry(publication) do
    detail =
      if publication.pull_request_url,
        do: " · #{publication.pull_request_url}",
        else: ""

    %{
      sort: {DateTime.to_unix(publication.updated_at, :microsecond), 2, 0},
      text: "- #{timestamp(publication.updated_at)} · Publication #{publication.status}#{detail}"
    }
  end

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

  defp current_goals(records) do
    states =
      records
      |> Enum.filter(&(&1.kind == "goal_state"))
      |> Map.new(&{&1.payload["goal_id"], &1.payload})

    records
    |> Enum.filter(&(&1.kind == "goal"))
    |> Enum.map(fn goal ->
      state = get_in(states, [goal.payload["id"], "state"]) || "ready"

      relationships =
        [
          optional_goal_relation("stage", goal.payload["stage"]),
          optional_goal_relation("retries", goal.payload["successor_of"]),
          optional_goal_relation("parent", goal.payload["parent_goal_id"]),
          optional_goal_relation(
            "after",
            joined_goal_refs(goal.payload["prerequisite_goal_ids"])
          ),
          optional_goal_relation("writes", goal.payload["writable_repository"]),
          optional_goal_relation(
            "reads",
            joined_goal_refs(goal.payload["read_only_repositories"])
          )
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      suffix = if relationships == "", do: "", else: " (#{relationships})"

      "- #{goal.payload["id"]} · #{state}: #{compact(goal.payload["requested_outcome"], 500)}#{suffix}"
    end)
  end

  defp joined_goal_refs(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp joined_goal_refs(_values), do: nil

  defp optional_goal_relation(_label, nil), do: nil
  defp optional_goal_relation(label, value), do: "#{label} #{value}"

  defp corrective_actions(records) do
    records
    |> Enum.filter(&(&1.kind == "goal"))
    |> Enum.map(fn goal ->
      "- #{goal.payload["id"]}: #{compact(goal.payload["requested_outcome"], 700)}"
    end)
  end

  defp latest(records, kind), do: records |> Enum.filter(&(&1.kind == kind)) |> List.last()

  defp progress_line(nil), do: "Latest progress: none recorded."

  defp progress_line(record),
    do: "Latest progress: #{record.payload["phase"]} — #{compact(record.payload["summary"], 900)}"

  defp wait_line(%Record{kind: "input_request", payload: payload}),
    do: "- Input: #{compact(payload["question"], 700)}"

  defp wait_line(%Record{kind: "event_wait", payload: payload}),
    do: "- Event: #{compact(payload["verification"], 700)} by #{payload["deadline_at"]}"

  defp publication_line(nil), do: "Publication: none recorded."

  defp publication_line(publication),
    do:
      "Publication: #{publication.status}#{if publication.pull_request_url, do: " · #{publication.pull_request_url}", else: ""}"

  defp owner(%{owner_kind: nil}), do: "none"
  defp owner(episode), do: "#{episode.owner_kind}:#{episode.owner_ref}"

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

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp compact(value, maximum) when is_binary(value) do
    graphemes = String.graphemes(value)

    if length(graphemes) <= maximum,
      do: value,
      else: graphemes |> Enum.take(maximum - 1) |> Enum.join() |> Kernel.<>("…")
  end

  defp compact(_value, _maximum), do: "not recorded"

  defp compact_message(message), do: compact(message, @maximum_message_characters)
end

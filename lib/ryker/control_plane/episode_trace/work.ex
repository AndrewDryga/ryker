defmodule Ryker.ControlPlane.EpisodeTrace.Work do
  @moduledoc """
  "The work" and "The answer": each Work turn from queueing through the
  provider finishing, every validation verdict, the accepted result and its
  delivery, the state records the model wrote, the worker's own events and the
  Slack status updates that accompanied them.
  """
  import Ryker.ControlPlane.EpisodeTrace.Step
  alias Ryker.CoopFleet
  alias Ryker.Delivery
  alias Ryker.InspectionRedactor
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Text
  alias Ryker.UTCDateTime
  alias Ryker.Wording
  alias Ryker.Work

  @doc "Each Work turn from queueing through its result and delivery."
  def turn_steps(turns, sessions) do
    sessions_by_id = Map.new(sessions, &{&1.id, &1})

    turns
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {turn, ordinal} ->
      session = Map.get(sessions_by_id, turn.session_id)

      prepared =
        step(
          "turn-#{turn.id}-prepared",
          :ready,
          turn.inserted_at,
          %{
            actor: "Ryker",
            owner: {:turn, turn.id},
            details:
              compact_details([
                {"Execution policy", session && session.policy},
                {"Repository", session && session.repository_ref}
              ]),
            stage: "Routing",
            state: "",
            summary: "The new input was queued for model work.",
            title: "Run #{ordinal} queued",
            tone: nil
          }
        )

      work = work_step(turn, ordinal)
      answer = answer_steps(turn, ordinal)
      outcome = delivery_step(turn)

      ([prepared, work] ++ answer ++ outcome)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp work_step(%Work.Turn{remote_finished_at: nil, accepted_at: nil}, _ordinal), do: nil

  # The request card says the model, tokens, cost and how long a run took, so a finished run is a
  # step of its own only when its timing or usage was not reported (Andrew, 2026-10-01, of
  # "Run 1 finished · Details · Work claims 8": "how this card is helpful?").
  defp work_step(turn, ordinal) do
    case measurement_issue(turn) do
      nil ->
        nil

      issue ->
        step(
          "turn-#{turn.id}-work",
          :work,
          turn.remote_finished_at || turn.accepted_at || turn.remote_started_at,
          %{
            actor: "Coop",
            owner: {:turn, turn.id},
            details: [],
            duration_ms: turn.usage_provider_ms,
            stage: "Execution",
            state: "finished",
            summary: issue,
            title: "Run #{ordinal} finished",
            tone: :warn
          }
        )
    end
  end

  defp answer_steps(turn, ordinal) do
    validations = validation_steps(turn)
    accepted = accepted_step(turn, ordinal)
    validations ++ Enum.reject([accepted], &is_nil/1)
  end

  defp validation_steps(%Work.Turn{validation_history: history} = turn)
       when is_list(history) and history != [] do
    Enum.map(history, &validation_history_step(turn, &1))
  end

  defp validation_steps(%Work.Turn{validation_intent: nil, candidate_attempt: nil}), do: []
  defp validation_steps(turn), do: [validation_step(turn)]

  defp validation_band(nil, _at), do: :work
  defp validation_band(_finished_at, nil), do: :answer

  defp validation_band(finished_at, at),
    do: if(DateTime.compare(at, finished_at) == :lt, do: :work, else: :answer)

  defp validation_history_step(turn, entry) do
    validation_step(turn, %{
      at: parsed_time(entry["recorded_at"]),
      attempt: entry["candidate_attempt"],
      verdict: entry["verdict"],
      violations: bounded_strings(entry["violations"])
    })
  end

  defp validation_step(turn) do
    intent = turn.validation_intent || %{}

    validation_step(turn, %{
      at: nil,
      attempt: turn.candidate_attempt,
      verdict: intent["verdict"],
      violations: bounded_strings(intent["violations"])
    })
  end

  defp validation_step(turn, %{at: at, attempt: attempt, verdict: verdict, violations: violations}) do
    {title, tone} = validation_presentation(verdict)

    step(
      "turn-#{turn.id}-validation-#{attempt || 0}",
      validation_band(turn.remote_finished_at, at),
      at,
      %{
        actor: "Ryker",
        owner: {:turn, turn.id},
        details: validation_details(violations),
        stage: "Validation",
        state: verdict || "candidate recorded",
        summary: validation_summary(verdict, violations, attempt),
        title: title,
        tone: tone
      }
    )
  end

  # A sent-back answer is Ryker's routine check working, not a failure (Andrew, 2026-10-01, of
  # "Answer rejected": "is it a failure? is it a bug?").
  defp validation_presentation("reject"), do: {"Sent back to fix", nil}
  defp validation_presentation("accept"), do: {"Answer validated", :good}
  defp validation_presentation(_), do: {"Response recorded", nil}

  defp accepted_step(%Work.Turn{accepted_at: nil}, _ordinal), do: nil

  defp accepted_step(turn, ordinal) do
    step(
      "turn-#{turn.id}-accepted",
      :answer,
      turn.accepted_at,
      %{
        actor: "Ryker",
        owner: {:turn, turn.id},
        result_ref: turn.result_ref,
        details:
          compact_details([
            {"Result", turn.result_ref, identifier: true},
            {"Delivery", delivery_kind(turn.delivery_document)},
            {"Artifacts", outcome_count(turn.delivery_document, "artifact_refs")},
            {"Records", outcome_count(turn.delivery_document, "record_refs")},
            {"Outcome", get_in(turn.delivery_document || %{}, ["outcome", "state"])}
          ]),
        stage: "Result",
        state: "accepted",
        summary: delivery_summary(turn.delivery_document),
        title: "Run #{ordinal} answer accepted",
        tone: :good
      }
    )
  end

  defp delivery_step(%Work.Turn{delivery_ref: nil, delivered_at: nil, external_receipt: nil}),
    do: []

  defp delivery_step(turn) do
    queued =
      step(
        "turn-#{turn.id}-delivery-queued",
        :outcome,
        turn.accepted_at,
        %{
          actor: "Ryker",
          owner: {:turn, turn.id},
          delivery_ref: turn.delivery_ref,
          details: [],
          stage: "Delivery",
          state: "queued",
          summary: "The accepted response was queued for delivery.",
          title: "Response queued for delivery",
          tone: nil
        }
      )

    [queued | confirmed_delivery_step(turn)]
  end

  defp confirmed_delivery_step(%Work.Turn{delivered_at: nil}), do: []

  defp confirmed_delivery_step(turn) do
    [
      step(
        "turn-#{turn.id}-delivery-confirmed",
        :outcome,
        turn.delivered_at,
        %{
          actor: delivery_actor(turn.external_receipt),
          owner: {:turn, turn.id},
          delivery_ref: turn.delivery_ref,
          details:
            compact_details([
              {"Delivery", turn.delivery_ref, identifier: true},
              {"Transport", get_in(turn.external_receipt || %{}, ["transport"])},
              {"Message", get_in(turn.external_receipt || %{}, ["message_ref"]), identifier: true}
            ]),
          stage: "Delivery",
          state: "delivered",
          summary: delivery_confirmation(turn.external_receipt),
          title: "Delivery confirmed",
          tone: :good
        }
      )
    ]
  end

  @doc """
  One step per state record the model wrote, with its card when it has one,
  except the plan: every goal and goal update is one Work plan card. A piece
  of evidence carries the row its Observations card shows (`observations/1`).
  """
  def record_steps(records) do
    anchors = record_anchors(records)
    {goals, others} = Enum.split_with(records, &(&1.kind in ~w(goal goal_state)))

    plan_steps(goals, anchors) ++
      (others
       |> Enum.with_index(1)
       |> Enum.map(fn {record, index} -> record_step(record, index, anchors) end))
  end

  defp record_step(record, index, anchors) do
    card =
      case Delivery.ChatCard.project(%{
             record
             | status: :open,
               updated_at: record.inserted_at,
               wait_error: nil
           }) do
        {:ok, projected} -> projected
        none when none in [:none, :ignore] -> nil
      end

    # Creating an offer or a question is model work; only a delivery receipt
    # proves one was sent, so every record sits in the work chapter, with the
    # turn that saved it rather than the message read last before it.
    step(
      "record-#{record.id || index}",
      :work,
      record.inserted_at,
      %{
        actor: "Ryker state",
        owner: record_owner(record),
        record_ref: record.ref,
        details: compact_details(record_details(record, card)),
        href: nil,
        stage: record_stage(record.kind),
        state: "",
        summary: record_summary(record, card),
        title: record_title(record, card),
        current_warning: Delivery.ChatCard.wait_warning(record),
        observation: observation(record, anchors),
        wait: wait_details(record),
        tone: nil
      }
    )
  end

  defp wait_details(%Records.Record{kind: "event_wait"} = record) do
    with {:ok, %{payload: payload}} <-
           Records.RecordPayload.prepare(record.kind, record.payload, record.ref),
         %{state: :retained, truncated: false, text: text} <- InspectionRedactor.artifact(payload),
         {:ok, sanitized} <- Jason.decode(text) do
      matcher = sanitized["event_matcher"]

      timing =
        [
          {"Check again", wait_time(matcher["poll_after"] || matcher["at"])},
          {"Delay", matcher["delay"]},
          {"If time runs out", matcher["on_timeout"]}
        ]
        |> Enum.filter(fn {_label, value} -> is_binary(value) or is_number(value) end)

      %{
        verification: sanitized["verification"],
        trigger: wait_trigger(matcher),
        deadline: wait_time(sanitized["deadline_at"]),
        conditions: wait_conditions(matcher["match"], [], matcher["source_kind"]),
        timing: compact_details(timing),
        record: text
      }
    else
      _unavailable -> nil
    end
  end

  defp wait_details(_record), do: nil

  defp wait_trigger(%{"type" => "source_event", "source_kind" => kind}) when is_binary(kind),
    do: capitalize(kind) <> " event"

  defp wait_trigger(%{"type" => "source_event"}), do: "Matching source event"
  defp wait_trigger(%{"type" => type}) when type in ["after", "at"], do: "Scheduled time"
  defp wait_trigger(_matcher), do: "Recorded event condition"

  defp wait_conditions(value, [_ | _] = path, source) when is_map(value) and map_size(value) == 0,
    do: [wait_condition(value, path, source)]

  defp wait_conditions(value, path, source) when is_map(value) do
    # Block Kit explicitly distinguishes literal text from mrkdwn. Keep the
    # parent object's choice while walking down to its nested text field.
    source = if value["type"] == "plain_text", do: nil, else: source

    value
    |> Enum.sort()
    |> Enum.flat_map(fn {key, nested} -> wait_conditions(nested, path ++ [key], source) end)
  end

  defp wait_conditions([_ | _] = value, path, source) do
    if Enum.all?(value, &is_map/1) do
      value
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {nested, index} ->
        wait_conditions(nested, path ++ ["match #{index}"], source)
      end)
    else
      [wait_condition(value, path, source)]
    end
  end

  defp wait_conditions(nil, [], _source), do: []
  defp wait_conditions(value, path, source), do: [wait_condition(value, path, source)]

  defp wait_condition(value, path, source) do
    label = Enum.map_join(path, " · ", &capitalize(human(&1)))

    %{
      label: label,
      value: wait_value(value, List.last(path)),
      href: wait_url(value),
      markdown?: source == "slack" and is_binary(value) and List.last(path) in ~w(text pretext)
    }
  end

  defp wait_value(nil, _field), do: "No value (null)"
  defp wait_value([], _field), do: "Empty list"
  defp wait_value(value, _field) when is_map(value), do: "Any object"
  defp wait_value(value, _field) when is_list(value), do: "Exactly " <> Jason.encode!(value)

  defp wait_value(value, field) when field in ["bot_id", "app_id", "user"] and is_binary(value),
    do: Slack.Names.name(Slack.Names.workspace(), value)

  defp wait_value(value, _field), do: to_string(value)

  defp wait_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["https", "http"] and is_binary(host) ->
        value

      _not_url ->
        nil
    end
  end

  defp wait_url(_value), do: nil

  defp wait_time(nil), do: nil

  defp wait_time(value) do
    case UTCDateTime.parse(value) do
      {:ok, at} -> UTCDateTime.readable(at)
      _invalid -> nil
    end
  end

  defp record_owner(%Records.Record{turn_id: turn_id}) when is_binary(turn_id),
    do: {:turn, turn_id}

  defp record_owner(_record), do: :episode

  # Where each record's ref is read on the timeline, and the words a link to
  # it shows: a goal and its updates at the goal's step, evidence at its row.
  defp record_anchors(records) do
    goal_rows =
      for %Records.Record{kind: "goal", subject_ref: goal_id} = goal <- records,
          into: %{},
          do: {goal_id, goal}

    Enum.reduce(records, %{}, fn
      %Records.Record{ref: ref} = record, anchors when is_binary(ref) ->
        case anchor(record, goal_rows) do
          nil -> anchors
          anchor -> Map.put(anchors, ref, anchor)
        end

      _record, anchors ->
        anchors
    end)
  end

  defp anchor(%Records.Record{kind: "evidence", id: id, payload: payload}, _goals),
    do: %{href: "#event-record-#{id}", title: observation_area(payload)}

  defp anchor(%Records.Record{kind: "goal", id: id, payload: payload}, _goals),
    do: %{href: "#event-record-#{id}", title: payload["requested_outcome"]}

  defp anchor(%Records.Record{kind: "goal_state", subject_ref: goal_id}, goals) do
    case goals[goal_id] do
      %Records.Record{} = goal -> anchor(goal, goals)
      nil -> nil
    end
  end

  defp anchor(_record, _goals), do: nil

  @doc """
  Adjacent evidence from one turn as one Observations card: a compact row per
  record, in the order they were written, instead of a framed card each
  (Andrew approved the card, 2026-10-15). Evidence with other work between it,
  or from another turn, starts a card of its own, so nothing reads as a
  summary of work it was not part of. Each row keeps its record's anchor.
  """
  def observations(steps) do
    steps
    |> Enum.chunk_by(fn
      %{stage: "Evidence", observation: %{}, owner: owner} -> {:evidence, owner}
      step -> {:step, step.id}
    end)
    |> Enum.flat_map(fn
      [%{stage: "Evidence", observation: %{}} | _] = run -> [observations_step(run)]
      run -> run
    end)
  end

  defp observations_step([first | _] = run) do
    step(
      "observations-" <> String.replace_prefix(first.id, "record-", ""),
      first.band,
      first.at,
      %{
        actor: "Ryker state",
        owner: first.owner,
        details: [],
        stage: "Observations",
        state: "",
        summary: nil,
        title: "Observations",
        observations: Enum.map(run, & &1.observation),
        tone: nil
      }
    )
  end

  # What a piece of evidence is about, what was observed, where it came from
  # and when it was measured, and any limit on what it covers. `observed_at` is
  # the measurement; the record's own time is only when it was written down,
  # so a missing measurement stays missing. A health effect is shown only
  # when it names a problem or says it is unknown: "none" proves no health.
  defp observation(%Records.Record{kind: "evidence", payload: payload} = record, anchors) do
    area = observation_area(payload)

    %{
      id: "record-#{record.id}",
      record_ref: record.ref,
      area: area,
      text: payload["observation"],
      source: observation_source(payload["source_name"]),
      source_name: payload["source_name"],
      measured_at: observed_at(payload["observed_at"]),
      freshness: payload["freshness"],
      scope_note: payload["scope_note"],
      effect: health_effect(payload["health_effect"]),
      contradicts: payload["relation"] == "contradicts",
      replaces:
        Enum.map(payload["supersedes"] || [], fn ref ->
          Map.get(anchors, ref, %{href: nil, title: ref})
        end),
      details:
        compact_details(
          [
            {"Claim", if(payload["claim"] != area, do: payload["claim"])},
            {"Measured", payload["observed_at"] || "Not recorded"},
            {"Recorded", record.inserted_at},
            {"Source type", payload["source_type"] && human(payload["source_type"])},
            {"Confidence", payload["confidence"]},
            {"Health effect", payload["health_effect"]},
            {"Relation", payload["relation"]}
          ] ++
            measurements(payload["dimensions"]) ++
            [
              {"Source reference", payload["source_id"], identifier: true},
              {"Claim ID", payload["claim_id"], identifier: true},
              {"Record", record.ref, identifier: true},
              {"Operation", record.operation_id, identifier: true}
            ]
        )
    }
  end

  defp observation(_record, _anchors), do: nil

  defp observation_source("slack-source:v1:" <> _reference), do: "Slack source"
  defp observation_source("admit_input:" <> _reference), do: "Incoming message"
  defp observation_source(name), do: name

  defp observation_area(payload),
    do: payload["target"] || payload["claim"] || payload["source_name"] || "Observation"

  defp observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp observed_at(_value), do: nil

  defp health_effect("unhealthy"), do: {:bad, "Unhealthy"}
  defp health_effect("degraded"), do: {:warn, "Degraded"}
  defp health_effect("risk"), do: {:warn, "Risk"}
  defp health_effect("unknown"), do: {nil, "Unknown"}
  defp health_effect(_none), do: nil

  defp measurements(%{} = dimensions) do
    dimensions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, value} -> {"Measured " <> human(name), value} end)
  end

  defp measurements(_dimensions), do: []

  # The request's goals as one Work plan card where the first was planned:
  # each goal's latest attempt is a step with its status, what finishes it
  # and, once done, its recorded result and evidence. Authority, kind,
  # record IDs, earlier attempts and every state change stay under Details
  # and history (Andrew approved the card, 2026-10-15: Read only stays out of
  # the face). Successful plan and update calls fold into it (`SavedRecords`).
  defp plan_steps([], _anchors), do: []

  defp plan_steps(records, anchors) do
    goals = for %Records.Record{kind: "goal"} = record <- records, do: record

    states =
      records
      |> Enum.filter(&(&1.kind == "goal_state"))
      |> Enum.group_by(& &1.subject_ref)

    successors =
      for %Records.Record{subject_ref: id, payload: %{"successor_of" => predecessor}} <- goals,
          is_binary(predecessor),
          into: %{},
          do: {predecessor, id}

    by_id = Map.new(goals, &{&1.subject_ref, &1})

    planned =
      Enum.map(goals, fn goal ->
        plan_goal(goal, Map.get(states, goal.subject_ref, []), by_id, successors, anchors)
      end)

    # A goal whose plan record this page does not hold still shows its updates.
    unplanned =
      for {goal_id, updates} <- states, not Map.has_key?(by_id, goal_id) do
        unplanned_goal(goal_id, updates, anchors)
      end

    first = List.first(goals) || List.first(records)

    [
      step("plan-#{first.id}", :work, first.inserted_at, %{
        actor: "Ryker state",
        owner: record_owner(first),
        details: [],
        stage: "Work plan",
        state: "",
        summary: nil,
        title: "Work plan",
        plan: %{
          steps: current_steps(planned ++ unplanned, by_id),
          history: planned ++ unplanned
        },
        tone: nil
      })
    ]
  end

  defp plan_goal(%Records.Record{payload: payload} = goal, updates, by_id, successors, anchors) do
    latest = List.last(updates)
    state = (latest && latest.payload["state"]) || "ready"
    {status, tone} = goal_status(state)

    %{
      id: "record-#{goal.id}",
      record_ref: goal.ref,
      goal_id: goal.subject_ref,
      title: payload["requested_outcome"],
      state: state,
      status: status,
      tone: tone,
      optional: payload["required"] == false,
      contract: payload["completion_contract"],
      detail: latest && latest.payload["detail"],
      evidence: goal_evidence(latest, anchors),
      parent: payload["parent_goal_id"],
      attempt: attempt(goal.subject_ref, by_id),
      replaced: Map.has_key?(successors, goal.subject_ref),
      facts:
        compact_details([
          {"Done when", payload["completion_contract"]},
          {"Kind", payload["kind"] && human(payload["kind"])},
          {"Mode", payload["authority"] && human(payload["authority"])},
          {"Membership", if(payload["required"] == false, do: "Optional", else: "Required")},
          {"Stage", payload["stage"] && human(payload["stage"])},
          {"Changes", payload["writable_repository"]},
          {"Reads", read_only(payload["read_only_repositories"])},
          {"Part of", goal_name(payload["parent_goal_id"], by_id)},
          {"After", goal_names(payload["prerequisite_goal_ids"], by_id)},
          {"Repeats", goal_name(payload["successor_of"], by_id)},
          {"Repeated by", goal_name(successors[goal.subject_ref], by_id)},
          {"Planned", goal.inserted_at},
          {"Goal ID", goal.subject_ref, identifier: true},
          {"Record", goal.ref, identifier: true},
          {"Operation", goal.operation_id, identifier: true}
        ]),
      changes: Enum.map(updates, &goal_change(&1, anchors))
    }
  end

  defp unplanned_goal(goal_id, updates, anchors) do
    latest = List.last(updates)
    {status, tone} = goal_status(latest.payload["state"])

    %{
      id: "record-#{latest.id}",
      record_ref: nil,
      goal_id: goal_id,
      title: goal_id,
      state: latest.payload["state"],
      status: status,
      tone: tone,
      optional: false,
      contract: nil,
      detail: latest.payload["detail"],
      evidence: goal_evidence(latest, anchors),
      parent: nil,
      attempt: 1,
      replaced: false,
      facts:
        compact_details([
          {"Plan", "Its plan record is not on this page."},
          {"Goal ID", goal_id, identifier: true}
        ]),
      changes: Enum.map(updates, &goal_change(&1, anchors))
    }
  end

  # The steps the card shows: each goal's latest attempt, where its first
  # attempt was planned, and a subgoal under the goal it belongs to. A goal
  # another attempt replaced stays in the history, so it never counts as the
  # work's result.
  defp current_steps(goals, by_id) do
    order = goals |> Enum.with_index() |> Map.new(fn {goal, index} -> {goal.goal_id, index} end)

    current =
      goals
      |> Enum.reject(& &1.replaced)
      |> Enum.sort_by(&Map.get(order, root(&1.goal_id, by_id), 0))

    ids = MapSet.new(current, & &1.goal_id)
    children = Enum.group_by(current, &if(&1.parent in ids, do: &1.parent))

    children
    |> Map.get(nil, [])
    |> Enum.flat_map(&with_children(&1, children, 0))
  end

  defp with_children(goal, children, depth) do
    [
      Map.put(goal, :depth, depth)
      | Enum.flat_map(
          Map.get(children, goal.goal_id, []),
          &with_children(&1, children, depth + 1)
        )
    ]
  end

  # The first attempt a repeated goal goes back to.
  defp root(goal_id, by_id) do
    case by_id[goal_id] do
      %Records.Record{payload: %{"successor_of" => predecessor}} when is_binary(predecessor) ->
        root(predecessor, by_id)

      _first ->
        goal_id
    end
  end

  defp attempt(goal_id, by_id) do
    case by_id[goal_id] do
      %Records.Record{payload: %{"successor_of" => predecessor}} when is_binary(predecessor) ->
        attempt(predecessor, by_id) + 1

      _first ->
        1
    end
  end

  defp goal_change(%Records.Record{payload: payload} = update, anchors) do
    {status, tone} = goal_status(payload["state"])

    %{
      id: "record-#{update.id}",
      record_ref: update.ref,
      at: update.inserted_at,
      status: status,
      tone: tone,
      detail: payload["detail"],
      evidence: goal_evidence(update, anchors),
      facts:
        compact_details([
          {"Record", update.ref, identifier: true},
          {"Operation", update.operation_id, identifier: true}
        ])
    }
  end

  defp goal_evidence(nil, _anchors), do: []

  defp goal_evidence(%Records.Record{payload: payload}, anchors) do
    Enum.map(payload["evidence_refs"] || [], fn ref ->
      Map.get(anchors, ref, %{href: nil, title: ref})
    end)
  end

  # The words a status is read in, as text with its tone: a skipped or
  # cancelled goal is never shown as done.
  defp goal_status("ready"), do: {"Not started", nil}
  defp goal_status("working"), do: {"In progress", :busy}
  defp goal_status("waiting"), do: {"Waiting", :warn}
  defp goal_status("blocked"), do: {"Blocked", :bad}
  defp goal_status("completed"), do: {"Done", :on}
  defp goal_status("excluded"), do: {"Skipped", nil}
  defp goal_status("cancelled"), do: {"Cancelled", nil}
  defp goal_status(other), do: {capitalize(human(other)), nil}

  defp goal_name(nil, _by_id), do: nil

  defp goal_name(goal_id, by_id) do
    case by_id[goal_id] do
      %Records.Record{payload: %{"requested_outcome" => outcome}} -> outcome
      _missing -> goal_id
    end
  end

  defp goal_names(ids, by_id) when is_list(ids) and ids != [],
    do: Enum.map_join(ids, ", ", &goal_name(&1, by_id))

  defp goal_names(_ids, _by_id), do: nil

  defp read_only(names) when is_list(names) and names != [], do: Wording.list(names)
  defp read_only(_names), do: nil

  @doc "The worker fleet's own events for the episode's sessions."
  def coop_steps([]), do: []

  def coop_steps(sessions) do
    session_ids = Enum.map(sessions, & &1.id)

    session_ids
    |> CoopFleet.Event.Query.by_session_ids()
    |> CoopFleet.Event.Query.excluding_kind("session_event")
    |> CoopFleet.Event.Query.ordered_by_inserted_at_and_sequence()
    |> CoopFleet.Event.Query.limit_to(500)
    |> Repo.all()
    |> Enum.map(fn event ->
      step(
        "coop-event-#{event.id}",
        coop_band(event.kind),
        event.inserted_at,
        %{
          actor: "Coop fleet",
          details:
            compact_details([
              {"Worker", event.worker_id, identifier: true},
              {"Placement generation", event.placement_generation},
              {"Sequence", event.sequence}
            ]),
          stage: "Worker",
          state: event.kind,
          summary: coop_summary(event.payload),
          title: coop_title(event.kind),
          tone: coop_tone(event.kind)
        }
      )
    end)
  end

  @doc "Every Slack working-status update sent for the episode, and any that failed."
  def slack_status_steps(episode_id) do
    Enum.map(Slack.ThreadStatusReceipts.for_episode(episode_id), fn receipt ->
      clear = receipt.text == ""

      band = status_band(receipt)

      step("slack-status-#{receipt.id}", band, receipt.acknowledged_at || receipt.inserted_at, %{
        actor: "Slack",
        stage: "Status",
        state: if(receipt.error, do: "failed", else: ""),
        title: status_title(receipt),
        summary: receipt.error || if(clear, do: nil, else: receipt.text),
        details: [],
        tone: if(receipt.error, do: :warn)
      })
    end)
  end

  defp status_band(%{text: ""}), do: :outcome

  defp status_band(%{phase: phase}) when phase in ~w(queued admitting admission_retry),
    do: :routing

  defp status_band(_), do: :work
  defp status_title(%{error: error}) when is_binary(error), do: "Slack status update failed"
  defp status_title(%{text: ""}), do: "Slack working status cleared"
  defp status_title(_), do: "Slack working status set"

  defp record_stage("evidence"), do: "Evidence"
  defp record_stage("coverage"), do: "Coverage"
  defp record_stage("progress"), do: "Progress"
  defp record_stage("input_request"), do: "Wait"
  defp record_stage("event_wait"), do: "Wait"
  defp record_stage(_kind), do: "State record"

  defp record_title(%Records.Record{kind: "progress"}, %{title: title}), do: "Progress · #{title}"
  defp record_title(%Records.Record{kind: "input_request"}, _card), do: "Question prepared"
  defp record_title(%Records.Record{kind: "event_wait"}, _card), do: "Wait prepared"

  defp record_title(%Records.Record{kind: "evidence"}, %{title: title}),
    do: "Evidence recorded · #{title}"

  defp record_title(_record, %{label: label, title: title}) when is_binary(title),
    do: "#{label} · #{title}"

  defp record_title(record, _card), do: capitalize(human(record.kind)) <> " recorded"

  defp record_summary(%Records.Record{kind: "input_request", payload: payload}, _card),
    do: payload["reason"] || "The model prepared a question for the reply."

  # A finding's reason is what makes it one, so it reads on the card with its
  # conclusion instead of folded into Details; since its call's own card went
  # (`SavedRecords`), this card is the finding's only one.
  defp record_summary(%Records.Record{kind: "finding"}, %{summary: what} = card)
       when is_binary(what) do
    case List.keyfind(card.details, "Why", 0) do
      {"Why", why} when is_binary(why) and why != "" -> what <> "\n\n" <> why
      _no_reason -> what
    end
  end

  defp record_summary(_record, %{summary: summary}) when is_binary(summary), do: summary
  defp record_summary(%Records.Record{subject_ref: value}, _card) when is_binary(value), do: value
  defp record_summary(%Records.Record{operation_id: value}, _card), do: value

  defp record_details(record, nil),
    do: [
      {"Record", record.ref, identifier: true},
      {"Operation", record.operation_id, identifier: true}
    ]

  defp record_details(record, card) do
    [
      {"Record", record.ref, identifier: true},
      {"Operation", record.operation_id, identifier: true}
    ] ++
      cited_source(record) ++
      shown_details(record, Map.get(card, :details, []))
  end

  defp shown_details(%Records.Record{kind: "finding"}, details),
    do: List.keydelete(details, "Why", 0)

  defp shown_details(_record, details), do: details

  # A citation names its source by the reference a tool issued. The Chat card
  # leaves that out, since nobody can read or open it there; tracing it is what
  # the timeline is for.
  defp cited_source(%Records.Record{kind: "evidence", payload: %{"source_id" => source}})
       when is_binary(source),
       do: [{"Source reference", source, identifier: true}]

  defp cited_source(_record), do: []

  defp coop_band(kind) when kind in ["turn", "candidate", "validation"], do: :work
  defp coop_band(_kind), do: :ready
  # What the worker reported, named for what it is to the reader: its run of
  # the model, the answer it returned, the working copy it kept.
  defp coop_title("operation"), do: "Worker finished an operation"
  defp coop_title("session"), do: "Worker session update"
  defp coop_title("turn"), do: "Worker run update"
  defp coop_title("candidate"), do: "Worker returned an answer"
  defp coop_title("validation"), do: "Worker checked the answer"
  defp coop_title("workspace"), do: "Working copy update"
  defp coop_title("checkpoint"), do: "Working copy saved"
  defp coop_title("capacity"), do: "Worker capacity update"
  defp coop_title(_kind), do: "Worker update"
  defp coop_summary(%{"state" => state}), do: "Worker reported #{human(state)}."
  defp coop_summary(_payload), do: "The worker sent an update about this request."
  defp coop_tone(kind) when kind in ["candidate", "validation"], do: :good
  defp coop_tone(_kind), do: nil

  defp measurement_issue(%Work.Turn{measurement_error_code: code})
       when is_binary(code) and code != "",
       do: "Measurement failed: #{human(code)}."

  defp measurement_issue(%Work.Turn{timing_recorded: false, usage_recorded: false}),
    do: "Timing and usage were not reported."

  defp measurement_issue(%Work.Turn{timing_recorded: false}), do: "Timing was not reported."
  defp measurement_issue(%Work.Turn{usage_recorded: false}), do: "Usage was not reported."
  defp measurement_issue(_turn), do: nil

  # The exact correction sent to the model is for inspection, under Details;
  # the step says why in a sentence (QA re-test, 2026-09-26: the step quoted
  # "Call validate_final with this exact candidate…"). The response's shape
  # and size are the raw response's own line (Andrew, 2026-09-27: "details not
  # needed the duplicate whats already shown above nicely").
  defp validation_details(violations) do
    compact_details([
      {"What Ryker told the model", if(violations != [], do: Enum.join(violations, " "))}
    ])
  end

  # What was sent back and why, in a person's words; the exact correction the model got stays
  # under Details.
  defp validation_summary("reject", violations, _attempt) do
    "Ryker checks every answer before sending it. " <>
      sent_back_reason(Enum.join(violations, " ")) <> " This is a routine check, not an error."
  end

  # In the words the model call's Checks line uses: first time, or on
  # which attempt.
  defp validation_summary("accept", _violations, 1),
    do: "Ryker checked the answer and accepted it the first time."

  defp validation_summary("accept", _violations, attempt) when is_integer(attempt),
    do: "Ryker checked the answer and accepted it on attempt #{attempt}."

  defp validation_summary("accept", _violations, _attempt),
    do: "Ryker checked the answer and accepted it."

  defp validation_summary(_verdict, _violations, _attempt),
    do: "The model returned an answer for Ryker to check."

  # What the correction was about, as the words a person reads; the first that matches wins.
  @sent_back [
    {["required goals remain open"],
     "The model said it was done while steps of its plan were still open, so Ryker sent it back to finish or close them."},
    {["no committed task changes"],
     "The model said it was done before it had changed anything, so Ryker sent it back to make the change."},
    {["answer the user"],
     "The model tried to finish without answering the person, so Ryker sent it back to reply."},
    {["platform actions are unresolved"],
     "The model tried to finish before its Slack or GitHub actions had gone through, so Ryker sent it back to wait for them."},
    {["timer wait", "durable waits", "waiting state", "waiting outcome"],
     "The answer didn't match what the model was waiting for, so Ryker sent it back to fix that."},
    {["record_refs", "artifact_refs", "host-issued reference"],
     "The answer pointed to a record or file that doesn't exist, so Ryker sent it back to fix the reference."},
    {["JSON", "top-level object", "For delivery"],
     "The answer wasn't in the shape Ryker needs, so Ryker sent it back to be written again."}
  ]

  defp sent_back_reason(correction) do
    case uncommitted(correction) do
      nil ->
        known_reason(correction)

      1 ->
        "The model said it was done, but 1 changed file wasn't committed yet, so Ryker sent it back to commit it."

      count ->
        "The model said it was done, but #{count} changed files weren't committed yet, so Ryker sent it back to commit them."
    end
  end

  defp known_reason(correction) do
    fallback = "This one didn't pass those checks, so Ryker sent it back for the model to fix."

    Enum.find_value(@sent_back, fallback, fn {phrases, words} ->
      if String.contains?(correction, phrases), do: words
    end)
  end

  defp uncommitted(correction) do
    case Regex.run(~r/has (\d+) uncommitted or conflicted path/, correction) do
      [_whole, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  defp delivery_summary(%{"delivery" => "reply", "message" => message}) when is_binary(message),
    do: "Ryker accepted this response for delivery."

  defp delivery_summary(%{"message" => message}) when is_binary(message),
    do: "Ryker accepted this response for delivery."

  defp delivery_summary(%{"delivery" => "none", "decision_reason" => reason})
       when is_binary(reason),
       do: "No reply: " <> (InspectionRedactor.artifact(reason).text |> Text.shorten(240))

  defp delivery_summary(_document), do: "Accepted result recorded."

  defp delivery_confirmation(%{"message_ref" => "eval-message:" <> _}),
    do: "The private replay captured the response. Nothing was sent to Slack."

  defp delivery_confirmation(%{"transport" => "slack"}),
    do: "Slack transport confirmed the delivery."

  defp delivery_confirmation(%{"transport" => "control_plane"}),
    do: "The conversation recorded the response."

  defp delivery_confirmation(_), do: "The destination confirmed the delivery."

  defp delivery_actor(%{"transport" => transport}) when is_binary(transport), do: transport
  defp delivery_actor(_receipt), do: "Delivery"

  defp delivery_kind(%{"delivery" => value}), do: value
  defp delivery_kind(%{}), do: "reply"
  defp delivery_kind(_document), do: nil

  defp outcome_count(document, key) do
    case get_in(document || %{}, ["outcome", key]) do
      values when is_list(values) -> length(values)
      _other -> nil
    end
  end

  defp parsed_time(value) when is_binary(value) do
    case UTCDateTime.parse(value) do
      {:ok, time} -> time
      _invalid -> nil
    end
  end

  defp parsed_time(_value), do: nil
end

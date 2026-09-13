defmodule Ryker.ControlPlane.EpisodeTrace.Work do
  @moduledoc """
  "The work" and "The answer": each Work turn from queueing through the
  provider finishing, every validation verdict, the accepted result and its
  delivery, the state records the model wrote, the worker's own events and the
  Slack status updates that accompanied them.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.{Card, InspectionRedactor}
  alias Ryker.CoopFleet.Event, as: CoopEvent
  alias Ryker.Repo
  alias Ryker.Slack.ThreadStatusReceipts
  alias Ryker.State.Record
  alias Ryker.Work.Turn

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
                {"Turn", turn.turn_ref},
                {"Policy", session && session.policy},
                {"Repository", session && session.repository_ref}
              ]),
            stage: "Routing",
            state: "",
            summary: "The new input was queued for model work.",
            title: "Turn #{ordinal} queued",
            tone: nil
          }
        )

      work = work_step(turn, ordinal)
      answer = answer_steps(turn, ordinal)
      outcome = delivery_step(turn, ordinal)

      ([prepared, work] ++ answer ++ outcome)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp work_step(%Turn{remote_finished_at: nil}, _ordinal), do: nil

  defp work_step(turn, ordinal) do
    step(
      "turn-#{turn.id}-work",
      :work,
      turn.remote_finished_at || turn.remote_started_at,
      %{
        actor: "Coop",
        owner: {:turn, turn.id},
        details:
          compact_details([
            {"Target", turn.execution_target},
            {"Queued", format_ms(turn.usage_queued_ms)},
            {"Provider", format_ms(turn.usage_provider_ms)},
            {"Host", format_ms(turn.usage_host_ms)},
            {"Work claims", turn.work_attempt_count},
            {"Remote operation", turn.remote_operation_kind},
            {"Measurement", turn.measurement_error_code || measurement_state(turn)}
          ]),
        duration_ms: turn.usage_provider_ms,
        stage: "Execution",
        state: work_state(turn),
        summary: work_summary(turn),
        title: "Turn #{ordinal} finished",
        tone: state_tone(work_state(turn))
      }
    )
  end

  defp answer_steps(turn, ordinal) do
    validations = validation_steps(turn, ordinal)
    accepted = accepted_step(turn, ordinal)
    validations ++ Enum.reject([accepted], &is_nil/1)
  end

  defp validation_steps(%Turn{validation_history: history} = turn, ordinal)
       when is_list(history) and history != [] do
    Enum.map(history, &validation_history_step(turn, ordinal, &1))
  end

  defp validation_steps(%Turn{validation_intent: nil, candidate_attempt: nil}, _ordinal), do: []

  defp validation_steps(turn, ordinal), do: [validation_step(turn, ordinal)]

  defp validation_band(nil, _at), do: :work
  defp validation_band(_finished_at, nil), do: :answer

  defp validation_band(finished_at, at),
    do: if(DateTime.compare(at, finished_at) == :lt, do: :work, else: :answer)

  defp validation_history_step(turn, ordinal, entry) do
    verdict = entry["verdict"]
    violations = bounded_strings(entry["violations"])
    attempt = entry["candidate_attempt"]
    at = parsed_time(entry["recorded_at"])

    validation_step(turn, ordinal,
      at: at,
      attempt: attempt,
      candidate_sha256: entry["candidate_sha256"],
      intent_fingerprint: entry["intent_fingerprint"],
      parse: entry["parse"],
      receipt: nil,
      response_bytes: entry["response_bytes"],
      verdict: verdict,
      violations: violations
    )
  end

  defp validation_step(turn, ordinal) do
    verdict = get_in(turn.validation_intent || %{}, ["verdict"])
    violations = bounded_strings(get_in(turn.validation_intent || %{}, ["violations"]))

    validation_step(turn, ordinal,
      at: nil,
      attempt: turn.candidate_attempt,
      candidate_sha256: turn.candidate_sha256,
      intent_fingerprint: turn.validation_intent_fingerprint,
      parse: candidate_parse(turn.candidate),
      receipt: turn.validation_receipt,
      response_bytes: if(is_binary(turn.candidate), do: byte_size(turn.candidate)),
      verdict: verdict,
      violations: violations
    )
  end

  defp validation_step(turn, ordinal, options) do
    verdict = Keyword.fetch!(options, :verdict)
    violations = Keyword.fetch!(options, :violations)
    attempt = Keyword.fetch!(options, :attempt)
    state = verdict || "candidate recorded"

    {title, tone} = validation_presentation(verdict)

    step(
      "turn-#{turn.id}-validation-#{attempt || 0}",
      validation_band(turn.remote_finished_at, Keyword.fetch!(options, :at)),
      Keyword.fetch!(options, :at),
      %{
        actor: "Ryker",
        owner: {:turn, turn.id},
        details:
          compact_details([
            {"Turn", ordinal},
            {"Candidate attempt", attempt},
            {"Response bytes", Keyword.fetch!(options, :response_bytes)},
            {"Parse", Keyword.fetch!(options, :parse)},
            {"Verdict", verdict},
            {"Violations", Enum.join(violations, " · ")},
            {"Result", if(verdict == "accept", do: "Passed the response checks")}
          ]),
        stage: "Validation",
        state: state,
        summary: validation_summary(verdict, violations, turn),
        title: title,
        tone: tone
      }
    )
  end

  defp validation_presentation("reject"), do: {"Answer rejected", :bad}
  defp validation_presentation("accept"), do: {"Answer validated", :good}
  defp validation_presentation(_), do: {"Response recorded", nil}

  defp accepted_step(%Turn{accepted_at: nil}, _ordinal), do: nil

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
            {"Result", turn.result_ref},
            {"Delivery", delivery_kind(turn.delivery_document)},
            {"Artifacts", outcome_count(turn.delivery_document, "artifact_refs")},
            {"Records", outcome_count(turn.delivery_document, "record_refs")},
            {"Outcome", get_in(turn.delivery_document || %{}, ["outcome", "state"])}
          ]),
        stage: "Result",
        state: "accepted",
        summary: delivery_summary(turn.delivery_document),
        title: "Turn #{ordinal} result accepted",
        tone: :good
      }
    )
  end

  defp delivery_step(
         %Turn{delivery_ref: nil, delivered_at: nil, external_receipt: nil},
         _ordinal
       ),
       do: []

  defp delivery_step(turn, ordinal) do
    queued =
      step(
        "turn-#{turn.id}-delivery-queued",
        :outcome,
        turn.accepted_at,
        %{
          actor: "Ryker",
          owner: {:turn, turn.id},
          delivery_ref: turn.delivery_ref,
          details: compact_details([{"Turn", ordinal}]),
          stage: "Delivery",
          state: "queued",
          summary: "The accepted response was queued for delivery.",
          title: "Response queued for delivery",
          tone: nil
        }
      )

    [queued | confirmed_delivery_step(turn, ordinal)]
  end

  defp confirmed_delivery_step(%Turn{delivered_at: nil}, _ordinal), do: []

  defp confirmed_delivery_step(turn, ordinal) do
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
              {"Turn", ordinal},
              {"Delivery", turn.delivery_ref},
              {"Transport", get_in(turn.external_receipt || %{}, ["transport"])},
              {"Message", get_in(turn.external_receipt || %{}, ["message_ref"])}
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

  @doc "One step per state record the model wrote, with its card when it has one."
  def record_steps(records) do
    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, index} ->
      card =
        case Card.project(%{
               record
               | status: :open,
                 updated_at: record.inserted_at,
                 wait_error: nil
             }) do
          {:ok, projected} -> projected
          :ignore -> nil
        end

      # Creating an offer or a question is model work; only a delivery receipt
      # proves one was sent, so every record sits in the work chapter.
      step(
        "record-#{record.id || index}",
        :work,
        record.inserted_at,
        %{
          actor: "Ryker state",
          record_ref: record.ref,
          details: compact_details(record_details(record, card)),
          href: nil,
          stage: record_stage(record.kind),
          state: "",
          summary: record_summary(record, card),
          title: record_title(record, card),
          current_warning: Card.wait_warning(record),
          tone: nil
        }
      )
    end)
  end

  @doc "The worker fleet's own events for the episode's sessions."
  def coop_steps([]), do: []

  def coop_steps(sessions) do
    session_ids = Enum.map(sessions, & &1.id)

    Repo.all(
      from(event in CoopEvent,
        where: event.session_id in ^session_ids and event.kind != "session_event",
        order_by: [asc: event.inserted_at, asc: event.sequence],
        limit: 500
      )
    )
    |> Enum.map(fn event ->
      step(
        "coop-event-#{event.id}",
        coop_band(event.kind),
        event.inserted_at,
        %{
          actor: "Coop fleet",
          details:
            compact_details([
              {"Worker", event.worker_id},
              {"Placement generation", event.placement_generation},
              {"Sequence", event.sequence},
              {"Event", event.kind},
              {"Payload", short_digest(event.payload_fingerprint)}
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
    Enum.map(ThreadStatusReceipts.for_episode(episode_id), fn receipt ->
      clear = receipt.text == ""

      band = status_band(receipt)

      step("slack-status-#{receipt.id}", band, receipt.acknowledged_at || receipt.inserted_at, %{
        actor: "Slack",
        stage: "Status",
        state: if(receipt.error, do: "failed", else: ""),
        title: status_title(receipt),
        summary: receipt.error || if(clear, do: nil, else: receipt.text),
        details:
          compact_details([
            {"Confirmation",
             if(receipt.acknowledged_at, do: "Slack acknowledged this status update.")},
            {"Status generation", receipt.generation}
          ]),
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
  defp record_stage("goal"), do: "Plan"
  defp record_stage("goal_state"), do: "Plan"
  defp record_stage("input_request"), do: "Wait"
  defp record_stage("event_wait"), do: "Wait"
  defp record_stage(_kind), do: "State record"

  defp record_title(%Record{kind: "progress"}, %{title: title}), do: "Progress · #{title}"
  defp record_title(%Record{kind: "input_request"}, _card), do: "Question prepared"
  defp record_title(%Record{kind: "event_wait"}, _card), do: "Wait prepared"
  defp record_title(%Record{kind: "goal"}, _card), do: "Goal recorded"

  defp record_title(%Record{kind: "evidence"}, %{title: title}),
    do: "Evidence recorded · #{title}"

  defp record_title(%Record{kind: "goal_state"}, %{title: title}), do: "Goal · #{title}"

  defp record_title(_record, %{label: label, title: title}) when is_binary(title),
    do: "#{label} · #{title}"

  defp record_title(record, _card), do: capitalize(human(record.kind)) <> " recorded"

  defp record_summary(%Record{kind: "input_request", payload: payload}, _card),
    do: payload["reason"] || "The model prepared a question for the reply."

  defp record_summary(_record, %{summary: summary}) when is_binary(summary), do: summary
  defp record_summary(%Record{subject_ref: value}, _card) when is_binary(value), do: value
  defp record_summary(%Record{operation_id: value}, _card), do: value

  defp record_details(record, nil),
    do: [{"Record", record.ref}, {"Operation", record.operation_id}]

  defp record_details(record, card) do
    [{"Record", record.ref}, {"Operation", record.operation_id}] ++
      Map.get(card, :details, [])
  end

  defp coop_band(kind) when kind in ["turn", "candidate", "validation"], do: :work
  defp coop_band(_kind), do: :ready
  defp coop_title(kind), do: "Worker · #{human(kind)}"
  defp coop_summary(%{"state" => state}), do: "Worker reported #{human(state)}."
  defp coop_summary(_payload), do: "Bound worker event recorded."
  defp coop_tone(kind) when kind in ["candidate", "validation"], do: :good
  defp coop_tone(_kind), do: nil

  defp work_state(%Turn{remote_finished_at: nil}), do: "running"
  defp work_state(_turn), do: "finished"

  defp work_summary(%Turn{remote_finished_at: nil}),
    do: "The provider is still handling this turn."

  defp work_summary(_turn), do: "The provider finished and returned control to Ryker."

  defp validation_summary("reject", [], _turn),
    do: "Ryker rejected this candidate and requested a same-turn correction."

  defp validation_summary("reject", violations, _turn), do: Enum.join(violations, " ")

  defp validation_summary("accept", _violations, _turn),
    do: "The response passed the checks for this attempt."

  defp validation_summary(_verdict, _violations, _turn),
    do: "A candidate reached the host validation boundary."

  defp delivery_summary(%{"delivery" => "reply", "message" => message}) when is_binary(message),
    do: "Ryker accepted this response for delivery."

  defp delivery_summary(%{"message" => message}) when is_binary(message),
    do: "Ryker accepted this response for delivery."

  defp delivery_summary(%{"delivery" => "none", "decision_reason" => reason})
       when is_binary(reason),
       do: "No reply: " <> (InspectionRedactor.artifact(reason).text |> bounded(240))

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

  defp measurement_state(%Turn{timing_recorded: true, usage_recorded: true}),
    do: "usage and timing recorded"

  defp measurement_state(%Turn{timing_recorded: true}), do: "timing recorded; usage unmeasured"
  defp measurement_state(_turn), do: "unmeasured"

  defp candidate_parse(candidate) when is_binary(candidate) do
    case Jason.decode(candidate) do
      {:ok, value} when is_map(value) -> "JSON object"
      {:ok, _value} -> "JSON value; object required"
      {:error, _reason} -> "invalid JSON"
    end
  end

  defp candidate_parse(_candidate), do: "not recorded"

  defp parsed_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> time
      _invalid -> nil
    end
  end

  defp parsed_time(_value), do: nil
end

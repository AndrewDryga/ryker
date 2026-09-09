defmodule Responder.ControlPlane.EpisodeTrace do
  alias Responder.ControlPlane.SlackNames
  alias Responder.Slack.ThreadStatusReceipts

  @moduledoc """
  Builds the bounded operator story for one durable episode.

  This projection deliberately presents identities, lifecycle, measurements,
  and host decisions rather than copying raw ingress, prompts, candidates, or
  provider diagnostics into the control plane.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.Card
  alias Responder.ControlPlane.CurrentInputs
  alias Responder.ControlPlane.EvidenceLinks
  alias Responder.ControlPlane.InspectionRedactor
  alias Responder.ControlPlane.SourceText
  alias Responder.ControlPlane.WorkRecovery
  alias Responder.CoopFleet.Event, as: CoopEvent
  alias Responder.Delivery.PlatformAction
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Operator.EpisodeReview
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Slack.IncidentRoom
  alias Responder.State.{Record, Schedule}
  alias Responder.Work.{Activity, ActivityEvent, ActivityPaths, Custody, Session, Turn}

  @chapters [
    {:input, "What came in", "The input, continuation, or trigger that opened this work."},
    {:ready, "Getting ready", "How Responder routed, scoped, and prepared the work."},
    {:routing, "Routing", "The routing model's briefing, activity, and decision."},
    {:work, "The work", "What ran, what it recorded, and whether the provider stayed active."},
    {:answer, "The answer", "Candidate validation, the accepted result, and any refusal."},
    {:outcome, "What came of it", "Delivery, durable side effects, waits, and follow-up work."}
  ]

  @spec project(Episode.t(), [Event.t()], [Record.t()]) :: map()
  def project(%Episode{} = episode, events, records) when is_list(events) and is_list(records) do
    inputs = inputs(episode.id)
    sessions = sessions(episode.id)
    turns = turns(episode.id)
    activity_page = Activity.page_for_episode(episode.id)

    activity =
      activity_page.events
      |> activity_steps()
      |> EvidenceLinks.attach(activity_page.events, turns, records)

    current_turn = List.last(turns)
    stopped = stopped(episode, current_turn)
    # Only collapse an entirely unstarted task, never earlier work in a resumed episode.
    startup =
      if current_blocked_turn?(episode, current_turn) and length(turns) == 1 and
           WorkRecovery.not_started?(current_turn) and
           Enum.all?(sessions, &is_nil(&1.coop_session_id)),
         do: task_start(episode, current_turn)

    totals = totals(episode.id, events, records, sessions, turns)
    review = review_state(episode)
    received_at = first_received_at(episode)
    platform_actions = platform_actions(episode.id)
    publications = publications(episode.id)
    source = source_link(episode, events, inputs)

    steps =
      []
      |> Kernel.++(kernel_steps(events, inputs))
      |> Kernel.++(session_steps(sessions))
      |> Kernel.++(turn_steps(turns, sessions))
      |> Kernel.++(activity)
      |> Kernel.++(slack_status_steps(episode.id))
      |> Kernel.++(record_steps(records))
      |> Kernel.++(coop_steps(sessions))
      |> Kernel.++(platform_action_steps(platform_actions))
      |> Kernel.++(incident_steps(episode.id))
      |> Kernel.++(publication_steps(publications))
      |> Kernel.++(schedule_steps(episode.id))
      |> chronological()

    %{
      activity: Map.drop(activity_page, [:events]),
      actions: operator_actions(episode, current_turn, review),
      case_file: case_file(episode.id, turns, sessions),
      startup: startup,
      chapters: chapters(steps, received_at),
      follow_through: follow_through(platform_actions, publications, source),
      history: history(totals, activity_page),
      metrics: metrics(episode, received_at, activity_page, totals, steps),
      next_action: next_action(episode, current_turn),
      received_at: received_at,
      review: review,
      source: source,
      stats: stats(steps, activity_page, totals),
      steps: steps,
      stopped: stopped
    }
  end

  defp slack_status_steps(episode_id) do
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

  defp case_file(episode_id, turns, sessions) do
    options = [
      secrets: InspectionRedactor.configured_secrets(),
      max_bytes: 12_000
    ]

    base = from(entry in subquery(CurrentInputs.for_episode(episode_id)))

    first =
      Repo.one(from(entry in base, order_by: [asc: entry.occurred_at, asc: entry.id], limit: 1))

    first = if first, do: case_message(first, options)

    messages =
      Repo.all(
        from(entry in base, order_by: [desc: entry.occurred_at, desc: entry.id], limit: 20)
      )
      |> Enum.reverse()
      |> Enum.map(&case_message(&1, options))

    replies = turns |> Enum.flat_map(&case_reply(&1, options)) |> Enum.take(-20)
    latest_reply = List.last(replies)
    current_turn = List.last(turns)

    task_session = task_session(current_turn, sessions)

    %{
      title: task_title(task_session) || input_title(first),
      expired_at: Enum.find_value(messages, & &1.expired_at),
      messages: messages,
      repository: case_repository(task_session, first),
      reply: latest_reply && latest_reply.text,
      reply_status: latest_reply && latest_reply.status,
      reply_request_id: latest_reply && latest_reply.id,
      awaiting_reply: is_nil(current_turn) or is_nil(current_turn.delivery_document),
      conversation:
        Enum.sort_by(messages ++ Enum.filter(replies, & &1.delivered), & &1.at, DateTime)
    }
  end

  defp task_session(%Turn{operational_pruned_at: nil, session_id: id}, sessions),
    do: Enum.find(sessions, &(&1.id == id and is_map(&1.workspace_task)))

  defp task_session(_, _), do: nil

  defp task_title(%Session{workspace_task: %{"title" => title}}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 240).text

  defp task_title(_), do: nil

  defp input_title(%{available: true, text: text}),
    do: text |> String.split("\n", parts: 2) |> hd() |> bounded(120)

  defp input_title(_), do: "Episode case file"

  defp case_repository(%Session{repository_ref: ref}, _) when is_binary(ref), do: ref
  defp case_repository(_, first), do: first && first.repository

  defp task_start(episode, turn) do
    offer =
      Repo.one(
        from(record in Record,
          join: source in Episode,
          on: source.id == record.episode_id,
          where: record.kind == "task_offer" and record.status == :confirmed,
          where: record.confirmed_episode_id == ^episode.id,
          where: record.episode_id == ^(episode.linked_episode_id || episode.id),
          select: %{
            inserted_at: record.inserted_at,
            confirmed_at: record.confirmed_at,
            episode_key: source.key
          },
          order_by: [desc: record.confirmed_at, desc: record.id],
          limit: 1
        )
      )

    %{
      confirmed: not is_nil(offer) and not is_nil(offer.confirmed_at),
      events:
        Enum.reject(
          [
            offer &&
              %{
                label: "Task proposed",
                at: offer.inserted_at,
                href: "/episodes/" <> segment(offer.episode_key)
              },
            offer && offer.confirmed_at &&
              %{label: "Task approved", at: offer.confirmed_at, href: nil},
            %{
              label: "Couldn’t start — code-editing setup needs attention",
              at: turn.cancelled_at || turn.updated_at,
              href: nil
            }
          ],
          &is_nil/1
        )
    }
  end

  defp case_reply(
         %{operational_pruned_at: nil, delivery_document: %{"message" => text}} = turn,
         options
       )
       when is_binary(text) do
    artifact = InspectionRedactor.artifact(text, options)

    [
      %{
        id: turn.id,
        at: turn.delivered_at || turn.accepted_at || turn.inserted_at,
        actor: "Responder",
        delivery_ref: turn.delivery_ref,
        delivered: not is_nil(turn.delivered_at),
        status: case_reply_status(turn),
        text: artifact.text,
        available: artifact.state == :retained,
        href: "requests?attempt=#{turn.id}&section=delivery"
      }
    ]
  end

  defp case_reply(_, _), do: []

  defp case_message(input, options) do
    artifact =
      InspectionRedactor.artifact(
        if(is_nil(input.operational_pruned_at),
          do:
            if(input.event_kind == :delete,
              do: "Message deleted",
              else: SourceText.from_content(input.content)
            )
        ),
        Keyword.put(options, :expired, not is_nil(input.operational_pruned_at))
      )

    %{
      id: input.id,
      at: input.occurred_at,
      transport: input.destination_transport,
      actor: if(input.actor_kind == :user, do: "User", else: "Source event"),
      display_actor:
        if(input.source_kind == "slack",
          do: SlackNames.name(input.source_ref, input.actor_ref)
        ),
      actor_ref: input.actor_ref,
      workspace: if(input.source_kind == "slack", do: input.source_ref),
      text: artifact.text,
      available: artifact.state == :retained,
      repository: input.repository_ref,
      expired_at: input.operational_pruned_at,
      href: "/episodes/ingress-input%3A#{input.id}"
    }
  end

  defp case_reply_status(%{
         delivered_at: %DateTime{},
         external_receipt: %{"message_ref" => "eval-message:" <> _}
       }),
       do: "Response captured in private replay"

  defp case_reply_status(%{delivered_at: %DateTime{}}), do: "Response sent"
  defp case_reply_status(%{accepted_at: %DateTime{}}), do: "Accepted · delivery not confirmed"
  defp case_reply_status(_turn), do: nil

  defp inputs(episode_id) do
    Repo.all(
      from(entry in Entry,
        where: entry.episode_id == ^episode_id,
        order_by: [asc: entry.occurred_at, asc: entry.id],
        limit: 200
      )
    )
    |> Enum.flat_map(&[{&1.dedupe_key, &1}, {"ingress-turn:#{&1.id}", &1}])
    |> Map.new()
  end

  defp first_received_at(episode) do
    received_at =
      Repo.one(
        from(entry in Entry,
          where: entry.episode_id == ^episode.id,
          select: min(entry.inserted_at)
        )
      )

    case received_at do
      %DateTime{} = at ->
        if DateTime.compare(at, episode.inserted_at) == :lt, do: at, else: episode.inserted_at

      nil ->
        episode.inserted_at
    end
  end

  defp event_input(event, inputs) do
    # Kernel command identity hashes and ingress delivery hashes have different
    # contracts. Admission records the exact ingress identity in its turn ref.
    Map.get(inputs, get_in(event.payload || %{}, ["turn_ref"])) ||
      Map.get(inputs, event.dedupe_key)
  end

  defp sessions(episode_id) do
    Repo.all(
      from(session in Session,
        where: session.episode_id == ^episode_id,
        order_by: [desc: session.inserted_at, desc: session.id],
        limit: 50
      )
    )
    |> Enum.reverse()
  end

  defp turns(episode_id) do
    Repo.all(
      from(turn in Turn,
        where: turn.episode_id == ^episode_id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 200
      )
    )
    |> Enum.reverse()
  end

  defp kernel_steps(events, inputs) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      input = event_input(event, inputs)

      step(
        "kernel-#{event.sequence || index}",
        kernel_band(event.kind),
        event.occurred_at,
        %{
          actor: "Episode kernel",
          input_id: input && input.id,
          delivery_ref: get_in(event.payload || %{}, ["expected_delivery_ref"]),
          result_ref: get_in(event.payload || %{}, ["result_ref"]),
          details: kernel_details(event, input),
          stage: kernel_stage(event.kind),
          state: event.kind,
          summary: kernel_summary(event.kind),
          title: kernel_title(event.kind),
          tone: kernel_tone(event.kind)
        }
      )
    end)
  end

  defp kernel_details(event, nil) do
    compact_details([
      {"Sequence", event.sequence},
      {"Identity", event.dedupe_key},
      {"Fingerprint", short_digest(event.fingerprint)}
    ])
  end

  defp kernel_details(event, input) do
    compact_details([
      {"Sequence", event.sequence},
      {"Source", join_ref(input.source_kind, input.source_ref)},
      {"Actor", join_ref(input.actor_kind, input.actor_ref)},
      {"Event", input.event_kind},
      {"Revision", input.revision},
      {"Message", source_text(input)},
      {"Attachments", source_attachments(input)},
      {"Fingerprint", short_digest(event.fingerprint)}
    ])
  end

  defp session_steps(sessions) do
    Enum.map(sessions, fn session ->
      target = workspace_target(session.workspace_task)

      step(
        "session-#{session.id}",
        :ready,
        session.inserted_at,
        %{
          actor: "Responder",
          details:
            compact_details([
              {"Policy", session.policy},
              {"Repository", session.repository_ref},
              {"Generation", session.generation},
              {"Workspace target", target}
            ]),
          stage: "Preparation",
          state: "",
          summary: session_summary(session, target),
          title: "Workspace selected",
          tone: nil
        }
      )
    end)
  end

  defp turn_steps(turns, sessions) do
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
            actor: "Responder",
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
        actor: "Responder",
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
        actor: "Responder",
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
          actor: "Responder",
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

  defp record_steps(records) do
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

      step(
        "record-#{record.id || index}",
        record_band(record.kind),
        record.inserted_at,
        %{
          actor: "Responder state",
          record_ref: record.ref,
          details: compact_details(record_details(record, card)),
          href: record_href(record),
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

  defp coop_steps([]), do: []

  defp coop_steps(sessions) do
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

  defp activity_steps(activity_events) do
    routing_ids =
      activity_events
      |> Enum.filter(&(not is_nil(&1.admission_input_id)))
      |> Enum.map(&("activity-" <> &1.id))
      |> MapSet.new()

    activity_events
    |> Enum.reject(&(&1.kind == "model.thought"))
    |> Enum.reduce({[], %{}}, &fold_activity/2)
    |> elem(0)
    |> Enum.map(fn step ->
      if MapSet.member?(routing_ids, step.id), do: %{step | band: :routing}, else: step
    end)
  end

  defp fold_activity(%ActivityEvent{kind: "tool.started"} = event, {steps, open}) do
    key = activity_tool_key(event)
    activity_step = tool_started_step(event)
    {steps ++ [activity_step], Map.put(open, key, length(steps))}
  end

  defp fold_activity(%ActivityEvent{kind: "tool.completed"} = event, {steps, open}) do
    key = activity_tool_key(event)

    case Map.pop(open, key) do
      {nil, open} -> {steps ++ [tool_completed_step(event)], open}
      {index, open} -> {steps ++ [complete_tool(Enum.at(steps, index), event)], open}
    end
  end

  defp fold_activity(event, {steps, open}), do: {steps ++ [activity_step(event)], open}

  defp tool_started_step(event) do
    input = event.payload["input"]

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        artifacts: tool_artifacts(event.payload),
        details:
          compact_details(
            [
              {"Kind", event.payload["kind"]},
              {"Tool call", event.payload["tool_call_id"]}
            ] ++ activity_tool_details(input)
          ),
        stage: "Tool call",
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        state: "started",
        summary: activity_tool_summary(input),
        title: activity_tool_title(event.payload),
        tone: nil
      }
    )
  end

  defp tool_completed_step(event) do
    status = event.payload["status"] || "completed"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        artifacts: tool_artifacts(event.payload),
        details:
          compact_details([
            {"Kind", event.payload["kind"]},
            {"Tool call", event.payload["tool_call_id"]},
            {"Status", status}
          ]),
        stage: "Tool call",
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        state: status,
        summary: tool_outcome(event.payload, status),
        title: event.payload["title"] || "Tool completion recorded",
        tone: activity_status_tone(status)
      }
    )
  end

  defp complete_tool(step, event) do
    status = event.payload["status"] || "completed"
    duration_ms = nonnegative_diff(event.occurred_at, step.at)

    %{
      step
      | id: "activity-#{event.id}",
        at: event.occurred_at,
        artifacts: merge_artifacts(step[:artifacts] || [], tool_artifacts(event.payload)),
        tool_kind: event.payload["kind"] || step.tool_kind,
        path_context: safe_path_context(event.payload["path_context"] || step.path_context),
        summary: tool_outcome(event.payload, status),
        details:
          step.details ++
            compact_details([
              {"Status", status},
              {"Finished", event.occurred_at}
            ]),
        duration_ms: duration_ms,
        state: human(status),
        tone: activity_status_tone(status)
    }
  end

  defp safe_path_context(value) do
    with %{} = paths <- ActivityPaths.sanitize(value),
         %{text: text, truncated: false} <- InspectionRedactor.artifact(paths, max_bytes: 16_384),
         {:ok, redacted} <- Jason.decode(text) do
      ActivityPaths.sanitize(redacted)
    else
      _ -> nil
    end
  end

  defp activity_step(%ActivityEvent{kind: "model.progress"} = event) do
    step("activity-#{event.id}", :work, event.occurred_at, %{
      actor: "Model",
      details: [],
      stage: "Progress",
      state: "",
      summary: event.payload["text"],
      title: "Progress update"
    })
  end

  defp activity_step(%ActivityEvent{kind: "model.plan"} = event) do
    count = event.payload["step_count"] || 0

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Model",
        artifacts:
          if(event.payload["entries"] in [nil, []],
            do: [],
            else: [
              %{
                label: "Plan",
                artifact: InspectionRedactor.artifact(event.payload["entries"], max_bytes: 20_000)
              }
            ]
          ),
        details: compact_details([{"Plan steps", count}]),
        stage: "Plan",
        state: "updated",
        summary: plural(count, "plan step"),
        title: "Model plan updated",
        tone: nil
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "permission.decided"} = event) do
    outcome = event.payload["outcome"] || "recorded"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop policy",
        details:
          compact_details([
            {"Tool call", event.payload["tool_call_id"]},
            {"Option", event.payload["option_kind"]}
          ]),
        stage: "Permission",
        state: outcome,
        summary: permission_summary(event.payload),
        title: "Tool permission decided",
        tone: activity_status_tone(outcome)
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "activity.elided"} = event) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: compact_details([{"Dropped events", event.payload["dropped"]}]),
        stage: "Recorder",
        state: "bounded",
        summary: "The turn exceeded its bounded narration budget.",
        title: "Some activity was elided",
        tone: :warn
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "provider.backoff"} = event) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: safe_payload_details(event.payload),
        stage: "Provider",
        state: "backing off",
        summary: provider_backoff_summary(event.payload),
        title: "Provider rate limit",
        tone: :warn
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "provider.alive"} = event) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: safe_payload_details(event.payload),
        stage: "Provider",
        state: "alive",
        summary: provider_alive_summary(event.payload),
        title: "Provider is still responding",
        tone: nil
      }
    )
  end

  defp activity_step(event) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: [],
        stage: "Worker activity",
        state: "recorded",
        summary: "Bounded activity event recorded.",
        title: capitalize(human(event.kind)),
        tone: nil
      }
    )
  end

  defp tool_artifacts(payload) do
    for {key, label} <- [
          {"input", "Arguments"},
          {"output", "Response"},
          {"error", "Error"},
          {"content", "Output and changes"},
          {"locations", "Files"}
        ],
        Map.has_key?(payload, key),
        payload[key] != nil do
      %{label: label, artifact: InspectionRedactor.artifact(payload[key], max_bytes: 20_000)}
    end
  end

  defp merge_artifacts(start, finish),
    do:
      Enum.reject(start, fn artifact -> Enum.any?(finish, &(&1.label == artifact.label)) end) ++
        finish

  defp tool_outcome(payload, "failed") do
    case payload["error"] || payload["output"] || payload["content"] do
      nil -> "The tool failed. Its error response was not recorded for this older call."
      value -> value |> InspectionRedactor.artifact(max_bytes: 300) |> Map.fetch!(:text)
    end
  end

  defp tool_outcome(_payload, "cancelled"), do: "The tool call was cancelled."
  defp tool_outcome(_payload, _status), do: nil

  defp activity_tool_key(event),
    do:
      {event.session_id, event.coop_turn_id,
       event.payload["tool_call_id"] || event.remote_event_id}

  defp activity_tool_title(%{
         "input" => %{"operation" => action, "server" => server}
       })
       when is_binary(server) and is_binary(action),
       do: "#{server} · #{action}"

  defp activity_tool_title(%{"title" => title}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 200).text

  defp activity_tool_title(_payload), do: "Tool call"

  defp activity_tool_summary(%{} = input) do
    [input["server"], input["operation"] || input["tool"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> present()
  end

  defp activity_tool_summary(_input), do: "Tool execution recorded."

  defp activity_tool_details(input) when is_map(input) do
    [
      {"Server", input["server"]},
      {"Tool", input["tool"]},
      {"Operation", input["operation"]}
    ]
  end

  defp activity_tool_details(_input), do: []

  defp safe_payload_details(payload), do: payload |> safe_fields() |> compact_details()

  defp safe_fields(%{} = fields) do
    fields
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} ->
      case safe_activity_value(value) do
        nil -> []
        safe -> [{capitalize(human(key)), safe}]
      end
    end)
    |> Enum.take(20)
  end

  defp safe_fields(_fields), do: []

  defp safe_activity_value(value) when is_binary(value), do: value |> scrub_url() |> bounded(512)

  defp safe_activity_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp safe_activity_value(value) when is_map(value) or is_list(value) do
    value
    |> redact_activity_value()
    |> CanonicalJSON.encode!()
    |> bounded(512)
  rescue
    ArgumentError -> nil
  end

  defp safe_activity_value(_value), do: nil

  defp redact_activity_value(%{} = value) do
    value
    |> Enum.reject(fn {key, _nested} -> sensitive_key?(key) end)
    |> Map.new(fn {key, nested} -> {to_string(key), redact_activity_value(nested)} end)
  end

  defp redact_activity_value(value) when is_list(value),
    do: value |> Enum.take(32) |> Enum.map(&redact_activity_value/1)

  defp redact_activity_value(value) when is_binary(value), do: scrub_url(value)
  defp redact_activity_value(value), do: value

  defp sensitive_key?(key) when is_atom(key) or is_binary(key),
    do:
      Regex.match?(~r/(?:authorization|cookie|credential|password|secret|token)/i, to_string(key))

  defp sensitive_key?(_key), do: false

  defp scrub_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        uri |> Map.merge(%{fragment: nil, query: nil, userinfo: nil}) |> URI.to_string()

      _not_url ->
        value
    end
  end

  defp permission_summary(payload) do
    case payload["outcome"] do
      "cancelled" -> "Coop policy refused this unattended permission request."
      outcome when is_binary(outcome) -> "Coop policy recorded #{human(outcome)}."
      _missing -> "Coop policy recorded a permission decision."
    end
  end

  defp provider_backoff_summary(payload) do
    target = payload["target"] || payload["provider"]
    reset = payload["reset_at"] || payload["retry_after"]

    [target && "#{target} is rate limited", reset && "retry #{reset}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Coop paused this turn at the provider's rate limit."
      summary -> summary
    end
  end

  defp provider_alive_summary(payload) do
    frames = payload["frames"]
    bytes = payload["bytes"]

    [frames && "#{frames} frames", bytes && "#{bytes} bytes observed"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Provider frames are still arriving although no higher-level activity was narrated."
      summary -> summary
    end
  end

  defp activity_status_tone(status) when status in ["failed", "denied"], do: :bad
  defp activity_status_tone(status) when status in ["cancelled", "backing off"], do: :warn
  defp activity_status_tone(status) when status in ["completed", "selected", "allowed"], do: :good
  defp activity_status_tone(_status), do: nil

  defp nonnegative_diff(%DateTime{} = right, %DateTime{} = left),
    do: max(DateTime.diff(right, left, :millisecond), 0)

  defp nonnegative_diff(_right, _left), do: nil

  defp platform_actions(episode_id) do
    Repo.all(
      from(action in PlatformAction,
        where: action.episode_id == ^episode_id,
        order_by: [asc: action.inserted_at, asc: action.id],
        limit: 200
      )
    )
  end

  defp platform_action_steps(actions) do
    Enum.flat_map(actions, fn action ->
      queued =
        step(
          "platform-action-#{action.id}",
          :outcome,
          action.inserted_at,
          %{
            actor: action.transport,
            details:
              compact_details([
                {"Action", action.action_ref},
                {"Conversation", action.conversation_ref},
                {"Thread", action.thread_ref}
              ]),
            stage: "Platform action",
            state: "queued",
            summary: "Queued for #{capitalize(action.transport)} delivery.",
            title: platform_action_title(action.tool),
            tone: nil
          }
        )

      if action.delivered_at do
        [
          queued,
          step("platform-action-#{action.id}-confirmed", :outcome, action.delivered_at, %{
            actor: action.transport,
            details: [],
            stage: "Platform action",
            state: "confirmed",
            title: platform_action_title(action.tool) <> " confirmed",
            summary: "#{capitalize(action.transport)} confirmed the action.",
            tone: :good
          })
        ]
      else
        [queued]
      end
    end)
  end

  defp incident_steps(episode_id) do
    Repo.all(
      from(room in IncidentRoom,
        where: room.episode_id == ^episode_id or room.source_episode_id == ^episode_id,
        order_by: [asc: room.requested_at, asc: room.id],
        limit: 50
      )
    )
    |> Enum.map(fn room ->
      step(
        "incident-#{room.id}",
        :outcome,
        room.requested_at || room.inserted_at,
        %{
          actor: "Responder",
          details:
            compact_details([
              {"Incident", room.ref},
              {"Repository", room.repository_ref}
            ]),
          href: "/incidents/#{segment(room.ref)}",
          stage: "Incident",
          state: nil,
          summary: "An incident room was requested. Open the incident for its current state.",
          title: "Incident requested",
          tone: nil
        }
      )
    end)
  end

  defp publications(episode_id) do
    Repo.all(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [asc: publication.inserted_at, asc: publication.id],
        limit: 50
      )
    )
  end

  defp publication_steps(publications) do
    Enum.flat_map(publications, fn publication ->
      requested =
        step(
          "publication-#{publication.id}",
          :outcome,
          publication.inserted_at,
          %{
            actor: "Responder",
            details:
              compact_details([
                {"Publication", publication.ref},
                {"Repository", publication.repository}
              ]),
            stage: "Publication",
            state: nil,
            summary: "Changes were offered for review before publication.",
            title: "Publication requested",
            tone: nil
          }
        )

      if publication.published_at do
        [
          requested,
          step("publication-#{publication.id}-published", :outcome, publication.published_at, %{
            actor: "Responder",
            stage: "Publication",
            state: nil,
            title: "Draft pull request published",
            summary: "Pull request ##{publication.pull_request_number}",
            details:
              compact_details([
                {"Repository", publication.repository},
                {"Branch", publication.branch_ref},
                {"Commit", publication.commit_sha}
              ]),
            tone: :good
          })
        ]
      else
        [requested]
      end
    end)
  end

  # Current follow-through is deliberately outside historical timeline events.
  # Retrying may change this status; it must not rewrite the original request.
  defp follow_through(actions, publications, source) do
    action_status =
      for action <- actions,
          action.status != :delivered,
          action.status == :blocked or not is_nil(action.last_error_code) do
        %{
          id: "platform-action-#{action.id}",
          title: platform_action_title(action.tool),
          state: capitalize(human(action.status)),
          error: InspectionRedactor.artifact(action.last_error_code).text,
          href:
            if(action.status == :blocked, do: "/failures/delivery/#{segment(action.action_ref)}"),
          link_label: "Open recovery"
        }
      end

    publication_status =
      for publication <- publications, publication.status != :published do
        %{
          id: "publication-#{publication.id}",
          title: InspectionRedactor.artifact(publication.title).text,
          state: capitalize(human(publication.status)),
          error: InspectionRedactor.artifact(publication.last_error_code).text,
          href: if(source, do: source.href),
          link_label: "Open conversation"
        }
      end

    action_status ++ publication_status
  end

  defp schedule_steps(episode_id) do
    Repo.all(
      from(schedule in Schedule,
        where: schedule.source_episode_id == ^episode_id,
        order_by: [asc: schedule.confirmed_at, asc: schedule.id],
        limit: 50
      )
    )
    |> Enum.map(fn schedule ->
      step(
        "schedule-#{schedule.id}",
        :outcome,
        schedule.confirmed_at || schedule.inserted_at,
        %{
          actor: "Responder",
          details:
            compact_details([
              {"Schedule", schedule.ref}
            ]),
          href: "/schedules/#{segment(schedule.ref)}",
          stage: "Schedule",
          state: nil,
          summary: "A schedule was created. Open it for its configuration and next run.",
          title: "Schedule created",
          tone: nil
        }
      )
    end)
  end

  defp totals(episode_id, events, records, sessions, turns) do
    turn_totals =
      Repo.one!(
        from(turn in Turn,
          where: turn.episode_id == ^episode_id,
          select: %{
            cost:
              type(
                fragment(
                  "COALESCE(SUM(CASE WHEN ? THEN COALESCE(?, 0) ELSE 0 END), 0)",
                  turn.usage_cost_recorded,
                  turn.usage_cost_usd
                ),
                :decimal
              ),
            costed:
              type(
                fragment("COUNT(*) FILTER (WHERE ?)::bigint", turn.usage_cost_recorded),
                :integer
              ),
            measured:
              type(
                fragment("COUNT(*) FILTER (WHERE ?)::bigint", turn.usage_recorded),
                :integer
              ),
            repairs:
              type(
                fragment(
                  "COALESCE(SUM(GREATEST(COALESCE(?, 1) - 1, 0)), 0)::bigint",
                  turn.candidate_attempt
                ),
                :integer
              ),
            tokens:
              type(
                fragment(
                  "COALESCE(SUM(CASE WHEN ? THEN COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) ELSE 0 END), 0)::bigint",
                  turn.usage_recorded,
                  turn.usage_input_tokens,
                  turn.usage_cached_input_tokens,
                  turn.usage_output_tokens,
                  turn.usage_reasoning_tokens
                ),
                :integer
              ),
            turns: count(turn.id),
            work_claims:
              type(
                fragment("COALESCE(SUM(?), 0)::bigint", turn.work_attempt_count),
                :integer
              )
          }
        )
      )

    Map.merge(turn_totals, %{
      current_turn: List.last(turns),
      events:
        Repo.aggregate(from(event in Event, where: event.episode_id == ^episode_id), :count),
      events_shown: length(events),
      records:
        Repo.aggregate(from(record in Record, where: record.episode_id == ^episode_id), :count),
      records_shown: length(records),
      sessions:
        Repo.aggregate(from(session in Session, where: session.episode_id == ^episode_id), :count),
      sessions_shown: length(sessions),
      turns_shown: length(turns)
    })
  end

  defp history(totals, activity_page) do
    windows = [
      history_window("kernel events", totals.events_shown, totals.events),
      history_window("records", totals.records_shown, totals.records),
      history_window("sessions", totals.sessions_shown, totals.sessions),
      history_window("turns", totals.turns_shown, totals.turns),
      history_window("activity events", activity_page.shown, activity_page.total)
    ]

    %{truncated: Enum.any?(windows, & &1.truncated), windows: windows}
  end

  defp history_window(label, shown, total),
    do: %{label: label, shown: shown, total: total, truncated: total > shown}

  defp latest_time(steps, fallback) do
    Enum.reduce(steps, fallback, fn
      %{at: %DateTime{} = at}, %DateTime{} = latest ->
        if DateTime.compare(at, latest) == :gt, do: at, else: latest

      _step, latest ->
        latest
    end)
  end

  defp metrics(episode, received_at, activity_page, totals, steps) do
    [
      metric(
        "State",
        human(episode.state),
        next_action(episode, totals.current_turn),
        state_tone(episode.state)
      ),
      metric(
        "Elapsed",
        elapsed(received_at, latest_time(steps, episode.updated_at)),
        "first input to latest change"
      ),
      metric("Turns", totals.turns, plural(totals.work_claims, "Work claim")),
      metric(
        "Repairs",
        totals.repairs,
        "candidate corrections",
        if(totals.repairs > 0, do: :warn, else: nil)
      ),
      metric(
        "Tokens",
        if(totals.measured == 0, do: "unmeasured", else: format_integer(totals.tokens)),
        "#{totals.measured}/#{totals.turns} measured"
      ),
      metric(
        "Cost",
        if(totals.costed == 0,
          do: "unmeasured",
          else: "$" <> Decimal.to_string(totals.cost, :normal)
        ),
        "#{totals.costed}/#{totals.turns} costed"
      ),
      metric(
        "Tool calls",
        activity_page.tool_calls,
        "durably narrated by Coop"
      ),
      metric("Records", totals.records, "durable state records")
    ]
  end

  defp stats(steps, activity_page, totals) do
    [
      %{label: "steps shown", value: length(steps)},
      %{label: "turns", value: totals.turns},
      %{label: "records", value: totals.records},
      %{label: "activity", value: activity_page.total}
    ]
  end

  defp stopped(%Episode{state: :waiting_for_input}, _turn) do
    %{
      action: "Reply in the bound conversation",
      attempted: [],
      headline: "Waiting for a person",
      href: nil,
      reason: "The model recorded a material question and released its worker lease."
    }
  end

  defp stopped(%Episode{state: :waiting_for_event}, _turn) do
    %{
      action: "Wait for the recorded event or deadline",
      attempted: [],
      headline: "Waiting for an external event",
      href: nil,
      reason: "The episode is parked durably and will resume only for its bound trigger."
    }
  end

  defp stopped(%Episode{state: :cancelled}, _turn) do
    %{
      action: "No action is required",
      attempted: [],
      headline: "Episode cancelled",
      href: nil,
      reason: "The durable episode owner recorded cancellation."
    }
  end

  defp stopped(_episode, %Turn{status: :blocked, delivery_ref: ref}) when is_binary(ref) do
    %{
      action:
        "Inspect the delivery failure and check the conversation before retrying the saved reply.",
      attempted: [],
      headline: "The reply could not be delivered",
      href: "/failures/delivery/#{segment(ref)}",
      reason: "The answer is already saved. Delivery recovery does not run the model again."
    }
  end

  defp stopped(episode, %Turn{status: :blocked} = turn) do
    recovery =
      WorkRecovery.project(turn, Custody.completed_workspace_recoverable(turn))

    attempts =
      [
        plural(turn.work_attempt_count || 0, "Work claim"),
        turn.candidate_attempt && plural(turn.candidate_attempt, "candidate attempt"),
        turn.coop_turn_id && "Coop turn created",
        turn.validation_intent && "host validation recorded"
      ]
      |> Enum.reject(&(&1 in [nil, "0 Work claims"]))

    %{
      action: recovery.next_step,
      attempted: attempts,
      headline: recovery.headline,
      model_output: recovery.model_output,
      delivery: recovery.delivery,
      not_started: recovery.not_started,
      href: recovery.setup_href || "/failures/work/#{segment(episode.key)}",
      link_label: if(recovery.setup_href, do: "View required setup", else: "Open recovery"),
      reason: recovery.cause
    }
  end

  defp stopped(_episode, _turn), do: nil

  @doc "Groups adjacent chronological entries without moving later messages ahead of earlier work."
  def chapters(steps, started_at) do
    {entries, _state} = Enum.map_reduce(steps, {0, MapSet.new()}, &conversation_part/2)

    entries
    |> Enum.chunk_by(fn {step, part, _boundary} -> {step.band, part} end)
    |> Enum.map(fn chapter_entries ->
      [{_step, conversation_turn, _boundary} | _] = chapter_entries
      chapter_steps = Enum.map(chapter_entries, &elem(&1, 0))
      starts_conversation = Enum.any?(chapter_entries, &elem(&1, 2))

      {band, title, blurb} =
        Enum.find(@chapters, fn {band, _title, _blurb} ->
          band == List.first(chapter_steps).band
        end)

      %{
        band: band,
        title:
          if(starts_conversation and conversation_turn > 1, do: "Follow-up received", else: title),
        conversation_turn: conversation_turn,
        starts_conversation: starts_conversation,
        blurb: blurb,
        span: chapter_span(chapter_steps, started_at),
        steps: chapter_steps
      }
    end)
  end

  defp conversation_part(%{kind: :message, band: :input, id: id} = step, {part, seen}) do
    boundary = not MapSet.member?(seen, id)
    part = if boundary, do: part + 1, else: part
    {{step, part, boundary}, {part, MapSet.put(seen, id)}}
  end

  defp conversation_part(step, {part, _seen} = state), do: {{step, part, false}, state}

  defp chapter_span(steps, started_at) do
    values = steps |> Enum.map(&relative(&1.at, started_at)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      [one] -> one
      many -> List.first(many) <> " → " <> List.last(many)
    end
  end

  defp chronological(steps) do
    steps
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} -> {time_key(item.at), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp step(id, band, at, attributes) do
    %{
      actor: human(Map.fetch!(attributes, :actor)),
      input_id: Map.get(attributes, :input_id),
      record_ref: Map.get(attributes, :record_ref),
      result_ref: Map.get(attributes, :result_ref),
      delivery_ref: Map.get(attributes, :delivery_ref),
      artifacts: Map.get(attributes, :artifacts, []),
      current_warning: Map.get(attributes, :current_warning),
      at: at,
      band: band,
      details: Map.fetch!(attributes, :details),
      duration_ms: Map.get(attributes, :duration_ms),
      tool_kind: Map.get(attributes, :tool_kind),
      path_context: Map.get(attributes, :path_context),
      href: Map.get(attributes, :href),
      id: id,
      stage: human(Map.fetch!(attributes, :stage)),
      state: human(Map.fetch!(attributes, :state)),
      summary: present(Map.fetch!(attributes, :summary)),
      title: present(Map.fetch!(attributes, :title)),
      tone: Map.get(attributes, :tone)
    }
  end

  defp metric(label, value, detail, tone \\ nil),
    do: %{detail: to_string(detail), label: label, tone: tone, value: to_string(value)}

  defp kernel_band(kind)
       when kind in [:input_admitted, :input_wait_started, :event_wait_started, :wait_resumed],
       do: :input

  defp kernel_band(:owner_transferred), do: :ready
  defp kernel_band(:result_accepted), do: :answer
  defp kernel_band(_kind), do: :outcome

  defp kernel_stage(:input_admitted), do: "Input"

  defp kernel_stage(kind) when kind in [:input_wait_started, :event_wait_started, :wait_resumed],
    do: "Wait"

  defp kernel_stage(:owner_transferred), do: "Custody"
  defp kernel_stage(:result_accepted), do: "Result"
  defp kernel_stage(:delivery_confirmed), do: "Delivery"
  defp kernel_stage(:reaction_recorded), do: "Feedback"
  defp kernel_stage(:episode_cancelled), do: "Cancellation"
  defp kernel_stage(_kind), do: "Lifecycle"

  defp kernel_title(kind), do: kind |> human() |> capitalize()

  defp kernel_summary(:input_admitted), do: "Message added to this request."

  defp kernel_summary(:owner_transferred),
    do: "The kernel transferred exclusive responsibility for the next transition."

  defp kernel_summary(:input_wait_started),
    do: "Work parked until a person supplies the requested information."

  defp kernel_summary(:event_wait_started),
    do: "Work parked until an exact event or deadline resumes it."

  defp kernel_summary(:wait_resumed),
    do: "The recorded wait matched and work became eligible again."

  defp kernel_summary(:result_accepted), do: "Responder accepted the host-validated result."

  defp kernel_summary(:delivery_confirmed),
    do: "Delivery was confirmed."

  defp kernel_summary(:episode_cancelled), do: "The episode reached a durable cancelled state."

  defp kernel_summary(:reaction_recorded),
    do: "Conversation feedback was recorded for the next logical turn."

  defp kernel_summary(_kind), do: "Durable lifecycle transition recorded."

  defp kernel_tone(kind) when kind in [:result_accepted, :delivery_confirmed, :wait_resumed],
    do: :good

  defp kernel_tone(:episode_cancelled), do: :warn
  defp kernel_tone(_kind), do: nil

  # Creating an offer/question is model work. Only a delivery receipt proves it was sent.
  defp record_band(kind)
       when kind in [
              "input_request",
              "event_wait",
              "task_offer",
              "publication_offer",
              "schedule_offer",
              "automation_change_offer",
              "memory_offer",
              "preference_offer",
              "guidance_offer",
              "standing_assignment_offer",
              "slack_post_offer",
              "emisar_approval"
            ],
       do: :work

  defp record_band(_kind), do: :work

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

  defp record_href(_record), do: nil

  defp coop_band(kind) when kind in ["turn", "candidate", "validation"], do: :work
  defp coop_band(_kind), do: :ready
  defp coop_title(kind), do: "Worker · #{human(kind)}"
  defp coop_summary(%{"state" => state}), do: "Worker reported #{human(state)}."
  defp coop_summary(_payload), do: "Bound worker event recorded."
  defp coop_tone(kind) when kind in ["candidate", "validation"], do: :good
  defp coop_tone(_kind), do: nil

  defp platform_action_title(:post_slack_message), do: "Additional message"
  defp platform_action_title(:set_slack_reaction), do: "Slack reaction"
  defp platform_action_title(:set_github_reaction), do: "GitHub reaction"
  defp platform_action_title(tool), do: human(tool)

  defp work_state(%Turn{remote_finished_at: nil}), do: "running"
  defp work_state(_turn), do: "finished"

  defp work_summary(%Turn{remote_finished_at: nil}),
    do: "The provider is still handling this turn."

  defp work_summary(_turn), do: "The provider finished and returned control to Responder."

  defp validation_summary("reject", [], _turn),
    do: "Responder rejected this candidate and requested a same-turn correction."

  defp validation_summary("reject", violations, _turn), do: Enum.join(violations, " ")

  defp validation_summary("accept", _violations, _turn),
    do: "The response passed the checks for this attempt."

  defp validation_summary(_verdict, _violations, _turn),
    do: "A candidate reached the host validation boundary."

  defp delivery_summary(%{"delivery" => "reply", "message" => message}) when is_binary(message),
    do: "Responder accepted this response for delivery."

  defp delivery_summary(%{"message" => message}) when is_binary(message),
    do: "Responder accepted this response for delivery."

  defp delivery_summary(%{"delivery" => "none", "decision_reason" => reason})
       when is_binary(reason),
       do: "No reply: " <> (reason |> redact_operator_text() |> bounded(240))

  defp delivery_summary(_document), do: "Accepted result recorded."

  defp delivery_confirmation(%{"message_ref" => "eval-message:" <> _}),
    do: "The private replay captured the response. Nothing was sent to Slack."

  defp delivery_confirmation(%{"transport" => "slack"}),
    do: "Slack transport confirmed the delivery."

  defp delivery_confirmation(%{"transport" => "control_plane"}),
    do: "Conversation Lab recorded the response."

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

  defp workspace_target(%{"repository" => repository}) when is_binary(repository), do: repository
  defp workspace_target(%{"primary" => %{"name" => name}}) when is_binary(name), do: name
  defp workspace_target(_task), do: nil

  defp source_text(%Entry{content: %{"text" => value}}) when is_binary(value),
    do: retained_text(value)

  defp source_text(%Entry{source_kind: "github", content: %{"payload" => payload}})
       when is_map(payload) do
    value =
      get_in(payload, ["comment", "body"]) || get_in(payload, ["review", "body"]) ||
        get_in(payload, ["issue", "body"]) || get_in(payload, ["pull_request", "body"])

    if is_binary(value), do: retained_text(value), else: nil
  end

  defp source_text(_input), do: nil

  defp source_attachments(%Entry{content: %{"files" => files}}) when is_list(files) do
    names =
      files
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [bounded(name, 128)]
        _file -> []
      end)
      |> Enum.take(5)

    [plural(length(files), "file"), Enum.join(names, " · ")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp source_attachments(_input), do: nil

  defp source_link(episode, events, inputs) do
    events
    |> Enum.find_value(fn event ->
      case event_input(event, inputs) do
        %Entry{} = input -> entry_source_link(episode, input)
        nil -> nil
      end
    end)
  end

  defp entry_source_link(
         %Episode{
           destination_conversation_ref: "slack:" <> conversation,
           destination_thread_ref: thread
         },
         %Entry{source_item_ref: message_ref}
       ) do
    with [_workspace, channel] <- String.split(conversation, ":", parts: 2),
         true <- slack_ref?(channel),
         true <- slack_timestamp?(message_ref) do
      stamp = "p" <> String.replace(message_ref, ".", "")
      base = "https://slack.com/archives/#{channel}/#{stamp}"

      href =
        if slack_timestamp?(thread) and thread != message_ref,
          do: base <> "?" <> URI.encode_query(%{"cid" => channel, "thread_ts" => thread}),
          else: base

      %{href: href, label: "Open source message", transport: "Slack"}
    else
      _invalid -> nil
    end
  end

  defp entry_source_link(
         %Episode{destination_conversation_ref: "control-plane:lab:" <> conversation_id},
         _input
       ) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, id} -> %{href: "/lab/#{id}", label: "Open source conversation", transport: "Lab"}
      :error -> nil
    end
  end

  defp entry_source_link(
         _episode,
         %Entry{
           source_kind: "github",
           source_item_ref: source_item_ref,
           content: %{"payload" => payload}
         }
       )
       when is_map(payload) do
    repository = get_in(payload, ["repository", "full_name"])
    number = get_in(payload, ["issue", "number"]) || get_in(payload, ["pull_request", "number"])
    comment_id = get_in(payload, ["comment", "id"])
    review_id = get_in(payload, ["review", "id"])
    pull? = is_map(get_in(payload, ["issue", "pull_request"]))

    github_source_link(repository, number, comment_id, review_id, source_item_ref, pull?)
  end

  defp entry_source_link(_episode, _input), do: nil

  defp review_state(%Episode{} = episode) do
    latest =
      Repo.one(
        from(review in EpisodeReview,
          where: review.episode_id == ^episode.id,
          order_by: [desc: review.semantic_version, desc: review.reviewed_at],
          limit: 1
        )
      )

    terminal = episode.state in [:complete, :cancelled]
    current = not is_nil(latest) and latest.semantic_version == episode.semantic_version

    %{
      actor_ref: latest && latest.actor_ref,
      at: latest && latest.reviewed_at,
      awaiting: terminal and not current,
      current: current,
      note: latest && latest.note,
      semantic_version: latest && latest.semantic_version
    }
  end

  defp operator_actions(episode, current_turn, review) do
    recovery =
      if current_blocked_turn?(episode, current_turn) and is_nil(current_turn.delivery_ref),
        do:
          WorkRecovery.project(
            current_turn,
            Custody.completed_workspace_recoverable(current_turn)
          )

    []
    |> maybe_action(
      recovery != nil and recovery.action == :retry,
      if(recovery, do: recovery.action_label, else: "Retry work"),
      "/actions/work/#{segment(episode.key)}/retry",
      :primary
    )
    |> maybe_action(
      resolvable?(episode, current_turn),
      "Close as no longer needed",
      "/actions/episode/#{segment(episode.key)}/resolve",
      :danger
    )
    |> maybe_action(
      review.awaiting,
      "Mark ending reviewed",
      "/actions/episode/#{segment(episode.key)}/review",
      :secondary
    )
  end

  defp current_blocked_turn?(
         %Episode{state: :working, owner_kind: :turn, owner_ref: ref},
         %Turn{status: :blocked, turn_ref: ref}
       ),
       do: true

  defp current_blocked_turn?(_episode, _turn), do: false

  defp maybe_action(actions, true, label, href, tone),
    do: actions ++ [%{href: href, label: label, tone: tone}]

  defp maybe_action(actions, false, _label, _href, _tone), do: actions

  defp resolvable?(%Episode{state: state}, _turn)
       when state in [:waiting_for_input, :waiting_for_event],
       do: true

  defp resolvable?(%Episode{state: :working, owner_kind: :turn}, %Turn{status: :blocked}),
    do: true

  defp resolvable?(_episode, _turn), do: false

  defp slack_ref?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value)

  defp slack_timestamp?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, value)

  defp github_repository?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value)

  defp github_source_link(
         repository,
         number,
         comment_id,
         _review_id,
         "github:pull_request_review_comment:" <> _item_id,
         _pull?
       ),
       do: github_comment_link(repository, number, comment_id, "pull", "discussion_r")

  defp github_source_link(
         repository,
         number,
         comment_id,
         _review_id,
         "github:issue_comment:" <> _item_id,
         true
       ),
       do: github_comment_link(repository, number, comment_id, "pull", "issuecomment-")

  defp github_source_link(
         repository,
         number,
         comment_id,
         _review_id,
         "github:issue_comment:" <> _item_id,
         false
       ),
       do: github_comment_link(repository, number, comment_id, "issues", "issuecomment-")

  defp github_source_link(
         repository,
         number,
         _comment_id,
         review_id,
         "github:pull_request_review:" <> _item_id,
         _pull?
       ),
       do: github_review_link(repository, number, review_id)

  defp github_source_link(
         _repository,
         _number,
         _comment_id,
         _review_id,
         _source_item_ref,
         _pull?
       ),
       do: nil

  defp github_comment_link(repository, number, comment_id, path, anchor) do
    if github_repository?(repository) and is_integer(number) and is_integer(comment_id) do
      %{
        href: "https://github.com/#{repository}/#{path}/#{number}##{anchor}#{comment_id}",
        label: "Open source comment",
        transport: "GitHub"
      }
    end
  end

  defp github_review_link(repository, number, review_id) do
    if github_repository?(repository) and is_integer(number) and is_integer(review_id) do
      %{
        href: "https://github.com/#{repository}/pull/#{number}#pullrequestreview-#{review_id}",
        label: "Open source review",
        transport: "GitHub"
      }
    end
  end

  defp retained_text(value) do
    "retained · #{byte_size(value)} bytes · sha256 #{value |> sha256() |> short_digest()} · content withheld"
  end

  defp redact_operator_text(value) do
    configured_secrets()
    |> Enum.reduce(value, &String.replace(&2, &1, "[redacted]"))
    |> String.replace(~r/(?i)\b(bearer\s+)[A-Za-z0-9._~+\/-]+/, "\\1[redacted]")
    |> String.replace(
      ~r/(?i)\b(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+/,
      "\\1=[redacted]"
    )
    |> String.replace(
      ~r/\b(?:xox[baprs]-|gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+/,
      "[redacted]"
    )
    |> scrub_embedded_urls()
  end

  defp scrub_embedded_urls(value) do
    Regex.replace(~r/https?:\/\/[^\s<>()]+/, value, fn url -> scrub_url(url) end)
  end

  defp configured_secrets do
    Application.get_all_env(:responder)
    |> Enum.flat_map(fn {_key, value} -> secret_values(value, false) end)
    |> Enum.filter(&(byte_size(&1) >= 8))
    |> Enum.uniq()
  end

  defp secret_values(value, _inherited?) when is_struct(value), do: []

  defp secret_values(%{} = value, inherited?) do
    Enum.flat_map(value, fn {key, nested} ->
      secret? = inherited? or sensitive_key?(key) or key in [:secrets, "secrets"]
      secret_values(nested, secret?)
    end)
  end

  defp secret_values(value, inherited?) when is_list(value),
    do: Enum.flat_map(value, &secret_values(&1, inherited?))

  defp secret_values(value, true) when is_binary(value), do: [value]
  defp secret_values(_value, _inherited?), do: []

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp session_summary(session, target) do
    case session.repository_ref || target do
      nil ->
        "No repository working copy was requested."

      repository ->
        "#{repository} was supplied by this input's configured work profile. Routing chooses the work class; it does not choose an arbitrary repository."
    end
  end

  defp next_action(%Episode{state: :waiting_for_input}, _turn), do: "operator input"
  defp next_action(%Episode{state: :waiting_for_event}, _turn), do: "external event"
  defp next_action(_episode, %Turn{status: :blocked}), do: "operator recovery"
  defp next_action(%Episode{owner_kind: :delivery}, _turn), do: "deliver result"
  defp next_action(%Episode{state: :complete}, _turn), do: "complete"
  defp next_action(%Episode{state: :cancelled}, _turn), do: "cancelled"
  defp next_action(_episode, nil), do: "start work"
  defp next_action(_episode, _turn), do: "continue work"

  defp compact_details(values) do
    values
    |> Enum.flat_map(fn
      {_label, nil} -> []
      {_label, ""} -> []
      {label, %DateTime{} = value} -> [%{label: label, value: DateTime.to_iso8601(value)}]
      {label, value} -> [%{label: label, value: bounded(to_string(value), 1_024)}]
    end)
    |> Enum.take(20)
  end

  defp bounded_strings(values) when is_list(values) do
    values |> Enum.filter(&is_binary/1) |> Enum.map(&bounded(&1, 512)) |> Enum.take(16)
  end

  defp bounded_strings(_values), do: []

  defp bounded(value, maximum) when byte_size(value) <= maximum, do: value
  defp bounded(value, maximum), do: String.slice(value, 0, maximum) <> "…"

  defp short_digest(value) when is_binary(value) and byte_size(value) > 12,
    do: binary_part(value, 0, 12) <> "…"

  defp short_digest(value) when is_binary(value), do: value
  defp short_digest(_value), do: nil

  defp join_ref(nil, nil), do: nil

  defp join_ref(kind, ref),
    do: [kind, ref] |> Enum.reject(&is_nil/1) |> Enum.map_join(":", &to_string/1)

  defp elapsed(%DateTime{} = left, %DateTime{} = right),
    do: format_ms(max(DateTime.diff(right, left, :millisecond), 0))

  defp elapsed(_left, _right), do: "unmeasured"

  defp relative(%DateTime{} = at, %DateTime{} = started_at),
    do: "+" <> format_ms(max(DateTime.diff(at, started_at, :millisecond), 0))

  defp relative(_at, _started_at), do: nil

  defp time_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp time_key(_value), do: 9_223_372_036_854_775_807

  defp format_ms(nil), do: nil
  defp format_ms(value) when value < 1_000, do: "#{value} ms"
  defp format_ms(value) when value < 60_000, do: format_decimal(value / 1_000, "s")
  defp format_ms(value) when value < 3_600_000, do: format_decimal(value / 60_000, "m")
  defp format_ms(value), do: format_decimal(value / 3_600_000, "h")

  defp format_decimal(value, suffix) do
    number =
      :erlang.float_to_binary(value, decimals: 1)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    number <> suffix
  end

  defp format_integer(value),
    do:
      Integer.to_string(value)
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(value, noun), do: "#{value} #{noun}s"

  defp human(nil), do: "unrecorded"
  defp human(value) when is_atom(value), do: value |> Atom.to_string() |> human()
  defp human(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp human(value), do: to_string(value)

  defp capitalize(value), do: String.capitalize(value)

  defp present(nil), do: nil
  defp present(value), do: bounded(to_string(value), 2_000)

  defp state_tone(state)
       when state in [:blocked, "blocked", :failed, "failed", :superseded, "superseded"], do: :bad

  defp state_tone(state)
       when state in [
              :complete,
              "complete",
              :settled,
              "settled",
              :delivered,
              "delivered",
              :published,
              "published",
              :ready,
              "ready",
              :active,
              "active"
            ],
       do: :good

  defp state_tone(state)
       when state in [
              :waiting_for_input,
              :waiting_for_event,
              :cancelled,
              :cancel_pending,
              :pending,
              :review_pending,
              :publish_pending
            ],
       do: :warn

  defp state_tone(_state), do: nil

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end

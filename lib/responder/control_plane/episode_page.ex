defmodule Responder.ControlPlane.EpisodePage do
  alias Responder.Accounting.Pricing
  alias Responder.ControlPlane.SlackMarkdown

  @moduledoc "One chronological case file: conversation, model requests, host decisions and delivery."
  use Phoenix.Component
  import Responder.ControlPlane.Components
  alias Responder.ControlPlane.{EpisodeRequest, EpisodeTrace}

  def render(assigns) do
    assigns = assign_new(assigns, :timeline, fn -> %{items: [], truncated: false} end)
    assigns = assign(assigns, :startup, assigns.snapshot.trace[:startup])

    assigns =
      assign(
        assigns,
        :related,
        assigns.snapshot[:related_episodes] || %{items: [], truncated: false}
      )

    assigns = assign(assigns, :chapters, chapters(assigns.snapshot, assigns.timeline))

    ~H"""
    <div class="episode-workbench execution-document">
      <div class="episode-page-intro">
        <.link navigate="/" class="back-to-activity">← Activity</.link>
        <div class="episode-title-row">
          <h1>{@snapshot.trace.case_file.title}</h1><.status state={
            if(@startup, do: "not_started", else: to_string(@snapshot.episode.state))
          } />
        </div>
        <p class="episode-location">
          <span :if={@snapshot.trace.case_file.repository}>{@snapshot.trace.case_file.repository}</span>
          <time>{timestamp(@snapshot.trace.received_at)}</time>
          <a :if={@snapshot.trace.source} href={@snapshot.trace.source.href} rel="noopener noreferrer">{@snapshot.trace.source.label} →</a>
          <a
            :if={@snapshot.episode[:conversation_ref]}
            href={
              Responder.ControlPlane.Activity.conversation_path(
                @snapshot.episode.transport,
                @snapshot.episode.conversation_ref
              )
            }
          >All activity in this conversation →</a>
          <a
            :if={@snapshot.episode[:transport] == "slack" && @snapshot.episode[:thread_ref]}
            href={
              Responder.ControlPlane.Activity.conversation_path(
                @snapshot.episode.transport,
                @snapshot.episode.conversation_ref,
                @snapshot.episode.thread_ref
              )
            }
          >This Slack thread →</a>
        </p>
      </div>
      <section :if={@startup} class="task-start-failure" aria-labelledby="task-start-heading">
        <h2 id="task-start-heading">{@snapshot.trace.stopped.headline}</h2>
        <p :if={@startup.confirmed}>Your confirmation was received.</p>
        <p>{@snapshot.trace.stopped.reason}</p>
        <p class="task-start-facts">No files changed. No checks ran. No task reply was sent.</p>
        <p>{@snapshot.trace.stopped.action}</p>
        <nav class="task-start-actions" aria-label="Task resolution">
          <a href={@snapshot.trace.stopped.href} class="ui-button primary">View required setup</a>
          <.action_button
            :for={action <- @snapshot.trace.actions}
            path={action.href}
            label={action.label}
            tone={action.tone}
          />
        </nav>
      </section>
      <section :if={@startup} class="task-start-history" aria-label="Task history">
        <h2>What happened</h2>
        <ol>
          <li :for={event <- @startup.events}>
            <time>{timestamp(event.at)}</time>
            <a :if={event.href} href={event.href}>{event.label} →</a>
            <span :if={!event.href}>{event.label}</span>
          </li>
        </ol>
      </section>
      <dl :if={!@startup} class="episode-metrics">
        <div>
          <dt title="First message to the latest recorded change">Elapsed</dt><dd>
            {elapsed(@snapshot)}
          </dd>
        </div>
        <div>
          <dt>Model cost</dt><dd>{cost(@snapshot[:accounting])}</dd>
        </div>
        <div>
          <dt>Work turns</dt><dd>{metric(@snapshot.trace.metrics, "Turns")}</dd>
        </div>
        <div>
          <dt>Tool calls</dt><dd>{metric(@snapshot.trace.metrics, "Tool calls")}</dd>
        </div>
      </dl>
      <section
        :if={!@startup && @related.items != []}
        class="episode-follow-through"
        aria-label="Related episode history"
      >
        <h2>Related episode history</h2>
        <p>
          These are linked records, not merged episodes. Each retains its original inputs and delivery receipts.
        </p>
        <ul>
          <li :for={item <- @related.items}>
            <a href={item.href}>{item.relation} · {item.title} · {timestamp(item.at)} →</a>
            <.status state={to_string(item.state)} />
          </li>
        </ul>
        <p :if={@related.truncated}>
          Showing the first 20 linked episodes.
          <a href={
            Responder.ControlPlane.Activity.conversation_path(
              @snapshot.episode.transport,
              @snapshot.episode.conversation_ref
            )
          }>Browse all activity in this conversation →</a>
        </p>
      </section>
      <section :if={@snapshot.trace.case_file[:expired_at]} class="story-stop">
        <h2>Older request details expired</h2>
        <p>
          Saved content was removed by retention on {timestamp(@snapshot.trace.case_file.expired_at)}. The remaining timeline still shows when the request ran and finished.
        </p>
      </section>
      <nav :if={!@startup} class="case-actions" aria-label="Execution actions">
        <a href={if(@requests, do: base(@snapshot), else: "") <> outcome_anchor(@snapshot)}>Jump to latest outcome ↓</a>
        <.action_button
          :for={action <- @snapshot.trace.actions}
          path={action.href}
          label={action.label}
          tone={action.tone}
        />
      </nav>
      <section :if={@snapshot.trace.stopped && !@startup} class="story-stop">
        <p class="ui-eyebrow">NEXT ACTION</p><h3>{@snapshot.trace.stopped.headline}</h3>
        <p>{@snapshot.trace.stopped.reason}</p><strong>{@snapshot.trace.stopped.action}</strong>
        <details :if={@snapshot.trace.stopped[:model_output]} class="recovery-worker-report">
          <summary>Worker’s saved response</summary>
          <p class="recovery-attribution">
            {@snapshot.trace.stopped[:delivery]} This is the worker’s report, not an independently verified check result.
          </p>
          <div class="recovery-model-output">
            {Phoenix.HTML.raw(SlackMarkdown.preview(@snapshot.trace.stopped.model_output))}
          </div>
        </details>
        <a
          :if={@snapshot.trace.stopped.href}
          class="ui-button secondary"
          href={@snapshot.trace.stopped.href}
        >{@snapshot.trace.stopped[:link_label] || "Open recovery"} <.icon name={:arrow} /></a>
        <details :if={@snapshot.trace.stopped.attempted != []}>
          <summary>Already attempted</summary><ul>
            <li :for={attempt <- @snapshot.trace.stopped.attempted}>{attempt}</li>
          </ul>
        </details>
      </section>
      <section
        :if={(@snapshot.trace[:follow_through] || []) != []}
        class="episode-follow-through"
        aria-label="Current follow-up status"
      >
        <h2>Follow-up status <small>Current</small></h2>
        <ul>
          <li :for={item <- @snapshot.trace.follow_through}>
            <div><strong>{item.title}</strong><span>{item.state}</span></div>
            <p :if={item.error}>Error: {item.error}</p>
            <a :if={item.href} href={item.href}>{item.link_label} →</a>
          </li>
        </ul>
      </section>
      <p :if={@requests}><.link patch={base(@snapshot)}>← Back to the timeline</.link></p>
      <details :if={@requests} open class="specific-request">
        <summary>Selected model call · exact retained artifact</summary>
        <Responder.ControlPlane.RequestPage.render
          view={@requests}
          params={@params}
          path={base(@snapshot) <> "/model-calls"}
        />
      </details>
      <.execution_timeline
        :if={!@requests && !@startup}
        snapshot={@snapshot}
        timeline={@timeline}
        chapters={@chapters}
      />
      <details class="story-identity">
        <summary>Technical details &amp; review history</summary>
        <.execution_timeline
          :if={!@requests && @startup}
          snapshot={@snapshot}
          timeline={@timeline}
          chapters={@chapters}
        />
        <.link patch={base(@snapshot) <> "/model-calls"}>Model calls →</.link>
        <p>{coverage(@snapshot[:accounting])}</p>
        <p :if={@snapshot.trace.review[:note] not in [nil, ""]}>
          {@snapshot.trace.review[:note]
          |> Responder.ControlPlane.InspectionRedactor.artifact(max_bytes: 2_048)
          |> Map.fetch!(:text)}
        </p>
        <dl>
          <dt>Episode</dt><dd>{@snapshot.episode.ref}</dd><dt>Destination</dt><dd>
            {@snapshot.episode.destination}
          </dd>
          <dt>Created</dt><dd>{timestamp(@snapshot.episode.created_at)}</dd><dt>Reviewed</dt><dd>
            {timestamp(@snapshot.trace.review[:at])}
          </dd>
        </dl>
      </details>
    </div>
    """
  end

  @doc """
  The phases this page renders, grouped by the durable owner of each step.

  Exposed so the grouping can be asserted without going through HTML: which
  turn a receipt belongs to is a projection fact, not a rendering detail.
  """
  def chapters(snapshot, timeline) do
    snapshot
    |> entries(timeline)
    |> separate_routing()
    |> EpisodeTrace.chapters(snapshot.trace.received_at, snapshot.trace.causality)
    |> execution_phases()
  end

  defp execution_timeline(assigns) do
    ~H"""
    <section
      class="case-timeline"
      id="execution-timeline"
      aria-label="Complete execution timeline"
    >
      <h2 class="sr-only">Execution timeline</h2>
      <p :if={@snapshot.trace.history.truncated || @timeline.truncated} class="timeline-bound">
        History is bounded. Older model calls are available under “Model calls” in the technical record below. Long artifacts are labeled when truncated.
      </p>
      <section
        :for={{chapter, index} <- Enum.with_index(@chapters, 1)}
        class={"trace-chapter phase-#{chapter.band} #{if chapter.starts_conversation, do: "conversation-boundary"}"}
        data-conversation-turn={chapter.conversation_turn}
        aria-labelledby={"chapter-#{index}"}
      >
        <div class="chapter-heading">
          <span class="phase-number" aria-hidden="true">{phase_number(chapter.band)}</span>
          <div class="chapter-description">
            <p
              :if={chapter.starts_conversation && chapter.conversation_turn > 1}
              class="turn-divider-label"
            >
              Message {chapter.conversation_turn}
            </p>
            <h3 id={"chapter-#{index}"}>{chapter_title(chapter)}</h3>
            <p :if={turn_association(chapter)} class="turn-association">
              {turn_association(chapter)}
            </p>
            <p>{chapter_description(chapter.band)}</p>
          </div>
          <span :if={chapter.span} class="chapter-span" title="Time since the first message">{chapter_span(
            chapter,
            @snapshot.trace.received_at
          )} from start</span>
        </div>
        <div class="phase-entries">
          <.entry :for={entry <- chapter.steps} entry={entry} />
        </div>
      </section>
      <div id="latest-outcome" class="case-outcome">
        <div
          :if={@snapshot.trace.case_file.awaiting_reply && !@snapshot.trace[:startup]}
          class="story-wait"
        >
          <span class="pulse-dot"></span><div>
            <strong>{pending_answer_label(@snapshot)}</strong><p>{@snapshot.episode.next_action}</p>
          </div>
        </div>
        <a href="#execution-timeline">Back to start ↑</a>
      </div>
    </section>
    """
  end

  # Routing has its own model call. The work briefing belongs to the following
  # work phase, so preparation does not restart after routing has finished.
  defp separate_routing(entries) do
    Enum.map(entries, fn
      %{kind: :request, source_kind: :admission} = entry ->
        %{entry | band: :routing}

      %{kind: :request, source_kind: :work, band: :ready} = entry ->
        %{entry | band: :work}

      %{kind: :event, band: :ready, step: %{stage: stage}} = entry
      when stage in ["Preparation", "Routing"] ->
        %{entry | band: :work}

      entry ->
        entry
    end)
  end

  # Establish message boundaries before merging input into setup. Only adjacent
  # phases merge: a follow-up never moves ahead of work that already happened.
  defp execution_phases(chapters) do
    chapters
    |> Enum.map(&%{&1 | band: phase_band(&1.band)})
    |> Enum.chunk_by(&{&1.band, &1.conversation_turn})
    |> Enum.map(fn [first | _] = group ->
      owners = group |> Enum.flat_map(& &1.owners) |> Enum.uniq()
      turns = Enum.filter(owners, &match?({:turn, _id}, &1))

      %{
        first
        | steps: Enum.flat_map(group, & &1.steps),
          owners: owners,
          # Merging two turns into one phase would put one turn's name on
          # another turn's receipts, so a merged phase keeps no turn identity.
          turn: if(match?([_one], turns), do: Enum.find_value(group, & &1.turn)),
          starts_conversation: Enum.any?(group, & &1.starts_conversation)
      }
    end)
  end

  # Only say what the recorded association actually explains: a turn built from
  # several inputs, or one that continues earlier work. Everything else is
  # noise on a single-message request.
  defp turn_association(%{turn: %{kind: :turn} = turn}) do
    parts =
      [input_association(turn.inputs), continuation(turn.continues)]
      |> Enum.reject(&is_nil/1)

    if parts != [], do: "#{turn.label} · " <> Enum.join(parts, " · ")
  end

  defp turn_association(_chapter), do: nil

  defp input_association(:not_recorded), do: "Selected inputs not recorded"
  defp input_association(ordinals) when length(ordinals) < 2, do: nil

  defp input_association(ordinals),
    do: "Inputs: " <> Enum.map_join(ordinals, " + ", &"Message #{&1}")

  defp continuation(nil), do: nil
  defp continuation(ordinal), do: "Continues Turn #{ordinal}"

  defp phase_band(:input), do: :ready
  defp phase_band(:outcome), do: :answer
  defp phase_band(band), do: band

  defp entry(assigns) do
    ~H"""
    <article
      id={@entry.id}
      class={"case-entry case-#{@entry.kind} #{if compact_entry?(@entry), do: "case-checkpoint"}"}
      data-entry-kind={@entry.kind}
    >
      <div class="case-entry-time">
        <time title={timestamp(@entry.at)}>{clock_time(@entry.at)}</time>
      </div>
      <div class="case-entry-body">
        <.message :if={@entry.kind == :message} message={@entry.message} />
        <Responder.ControlPlane.ToolCard.render
          :if={@entry.kind == :event && @entry.step.stage == "Tool call"}
          step={@entry.step}
        />
        <.event :if={@entry.kind == :event && @entry.step.stage != "Tool call"} step={@entry.step} />
        <EpisodeRequest.render :if={@entry.kind == :request} request={@entry} />
      </div>
    </article>
    """
  end

  defp message(assigns) do
    ~H"""
    <div class="story-byline">
      <strong title={@message[:actor_ref]}>{@message[:display_actor] || @message.actor}</strong><span :if={
        @message[:status]
      }>{@message.status}</span>
    </div>
    <p :if={@message[:response_reference]} class="response-reference">
      <a href={@message.response_reference}>View response ↑</a>
    </p>
    <div :if={!@message[:response_reference]} class="case-message-text markdown-preview">
      {message_text(@message)}
    </div>
    """
  end

  defp message_text(%{available: false}), do: "Source content not recorded or expired"

  defp message_text(%{transport: "slack", workspace: workspace, text: text}) when is_binary(text),
    do: text |> SlackMarkdown.preview(workspace) |> Phoenix.HTML.raw()

  defp message_text(message), do: message.text |> SlackMarkdown.preview() |> Phoenix.HTML.raw()

  defp event(assigns) do
    ~H"""
    <div class="case-event-content">
      <div class="case-event-heading">
        <h3>{event_title(@step)}</h3><span
          :if={show_event_state?(@step)}
          class={"event-state tone-#{@step.tone}"}
        >{label(@step.state)}</span>
        <span :if={@step.duration_ms}>{duration(@step.duration_ms)}</span>
      </div>
      <p :if={@step.summary && @step.summary != event_title(@step)} class="case-event-summary">
        {@step.summary}
      </p>
      <p :if={@step[:current_warning]} class="action-error">
        <strong>Current scheduling status:</strong> {@step.current_warning}
      </p>
      <div :if={@step[:candidate_response]} class="candidate-evidence">
        <Responder.ControlPlane.RequestPage.candidate_response
          :if={
            @step.candidate_response.artifact &&
              @step.candidate_response.artifact.state in [:retained, :expired]
          }
          response={@step.candidate_response.artifact}
          attempt={@step.candidate_response.attempt}
          prefix={@step.candidate_response.prefix}
        />
        <p :if={!@step.candidate_response.artifact}>
          <a href={@step.candidate_response.href}>Inspect response for attempt {@step.candidate_response.attempt} →</a>
        </p>
        <p
          :if={
            @step.candidate_response.artifact &&
              @step.candidate_response.artifact.state == :not_recorded
          }
          class="artifact-unavailable"
        >
          Response body not retained for this attempt. Its check receipt is preserved here.
        </p>
      </div>
      <div :if={(@step[:artifacts] || []) != []} class="tool-evidence">
        <details
          :for={{item, index} <- Enum.with_index(@step.artifacts)}
          id={"tool-evidence-#{@step.id}-#{index}"}
        >
          <summary>
            {item.label}<span :if={item.artifact.truncated}> · Partial display</span><span :if={
              item.artifact.redacted
            }> · Secrets redacted</span>
          </summary>
          <pre>{item.artifact.text}</pre>
        </details>
      </div>
      <details
        :if={@step.details != [] || @step.href}
        class="case-event-details"
        id={"event-detail-#{@step.id}"}
      >
        <summary>{if @step.stage == "Tool call", do: "Call metadata", else: "Details"}</summary><.event_details step={
          @step
        } />
      </details>
    </div>
    """
  end

  defp event_details(assigns) do
    ~H"""
    <a :if={@step.href} href={@step.href}>Inspect related record →</a>
    <dl class="event-facts">
      <div :for={detail <- @step.details}>
        <dt>{detail.label}</dt><dd>{detail.value}</dd>
      </div>
    </dl>
    """
  end

  defp bookkeeping?(step),
    do:
      step.tone not in [:bad, :warn] and
        not silent_result?(step) and
        step.stage in ["Preparation", "Routing", "Input", "Result", "Delivery", "Validation"]

  defp compact_entry?(%{kind: :event, step: step}), do: bookkeeping?(step)
  defp compact_entry?(_), do: false

  defp show_event_state?(step),
    do:
      step.state not in [nil, ""] &&
        step.stage not in ["Preparation", "Execution", "Evidence"] &&
        String.downcase(label(step.state)) != String.downcase(event_title(step))

  defp event_title(%{stage: "Tool call", title: "Tool call", summary: summary})
       when is_binary(summary), do: summary

  defp event_title(step), do: if(silent_result?(step), do: "No reply sent", else: step.title)

  defp silent_result?(%{stage: "Result", details: details}),
    do: Enum.any?(details, &(&1.label == "Delivery" && &1.value == "none"))

  defp silent_result?(_step), do: false

  defp chapter_title(%{band: :ready, conversation_turn: turn}) when turn > 1,
    do: "New input received"

  defp chapter_title(%{band: :ready}), do: "Getting ready"
  defp chapter_title(%{band: :routing}), do: "Routing"
  defp chapter_title(%{band: :work}), do: "The work"
  defp chapter_title(%{band: :answer}), do: "The answer"
  defp chapter_title(chapter), do: chapter.title

  defp phase_number(:ready), do: "01"
  defp phase_number(:routing), do: "02"
  defp phase_number(:work), do: "03"
  defp phase_number(:answer), do: "04"

  defp chapter_description(:ready),
    do: "The message and context that started this part of the conversation."

  defp chapter_description(:routing),
    do:
      "The model call that decides whether to respond, continue earlier work, or leave the message alone."

  defp chapter_description(:work),
    do: "The model's briefing, progress, tool calls, and results."

  defp chapter_description(:answer),
    do: "What the model returned and what Responder decided to do."

  defp metric(metrics, label) do
    case Enum.find(metrics, &(&1.label == label)) do
      nil -> "—"
      metric -> metric.value
    end
  end

  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  defp entries(snapshot, timeline) do
    record_links =
      for step <- snapshot.trace.steps,
          step[:record_ref],
          into: %{},
          do: {step.record_ref, %{href: "#event-#{step.id}", title: step.title}}

    requests = Enum.map(timeline.items, &Map.put(&1, :record_links, record_links))

    messages =
      Enum.map(snapshot.trace.case_file.conversation, fn message ->
        %{
          id: "story-message-#{message.id}",
          owner: message[:owner] || :episode,
          at: message.at,
          kind: :message,
          message: Map.put(message, :response_reference, response_reference(message, requests)),
          band: if(message.actor == "Responder", do: :outcome, else: :input)
        }
      end)

    copies = visible_copies(snapshot.trace.steps, messages, timeline.items)

    responses =
      for request <- requests,
          section <- request.sections,
          {id, response} <- section[:response_links] || %{},
          into: %{},
          do: {id, response}

    steps =
      snapshot.trace.steps
      |> Enum.reject(&redundant_step?(&1, copies))
      |> Enum.map(fn step ->
        %{
          id: "event-#{step.id}",
          owner: step[:owner] || :episode,
          at: step.at,
          kind: :event,
          step: Map.put(step, :candidate_response, responses[step.id]),
          band: step.band
        }
      end)

    # Stable sort preserves the trace's numeric sequence/lifecycle ordering on ties.
    Enum.sort_by(messages ++ steps ++ requests, &unix(&1.at || &1[:sort_at]))
  end

  # A receipt may point back to this turn's exact response; a changed, missing or
  # truncated candidate must never hide what actually reached the conversation.
  defp response_reference(message, requests) do
    if delivered_message?(message) do
      id = "request-#{message.id}-result"

      with %{sections: sections} <- Enum.find(requests, &(&1.id == id)),
           %{artifact: %{state: :retained, truncated: false, text: text}} <-
             Enum.find(sections, &(&1.id == "candidate")),
           {:ok, %{"message" => body}} when is_binary(body) <- Jason.decode(text),
           true <- body == message.text do
        "##{id}"
      else
        _ -> nil
      end
    end
  end

  defp visible_copies(steps, messages, requests) do
    input_ids = for %{message: message} <- messages, message.actor != "Responder", do: message.id

    delivery_refs =
      for %{message: message} <- messages,
          delivered_message?(message),
          do: message.delivery_ref

    confirmed_delivery_refs =
      for %{id: "turn-" <> _, stage: "Delivery", state: "delivered", delivery_ref: ref} <- steps,
          is_binary(ref) && ref != "",
          do: ref

    briefing_ids =
      for %{phase: :submission, source_kind: :work} = item <- requests, do: item.id

    result_refs =
      for step <- steps,
          String.starts_with?(step.id, "turn-") && step.stage == "Result" && step[:result_ref],
          do: step.result_ref

    %{
      input_ids: input_ids,
      result_refs: result_refs,
      delivery_refs: delivery_refs,
      confirmed_delivery_refs: confirmed_delivery_refs,
      briefing_ids: briefing_ids
    }
  end

  defp delivered_message?(message),
    do:
      message.actor == "Responder" && message[:delivery_ref] &&
        (message[:delivered] || message[:status] == "Response sent")

  defp redundant_step?(%{state: "input admitted"} = step, copies),
    do: step[:input_id] in copies.input_ids

  defp redundant_step?(%{state: "result accepted"} = step, copies),
    do: step[:result_ref] in copies.result_refs

  # The message body can expire independently of its delivery receipt. Keep the
  # exact turn receipt and hide only its matching kernel lifecycle confirmation.
  defp redundant_step?(%{stage: "Delivery", state: "delivery confirmed"} = step, copies),
    do:
      step[:delivery_ref] in copies.delivery_refs ||
        (String.starts_with?(step.id, "kernel-") &&
           step[:delivery_ref] in copies.confirmed_delivery_refs)

  defp redundant_step?(%{stage: "Delivery", state: "delivered"} = step, copies),
    do: step[:delivery_ref] in copies.delivery_refs

  defp redundant_step?(step, copies),
    do:
      String.ends_with?(step.id, "-prepared") &&
        String.replace(step.id, ~r/^turn-(.*)-prepared$/, "request-\\1") in copies.briefing_ids

  defp unix(nil), do: 9_223_372_036_854_775_807
  defp unix(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> unix()
  defp unix(at), do: DateTime.to_unix(at, :microsecond)
  defp clock_time(nil), do: "Not recorded"
  defp clock_time(at), do: Calendar.strftime(at, "%H:%M:%S")
  defp base(snapshot), do: "/timeline/" <> URI.encode_www_form(snapshot.episode.ref)
  defp pending_answer_label(%{episode: %{state: :cancelled}}), do: "Stopped"
  defp pending_answer_label(%{episode: %{state: :complete}}), do: "No further reply was sent"
  defp pending_answer_label(%{trace: %{stopped: %{headline: headline}}}), do: headline
  defp pending_answer_label(%{trace: %{case_file: %{reply: nil}}}), do: "No visible answer yet"
  defp pending_answer_label(_), do: "Follow-up in progress"

  defp outcome_anchor(snapshot) do
    if snapshot.trace.case_file.awaiting_reply do
      "#latest-outcome"
    else
      accepted_outcome_anchor(snapshot)
    end
  end

  defp accepted_outcome_anchor(snapshot) do
    decision =
      snapshot.trace.steps
      |> Enum.reverse()
      |> Enum.find(fn step ->
        step.stage == "Result" && Enum.any?(step.details, &(&1.label == "Delivery"))
      end)

    reply =
      snapshot.trace.case_file.conversation
      |> Enum.reverse()
      |> Enum.find(&(&1.actor == "Responder"))

    cond do
      decision && silent_result?(decision) ->
        "#event-#{decision.id}"

      decision && (is_nil(reply) || decision.id != "turn-#{reply.id}-accepted") ->
        "#event-#{decision.id}"

      reply ->
        "#story-message-#{reply.id}"

      true ->
        "#latest-outcome"
    end
  end

  defp elapsed(%{trace: %{received_at: nil}}), do: "Not recorded"

  defp elapsed(snapshot) do
    latest =
      [snapshot.episode.updated_at | Enum.map(snapshot.trace.steps, & &1.at)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&unix/1)
      |> Enum.max(fn -> unix(snapshot.trace.received_at) end)

    seconds = max(div(latest - unix(snapshot.trace.received_at), 1_000_000), 0)

    if seconds == 0, do: "< 1s", else: duration_seconds(seconds)
  end

  defp chapter_span(chapter, started) do
    times =
      chapter.steps
      |> Enum.flat_map(fn entry -> [entry.at, get_in(entry, [:routing_result, :at])] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&unix/1)

    offsets =
      [List.first(times), List.last(times)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&("+" <> duration_seconds(max(div(unix(&1) - unix(started), 1_000_000), 0))))
      |> Enum.uniq()

    Enum.join(offsets, " → ")
  end

  defp duration_seconds(0), do: "0s"

  defp duration_seconds(seconds) do
    [{div(seconds, 3600), "h"}, {div(rem(seconds, 3600), 60), "m"}, {rem(seconds, 60), "s"}]
    |> Enum.reject(fn {count, _} -> count == 0 end)
    |> Enum.map_join(" ", fn {count, unit} -> "#{count}#{unit}" end)
  end

  defp cost(%{costed: _} = totals), do: Pricing.amount(totals)

  defp cost(_), do: "Cost not reported"

  defp coverage(%{costed: costed, attempts: attempts} = totals),
    do: "#{costed} reported · #{Map.get(totals, :estimated, 0)} estimated / #{attempts} requests"

  defp coverage(_), do: "No price estimate substituted"
end

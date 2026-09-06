defmodule Responder.ControlPlane.EpisodePage do
  alias Responder.Accounting.Pricing
  alias Responder.ControlPlane.SlackMarkdown

  @moduledoc "One chronological case file: conversation, model requests, host decisions and delivery."
  use Phoenix.Component
  import Responder.ControlPlane.Components
  alias Responder.ControlPlane.{EpisodeRequest, EpisodeTrace}

  def render(assigns) do
    assigns = assign_new(assigns, :timeline, fn -> %{items: [], truncated: false} end)

    chapters =
      assigns.snapshot
      |> entries(assigns.timeline)
      |> separate_routing()
      |> EpisodeTrace.chapters(assigns.snapshot.trace.received_at)
      |> execution_phases()

    assigns = assign(assigns, :chapters, chapters)

    ~H"""
    <div class="episode-workbench execution-document">
      <div class="episode-page-intro">
        <.link navigate="/" class="back-to-activity">← Activity</.link>
        <div class="episode-title-row">
          <h1>{@snapshot.trace.case_file.title}</h1><.status state={
            to_string(@snapshot.episode.state)
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
          >All requests in this conversation →</a>
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
      <dl class="episode-metrics">
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
      <section :if={@snapshot.trace.case_file[:expired_at]} class="story-stop">
        <h2>Older request details expired</h2>
        <p>
          Saved content was removed by retention on {timestamp(@snapshot.trace.case_file.expired_at)}. The remaining timeline still shows when the request ran and finished.
        </p>
      </section>
      <nav class="case-actions" aria-label="Execution actions">
        <a href={outcome_anchor(@snapshot)}>Jump to latest outcome ↓</a>
        <.action_button
          :for={action <- @snapshot.trace.actions}
          path={action.href}
          label={action.label}
          tone={action.tone}
        />
      </nav>
      <section :if={@snapshot.trace.stopped} class="story-stop">
        <p class="ui-eyebrow">NEXT ACTION</p><h3>{@snapshot.trace.stopped.headline}</h3>
        <p>{@snapshot.trace.stopped.reason}</p><strong>{@snapshot.trace.stopped.action}</strong>
        <a
          :if={@snapshot.trace.stopped.href}
          class="ui-button secondary"
          href={@snapshot.trace.stopped.href}
        >Open recovery <.icon name={:arrow} /></a>
        <details :if={@snapshot.trace.stopped.attempted != []}>
          <summary>Already attempted</summary><ul>
            <li :for={attempt <- @snapshot.trace.stopped.attempted}>{attempt}</li>
          </ul>
        </details>
      </section>
      <details :if={@requests} open class="specific-request">
        <summary>Selected request · exact retained artifact</summary>
        <Responder.ControlPlane.RequestPage.render
          view={@requests}
          params={@params}
          path={base(@snapshot) <> "/requests"}
        />
      </details>
      <section class="case-timeline" id="execution-timeline" aria-label="Complete execution timeline">
        <h2 class="sr-only">Execution timeline</h2>
        <p :if={@snapshot.trace.history.truncated || @timeline.truncated} class="timeline-bound">
          History is bounded. Older model requests are available under “All model requests” in the technical record below. Long artifacts are labeled when truncated.
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
          <div :if={@snapshot.trace.case_file.awaiting_reply} class="story-wait">
            <span class="pulse-dot"></span><div>
              <strong>{pending_answer_label(@snapshot)}</strong><p>{@snapshot.episode.next_action}</p>
            </div>
          </div>
          <a href="#execution-timeline">Back to start ↑</a>
        </div>
      </section>
      <details class="story-identity">
        <summary>Technical record & review history</summary>
        <.link patch={base(@snapshot) <> "/requests"}>All model requests →</.link>
        <p>{coverage(@snapshot[:accounting])}</p>
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
      %{
        first
        | steps: Enum.flat_map(group, & &1.steps),
          starts_conversation: Enum.any?(group, & &1.starts_conversation)
      }
    end)
  end

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
        <.event :if={@entry.kind == :event} step={@entry.step} />
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
    <div class="case-message-text markdown-preview">{message_text(@message)}</div>
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
      (step.stage != "Preparation" || step.tone in [:bad, :warn]) &&
        String.downcase(label(step.state)) != String.downcase(event_title(step))

  defp event_title(%{stage: "Tool call", title: "Tool call", summary: summary})
       when is_binary(summary), do: summary

  defp event_title(step), do: if(silent_result?(step), do: "No reply sent", else: step.title)

  defp silent_result?(%{stage: "Result", details: details}),
    do: Enum.any?(details, &(&1.label == "Delivery" && &1.value == "none"))

  defp silent_result?(_step), do: false

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
    messages =
      Enum.map(snapshot.trace.case_file.conversation, fn message ->
        %{
          id: "story-message-#{message.id}",
          at: message.at,
          kind: :message,
          message: message,
          band: if(message.actor == "Responder", do: :outcome, else: :input)
        }
      end)

    steps =
      Enum.map(snapshot.trace.steps, fn step ->
        %{id: "event-#{step.id}", at: step.at, kind: :event, step: step, band: step.band}
      end)

    # Stable sort preserves the trace's numeric sequence/lifecycle ordering on ties.
    Enum.sort_by(messages ++ steps ++ timeline.items, &unix(&1.at))
  end

  defp unix(nil), do: 0
  defp unix(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> unix()
  defp unix(at), do: DateTime.to_unix(at, :microsecond)
  defp clock_time(nil), do: "Not recorded"
  defp clock_time(at), do: Calendar.strftime(at, "%H:%M:%S")
  defp base(snapshot), do: "/episodes/" <> URI.encode_www_form(snapshot.episode.ref)
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
      Enum.max([unix(snapshot.episode.updated_at) | Enum.map(snapshot.trace.steps, &unix(&1.at))])

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

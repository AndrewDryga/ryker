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
      |> Enum.map(fn entry ->
        if entry.band == :outcome, do: %{entry | band: :answer}, else: entry
      end)
      |> EpisodeTrace.chapters(assigns.snapshot.trace.received_at)

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
          <dt>Executions</dt><dd>{get_in(@snapshot, [:accounting, :attempts]) || "—"}</dd>
        </div>
        <div>
          <dt>Tool calls</dt><dd>{metric(@snapshot.trace.metrics, "Tool calls")}</dd>
        </div>
      </dl>
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
        <div class="story-section-heading">
          <h2>Execution timeline</h2><span>{count_label(
            metric(@snapshot.trace.metrics, "Turns"),
            "work turn"
          )} · {count_label(metric(@snapshot.trace.metrics, "Repairs"), "correction")}</span>
        </div>
        <p :if={@snapshot.trace.history.truncated || @timeline.truncated} class="timeline-bound">
          History is bounded. Older model requests are available under “All model requests” in the technical record below. Long artifacts are labeled when truncated.
        </p>
        <section
          :for={{chapter, index} <- Enum.with_index(@chapters, 1)}
          class={"trace-chapter #{if chapter.starts_conversation && chapter.conversation_turn > 1, do: "conversation-boundary"}"}
          data-conversation-turn={chapter.conversation_turn}
          aria-labelledby={"chapter-#{index}"}
        >
          <div class="chapter-heading">
            <div>
              <p
                :if={chapter.starts_conversation && chapter.conversation_turn > 1}
                class="turn-divider-label"
              >
                Message {chapter.conversation_turn}
              </p>
              <h3 id={"chapter-#{index}"}>{chapter_title(chapter)}</h3>
            </div>
            <span :if={chapter.span} class="chapter-span" title="Time since the first message">{chapter_span(
              chapter,
              @snapshot.trace.received_at
            )} from start</span>
          </div>
          <.entry_group :for={group <- entry_groups(chapter.steps)} group={group} />
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

  defp entry_groups(steps), do: Enum.chunk_by(steps, &receipt_entry?/1)

  defp receipt_entry?(%{kind: :event, band: :answer, step: step}), do: bookkeeping?(step)
  defp receipt_entry?(_entry), do: false

  defp entry_group(assigns) do
    assigns =
      assign(assigns, :grouped, length(assigns.group) > 1 && receipt_entry?(hd(assigns.group)))

    ~H"""
    <details :if={@grouped} class="case-receipt-group" id={"receipts-#{hd(@group).id}"}>
      <summary>Result & delivery details <span>{length(@group)} records</span></summary>
      <.entry :for={entry <- @group} entry={entry} />
    </details>
    <.entry :for={entry <- @group} :if={!@grouped} entry={entry} />
    """
  end

  defp entry(assigns) do
    ~H"""
    <article id={@entry.id} class={"case-entry case-#{@entry.kind}"} data-entry-kind={@entry.kind}>
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
    <p class="case-message-text">{message_text(@message)}</p>
    """
  end

  defp message_text(%{available: false}), do: "Source content not recorded or expired"

  defp message_text(%{transport: "slack", workspace: workspace, text: text}) when is_binary(text),
    do: text |> SlackMarkdown.mentions(workspace) |> Phoenix.HTML.raw()

  defp message_text(message), do: message.text

  defp event(assigns) do
    assigns = assign(assigns, :bookkeeping, bookkeeping?(assigns.step))

    ~H"""
    <details :if={@bookkeeping} class="case-system-event" id={"event-detail-#{@step.id}"}>
      <summary>{@step.title}</summary>
      <p class="case-event-summary">{@step.summary}</p>
      <.event_details step={@step} />
    </details>
    <div :if={!@bookkeeping}>
      <div class="case-event-heading">
        <h3>{event_title(@step)}</h3><span class={"event-state tone-#{@step.tone}"}>{label(
          @step.state
        )}</span>
        <span :if={@step.duration_ms}>{duration(@step.duration_ms)}</span>
      </div>
      <p :if={@step.summary && @step.summary != event_title(@step)} class="case-event-summary">
        {@step.summary}
      </p>
      <details
        :if={@step.details != [] || @step.href}
        class="case-event-details"
        id={"event-detail-#{@step.id}"}
      >
        <summary>Details</summary><.event_details step={@step} />
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

  defp event_title(%{stage: "Tool call", title: "Tool call", summary: summary})
       when is_binary(summary), do: summary

  defp event_title(step), do: if(silent_result?(step), do: "No reply sent", else: step.title)

  defp silent_result?(%{stage: "Result", details: details}),
    do: Enum.any?(details, &(&1.label == "Delivery" && &1.value == "none"))

  defp silent_result?(_step), do: false

  defp chapter_title(%{starts_conversation: true, conversation_turn: turn}) when turn > 1,
    do: "Follow-up received"

  defp chapter_title(%{band: :input}), do: "Message received"
  defp chapter_title(%{band: :ready}), do: "Routing & preparation"
  defp chapter_title(%{band: :work}), do: "Model activity"
  defp chapter_title(%{band: :answer}), do: "Answer & delivery"
  defp chapter_title(chapter), do: chapter.title

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

  defp count_label(count, noun) when count in [1, "1"], do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  defp elapsed(%{trace: %{received_at: nil}}), do: "Not recorded"

  defp elapsed(snapshot) do
    latest =
      Enum.max([unix(snapshot.episode.updated_at) | Enum.map(snapshot.trace.steps, &unix(&1.at))])

    seconds = max(div(latest - unix(snapshot.trace.received_at), 1_000_000), 0)

    if seconds == 0, do: "< 1s", else: duration_seconds(seconds)
  end

  defp chapter_span(chapter, started) do
    times = chapter.steps |> Enum.map(& &1.at) |> Enum.reject(&is_nil/1)

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

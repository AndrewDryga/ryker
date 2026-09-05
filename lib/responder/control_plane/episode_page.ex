defmodule Responder.ControlPlane.EpisodePage do
  @moduledoc "One chronological case file: conversation, model requests, host decisions and delivery."
  use Phoenix.Component
  import Responder.ControlPlane.Components

  def render(assigns) do
    assigns = assign_new(assigns, :timeline, fn -> %{items: [], truncated: false} end)
    assigns = assign(assigns, :entries, entries(assigns.snapshot, assigns.timeline))

    ~H"""
    <div class="episode-workbench">
      <div class="episode-page-intro">
        <.link navigate="/" class="back-to-activity">← Activity</.link>
        <div class="episode-title-row">
          <h1>{@snapshot.trace.case_file.title}</h1><.status state={
            to_string(@snapshot.episode.state)
          } />
        </div>
        <p>
          {@snapshot.episode.next_action}<span :if={@snapshot.trace.case_file.repository}> · {@snapshot.trace.case_file.repository}</span>
        </p>
      </div>
      <div class="episode-context-bar">
        <div>
          <.icon name={:clock} /><span>{elapsed(@snapshot.trace.metrics)}</span><small>received → latest change</small>
        </div>
        <div>
          <.icon name={:usage} /><strong>{cost(@snapshot[:accounting])}</strong><small>{coverage(
            @snapshot[:accounting]
          )}</small>
        </div>
        <a
          :if={@snapshot.trace.source}
          class="source-jump"
          href={@snapshot.trace.source.href}
          rel="noopener noreferrer"
        >{@snapshot.trace.source.label} <.icon name={:arrow} /></a>
      </div>
      <nav class="case-actions" aria-label="Execution actions">
        <a href="#execution-timeline">Read execution</a><a href="#latest-outcome">Latest outcome ↓</a>
        <a :for={action <- @snapshot.trace.actions} class="ui-button secondary" href={action.href}>{action.label}</a>
        <.link patch={base(@snapshot) <> "/requests"}>Find a specific request <.icon name={:arrow} /></.link>
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
          <h2>Complete execution timeline</h2><span>Oldest → newest · live</span>
        </div>
        <p class="timeline-explainer">
          Messages, what the model received, public tool activity, host validation and delivery — in execution order. No private reasoning is recorded.
        </p>
        <p :if={@snapshot.trace.history.truncated || @timeline.truncated} class="timeline-bound">
          History is bounded. This view contains the latest retained records; use “Find a specific request” for older request pages. Long artifacts are labeled when truncated.
        </p>
        <article :for={entry <- @entries} id={entry.id} class={"case-entry case-#{entry.kind}"}>
          <div class="case-entry-time">
            <time>{clock_time(entry.at)}</time><span>{date(entry.at)}</span>
          </div>
          <div class="case-entry-body">
            <.message :if={entry.kind == :message} message={entry.message} base={base(@snapshot)} />
            <.event :if={entry.kind == :event} step={entry.step} />
            <.request :if={entry.kind == :request} request={entry} />
          </div>
        </article>
        <div id="latest-outcome" class="case-outcome">
          <div :if={@snapshot.trace.case_file.awaiting_reply} class="story-wait">
            <span class="pulse-dot"></span><div>
              <strong>{pending_answer_label(@snapshot)}</strong><p>{@snapshot.episode.next_action}</p>
            </div>
          </div>
          <p :if={!@snapshot.trace.case_file.awaiting_reply}>
            End of retained execution · {@snapshot.episode.next_action}
          </p>
          <a href="#execution-timeline">Back to start ↑</a>
        </div>
      </section>
      <details class="story-identity">
        <summary>Source identity & review history</summary><dl>
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

  defp message(assigns) do
    ~H"""
    <div class="story-byline">
      <strong>{@message.actor}</strong><span :if={@message[:status]}>{@message.status}</span>
    </div>
    <p class="case-message-text">
      {if @message.available, do: @message.text, else: "Source content not recorded or expired"}
    </p>
    <.link
      navigate={
        if @message.actor == "Responder", do: @base <> "/" <> @message.href, else: @message.href
      }
      class="message-inspect"
    >{if @message.actor == "Responder", do: "Inspect accepted answer", else: "Inspect admission"}
    <.icon name={:arrow} /></.link>
    """
  end

  defp event(assigns) do
    ~H"""
    <div class="case-event-heading">
      <i class={"event-dot tone-#{@step.tone}"}></i><h3>{@step.title}</h3><span>{@step.actor} · {@step.state}</span>
    </div>
    <p :if={@step.summary && @step.summary != @step.title} class="case-event-summary">
      {@step.summary}
    </p>
    <a :if={@step.href} href={@step.href}>Inspect related record <.icon name={:arrow} /></a>
    <details :if={@step.details != []} class="case-event-details" id={"event-detail-#{@step.id}"}>
      <summary>Recorded details</summary><dl>
        <div :for={detail <- @step.details}>
          <dt>{detail.label}</dt><dd>{detail.value}</dd>
        </div>
      </dl>
    </details>
    """
  end

  defp request(assigns) do
    ~H"""
    <div class="case-request-heading">
      <div>
        <p class="ui-eyebrow">{@request.title}</p><h3>{@request.target}</h3>
      </div><a href={@request.href}>Full artifact <.icon name={:arrow} /></a>
    </div>
    <dl :if={@request.timing != []} class="request-timing">
      <div :for={metric <- @request.timing}>
        <dt>{metric.label}</dt><dd>{metric.value}</dd>
      </div>
    </dl>
    <p :if={@request.timing != []} class="coverage-note">
      Agent execution includes provider startup, model and tool work. It is not a measurement of thinking time alone.
    </p>
    <p class="coverage-note">{@request.coverage}</p>
    <div :for={section <- @request.sections}>
      <Responder.ControlPlane.RequestPage.artifact
        :if={section.id not in ["request", "contract"]}
        section={section}
        prefix={@request.id}
      />
      <details
        :if={section.id in ["request", "contract"]}
        class="case-raw-artifact"
        id={"#{@request.id}-#{section.id}-disclosure"}
      >
        <summary>{section.title}</summary><Responder.ControlPlane.RequestPage.artifact
          section={section}
          prefix={@request.id}
        />
      </details>
    </div>
    """
  end

  defp entries(snapshot, timeline) do
    messages =
      Enum.map(snapshot.trace.case_file.conversation, fn message ->
        %{id: "story-message-#{message.id}", at: message.at, kind: :message, message: message}
      end)

    steps =
      Enum.map(snapshot.trace.steps, fn step ->
        %{id: "event-#{step.id}", at: step.at, kind: :event, step: step}
      end)

    # Stable sort preserves the trace's numeric sequence/lifecycle ordering on ties.
    Enum.sort_by(messages ++ steps ++ timeline.items, &unix(&1.at))
  end

  defp unix(nil), do: 0
  defp unix(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> unix()
  defp unix(at), do: DateTime.to_unix(at, :microsecond)
  defp clock_time(nil), do: "Not recorded"
  defp clock_time(at), do: Calendar.strftime(at, "%H:%M:%S")
  defp date(nil), do: ""
  defp date(at), do: Calendar.strftime(at, "%d %b · UTC")
  defp base(snapshot), do: "/episodes/" <> URI.encode_www_form(snapshot.episode.ref)
  defp pending_answer_label(%{episode: %{state: :cancelled}}), do: "Stopped"
  defp pending_answer_label(%{episode: %{state: :complete}}), do: "No further reply was sent"
  defp pending_answer_label(%{trace: %{stopped: %{headline: headline}}}), do: headline
  defp pending_answer_label(%{trace: %{case_file: %{reply: nil}}}), do: "No visible answer yet"
  defp pending_answer_label(_), do: "Follow-up in progress"

  defp elapsed(metrics) do
    case Enum.find(metrics, &(&1.label == "Elapsed")) do
      nil -> "Not recorded"
      metric -> metric.value
    end
  end

  defp cost(%{costed: count, cost_usd: cost}) when count > 0,
    do: "$" <> Decimal.to_string(cost, :normal)

  defp cost(_), do: "Cost not reported"

  defp coverage(%{costed: costed, attempts: attempts}),
    do: "#{costed}/#{attempts} requests priced · own cost"

  defp coverage(_), do: "No price estimate substituted"
end

defmodule Responder.ControlPlane.EpisodePage do
  @moduledoc "Conversation, custody, and a selectable execution timeline in one case file."
  use Phoenix.Component
  import Responder.ControlPlane.Components

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :step,
        Enum.find(assigns.snapshot.trace.steps, &(&1.id == assigns.selected_step)) ||
          List.last(assigns.snapshot.trace.steps)
      )

    ~H"""
    <div class="episode-workbench">
      <div class="episode-page-intro">
        <.link navigate="/" class="back-to-activity">← Activity</.link><div class="episode-title-row">
          <h1>{@snapshot.trace.case_file.title}</h1><.status state={
            to_string(@snapshot.episode.state)
          } />
        </div><p>
          {@snapshot.episode.next_action}<span :if={@snapshot.trace.case_file.repository}> · {@snapshot.trace.case_file.repository}</span>
        </p>
      </div>
      <div class="episode-context-bar">
        <div>
          <.icon name={:clock} /><span>{elapsed(@snapshot.trace.metrics)}</span><small>received → latest change</small>
        </div><div>
          <.icon name={:usage} /><strong>{cost(@snapshot[:accounting])}</strong><small>{coverage(
            @snapshot[:accounting]
          )}</small>
        </div><a
          :if={@snapshot.trace.source}
          class="source-jump"
          href={@snapshot.trace.source.href}
          rel="noopener noreferrer"
        >{@snapshot.trace.source.label} <.icon name={:arrow} /></a>
      </div>
      <div class="episode-viewbar">
        <nav class="ui-tabs" aria-label="Episode view">
          <.link patch={base(@snapshot)} aria-current={if !@requests, do: "page"}>Conversation & timeline</.link><.link
            patch={base(@snapshot) <> "/requests"}
            aria-current={if @requests, do: "page"}
          >Model requests <.icon name={:arrow} /></.link>
        </nav><div class="episode-controls">
          <a :for={action <- @snapshot.trace.actions} href={action.href}>{action.label}</a>
        </div>
      </div>
      <Responder.ControlPlane.RequestPage.render
        :if={@requests}
        view={@requests}
        params={@params}
        path={base(@snapshot) <> "/requests"}
      />
      <div :if={!@requests} class="episode-story">
        <section class="story-conversation" aria-label="Conversation">
          <div class="story-section-heading">
            <h2>Conversation</h2><span>Latest retained messages</span>
          </div>
          <p :if={@snapshot.trace.case_file.messages == []} class="story-empty">
            Source content is unavailable. The recorded execution history is still inspectable.
          </p>
          <article
            :for={message <- @snapshot.trace.case_file.conversation}
            id={"story-message-#{message.id}"}
            class={"story-message #{if message.actor == "Responder", do: "responder-message"}"}
          >
            <span class="story-avatar" aria-hidden="true">{if message.actor == "Responder",
              do: "r.",
              else: "U"}</span><div>
              <div class="story-byline">
                <strong>{message.actor}</strong><time>{timestamp(message.at)}</time><span :if={
                  message[:status]
                }>{message.status}</span>
              </div><p>
                {if message.available,
                  do: message.text,
                  else: "Source content not recorded or expired"}
              </p><.link
                navigate={
                  if message.actor == "Responder",
                    do: base(@snapshot) <> "/" <> message.href,
                    else: message.href
                }
                class="message-inspect"
              >{if message.actor == "Responder",
                do: "Inspect accepted answer",
                else: "Inspect admission"}
              <.icon name={:arrow} /></.link>
            </div>
          </article>
          <div :if={@snapshot.trace.case_file.awaiting_reply} class="story-wait">
            <span class="pulse-dot"></span><div>
              <strong>{pending_answer_label(@snapshot)}</strong><p>{@snapshot.episode.next_action}</p><.link patch={base(@snapshot) <> "/requests"}>Inspect current request
              <.icon name={:arrow} /></.link>
            </div>
          </div>
          <section :if={@snapshot.trace.stopped} class="story-stop">
            <p class="ui-eyebrow">NEXT ACTION</p><h3>{@snapshot.trace.stopped.headline}</h3><p>
              {@snapshot.trace.stopped.reason}
            </p><strong>{@snapshot.trace.stopped.action}</strong><a
              :if={@snapshot.trace.stopped.href}
              class="ui-button secondary"
              href={@snapshot.trace.stopped.href}
            >Open recovery <.icon name={:arrow} /></a><details :if={
              @snapshot.trace.stopped.attempted != []
            }>
              <summary>Already attempted</summary><ul>
                <li :for={attempt <- @snapshot.trace.stopped.attempted}>{attempt}</li>
              </ul>
            </details>
          </section>
          <details class="story-identity">
            <summary>Source identity & review history</summary><dl>
              <dt>Episode</dt><dd>{@snapshot.episode.ref}</dd><dt>Destination</dt><dd>
                {@snapshot.episode.destination}
              </dd><dt>Created</dt><dd>{timestamp(@snapshot.episode.created_at)}</dd><dt>Reviewed</dt><dd>
                {timestamp(@snapshot.trace.review[:at])}
              </dd>
            </dl>
          </details>
        </section>
        <aside class="story-execution" aria-label="Execution timeline">
          <div class="story-section-heading">
            <h2>Behind the answer</h2><span>{length(@snapshot.trace.steps)} recorded events</span>
          </div>
          <div :if={@snapshot.trace.history.truncated} class="timeline-bound">
            History is bounded. Older records remain outside this view.
          </div>
          <div class="execution-timeline" id="execution-timeline">
            <section :for={chapter <- @snapshot.trace.chapters} class="execution-chapter">
              <div class="execution-chapter-heading">
                <strong>{chapter.title}</strong><span>{chapter.span}</span>
              </div><button
                :for={step <- chapter.steps}
                id={"event-#{step.id}"}
                class="execution-event"
                phx-click="inspect-step"
                phx-value-id={step.id}
                aria-pressed={@step && @step.id == step.id}
              ><i class={"event-dot tone-#{step.tone}"}></i><span><strong>{step.title}</strong><small>{step.actor} · {timestamp(
                step.at
              )}</small></span><.icon name={:chevron} /></button>
            </section>
          </div>
          <section :if={@step} class="event-inspector" aria-label="Selected event">
            <div class="event-inspector-heading">
              <p class="ui-eyebrow">SELECTED EVENT</p><span>{@step.stage} · {@step.state}</span>
            </div><h3>{@step.title}</h3><p>{@step.summary}</p><a :if={@step.href} href={@step.href}>Inspect related record
            <.icon name={:arrow} /></a><details
              :if={@step.details != []}
              id={"event-detail-#{@step.id}"}
            >
              <summary>Recorded details</summary><dl>
                <div :for={detail <- @step.details}>
                  <dt>{detail.label}</dt><dd>{detail.value}</dd>
                </div>
              </dl>
            </details>
          </section>
        </aside>
      </div>
    </div>
    """
  end

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

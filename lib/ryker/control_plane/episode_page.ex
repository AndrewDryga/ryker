defmodule Ryker.ControlPlane.EpisodePage do
  @moduledoc "One chronological case file: conversation, model requests, host decisions and delivery."
  use Phoenix.Component
  import Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.{EpisodeRequest, EpisodeTrace, FeedbackPage, Kit, Paths}
  alias Ryker.ControlPlane.{RequestContextHTML, ShortTime, ThreadContext, ToolCard, Units}
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.Episodes
  alias Ryker.Slack
  alias Ryker.Wording

  def render(assigns) do
    assigns = assign_new(assigns, :timeline, fn -> %{items: [], truncated: false} end)
    assigns = assign(assigns, :startup, assigns.snapshot.trace[:startup])

    assigns =
      assign(
        assigns,
        :response_metrics,
        assigns.snapshot.trace[:response_metrics] || empty_response_metrics()
      )

    assigns =
      assign(
        assigns,
        :related,
        assigns.snapshot[:related_episodes] || %{items: [], truncated: false}
      )

    chapters = chapters(assigns.snapshot, assigns.timeline)

    assigns =
      assign(
        assigns,
        :timeline_groups,
        timeline_groups(
          chapters,
          if(assigns.snapshot[:task], do: "The task"),
          feedback_groups(
            assigns.snapshot[:feedback] || [],
            assigns.snapshot[:self_analysis] || []
          )
        )
      )

    assigns =
      assigns
      |> assign(:source_link, source_link(assigns.snapshot))
      |> assign(:thread_link, thread_link(assigns.snapshot.episode))
      |> assign(:task, assigns.snapshot[:task])

    ~H"""
    <div class="episode-workbench execution-document">
      <div class="episode-page-intro">
        <Kit.back href="/" label="Activity" navigate />
        <div class="episode-title-row">
          <div class="episode-title-copy">
            <p class="episode-initial-label">{page_label(@task, @snapshot.trace.case_file)}</p>
            <h1>{@snapshot.trace.case_file.title}</h1>
          </div>
          <.status :if={@startup} state="not_started" />
          <nav
            :if={!@startup && @snapshot.trace.actions != []}
            class="episode-title-actions"
            aria-label="Execution actions"
          >
            <.action_button
              :for={action <- @snapshot.trace.actions}
              path={action.href}
              label={action.label}
              tone={action.tone}
            />
          </nav>
        </div>
        <p class="episode-location">
          <.status :if={!@startup} state={@snapshot.trace.state} />
          <time>{timestamp(@snapshot.trace.received_at)}</time>
          <a
            :if={@task && @task.repository_url}
            href={@task.repository_url}
            target="_blank"
            rel="noopener noreferrer"
          >{@task.repository} →</a>
          <a :for={item <- if(@task, do: @related.items, else: [])} href={item.href}>
            {task_relation(item)} →
          </a>
          <a
            :if={!@startup}
            href={outcome_anchor(@snapshot)}
          >Jump to latest outcome ↓</a>
          <a
            :if={@source_link}
            href={@source_link.href}
            target="_blank"
            rel="noopener noreferrer"
          >{@source_link.label} →</a>
          <a
            :if={@snapshot.episode[:conversation_link]}
            href={@snapshot.episode.conversation_link.href}
          >{@snapshot.episode.conversation_link.label} →</a>
          <a :if={@thread_link} href={@thread_link.href}>{@thread_link.label} →</a>
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
      <section :if={!@startup && @task} class="episode-metrics" aria-label="Task summary">
        <div class="metric-group metric-group-timing">
          <p class="metric-group-label">Time</p>
          <dl class="metric-group-items">
            <div class="metric metric-wall">
              <dt>{task_time_label(@snapshot.episode, @snapshot.trace.state)}</dt>
              <dd>{task_time(@snapshot.episode)}</dd>
            </div>
          </dl>
        </div>
        <div class="metric-group metric-group-cost">
          <p class="metric-group-label">Cost</p>
          <dl class="metric-group-items">
            <div class="metric metric-cost">
              <dt>Total cost</dt><dd>{cost(@snapshot[:accounting])}</dd>
            </div>
          </dl>
        </div>
      </section>
      <.progress_plan :if={!@startup && @task} task={@task} plan={@snapshot.trace[:work_plan]} />
      <.work_plan
        :if={!@startup && !@task && @snapshot.trace[:work_plan]}
        plan={@snapshot.trace.work_plan}
        final={@snapshot.episode.state in [:complete, :cancelled]}
      />
      <section :if={!@startup && !@task} class="episode-metrics" aria-label="Execution summary">
        <div class="metric-group metric-group-timing">
          <p class="metric-group-label">Timing</p>
          <dl class="metric-group-items">
            <div class="metric metric-wall">
              <dt>Conversation span</dt><dd title={wall_reason(@response_metrics.wall)}>
                {wall_time(@response_metrics.wall)}
              </dd>
            </div>
            <div class="metric metric-response">
              <dt>{response_label(@response_metrics.response)}</dt>
              <dd>{response_time(@response_metrics.response, @response_metrics.wall)}</dd>
              <p :if={response_note(@response_metrics.response)} class="metric-note">
                {response_note(@response_metrics.response)}
              </p>
            </div>
          </dl>
        </div>
        <div class="metric-group metric-group-conversation">
          <p class="metric-group-label">Conversation</p>
          <dl class="metric-group-items">
            <div class="metric metric-received">
              <dt>Received</dt><dd>{@response_metrics.messages.received}</dd>
            </div>
            <div class="metric metric-sent">
              <dt>Sent</dt><dd>{@response_metrics.messages.sent}</dd>
            </div>
          </dl>
        </div>
        <div class="metric-group metric-group-cost">
          <p class="metric-group-label">Cost</p>
          <dl class="metric-group-items">
            <div class="metric metric-cost">
              <dt>Total cost</dt><dd>{cost(@snapshot[:accounting])}</dd>
            </div>
          </dl>
        </div>
      </section>
      <section
        :if={!@startup && !@task && @related.items != []}
        class="episode-follow-through"
        aria-label="Related requests"
      >
        <h2>Related requests</h2>
        <ul>
          <li :for={item <- @related.items}>
            <a href={item.href}>{item.relation} · {item.title} · {timestamp(item.at)} →</a>
            <.status state={to_string(item.state)} />
          </li>
        </ul>
        <p :if={@related.truncated}>
          Showing the first 20 linked requests.
          <a href={
            Ryker.ControlPlane.Activity.conversation_path(
              @snapshot.episode.transport,
              @snapshot.episode.conversation_ref
            )
          }>Browse all activity in {Ryker.ControlPlane.Activity.scope_phrase(
            @snapshot.episode.conversation_ref
          )} →</a>
        </p>
      </section>
      <section :if={@snapshot.trace.case_file[:expired_at]} class="story-stop">
        <h2>Older request details expired</h2>
        <p>
          Saved content was removed by retention on {timestamp(@snapshot.trace.case_file.expired_at)}. The remaining timeline still shows when the request ran and finished.
        </p>
      </section>
      <section :if={@snapshot.trace.stopped && !@startup} class="story-stop">
        <p class="ui-eyebrow">NEXT ACTION</p><h3>{@snapshot.trace.stopped.headline}</h3>
        <p>{@snapshot.trace.stopped.reason}</p><strong>{@snapshot.trace.stopped.action}</strong>
        <a
          :if={@snapshot.trace.stopped.href}
          class="ui-button secondary"
          href={@snapshot.trace.stopped.href}
        >{@snapshot.trace.stopped[:link_label] || "Open recovery"} <.icon name={:arrow} /></a>
        <.disclosure
          :if={@snapshot.trace.stopped[:model_output]}
          class="recovery-worker-report"
          id="recovery-worker-report"
          label="Worker's saved response"
        >
          <p class="recovery-attribution">
            {@snapshot.trace.stopped[:delivery]} This is the worker's report, not an independently verified check result.
          </p>
          <div class="recovery-model-output">
            {SlackMarkdown.html(@snapshot.trace.stopped.model_output)}
          </div>
        </.disclosure>
        <.disclosure
          :if={@snapshot.trace.stopped.attempted != []}
          id="recovery-attempted"
          label="Already attempted"
        >
          <ul>
            <li :for={attempt <- @snapshot.trace.stopped.attempted}>{attempt}</li>
          </ul>
        </.disclosure>
      </section>
      <section
        :if={!@task && (@snapshot.trace[:follow_through] || []) != []}
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
      <Ryker.ControlPlane.WorkerEvidenceCard.render :if={!@task} episode_id={@snapshot.episode[:id]} />
      <.execution_timeline
        snapshot={@snapshot}
        timeline={@timeline}
        groups={@timeline_groups}
        params={@params}
      />
    </div>
    """
  end

  # Andrew, 2026-09-27: every answer records the feedback it gets. What people
  # said about this request's answers keeps its own chapter identity, ordered
  # among the other events by time, including ratings (2026-09-29):
  # one card per signal, oldest first, each saying how they felt and why. Ryker's own
  # analysis of what went wrong follows the feedback that started it, as the
  # model-request cards every other call has (2026-09-28). A request nobody
  # said anything about has no chapter.
  defp feedback_groups([], []), do: []

  defp feedback_groups(feedback, analysis) do
    steps =
      Enum.map(feedback, &%{id: "feedback-#{&1.id}", kind: :feedback, at: &1.at, feedback: &1}) ++
        requests_with_links(analysis, %{})

    [
      %{
        anchor: "feedback",
        band: :feedback,
        conversation_turn: nil,
        description: feedback_description(analysis),
        kind: :feedback,
        marker: "F",
        phases: [
          %{
            band: :feedback,
            turn: nil,
            steps: Enum.sort_by(steps, &(&1[:sort_at] || &1.at), DateTime)
          }
        ],
        title: "Feedback"
      }
    ]
  end

  defp feedback_description([]) do
    "What people said about Ryker's answers here: reactions, asking again, changing their message, and how they felt."
  end

  defp feedback_description(_analysis) do
    "What people said about Ryker's answers here, and Ryker's own analysis of what went wrong. The analysis sends no reply."
  end

  @doc """
  The page of a message that has no request of its own: a greeting routing
  answered itself, a message it reacted to or left alone, or one still waiting
  for routing.

  It is the request page's own furniture, not a second design (Andrew,
  2026-09-26: "why this page is so different … last one is properly designed
  while other IDK what is that even?!"): the header with what the message says
  and what happened to it, the summary strip with what applies, and one
  Message band in the request page's order. Intake is the message as it was
  sent and why Ryker read it; Routing is the queue, the search for earlier
  work, the briefing and the decision; Answer is what Ryker sent. Background
  learning keeps its own chapter identity in chronological order. The header links
  to every message of its thread (Andrew, 2026-09-28: "drop this, just add
  link here to show all messages in thread too").

  Andrew, 2026-09-27, of these pages for Slack messages: "They have some
  previous messages mid-text, timeline is broken apart and not following the
  logic". The thread sat between the answer and a "Routing details" section
  that held the routing cards away from the decision they led to.
  """
  attr(:view, :map, required: true, doc: "`Ryker.ControlPlane.ModelRequests.project_input/2`")

  def message_page(assigns) do
    view = assigns.view
    {intake, routing} = message_entries(view)

    message = %{
      id: "story-message-#{view.message.id}",
      kind: :message,
      at: view.message.at,
      message: view.message
    }

    groups =
      [
        ready: [message | intake],
        routing: routing,
        answer: view.answer,
        learning: view[:learning] || []
      ]
      |> Enum.map(fn {band, steps} ->
        %{
          band: band,
          steps: steps,
          turn: nil,
          owners: [],
          starts_conversation: false,
          conversation_turn: if(band == :learning, do: nil, else: 1)
        }
      end)
      |> timeline_groups(nil, feedback_groups(view[:feedback] || [], view[:self_analysis] || []))
      |> Enum.map(fn
        %{kind: :conversation} = group ->
          %{
            group
            | marker: "M",
              title: if(group.part > 1, do: "Message · continued", else: "Message")
          }

        group ->
          group
      end)

    source = view.heading.source

    assigns =
      assign(assigns,
        groups: groups,
        outcome: message_outcome(routing, view.answer),
        # A Chat message's source is the Chat itself; the header links there once.
        source:
          if(
            source && view.heading.conversation_link &&
              source.href == view.heading.conversation_link.href,
            do: nil,
            else: source
          )
      )

    ~H"""
    <div class="episode-workbench execution-document">
      <div class="episode-page-intro">
        <Kit.back href="/" label="Activity" navigate />
        <div class="episode-title-row">
          <div class="episode-title-copy">
            <p class="episode-initial-label">Message</p>
            <h1>{@view.heading.title}</h1>
          </div>
        </div>
        <p class="episode-location">
          <.status state={@view.heading.state} />
          <time :if={@view.heading.received_at}>{timestamp(@view.heading.received_at)}</time>
          <a :if={@outcome} href={@outcome}>Jump to latest outcome ↓</a>
          <a :if={@source} href={@source.href} target="_blank" rel="noopener noreferrer">{@source.label} →</a>
          <a
            :if={@view.heading.conversation_link}
            href={@view.heading.conversation_link.href}
          >{@view.heading.conversation_link.label} →</a>
          <a
            :if={@view.heading[:thread_link]}
            href={@view.heading.thread_link.href}
          >{@view.heading.thread_link.label} →</a>
        </p>
      </div>
      <.admission_recovery :if={@view.recovery} recovery={@view.recovery} />
      <section
        :if={@view.metrics.response_ms || @view.metrics.cost}
        class="episode-metrics"
        aria-label="Message summary"
      >
        <div :if={@view.metrics.response_ms} class="metric-group metric-group-timing">
          <p class="metric-group-label">Timing</p>
          <dl class="metric-group-items">
            <div class="metric metric-response">
              <dt>Response time</dt><dd>{Units.duration(@view.metrics.response_ms)}</dd>
            </div>
          </dl>
        </div>
        <div :if={@view.metrics.cost} class="metric-group metric-group-cost">
          <p class="metric-group-label">Cost</p>
          <dl class="metric-group-items">
            <div class="metric metric-cost">
              <dt>Routing cost</dt><dd>{@view.metrics.cost}</dd>
            </div>
          </dl>
        </div>
      </section>
      <section class="case-timeline" id="execution-timeline" aria-label="Message timeline">
        <h2 class="sr-only">Message timeline</h2>
        <.timeline_bands groups={@groups} started_at={@view.heading.received_at} />
      </section>
    </div>
    """
  end

  # One sequence in time order, as on a request's page, so a retried message
  # reads attempt by attempt and a wait that ran out folds into the result it
  # waited on. Why Ryker read the message belongs to its intake; everything
  # routing did, from the queue to the decision, is the Routing stage.
  defp message_entries(view) do
    view.preparation
    |> Enum.map(&%{id: "event-#{&1.id}", kind: :event, step: &1, at: &1.at})
    |> Kernel.++(requests_with_links(view.timeline, %{}))
    |> Enum.sort_by(&(&1[:sort_at] || &1.at), &(DateTime.compare(&1, &2) != :gt))
    |> fold_waits()
    |> merge_queue_runs()
    |> Enum.split_with(&ready_event?/1)
  end

  defp ready_event?(%{kind: :event, step: %{band: :ready}}), do: true
  defp ready_event?(_entry), do: false

  defp decided_request?(%{kind: :request, phase: :result}), do: true
  defp decided_request?(_entry), do: false

  defp result_event?(%{kind: :event, step: %{stage: "Result"}}), do: true
  defp result_event?(_entry), do: false

  defp message_outcome(routing, answer) do
    decided = Enum.filter(routing, &decided_request?/1)

    case List.last(answer) || List.last(decided) do
      %{id: id} -> "#" <> id
      nil -> nil
    end
  end

  defp thread_link(%{transport: "slack", conversation_ref: conversation, thread_ref: thread})
       when is_binary(conversation) and is_binary(thread),
       do: ThreadContext.thread_link("slack", conversation, thread)

  defp thread_link(_episode), do: nil

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

  @doc """
  Groups foreground phases under the message that caused them. Work before any
  message is `first` ("Before the first message"; a task's page names it "The
  task", since a task starts from its confirmation, not a message).
  """
  def timeline_groups(chapters, first \\ nil, feedback \\ []) do
    feedback =
      for group <- feedback, phase <- group.phases do
        %{
          band: :feedback,
          conversation_turn: nil,
          turn: nil,
          owners: [],
          starts_conversation: false,
          steps: phase.steps,
          description: group.description
        }
      end

    # Keep chronological order even when older work finishes after a new input.
    # A continued section retains that work's real owner, never the newer message.
    (chapters ++ feedback)
    |> Enum.flat_map(fn chapter -> Enum.map(chapter.steps, &%{chapter | steps: [&1]}) end)
    |> Enum.sort_by(&{entry_time(hd(&1.steps)), &1.conversation_turn || 0})
    |> Enum.chunk_by(&group_identity/1)
    |> Enum.map(&timeline_group(&1, first))
    |> Enum.map_reduce(%{}, &continued_group/2)
    |> elem(0)
    |> Enum.map_reduce(0, &number_background/2)
    |> elem(0)
  end

  defp group_identity(%{band: :maintenance}), do: :maintenance
  defp group_identity(%{band: :feedback}), do: :feedback

  defp group_identity(chapter) do
    if background_band?(chapter.band),
      do: {chapter.band, occurrence(hd(chapter.steps))},
      else: {:conversation, chapter.conversation_turn}
  end

  defp timeline_group([%{band: :feedback} = chapter | _] = chapters, _first) do
    %{
      anchor: "feedback",
      band: :feedback,
      conversation_turn: nil,
      description: chapter.description,
      kind: :feedback,
      marker: "F",
      phases: [merge_phase(chapters)],
      title: "Feedback"
    }
  end

  defp timeline_group([chapter | _] = chapters, first) do
    if background_band?(chapter.band) do
      %{
        band: chapter.band,
        conversation_turn: nil,
        description: chapter_description(chapter.band),
        kind: :background,
        marker: nil,
        phases: [merge_phase(chapters)],
        title: chapter_title(chapter)
      }
    else
      turn = chapter.conversation_turn

      %{
        band: :conversation,
        conversation_turn: turn,
        kind: :conversation,
        marker: if(turn > 0, do: "M#{turn}", else: "—"),
        phases: grouped_phases(chapters),
        title: if(turn > 0, do: "Message #{turn}", else: first || "Before the first message")
      }
    end
  end

  defp continued_group(%{kind: :conversation, conversation_turn: turn} = group, seen) do
    part = Map.get(seen, turn, 0) + 1
    title = group.title <> if(part > 1, do: " · continued", else: "")
    {Map.merge(group, %{part: part, title: title}), Map.put(seen, turn, part)}
  end

  defp continued_group(%{kind: :feedback} = group, seen) do
    part = Map.get(seen, :feedback, 0) + 1
    {Map.put(group, :anchor, "feedback" <> part_suffix(part)), Map.put(seen, :feedback, part)}
  end

  defp continued_group(group, seen), do: {group, seen}

  defp number_background(%{kind: :background} = group, index),
    do: {%{group | marker: "B#{index + 1}"}, index + 1}

  defp number_background(group, index), do: {group, index}

  # A learning pass's attempts share their batch; a learning card and its
  # result share their id's stem; a cleanup is one session's.
  defp occurrence(%{occurrence: key}) when not is_nil(key), do: key
  defp occurrence(%{id: id}), do: String.replace_suffix(id, "-result", "")

  defp execution_timeline(assigns) do
    ~H"""
    <section
      class="case-timeline"
      id="execution-timeline"
      aria-label="Complete execution timeline"
    >
      <h2 class="sr-only">Execution timeline</h2>
      <p :if={@snapshot.trace.history[:pruned_at]} class="timeline-bound history-pruned">
        Execution history was removed by retention on <time datetime={
          DateTime.to_iso8601(@snapshot.trace.history.pruned_at)
        }>{timestamp(@snapshot.trace.history.pruned_at)}</time>. What remains is when the request
        ran and finished, not a request that did nothing.
      </p>
      <p :if={@snapshot.trace.history.truncated || @timeline.truncated} class="timeline-bound">
        <span :for={window <- Map.get(@snapshot.trace.history, :windows, [])} :if={window.truncated}>
          Showing {window.shown} of {window.total} retained {window.label}.
        </span>
        <.link
          :if={@snapshot.trace.activity[:more]}
          patch={base(@snapshot) <> "?events=" <> Integer.to_string(@snapshot.trace.activity.more)}
        >Show earlier activity</.link>
        <span :if={@timeline[:call_history] && @timeline.call_history.more}>
          Showing {@timeline.call_history.shown} recent model requests.
          <.link patch={calls_path(@snapshot, @params, @timeline.call_history.more)}>
            Show earlier requests
          </.link>
        </span>
        <span :if={!(@timeline[:call_history] && @timeline.call_history.more)}>
          Long artifacts are labeled when truncated.
        </span>
      </p>
      <.timeline_bands groups={@groups} started_at={@snapshot.trace.received_at} />
      <.rate :if={@snapshot.trace.rating.awaiting} rating={@snapshot.trace.rating} />
      <div id="latest-outcome" class="case-outcome">
        <div
          :if={
            @snapshot.trace.case_file.awaiting_reply && !@snapshot.trace[:startup] &&
              !@snapshot.trace.stopped
          }
          class="story-wait"
          data-state={wait_state(@snapshot)}
          role="status"
        >
          <strong>{pending_answer_label(@snapshot)}</strong>
          <p :if={wait_text(@snapshot)}>{wait_text(@snapshot)}</p>
        </div>
        <a href="#execution-timeline">Back to start ↑</a>
      </div>
    </section>
    """
  end

  attr(:groups, :list, required: true)
  attr(:started_at, :any, required: true, doc: "The first message's time, where spans count from")

  # Both request and message pages use the same chronological chapters.
  # Adjacent events share a band; interleaved owners continue in a later band
  # instead of moving background work or feedback after the conversation.
  defp timeline_bands(assigns) do
    ~H"""
    <nav :if={@groups != []} class="timeline-index" aria-label="Jump to chapter">
      <span>Jump to</span>
      <ol>
        <li :for={{group, index} <- Enum.with_index(@groups, 1)}>
          <a href={"#chapter-#{index}"}>{group.title}</a>
        </li>
      </ol>
    </nav>
    <section
      :for={{group, index} <- Enum.with_index(@groups, 1)}
      id={group[:anchor]}
      class={"trace-chapter timeline-group #{if group.kind == :conversation, do: "conversation-chapter", else: "background-chapter"} phase-#{group.band}"}
      data-conversation-turn={group.conversation_turn}
      aria-labelledby={"chapter-#{index}"}
    >
      <div
        class="chapter-heading"
        id={if group.kind == :conversation, do: message_anchor(group)}
        tabindex={if group.kind == :conversation, do: "-1"}
      >
        <span class="phase-number" aria-hidden="true">{group.marker}</span>
        <div class="chapter-description">
          <p :if={group.kind == :background} class="chapter-background">Background</p>
          <h3 id={"chapter-#{index}"}>{group.title}</h3>
          <p :if={group[:description]}>{group.description}</p>
        </div>
        <.timeline_jumps links={message_jumps(@groups, group)} label="Message navigation" />
      </div>
      <section
        :for={{phase, phase_index} <- Enum.with_index(group.phases, 1)}
        class={"conversation-phase phase-#{phase.band}"}
        aria-labelledby={if(group.kind == :conversation, do: "chapter-#{index}-phase-#{phase_index}")}
        aria-label={if(group.kind != :conversation, do: group.title)}
      >
        <div
          :if={group.kind == :conversation}
          class="conversation-phase-heading"
          id={phase_anchor(group, phase)}
          tabindex="-1"
        >
          <h4 id={"chapter-#{index}-phase-#{phase_index}"}>{phase_title(phase.band)}</h4>
          <span :if={phase_summary(phase)} class="phase-summary">{phase_summary(phase)}</span>
          <p :if={turn_association(phase)} class="turn-association">
            {turn_association(phase)}
          </p>
          <span class="chapter-span" title="Time since the first message">{chapter_span(
            phase,
            @started_at
          )} from start</span>
          <.timeline_jumps
            links={phase_jumps(group, phase_index)}
            label="Stage navigation"
          />
        </div>
        <div class="phase-entries">
          <.entry :for={entry <- card_runs(phase.steps)} entry={entry} />
        </div>
      </section>
    </section>
    """
  end

  attr(:links, :list, required: true)
  attr(:label, :string, required: true)

  defp timeline_jumps(assigns) do
    ~H"""
    <nav :if={@links != []} class="timeline-jumps" aria-label={@label}>
      <a
        :for={link <- @links}
        href={link.href}
        aria-label={link.label}
        title={link.label}
        data-direction={link.direction}
      ><.icon name={if(link.direction == :previous, do: :arrow_up, else: :arrow_down)} /></a>
    </nav>
    """
  end

  defp message_anchor(group),
    do: "timeline-message-#{group.conversation_turn}" <> part_suffix(group[:part])

  defp phase_anchor(group, phase),
    do: "#{message_anchor(group)}-#{phase.band}" <> part_suffix(phase[:part])

  defp part_suffix(part) when is_integer(part) and part > 1, do: "-continued-#{part}"
  defp part_suffix(_part), do: ""

  defp message_jumps(groups, %{kind: :conversation, conversation_turn: turn} = group)
       when turn > 0 do
    messages = Enum.filter(groups, &(&1.kind == :conversation and &1.conversation_turn > 0))
    index = Enum.find_index(messages, &(&1 == group))
    adjacent_jumps(messages, index, "message", &message_anchor/1, & &1.title)
  end

  defp message_jumps(_groups, _group), do: []

  defp phase_jumps(group, index) do
    adjacent_jumps(
      group.phases,
      index - 1,
      "stage",
      &phase_anchor(group, &1),
      &phase_title(&1.band)
    )
  end

  defp adjacent_jumps(items, index, kind, anchor, label) do
    for {direction, offset, prefix} <- [{:previous, -1, "Previous"}, {:next, 1, "Next"}],
        target_index = index + offset,
        target_index >= 0 and target_index < length(items),
        target = Enum.at(items, target_index) do
      %{
        direction: direction,
        href: "##{anchor.(target)}",
        label: "#{prefix} #{kind}: #{label.(target)}"
      }
    end
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
      when stage in ["Work setup", "Routing"] ->
        %{entry | band: :work}

      entry ->
        entry
    end)
  end

  # Establish message boundaries before merging adjacent fragments of the same
  # phase. `timeline_groups/1` then files those phases under their durable input.
  defp execution_phases(chapters) do
    chapters
    |> Enum.map(&%{&1 | band: phase_band(&1.band)})
    |> Enum.chunk_by(&{&1.band, &1.conversation_turn})
    |> Enum.map(fn [first | _] = group ->
      owners = group |> Enum.flat_map(& &1.owners) |> Enum.uniq()
      turns = Enum.filter(owners, &match?({:turn, _id}, &1))

      %{
        first
        | steps: group |> Enum.flat_map(& &1.steps) |> fold_waits() |> merge_queue_runs(),
          owners: owners,
          # Merging two turns into one phase would put one turn's name on
          # another turn's receipts, so a merged phase keeps no turn identity.
          turn: if(match?([_one], turns), do: Enum.find_value(group, & &1.turn)),
          starts_conversation: Enum.any?(group, & &1.starts_conversation)
      }
    end)
  end

  defp grouped_phases(chapters) do
    chapters
    |> Enum.chunk_by(& &1.band)
    |> Enum.map(&merge_phase/1)
    |> Enum.map_reduce(%{}, fn phase, seen ->
      part = Map.get(seen, phase.band, 0) + 1
      {Map.put(phase, :part, part), Map.put(seen, phase.band, part)}
    end)
    |> elem(0)
  end

  defp merge_phase([first | _rest] = chapters) do
    owners = chapters |> Enum.flat_map(& &1.owners) |> Enum.uniq()
    turns = chapters |> Enum.map(& &1.turn) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      first
      | owners: owners,
        starts_conversation: Enum.any?(chapters, & &1.starts_conversation),
        steps: chapters |> Enum.flat_map(& &1.steps) |> fold_waits() |> merge_queue_runs(),
        turn: if(match?([_one], turns), do: List.first(turns))
    }
  end

  # A wait that ran out while the worker was still answering belongs to the
  # routing call it waited on, so it is told on that call's result card rather
  # than as a queue card ahead of the result. Until that result exists the
  # wait stays a card of its own: it is then the latest thing that happened.
  defp fold_waits(entries) do
    indexed = Enum.with_index(entries)

    targets =
      for {%{kind: :event, step: %{stage: "Queue", input_id: input} = step}, index} <- indexed,
          match?("Reattached" <> _, step.queue.qualifier || ""),
          later = Enum.drop(entries, index + 1),
          %{id: id} <- [Enum.find(later, &admission_result?(&1, input))],
          into: %{},
          do: {index, id}

    waits =
      Enum.group_by(targets, &elem(&1, 1), fn {index, _id} ->
        wait(Enum.at(entries, index).step.queue)
      end)

    for {entry, index} <- indexed, not Map.has_key?(targets, index) do
      case Map.fetch(waits, entry[:id]) do
        {:ok, found} -> Map.put(entry, :waits, found)
        :error -> entry
      end
    end
  end

  defp admission_result?(
         %{kind: :request, source_kind: :admission, phase: :result, owner: {:input, input}},
         input
       ),
       do: true

  defp admission_result?(_entry, _input), do: false

  defp wait(queue) do
    paused = Enum.find(queue.events, &(&1.kind == :retry_scheduled))
    resumed = Enum.find(queue.events, &(&1.kind in [:claimed, :reclaimed]))
    %{paused_at: paused && paused.at, resumed_at: resumed && resumed.at}
  end

  # Queue runs for one input that follow each other with nothing in between
  # read as one card: stopped, rearmed and picked up again is one stretch of
  # queue history. The runs stay separate wherever a routing call sits
  # between them.
  defp merge_queue_runs(entries) do
    entries
    |> Enum.reduce([], fn
      %{kind: :event, step: %{stage: "Queue", input_id: input}} = entry,
      [%{kind: :event, step: %{stage: "Queue", input_id: input}} = previous | rest] ->
        [merge_queue(previous, entry) | rest]

      entry, merged ->
        [entry | merged]
    end)
    |> Enum.reverse()
  end

  defp merge_queue(previous, entry) do
    earlier = previous.step.queue
    later = entry.step.queue
    events = earlier.events ++ later.events
    stopped? = Enum.any?(events, &(&1.kind == :blocked))

    queue = %{
      later
      | qualifier: earlier.qualifier || later.qualifier,
        events: events,
        started_at: earlier.started_at,
        # A stretch that includes a stop was not time spent waiting in the
        # queue; its clock times say how long it was stopped.
        duration_ms:
          if(!stopped? and later.ended_at,
            do: DateTime.diff(later.ended_at, earlier.started_at, :millisecond)
          )
    }

    %{previous | step: %{previous.step | queue: queue, tone: entry.step.tone}}
  end

  defp entry_time(entry), do: EpisodeTrace.Step.time_key(entry[:sort_at] || entry.at)

  defp calls_path(snapshot, params, page) do
    query =
      params
      |> Map.take(["events"])
      |> Map.put("calls", to_string(page))
      |> Paths.encode_query()

    base(snapshot) <> "?" <> query
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

  # A turn that stopped before choosing its messages, or one frozen before the
  # choice was kept, explains nothing about them to a reader.
  defp input_association(:not_recorded), do: nil
  defp input_association(ordinals) when length(ordinals) < 2, do: nil

  defp input_association(ordinals),
    do: "Inputs: " <> Enum.map_join(ordinals, " + ", &"Message #{&1}")

  defp continuation(nil), do: nil
  defp continuation(ordinal), do: "Continues Run #{ordinal}"

  defp phase_band(:input), do: :ready
  defp phase_band(:outcome), do: :answer
  defp phase_band(band), do: band

  # How a stage ended, read from its own recorded entries. The label summarizes
  # the stage; the cards below it stay exactly as each moment recorded them.
  # Routing's cards say what it decided; the heading does not repeat it.
  defp phase_summary(%{band: :routing}), do: nil

  # An update posted while the work ran is not the answer.
  defp phase_summary(%{band: :answer, steps: entries}) do
    cond do
      Enum.any?(entries, &(message_direction(&1) == "out" and !&1.message[:update])) ->
        "Response sent"

      Enum.any?(entries, &result_event?/1) ->
        "No reply sent"

      true ->
        nil
    end
  end

  defp phase_summary(_phase), do: nil

  # Background sections remain separate from message-caused work. Their cards
  # retain exact timestamps and interleave with conversation events by time.
  defp background_band?(band), do: band in [:learning, :maintenance]

  # Andrew, 2026-09-28: "nice design for every kind, branded cards for Emisar
  # tool calls, informative cards, consecutive calls collapsed into one card
  # where it fits (like queues)". Tool calls and Slack status updates that
  # follow each other within a stage read as one card, a line per step, each
  # opening to its full card. A failure remains a closed tool call with its
  # reason visible on the row. Goals, evidence and replies still end the run.
  defp tool_runs(entries) do
    entries
    |> Enum.reduce([], &add_to_run(&1, &2, tool_step?(&1)))
    |> Enum.reverse()
    |> Enum.map(fn
      %{kind: :event, step: %{stage: stage}} = entry when stage in ["Tool call", "Status"] ->
        %{kind: :tool_run, id: "steps-" <> entry.id, at: entry.at, entries: [entry]}

      entry ->
        entry
    end)
  end

  defp card_runs(entries) do
    entries
    |> tool_runs()
    |> Enum.chunk_by(&card_run_key/1)
    |> Enum.map(fn
      [%{kind: :event, step: %{stage: "Plan change"}} = first | _] = entries ->
        %{
          kind: :plan_run,
          id: "plan-run-" <> first.id,
          at: List.last(entries).at,
          entries: entries
        }

      [%{kind: :event, step: %{stage: "Maintenance"}} = first | _] = entries ->
        %{kind: :cleanup_run, id: "cleanup-run-" <> first.id, at: first.at, entries: entries}

      [entry] ->
        entry
    end)
  end

  defp card_run_key(%{kind: :event, step: %{stage: "Plan change", plan_change: change}} = entry),
    do: {:plan, entry.owner, change.kind}

  defp card_run_key(%{kind: :event, step: %{stage: "Maintenance"}}), do: :cleanup
  defp card_run_key(entry), do: entry.id

  defp add_to_run(entry, [%{kind: :tool_run} = run | rest], true),
    do: [%{run | entries: run.entries ++ [entry]} | rest]

  defp add_to_run(entry, [previous | rest] = runs, true) do
    if tool_step?(previous),
      do: [new_run(previous, entry) | rest],
      else: [entry | runs]
  end

  defp add_to_run(entry, runs, _tool_step?), do: [entry | runs]

  defp new_run(first, second),
    do: %{kind: :tool_run, id: "steps-" <> first.id, at: first.at, entries: [first, second]}

  defp tool_step?(%{kind: :event, step: %{stage: stage}})
       when stage in ["Tool call", "Status"],
       do: true

  defp tool_step?(_entry), do: false

  attr(:run, :map, required: true)

  defp tool_run(assigns) do
    lines = Enum.map(assigns.run.entries, &{&1, ToolCard.line(&1.step)})

    assigns =
      assign(assigns,
        lines: lines,
        services: lines |> Enum.map(&elem(&1, 1).service) |> Enum.uniq(),
        span: run_span(assigns.run.entries)
      )

    ~H"""
    <div class="tool-run">
      <.card_heading title="Tool activity">
        <:detail :if={length(@lines) > 1}>{length(@lines)} steps</:detail>
        <:description :if={length(@services) > 1}>
          {Enum.map_join(@services, ", ", &service_name/1)}
        </:description>
        <:meta :if={@span}><span class="action-duration">{@span}</span></:meta>
      </.card_heading>
      <.tool_run_lines lines={@lines} />
    </div>
    """
  end

  defp tool_run_lines(assigns) do
    ~H"""
    <ol class="tool-run-steps">
      <li
        :for={{entry, line} <- @lines}
        id={entry.id}
        class="tool-run-step"
        data-service={line.service}
      >
        <details
          :if={entry.step.stage == "Tool call"}
          id={"tool-#{entry.step.id}-call"}
          class="tool-run-detail"
        >
          <summary class="tool-run-line">
            <ToolCard.row line={line} state={entry.step.state} />
          </summary>
          <div class="tool-run-body">
            <ToolCard.render step={entry.step} grouped />
          </div>
        </details>
        <div :if={entry.step.stage != "Tool call"} class="tool-run-line">
          <ToolCard.row line={line} state={entry.step.state} />
        </div>
      </li>
    </ol>
    """
  end

  # When the run started and ended, by the clock, as the rows of a timeline
  # read: 04:42:40–04:43:23.
  defp run_span(entries) do
    times = entries |> Enum.map(& &1.at) |> Enum.reject(&is_nil/1)

    case times do
      [] -> nil
      [only] -> clock_time(only) <> " UTC"
      [first | _rest] -> clock_time(first) <> "–" <> clock_time(List.last(times)) <> " UTC"
    end
  end

  defp entry(assigns) do
    ~H"""
    <article
      id={@entry.id}
      class={[
        "case-entry case-#{@entry.kind}",
        message_container?(@entry) && "message-container"
      ]}
      data-entry-kind={@entry.kind}
      data-direction={message_direction(@entry)}
    >
      <div class="case-entry-time">
        <time
          datetime={if(@entry.at, do: DateTime.to_iso8601(@entry.at))}
          title={timestamp(@entry.at)}
        >{clock_time(@entry.at)}</time>
        <a
          class="card-link"
          href={"##{@entry.id}"}
          title="Link to this card"
          aria-label="Link to this card"
        >#</a>
      </div>
      <div class="case-entry-body">
        <.message :if={@entry.kind == :message} message={@entry.message} />
        <.tool_run :if={@entry.kind == :tool_run} run={@entry} />
        <.plan_change :if={@entry.kind == :plan_run} run={@entry} />
        <.cleanup_run :if={@entry.kind == :cleanup_run} run={@entry} />
        <Ryker.ControlPlane.ToolCard.render
          :if={@entry.kind == :event && @entry.step.stage == "Tool call"}
          step={@entry.step}
        />
        <.participation
          :if={@entry.kind == :event && @entry.step.stage == "Participation"}
          step={@entry.step}
        />
        <.input_queue
          :if={@entry.kind == :event && @entry.step.stage == "Queue"}
          step={@entry.step}
        />
        <.search_card
          :if={@entry.kind == :event && @entry.step.stage == "Search"}
          step={@entry.step}
        />
        <.work_setup
          :if={@entry.kind == :event && @entry.step.stage == "Work setup"}
          step={@entry.step}
        />
        <.observations
          :if={@entry.kind == :event && @entry.step.stage == "Observations"}
          step={@entry.step}
        />
        <.worker_activity
          :if={@entry.kind == :event && activity_stage?(@entry.step.stage)}
          step={@entry.step}
        />
        <.event_wait :if={@entry.kind == :event && @entry.step[:wait]} step={@entry.step} />
        <.finding :if={@entry.kind == :event && @entry.step[:finding]} step={@entry.step} />
        <.delivery_message :if={@entry.kind == :event && @entry.step[:message]} step={@entry.step} />
        <.event
          :if={
            @entry.kind == :event && !card_stage?(@entry.step.stage) && !@entry.step[:wait] &&
              !@entry.step[:finding] && !@entry.step[:message]
          }
          step={@entry.step}
        />
        <EpisodeRequest.render :if={@entry.kind == :request} request={@entry} />
        <.feedback :if={@entry.kind == :feedback} feedback={@entry.feedback} />
      </div>
    </article>
    """
  end

  attr(:feedback, :map, required: true)

  # One thing someone said about an answer, in the words the Feedback page
  # uses (`FeedbackPage`): how they felt as a dot and a word, who, what they
  # did or why, and the message it came from.
  defp feedback(assigns) do
    assigns = assign(assigns, :state, FeedbackPage.state(assigns.feedback))

    ~H"""
    <div class="case-event-content feedback-card">
      <.card_heading title={FeedbackPage.title(@feedback)}>
        <:description>
          <Kit.person person={@feedback.who} /><span :if={@feedback.request.where}> · {@feedback.request.where}</span><span :if={
            @feedback.message_href
          }> · <a href={@feedback.message_href}>Their message →</a></span>
        </:description>
        <:meta>
          <Kit.state tone={elem(@state, 0)} word={elem(@state, 1)} hint={elem(@state, 2)} />
        </:meta>
      </.card_heading>
      <p :if={feedback_reason(@feedback)} class="case-event-summary">
        {feedback_reason(@feedback)}
      </p>
    </div>
    """
  end

  # The heading says what kind of feedback it is; a reason or a note reads
  # under it.
  defp feedback_reason(%{kind: kind, note: note})
       when kind in [:sentiment, :reviewed] and is_binary(note),
       do: "\"#{note}\""

  defp feedback_reason(_feedback), do: nil

  attr(:rating, :map, required: true)

  # Andrew, 2026-09-28, of "Mark ending reviewed": "i just mark it so what
  # next? this is half baked!" A finished request asks how it went, and each
  # answer does something: Went well counts on Feedback, and Needs work sends
  # the request to Self-improvement, where Ryker works out what went wrong.
  defp rate(assigns) do
    ~H"""
    <Kit.section_card
      id="rate-request"
      title="How did this go?"
      lede="Needs work sends it to Self-improvement: Ryker works out what went wrong and suggests a test case for it."
      class="rate-request"
    >
      <:actions>
        <.action_button path={@rating.good} label="Went well" />
        <.action_button path={@rating.needs_work} label="Needs work" />
      </:actions>
    </Kit.section_card>
    """
  end

  # A summary of several paragraphs, such as a finding and its reason, reads
  # as several.
  defp summary_paragraphs(%{summary: summary}) when is_binary(summary),
    do: summary |> String.split(~r/\n\s*\n/, trim: true) |> Enum.map(&String.trim/1)

  defp summary_paragraphs(_step), do: []

  # Stages with their own card component instead of the generic event layout.
  defp card_stage?(stage) do
    stage in [
      "Tool call",
      "Participation",
      "Queue",
      "Search",
      "Work setup",
      "Plan change",
      "Observations"
    ] || activity_stage?(stage)
  end

  # One shared reading treatment for every narrative/transport update. Tools
  # retain their aggregate, and records keep their evidence and durable links.
  defp activity_stage?(stage) do
    stage in [
      "Thinking",
      "Progress",
      "Provider",
      "Plan",
      "Permission",
      "Recorder",
      "Worker activity"
    ]
  end

  defp message_container?(%{kind: :message, message: message}), do: is_nil(message[:provider])
  defp message_container?(_entry), do: false

  defp message_direction(%{kind: :message, message: %{actor: "Ryker"}}), do: "out"
  defp message_direction(%{kind: :message}), do: "in"
  defp message_direction(_entry), do: nil

  attr(:recovery, :map, required: true)

  # A message routing stopped on, with the way to retry it.
  defp admission_recovery(assigns) do
    ~H"""
    <section class="story-stop admission-recovery" aria-labelledby="admission-recovery-heading">
      <h2 id="admission-recovery-heading">Routing needs attention</h2>
      <p>{Episodes.label(@recovery.summary)}</p>
      <p>The message is safe. Retry the same routing attempt after the problem is resolved.</p>
      <.action_button path={@recovery.href} label="Review recovery" />
    </section>
    """
  end

  # State belongs in the header. The body retains the actual workspace/session
  # facts and, when preparation stopped, its recorded failure reason.
  defp work_setup(assigns) do
    ~H"""
    <div class="case-event-content work-setup" data-state={@step.setup.kind}>
      <.card_heading title="Work setup">
        <:meta>
          <span class={"event-state tone-#{@step.tone}"}>{@step.setup.label}</span>
        </:meta>
      </.card_heading>
      <.fact_list facts={@step.setup.rows} class="setup-facts" />
      <p :if={@step.summary} class="case-event-summary">{@step.summary}</p>
      <.disclosure
        :if={@step.setup.diagnostics != []}
        id={"setup-diagnostics-#{@step.id}"}
        label="Failure diagnostics"
        kind={:diagnostic}
        class="case-event-details"
      >
        <.fact_list facts={@step.setup.diagnostics} />
      </.disclosure>
    </div>
    """
  end

  # A current/final checklist is not a historical event. Each title goes back
  # to the event that supplied this status, outside this untimed summary.
  defp progress_plan(assigns) do
    steps = if assigns.plan, do: assigns.plan.steps, else: []
    stages = MapSet.new(assigns.task.stages, & &1["stage"])

    assigns =
      assign(assigns, :unassigned, %{steps: Enum.reject(steps, &MapSet.member?(stages, &1.stage))})

    ~H"""
    <Kit.section_card
      id="work-plan-summary"
      title={if(@plan, do: "Progress and plan", else: "Progress")}
      class="task-progress work-plan-summary"
    >
      <ol class="task-stage-list">
        <li
          :for={stage <- @task.stages}
          data-state={stage["state"]}
          data-stage={stage["stage"]}
          class={["task-stage", stage["current"] && "task-progress-current"]}
        >
          <span class="task-progress-glyph" aria-hidden="true">
            <.icon :if={stage["state"] == "completed"} name={:check} />
            <span :if={stage["state"] != "completed"}>{Slack.task_state_glyph(stage["state"])}</span>
          </span>
          <div class="task-stage-content">
            <div class="task-progress-row">
              <a :if={stage["url"]} href={stage["url"]} target="_blank" rel="noopener noreferrer">{stage_text(
                stage
              )}</a>
              <span :if={!stage["url"]}>{stage_text(stage)}</span>
              <span :if={stage["your_turn"]} class="task-progress-turn">← your turn</span>
            </div>
            <p :if={stage["reason"]} class="task-progress-reason">{stage["reason"]}</p>
            <.plan_steps
              :if={
                @plan && stage["state"] != "completed" &&
                  stage_plan(@plan, stage["stage"]).steps != []
              }
              plan={stage_plan(@plan, stage["stage"])}
              prefix="plan-summary"
              changes={%{}}
              current
              compact
            />
          </div>
        </li>
      </ol>
      <div :if={@unassigned.steps != []} class="task-stage-unassigned">
        <h3>Steps without a recorded stage</h3>
        <.plan_steps plan={@unassigned} prefix="plan-summary" changes={%{}} current compact />
      </div>
    </Kit.section_card>
    """
  end

  defp stage_plan(plan, stage), do: %{steps: Enum.filter(plan.steps, &(&1.stage == stage))}

  defp work_plan(assigns) do
    ~H"""
    <Kit.section_card
      id="work-plan-summary"
      title={if(@final, do: "Final work plan", else: "Current work plan")}
      class="work-plan-summary"
    >
      <.plan_steps plan={@plan} prefix="plan-summary" changes={%{}} current />
    </Kit.section_card>
    """
  end

  attr(:plan, :map, required: true)
  attr(:prefix, :string, required: true)
  attr(:changes, :map, required: true)
  attr(:current, :boolean, default: false)
  attr(:compact, :boolean, default: false)
  attr(:collapse_completed, :boolean, default: false)

  defp plan_steps(assigns) do
    groups =
      assigns.plan.steps
      |> Enum.chunk_by(fn goal ->
        assigns.collapse_completed && goal.state == "completed" &&
          !Map.has_key?(assigns.changes, goal.goal_id)
      end)
      |> Enum.map(fn rows ->
        %{
          rows: rows,
          folded:
            assigns.collapse_completed && hd(rows).state == "completed" &&
              !Map.has_key?(assigns.changes, hd(rows).goal_id)
        }
      end)

    assigns = assign(assigns, :groups, Enum.with_index(groups))

    ~H"""
    <ol class="plan-steps">
      <%= for {group, index} <- @groups do %>
        <li
          :if={group.folded}
          class="plan-completed-group"
          style={"--completed-count:#{length(group.rows)}"}
        >
          <.disclosure
            id={@prefix <> "-completed-#{index}"}
            label={Wording.count(length(group.rows), "completed step") <> " unchanged"}
            class="plan-completed"
          >
            <.plan_steps plan={%{steps: group.rows}} prefix={@prefix} changes={@changes} />
          </.disclosure>
        </li>
        <.plan_step_rows
          :if={!group.folded}
          plan={%{steps: group.rows}}
          prefix={@prefix}
          changes={@changes}
          current={@current}
          compact={@compact}
        />
      <% end %>
    </ol>
    """
  end

  defp plan_step_rows(assigns) do
    ~H"""
    <li
      :for={goal <- @plan.steps}
      id={@prefix <> "-" <> goal.id}
      class="plan-step"
      data-state={goal.state}
      data-depth={goal.depth}
      data-changed={Map.has_key?(@changes, goal.goal_id)}
    >
      <div class="plan-step-head">
        <.dynamic_tag
          tag_name={if @current && goal.state != "working", do: "span", else: "strong"}
          class="plan-step-title"
        >
          <a :if={@current} href={"#event-" <> goal.change_id}>{goal.title}</a>
          <span :if={!@current}>{goal.title}</span>
        </.dynamic_tag>
        <span class="plan-step-status" data-tone={goal.tone}>{goal.status}</span>
      </div>
      <p :if={goal.optional || goal.attempt > 1} class="plan-step-flags">
        <span :if={goal.optional}>Optional</span>
        <span :if={goal.attempt > 1}>Attempt {goal.attempt}</span>
      </p>
      <p
        :if={plan_line(goal, @compact) && !Map.has_key?(@changes, goal.goal_id)}
        class="plan-step-line"
      >
        <span :if={elem(plan_line(goal, @compact), 0)} class="plan-step-label">
          {elem(plan_line(goal, @compact), 0)}
        </span>
        {elem(plan_line(goal, @compact), 1)}
      </p>
      <div
        :for={entry <- Map.get(@changes, goal.goal_id, [])}
        id={entry.id}
        class="plan-step-change"
      >
        <p class="plan-change-meta">
          <time datetime={DateTime.to_iso8601(entry.at)}>{clock_time(entry.at)} UTC</time>
          <span :if={entry.step.plan_change.kind == "goal"}>Added to plan</span>
          <span :if={entry.step.plan_change.kind != "goal"}>
            {entry.step.plan_change.previous_status || "Not recorded"} → {entry.step.plan_change.status}
          </span>
        </p>
        <p :if={entry.step.plan_change.kind == "goal" && goal.contract} class="plan-step-line">
          <span class="plan-step-label">Done when</span> {goal.contract}
        </p>
        <p :if={entry.step.plan_change.detail} class="plan-step-line">
          {entry.step.plan_change.detail}
        </p>
        <.plan_evidence id={entry.id <> "-evidence"} items={entry.step.plan_change.evidence} />
      </div>
      <.plan_evidence
        :if={!Map.has_key?(@changes, goal.goal_id)}
        id={@prefix <> "-evidence-" <> goal.id}
        items={goal.evidence}
      />
    </li>
    """
  end

  # One reusable card for both kinds of recorded change. It carries no later
  # status or result; the surrounding timeline supplies the record's time.
  defp plan_change(assigns) do
    latest = List.last(assigns.run.entries).step.plan_change
    changes = Enum.group_by(assigns.run.entries, & &1.step.plan_change.goal_id)
    current_ids = MapSet.new(latest.snapshot.steps, & &1.goal_id)

    # A bounded page may put an old plan beside its replacement. Keep the old
    # record's anchor and changes without counting it in the current checklist.
    replaced =
      assigns.run.entries
      |> Enum.map(& &1.step.plan_change)
      |> Enum.uniq_by(& &1.goal_id)
      |> Enum.reject(&MapSet.member?(current_ids, &1.goal_id))
      |> Enum.map(&Map.merge(&1, %{state: "replaced", status: "Replaced", tone: nil, depth: 0}))

    plan = %{latest.snapshot | steps: replaced ++ latest.snapshot.steps}
    assigns = assign(assigns, plan: plan, changes: changes, kind: latest.kind)

    ~H"""
    <div class="case-event-content plan-change">
      <.card_heading title={if(@kind == "goal", do: "Work plan created", else: "Work plan updated")}>
        <:meta>
          {Wording.count(map_size(@changes), "step")} {if(@kind == "goal",
            do: "added",
            else: "changed"
          )}
        </:meta>
      </.card_heading>
      <.plan_steps
        plan={@plan}
        prefix={@run.id}
        changes={@changes}
        collapse_completed={@kind != "goal" && length(@plan.steps) > 3}
      />
    </div>
    """
  end

  defp cleanup_run(assigns) do
    ~H"""
    <div class="case-event-content cleanup-run">
      <.card_heading title="Worker cleanup">
        <:meta>{Wording.count(length(@run.entries), "session")}</:meta>
      </.card_heading>
      <ol class="cleanup-events">
        <li :for={entry <- @run.entries} id={entry.id}>
          <time datetime={if(entry.at, do: DateTime.to_iso8601(entry.at))}>{message_timestamp(
            entry.at
          )}</time>
          <div class="cleanup-event-content">
            <strong>{entry.step.title}</strong>
            <p>{entry.step.summary}</p>
            <a :if={entry.step.href} href={entry.step.href}>Review working copy →</a>
            <.disclosure
              :if={entry.step.details != []}
              id={"event-detail-#{entry.step.id}"}
              label="Cleanup details"
            >
              <.fact_list facts={entry.step.details} />
            </.disclosure>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:items, :list, required: true)

  # The same evidence treatment on the summary and each recorded change.
  # A bounded page may omit still-retained records; unavailable destinations
  # are one counted note, never an empty disclosure or a wall of identifiers.
  defp plan_evidence(assigns) do
    {links, missing} = Enum.split_with(assigns.items, & &1.href)
    assigns = assign(assigns, links: links, missing: length(missing))

    ~H"""
    <p :if={@links != [] && length(@links) <= 3} class="plan-step-evidence">
      <span class="plan-step-label">Evidence</span>
      <.record_links items={@links} />
    </p>
    <.disclosure
      :if={length(@links) > 3}
      id={@id}
      label={Wording.count(length(@links), "evidence record")}
      class="plan-evidence"
    >
      <.record_links items={@links} />
    </.disclosure>
    <p :if={@missing > 0} class="plan-step-evidence plan-evidence-unavailable">
      {Wording.count(@missing, "evidence record")} not on this page.
    </p>
    """
  end

  # What a step says under its title: before it is done, what finishes it,
  # labelled so it never reads as work already done; once it waits, stops
  # or ends, what it recorded, and nothing when it recorded nothing.
  defp plan_line(%{detail: detail}, true) when is_binary(detail) and detail != "",
    do: {nil, detail}

  defp plan_line(_goal, true), do: nil

  defp plan_line(%{state: state, contract: contract}, false)
       when state in ["ready", "working"] and is_binary(contract),
       do: {"Done when", contract}

  defp plan_line(%{detail: detail}, false) when is_binary(detail) and detail != "",
    do: {nil, detail}

  defp plan_line(%{state: state, contract: contract}, false)
       when state in ["waiting", "blocked"] and is_binary(contract),
       do: {"Done when", contract}

  defp plan_line(_goal, false), do: nil

  attr(:items, :list, required: true)

  # Records a step cites, each a link to its place on this page, or its
  # reference when this page does not show it.
  defp record_links(assigns) do
    ~H"""
    <span class="record-links">
      <span :for={item <- @items}>
        <a :if={item.href} href={item.href}>{item.title}</a><code :if={!item.href}>{item.title}</code>
      </span>
    </span>
    """
  end

  # Evidence from one turn, written one after another, as one card of compact
  # rows (`EpisodeTrace.Work.observations/1`): what each is about and what was
  # observed, where it came from and when it was measured, and any limit on
  # what it covers. Opening a row shows the whole observation and its record.
  defp observations(assigns) do
    assigns = assign(assigns, :groups, Enum.chunk_by(assigns.step.observations, & &1.area))

    ~H"""
    <div class="case-event-content observations">
      <.card_heading title="Observations" />
      <div class="observation-rows">
        <section :for={rows <- @groups} class="observation-group">
          <h4 class="observation-area">{hd(rows).area}</h4>
          <details :for={row <- rows} id={"event-" <> row.id} class="observation-row">
            <summary>
              <.icon name={:chevron} />
              <span class="observation-summary">
                <span :if={row.effect || row.contradicts} class="observation-head">
                  <Kit.state :if={row.effect} tone={elem(row.effect, 0)} word={elem(row.effect, 1)} />
                  <span :if={row.contradicts} class="observation-flag">Contradicts its claim</span>
                </span>
                <span class="observation-text">{row.text}</span>
                <span
                  :if={observation_meta(row)}
                  class="observation-meta"
                  data-source-name={row[:source_name]}
                >
                  {observation_meta(row)}
                </span>
                <span :if={row.scope_note} class="observation-scope">
                  <span class="observation-scope-label">Scope</span> {row.scope_note}
                </span>
              </span>
            </summary>
            <div class="observation-body">
              <p :if={row.replaces != []} class="plan-step-evidence">
                <span class="plan-step-label">Replaces</span>
                <.record_links items={row.replaces} />
              </p>
              <.fact_list facts={row.details} />
            </div>
          </details>
        </section>
      </div>
    </div>
    """
  end

  # Where an observation came from, when it was measured and how fresh the
  # source says it is; a measurement with no recorded time has none here.
  defp observation_meta(row) do
    measured =
      row.measured_at && "Measured " <> ShortTime.stamp(row.measured_at, DateTime.utc_now())

    case Enum.reject([row.source, measured, row.freshness], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # A queue card is one contiguous retained custody run. Only the unsealed tail
  # may carry a current row; a later retry gets another card instead of
  # rewriting the run that preceded Routing. That row says it is current, so
  # the heading carries no badge as well: the current card is the last one.
  defp input_queue(assigns) do
    assigns = assign(assigns, :queue_events, Enum.with_index(assigns.step.queue.events))

    ~H"""
    <div class="case-event-content input-queue" data-state={@step.queue.kind}>
      <.card_heading title="Queue">
        <:detail :if={@step.queue.qualifier}>{@step.queue.qualifier}</:detail>
        <:meta>
          <span class="queue-state">{queue_status(@step.queue)}</span>
          <span
            :if={
              !@step.queue.current && is_number(@step.queue.duration_ms) &&
                @step.queue.duration_ms > 0
            }
            class="action-duration"
          >
            {Units.duration(round(@step.queue.duration_ms))}
          </span>
        </:meta>
      </.card_heading>
      <ol class="queue-events">
        <li :for={{event, index} <- @queue_events} data-kind={event.kind}>
          <time :if={event.at} datetime={DateTime.to_iso8601(event.at)}>{precise_clock(event.at)}</time>
          <div class="queue-event-content">
            <div class="queue-event-heading">
              <strong>{event.label}</strong>
              <span
                :if={index > 0 && event.at}
                class="queue-event-delta"
                title="Time since the previous queue event"
              >{queue_delta(event.at, Enum.at(@step.queue.events, index - 1).at)}</span>
            </div>
            <p>{event.reason}</p>
            <a :if={event.href} href={event.href}>{event.link_label} →</a>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  defp queue_status(%{kind: :waiting}), do: "Queued"
  defp queue_status(%{kind: :needs_attention}), do: "Needs attention"
  defp queue_status(%{kind: :retry}), do: "Retry scheduled"

  defp queue_status(queue) do
    queue.events
    |> Enum.reject(&(&1.kind == :current))
    |> List.last()
    |> then(&if(&1, do: &1.label, else: "Waiting"))
  end

  defp queue_delta(%DateTime{} = at, %DateTime{} = previous) do
    elapsed = max(DateTime.diff(at, previous, :millisecond), 0)
    text = if elapsed == 0, do: "0s", else: elapsed |> Units.duration() |> String.replace(" ", "")
    "(+#{text})"
  end

  defp queue_delta(_at, _previous), do: nil

  # Ryker's own preparation before a briefing: where routing looked for earlier
  # work, or what a Work turn selected, and what was found but left out. The
  # briefing after it shows only what the model was sent.
  defp search_card(assigns) do
    ~H"""
    <div class="case-event-content search-card">
      <.card_heading title="Context search">
        <:meta :if={@step.search.summary}>{@step.search.summary}</:meta>
      </.card_heading>
      <p :if={@step.search[:text]} class="case-event-summary">{@step.search.text}</p>
      <dl
        :if={
          @step.search.facts != [] || @step.search[:where] || @step.search[:methods] not in [nil, []]
        }
        class="context-rows search-facts"
      >
        <div :if={@step.search[:where] not in [nil, ""]}>
          <dt>Where</dt>
          <dd>{@step.search.where}</dd>
        </div>
        <div :for={{label, value} <- @step.search.facts}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
      <section :if={@step.search[:methods] not in [nil, []]} class="search-method-section">
        <h4>How it searched</h4>
        <p class="search-method-help">A request can appear under more than one method.</p>
        <ul class="search-methods">
          <li :for={method <- @step.search.methods} data-found={to_string(method.found > 0)}>
            <div
              :if={!method.expandable}
              class="ui-disclosure ui-disclosure-source search-method search-method-static"
              aria-disabled="true"
            >
              <div class="prompt-source-row"><.search_method_label method={method} /></div>
            </div>
            <.disclosure
              :if={method.expandable}
              id={"#{@step.id}-method-#{method.key}"}
              label={method.name}
              kind={:source}
              class="search-method"
            >
              <:label_content>
                <.search_method_label method={method} />
              </:label_content>
              <p :if={method.used != []} class="search-query">
                <strong>Searched for</strong> <code :for={term <- method.used}>{term}</code>
              </p>
              <p :if={method.note} class="search-method-note">{method.note}</p>
              <div :if={method.meaning && method.meaning["model"]} class="search-meaning">
                <p>
                  Compares the meaning of the current message with earlier requests. Related requests can match even when their wording or language differs.
                </p>
                <dl class="context-rows">
                  <div>
                    <dt>Embedding model</dt><dd>{method.meaning["model"]}</dd>
                  </div>
                </dl>
              </div>
              <p :if={method[:ineligible] not in [nil, 0]} class="search-empty">
                {Wording.count(method.ineligible, "result")} {Wording.word(
                  method.ineligible,
                  "was",
                  "were"
                )} excluded because their sources were outside this request's scope.
              </p>
              <article :for={result <- method.results} class="search-match">
                <header class="search-match-heading">
                  <a :if={result.href} href={result.href}>{result.title} →</a><strong :if={
                    !result.href
                  }>{result.title}</strong><span>{if result.offered,
                    do: "Offered to routing",
                    else: "Not offered"}</span>
                </header>
                <p>{result.reason}</p>
              </article>
            </.disclosure>
          </li>
        </ul>
      </section>
      <.json_disclosure
        id={@step.id <> "-record"}
        label={@step.search.record_label}
        text={@step.search.record}
        class="search-record"
      />
      <a
        :if={@step.search[:briefing_href]}
        class="search-briefing-link"
        href={@step.search.briefing_href}
      >View the model briefing →</a>
    </div>
    """
  end

  defp search_method_label(assigns) do
    ~H"""
    <span class="search-method-label">
      <span class="search-method-name">{@method.name}</span>
      <span class="search-method-found"> · {@method.found} found<span :if={
        is_integer(@method.offered)
      }> / {@method.offered} offered</span>{if @method.limit,
        do: " · limit reached"}</span>
    </span>
    """
  end

  defp precise_clock(nil), do: "Not recorded"

  defp precise_clock(at) do
    {microseconds, _precision} = at.microsecond

    Calendar.strftime(at, "%H:%M:%S") <>
      "." <> String.pad_leading(Integer.to_string(div(microseconds, 1_000)), 3, "0")
  end

  # One input, one explanation: processing-time settings, this channel's frozen
  # rules and readable evidence, then the approved decision/reason composition.
  defp participation(assigns) do
    ~H"""
    <div
      class="case-event-content participation"
      data-state={@step.engagement.state}
      data-rules-state={@step.rules.state}
    >
      <.card_heading title="Participation" />

      <section
        :if={@step.participation.state != :not_recorded}
        class="participation-section participation-settings"
        aria-label="Channel setup at the time"
      >
        <h4>Channel setup at the time</h4>
        <p :if={@step.participation.settings == []} class="case-event-summary">
          {@step.participation.summary}
        </p>
        <.fact_list
          :if={@step.participation.settings != []}
          facts={@step.participation.settings}
          class="participation-facts"
        />
      </section>

      <section
        class="participation-section participation-rules"
        aria-label="Standing rules at processing time"
      >
        <div class="participation-section-heading">
          <h4>
            {if @step.rules.state == :recorded && @step.rules.rule_count > 0,
              do: "Standing rules at the time",
              else: "Standing rules"}
          </h4>
        </div>
        <p class="case-event-summary">{@step.rules.summary}</p>
        <ul :if={@step.rules.entries != []} class="standing-rule-list">
          <li
            :for={rule <- @step.rules.entries}
            class={"standing-rule verdict-#{rule.verdict}"}
            data-verdict={rule.verdict}
          >
            <div class="standing-rule-heading">
              <strong>{rule.title}</strong>
              <p class="standing-rule-verdict">{verdict_label(rule.verdict)}</p>
            </div>
            <p class="standing-rule-reason">{rule.reason}</p>
            <div :if={rule.criteria} class="standing-rule-definition">
              <.fact_list facts={rule_facts(rule)} />
            </div>
            <a :if={rule.ref} class="standing-rule-link" href={Paths.rule(rule.ref)}>
              Open in Standing rules →
            </a>
          </li>
        </ul>
      </section>
      <section class="participation-section participation-result" aria-label="Participation outcome">
        <h4>Outcome</h4>
        <.outcome
          kind={:participation}
          quiet={@step.engagement.result != "process"}
          decision={participation_decision(@step.engagement.result)}
          reason={@step.engagement.reason}
          reason_class="case-event-summary participation-summary"
        />
      </section>
    </div>
    """
  end

  defp participation_decision("process"), do: "Process this message"
  defp participation_decision("evaluate_only"), do: "Evaluate without responding"
  defp participation_decision("ignore"), do: "Do not process this message"
  defp participation_decision(""), do: "Decision not recorded"
  defp participation_decision(result) when is_binary(result), do: Episodes.label(result)
  defp participation_decision(_unreadable), do: "Decision not recorded"

  defp verdict_label("matched"), do: "Matched"
  defp verdict_label("not_matched"), do: "Did not match"
  defp verdict_label("not_considered"), do: "Not evaluated"
  defp verdict_label("disabled"), do: "Paused"
  defp verdict_label("expired"), do: "Expired"
  defp verdict_label(other), do: Episodes.label(other)

  defp message(assigns) do
    ~H"""
    <.provider_header :if={@message[:provider]} provider={@message.provider} id={@message.id} />
    <.message_block
      :if={!@message[:provider]}
      title={message_title(@message)}
      location={if(@message[:transport] == "github", do: @message[:title])}
      sender={@message[:display_actor] || @message.actor}
      person={@message[:person]}
      class="case-message"
      data-input-id={if @message[:details], do: "ingress-input:#{@message.id}"}
    >
      <:meta>
        <time :if={@message.at} datetime={DateTime.to_iso8601(@message.at)}>
          {message_timestamp(@message.at)}
        </time>
        <span :if={@message[:status]}>{@message.status}</span>
      </:meta>
      <div>{message_text(@message)}</div>
      <.message_attachments
        :if={@message[:attachments] not in [nil, []]}
        attachments={@message.attachments}
      />
      <:footer :if={@message[:source] || @message[:details]}>
        <%!-- The body keeps a message's own line breaks; a link to where it was
        written is the footer's, beside its details. --%>
        <a
          :if={@message[:source]}
          class="message-source"
          href={@message.source.href}
          target="_blank"
          rel="noopener noreferrer"
        >{@message.source.label} ↗</a>
        <.input_details :if={@message[:details]} message={@message} />
      </:footer>
    </.message_block>
    <.input_details :if={@message[:provider] && @message[:details]} message={@message} />
    """
  end

  defp message_attachments(assigns) do
    ~H"""
    <div class="message-attachments">
      <.message_attachment :for={attachment <- @attachments} attachment={attachment} />
    </div>
    """
  end

  defp message_attachment(assigns) do
    ~H"""
    <a :if={@attachment.path} class="attachment-download" href={@attachment.path}>
      <img
        :if={@attachment.media_type in ~w(image/png image/jpeg image/webp image/gif)}
        src={@attachment.path}
        alt={"Generated attachment: " <> @attachment.name}
        loading="lazy"
      />
      <.attachment_chip attachment={@attachment} />
    </a>
    <.attachment_chip :if={!@attachment.path} attachment={@attachment} />
    """
  end

  defp attachment_chip(assigns) do
    ~H"""
    <span class="attachment-chip">
      <strong>{@attachment.name}</strong>
      <span>{@attachment.media_type} · {@attachment.bytes} bytes</span>
    </span>
    """
  end

  defp message_title(%{transport: "github"}), do: "New GitHub message"
  defp message_title(%{title: title}) when is_binary(title), do: title
  defp message_title(%{actor: "Ryker"}), do: "Sent response"
  defp message_title(%{event_kind: :edit}), do: "Message edited"
  defp message_title(%{event_kind: :delete}), do: "Message deleted"
  defp message_title(%{answer: true}), do: "Answer to Ryker's question"
  defp message_title(%{event_kind: :event}), do: "Incoming event"
  defp message_title(_message), do: "Incoming message"

  # A notification's status is a plain fact inside its body, not a coloured
  # badge. Recognition still proves a format, not an authenticated sender.
  defp provider_header(assigns) do
    assigns = assign(assigns, :facts, provider_facts(assigns.provider))

    ~H"""
    <div
      class={"provider-message provider-#{@provider.provider}"}
      data-provider={@provider.provider}
      data-input-id={"ingress-input:#{@id}"}
    >
      <.card_heading title={@provider.name}>
        <:detail>via {source_transport(@provider)}</:detail>
      </.card_heading>
      <div class="provider-body">
        <p :if={@provider.subject || @provider.links != []} class="provider-subject">
          <span :if={@provider.subject}>{@provider.subject}</span>
          <span :if={@provider.links != []} class="provider-links">
            <a
              :for={link <- @provider.links}
              href={link.href}
              target="_blank"
              rel="noopener noreferrer"
            >{if @provider.provider == :grafana && link.label == "Open alert",
              do: "View on Grafana",
              else: link.label} ↗</a>
          </span>
        </p>
        <.fact_list :if={@facts != []} facts={@facts} class="provider-facts" />
        <.disclosure
          :for={group <- @provider[:groups] || []}
          label={group.label}
          class="provider-group"
          id={"provider-#{@id}-#{@provider.provider}-#{String.downcase(group.label)}"}
        >
          <.fact_list facts={group.entries} />
        </.disclosure>
      </div>
    </div>
    """
  end

  defp provider_facts(%{state: nil, facts: facts}), do: facts

  defp provider_facts(%{state: state, facts: facts}),
    do: [%{label: "Status", value: state} | facts]

  defp source_transport(%{provider: :grafana}), do: "webhook"
  defp source_transport(_provider), do: "Slack"

  # What the rule looked for and where, then what the check found in this
  # message, one row per condition.
  defp rule_facts(rule) do
    [
      %{label: "Looks for", value: rule_criteria(rule.criteria) <> rule_place(rule.scope_ref)}
    ] ++
      rule_filter_facts(rule.criteria["filter"], "") ++
      rule_evidence(rule.criteria, rule.evidence)
  end

  defp rule_criteria(%{"source_kind" => source}), do: "#{source_name(source)} events"

  # Present the recorded filter, not an interpretation of what its matcher does.
  # Paths retain array positions, and empty values remain distinct from absent fields.
  defp rule_filter_facts(filter, path) when is_map(filter) and map_size(filter) > 0 do
    filter
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} ->
      rule_filter_facts(value, rule_filter_path(path, key))
    end)
  end

  defp rule_filter_facts([_ | _] = values, path) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> rule_filter_facts(value, "#{path}[#{index}]") end)
  end

  defp rule_filter_facts(value, path) do
    [%{label: if(path == "", do: "Filter", else: path), value: rule_filter_value(value)}]
  end

  defp rule_filter_path(path, key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z_0-9]*$/, key) do
      if path == "", do: key, else: path <> "." <> key
    else
      path <> "[" <> Jason.encode!(key) <> "]"
    end
  end

  defp rule_filter_value(""), do: "Empty text"
  defp rule_filter_value(value) when is_binary(value), do: Jason.encode!(value)
  defp rule_filter_value([]), do: "Empty list"
  defp rule_filter_value(value) when is_map(value) and map_size(value) == 0, do: "Empty object"
  defp rule_filter_value(value), do: Jason.encode!(value)

  defp rule_place("slack:" <> _rest = scope), do: " in " <> Slack.destination_name(scope)
  defp rule_place(_scope), do: ""

  defp rule_evidence(_criteria, nil), do: []

  defp rule_evidence(%{"source_kind" => source}, evidence) do
    [
      %{
        label: "Source",
        value:
          if(evidence["source_matches"],
            do: "#{source_name(evidence["source_kind"])}, which this rule listens to",
            else:
              "#{source_name(evidence["source_kind"])}; this rule only listens to #{source_name(source)}"
          )
      },
      %{
        label: "Fields",
        value:
          if(evidence["filter_matches"],
            do: "Every field in the filter matched",
            else: "The message's fields did not match the filter"
          )
      }
    ]
  end

  defp source_name("github"), do: "GitHub"
  defp source_name("slack"), do: "Slack"
  defp source_name(source), do: Episodes.label(source)

  # The raw envelope, the normalized input and the original message are peer
  # collapsed bodies, loaded when opened. Raw and normalized are never
  # shown under each other's name, and an unrecorded envelope says so.
  defp input_details(assigns) do
    ~H"""
    <.input_body
      id={"input-raw-#{@message.id}"}
      title="Raw input (JSON)"
      body={@message.details.raw}
      absent={@message.details.raw.absent}
    />
    <.input_body
      id={"input-normalized-#{@message.id}"}
      title="Normalized input (JSON)"
      body={@message.details.normalized}
      absent="The normalized input was not retained."
    />
    <.disclosure class="input-body" id={"input-original-#{@message.id}"} label="Original message">
      <p :if={!@message.available} class="artifact-unavailable">
        Source content not recorded or expired.
      </p>
      <pre :if={@message.available}>{@message.text}</pre>
    </.disclosure>
    """
  end

  defp input_body(assigns) do
    assigns = assign(assigns, :artifact, assigns.body.artifact)

    ~H"""
    <.disclosure
      class="input-body"
      id={@id}
      label={@title}
      data-artifact={if @artifact.state in [:collapsed, :retained], do: @body.artifact_id}
      data-revoked={if @artifact.state in [:expired], do: "true"}
    >
      <:meta>
        <span :if={@artifact.state == :collapsed}>{EpisodeRequest.artifact_size(@artifact.bytes)}</span>
        <span :if={@artifact.state == :expired}>Expired</span>
        <span :if={@artifact.state == :not_recorded}>Not recorded</span>
        <span :if={@artifact.state == :omitted}>Omitted</span>
        <span :if={@artifact[:truncated]}>Partial display</span>
      </:meta>
      <p :if={@artifact.state == :collapsed} class="artifact-loading" role="status">Loading…</p>
      <p :if={@artifact.state == :not_recorded} class="artifact-unavailable">{@absent}</p>
      <p :if={@artifact.state == :expired} class="artifact-unavailable">
        Removed after the retention period.
      </p>
      <p :if={@artifact.state == :omitted} class="artifact-unavailable">
        {omission(@artifact)}
      </p>
      <pre :if={@artifact.state == :retained}>{@artifact.text}</pre>
    </.disclosure>
    """
  end

  defp omission(%{reason: "oversized", omitted_bytes: bytes}) do
    "The source payload was #{EpisodeRequest.artifact_size(bytes)}, over the 64 KiB limit, so it wasn't stored."
  end

  defp omission(%{reason: reason}), do: "The source payload was not stored (#{reason})."

  defp message_text(%{available: false}), do: "Source content not recorded or expired"

  defp message_text(%{transport: "slack", workspace: workspace, text: text}) when is_binary(text),
    do: SlackMarkdown.html(text, workspace)

  defp message_text(message), do: SlackMarkdown.html(message.text)

  defp event(assigns) do
    ~H"""
    <div class="case-event-content">
      <.card_heading title={event_title(@step)}>
        <:meta :if={show_event_state?(@step) || @step.duration_ms}>
          <span
            :if={show_event_state?(@step)}
            class={"event-state tone-#{@step.tone}"}
          >{Episodes.label(@step.state)}</span>
          <span :if={@step.duration_ms}>{Units.duration(@step.duration_ms)}</span>
        </:meta>
      </.card_heading>
      <p
        :for={paragraph <- summary_paragraphs(@step)}
        :if={@step.summary != event_title(@step)}
        class="case-event-summary"
      >
        {paragraph}
      </p>
      <p :if={@step[:current_warning]} class="action-error">
        <strong>Current scheduling status:</strong> {@step.current_warning}
      </p>
      <div :if={@step[:candidate_response]} class="candidate-evidence">
        <EpisodeRequest.candidate_response
          :if={
            @step.candidate_response.artifact &&
              @step.candidate_response.artifact.state in [:retained, :expired]
          }
          response={@step.candidate_response.artifact}
          attempt={@step.candidate_response.attempt}
          prefix={@step.candidate_response.prefix}
          sent={@step.candidate_response[:sent] || false}
          title_update={@step.candidate_response[:title_update]}
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
        <.evidence_body
          :for={{item, index} <- Enum.with_index(@step.artifacts)}
          id={"tool-evidence-#{@step.id}-#{index}"}
          item={item}
        />
      </div>
      <.disclosure
        :if={@step.details != [] || @step.href}
        id={"event-detail-#{@step.id}"}
        label={if @step.stage == "Tool call", do: "Call metadata", else: "Details"}
        class="case-event-details"
      >
        <.event_details step={@step} />
      </.disclosure>
    </div>
    """
  end

  defp finding(assigns) do
    ~H"""
    <div class="case-event-content finding-card">
      <.card_heading title="Finding" />
      <div class="finding-content">
        <div class="finding-conclusion markdown-preview">
          {SlackMarkdown.html(@step.finding.conclusion)}
        </div>
        <section :if={@step.finding.reason} class="finding-reason">
          <h4>Why</h4>
          <div class="markdown-preview">{SlackMarkdown.html(@step.finding.reason)}</div>
        </section>
        <.fact_list
          class="finding-metadata"
          facts={
            Enum.reject(
              [
                %{label: "Assessment", value: @step.finding.status},
                %{label: "Scope", value: @step.finding.scope}
              ],
              &is_nil(&1.value)
            )
          }
        />
        <.plan_evidence id={"finding-#{@step.id}-evidence"} items={@step.finding.evidence} />
      </div>
    </div>
    """
  end

  defp delivery_message(assigns) do
    ~H"""
    <div class="case-event-content delivery-message">
      <.card_heading title={@step.title} />
      <.message_block sender="Ryker">
        {SlackMarkdown.html(@step.message.text)}
      </.message_block>
      <p class="delivery-message-note">{@step.summary}</p>
    </div>
    """
  end

  defp worker_activity(assigns) do
    {label, title} = activity_heading(assigns.step)
    summary = if assigns.step.summary not in [nil, ""], do: assigns.step.summary

    assigns =
      assign(assigns,
        title: label || title,
        summary: summary,
        note_topic:
          if(label,
            do: title || if(!summary, do: "Note text was not recorded.")
          )
      )

    ~H"""
    <.activity_note
      title={@title}
      tone={@step.tone}
      details_id={"event-detail-#{@step.id}"}
    >
      <:meta :if={show_event_state?(@step) || @step.duration_ms}>
        <span :if={show_event_state?(@step)}>{Episodes.label(@step.state)}</span>
        <span :if={@step.duration_ms}>{Units.duration(@step.duration_ms)}</span>
      </:meta>
      <:body :if={@summary || @note_topic}>
        <div class="activity-narrative">
          <p :if={@note_topic} class="activity-note-topic">{@note_topic}</p>
          <div :if={@summary} class="markdown-preview">{SlackMarkdown.html(@summary)}</div>
        </div>
      </:body>
      <:evidence :if={@step.artifacts != []}>
        <.evidence_body
          :for={{item, index} <- Enum.with_index(@step.artifacts)}
          id={"tool-evidence-#{@step.id}-#{index}"}
          item={item}
        />
      </:evidence>
      <:details :if={@step.details != [] || @step.href}>
        <.event_details step={@step} />
      </:details>
    </.activity_note>
    """
  end

  defp activity_heading(%{stage: "Thinking", title: "Model's note"}), do: {"Model's note", nil}

  defp activity_heading(%{stage: "Thinking", title: title}),
    do: {"Model's note", String.replace_prefix(title, "Model's note: ", "")}

  defp activity_heading(step), do: {nil, step.title}

  defp event_wait(assigns) do
    ~H"""
    <div class="case-event-content event-wait">
      <.card_heading title="Wait prepared" />
      <p class="wait-verification">{@step.wait.verification}</p>
      <p class="wait-trigger">
        <span>{@step.wait.trigger}</span><span>{if @step.wait.deadline,
          do: "Until " <> @step.wait.deadline,
          else: "No deadline"}</span>
      </p>
      <dl :if={@step.wait.conditions != []} class="wait-match">
        <div :for={condition <- @step.wait.conditions}>
          <dt>{condition.label}</dt>
          <dd>
            <a :if={condition.href} href={condition.href}>{condition.value}</a><div
              :if={!condition.href && condition.markdown?}
              class="markdown-preview"
            >
              {SlackMarkdown.html(condition.value)}
            </div>
            <span :if={!condition.href && !condition.markdown?}>{condition.value}</span>
          </dd>
        </div>
      </dl>
      <.fact_list :if={@step.wait.timing != []} facts={@step.wait.timing} />
      <p :if={@step.current_warning} class="action-error">
        <strong>Current scheduling status:</strong> {@step.current_warning}
      </p>
      <.disclosure
        id={"wait-details-#{@step.id}"}
        label="Technical details"
        class="case-event-details"
      >
        <.event_details step={@step} />
        <.json_disclosure id={"wait-record-#{@step.id}"} label="Wait record" text={@step.wait.record} />
      </.disclosure>
    </div>
    """
  end

  # One retained tool body. It is not in the page until the reader opens it, and
  # a confirmed expiry closes it instead of restoring their place around content
  # that is gone.
  defp evidence_body(assigns) do
    assigns = assign(assigns, :artifact, assigns.item.artifact)

    ~H"""
    <.disclosure
      id={@id}
      label={@item.label}
      data-artifact={if @artifact.state in [:collapsed, :retained], do: @item[:artifact_id]}
      data-revoked={if @artifact.state in [:expired, :not_recorded], do: "true"}
    >
      <:meta>
        <span :if={@artifact.state == :collapsed}>{EpisodeRequest.artifact_size(@artifact.bytes)}</span><span :if={
          @artifact.truncated
        }>Partial display</span>
      </:meta>
      <p :if={@artifact.state == :collapsed} class="artifact-loading" role="status">Loading…</p>
      <p :if={@artifact.state in [:expired, :not_recorded]} class="artifact-unavailable">
        {if @artifact.state == :expired,
          do: "Removed after the retention period.",
          else: "This body was not recorded."}
      </p>
      <pre :if={@artifact.state == :retained}>{@artifact.text}</pre>
    </.disclosure>
    """
  end

  defp event_details(assigns) do
    ~H"""
    <a :if={@step.href} href={@step.href}>Inspect related record →</a>
    <.fact_list :if={@step.details != []} facts={@step.details} />
    """
  end

  defp show_event_state?(%{stage: "Validation", state: state}) when state in ["accept", "reject"],
    do: false

  defp show_event_state?(step) do
    step.state not in [nil, ""] &&
      step.stage not in ["Preparation", "Execution", "Evidence"] &&
      not String.contains?(
        String.downcase(event_title(step)),
        String.downcase(Episodes.label(step.state))
      )
  end

  defp event_title(%{stage: "Tool call", title: "Tool call", summary: summary})
       when is_binary(summary), do: summary

  defp event_title(step), do: if(silent_result?(step), do: "No reply sent", else: step.title)

  defp silent_result?(%{stage: "Result", details: details}),
    do: Enum.any?(details, &(&1.label == "Delivery" && &1.value == "none"))

  defp silent_result?(_step), do: false

  defp chapter_title(%{band: :learning}), do: "Learning"
  defp chapter_title(%{band: :maintenance}), do: "Cleanup"

  defp chapter_title(%{band: :ready, conversation_turn: turn}) when turn > 1,
    do: "New input received"

  defp chapter_title(%{band: :ready}), do: "Getting ready"
  defp chapter_title(%{band: :routing}), do: "Routing"
  defp chapter_title(%{band: :work}), do: "The work"
  defp chapter_title(%{band: :answer}), do: "The answer"
  defp chapter_title(chapter), do: chapter.title

  defp phase_title(:ready), do: "Intake"
  defp phase_title(:routing), do: "Routing"
  defp phase_title(:work), do: "Work"
  defp phase_title(:answer), do: "Answer"
  defp phase_title(band), do: chapter_title(%{band: band})

  defp chapter_description(:ready),
    do: "The message and context that started this part of the conversation."

  defp chapter_description(:routing) do
    "The model call that decides whether to respond, continue earlier work, or leave the message alone."
  end

  defp chapter_description(:work),
    do: "The model's briefing, progress, tool calls, and results."

  defp chapter_description(:answer),
    do: "What the model returned and what Ryker decided to do."

  defp chapter_description(:learning) do
    "Background learning from these messages, once the work they started has stopped. It sends no reply."
  end

  defp chapter_description(:maintenance),
    do: "What happened afterwards to the worker Ryker used and its working copy."

  # Each plan change links to its own event; evidence links to its row.
  defp step_record_links(%{observations: rows}) when is_list(rows) do
    for row <- rows, is_binary(row.record_ref) do
      {row.record_ref, %{href: "#event-" <> row.id, title: row.area}}
    end
  end

  defp step_record_links(%{record_ref: ref} = step) when is_binary(ref),
    do: [{ref, %{href: "#event-#{step.id}", title: step.title}}]

  defp step_record_links(_step), do: []

  defp entries(snapshot, timeline) do
    record_links =
      for step <- snapshot.trace.steps,
          link <- step_record_links(step),
          into: %{},
          do: link

    requests = requests_with_links(timeline.items, record_links)

    messages =
      Enum.map(snapshot.trace.case_file.conversation, fn message ->
        %{
          id: "story-message-#{message.id}",
          owner: message[:owner] || :episode,
          at: message.at,
          kind: :message,
          message: message,
          band: if(message.actor == "Ryker", do: :outcome, else: :input),
          # A task's own request opens the task; it is not a new message of it.
          boundary: Map.get(message, :boundary, true)
        }
      end)

    copies = visible_copies(snapshot.trace.steps, messages, timeline.items)

    # A reply sent exactly as checked is read once, in the conversation; the
    # check keeps its verdict and does not repeat the text.
    sent =
      for %{message: message} <- messages,
          anchor = sent_as_checked(message, requests),
          into: MapSet.new(),
          do: anchor

    # The timeline also carries Ryker's own steps, such as the search for
    # earlier work; only model calls have response sections.
    responses =
      for %{kind: :request, sections: sections} <- requests,
          section <- sections,
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
          step: Map.put(step, :candidate_response, sent_response(responses[step.id], sent)),
          band: step.band
        }
      end)

    # Stable sort preserves the trace's numeric sequence/lifecycle ordering on ties.
    Enum.sort_by(messages ++ steps ++ requests, &unix(&1.at || &1[:sort_at]))
  end

  defp sent_response(%{prefix: prefix, attempt: attempt} = response, sent) do
    if MapSet.member?(sent, "#{prefix}-response-#{attempt}-body"),
      do: Map.put(response, :sent, true),
      else: response
  end

  defp sent_response(response, _sent), do: response

  defp requests_with_links(requests, record_links) do
    candidate_links =
      for %{source_kind: :admission, phase: :submission} = request <- requests,
          into: %{},
          do: {request.id, RequestContextHTML.candidate_links(request.sections, request.id)}

    Enum.map(requests, fn request ->
      call_id = String.replace_suffix(request.id, "-result", "")

      request
      |> Map.put(:record_links, record_links)
      |> Map.put(:candidate_links, candidate_links[call_id] || %{})
    end)
  end

  # The checked answer a reply was sent exactly as, by the anchor of its
  # response on the timeline. A changed, missing or truncated candidate is
  # never one: its card must keep showing what the model wrote.
  defp sent_as_checked(message, requests) do
    if delivered_message?(message) do
      id = "request-#{message.id}-result"

      with %{sections: sections} <- Enum.find(requests, &(&1.id == id)),
           %{artifact: %{state: :retained, truncated: false, text: text}} <-
             Enum.find(sections, &(&1.id == "candidate")),
           {:ok, %{"message" => body}} when is_binary(body) <- Jason.decode(text),
           true <- body == message.text,
           %{attempt: attempt} <- EpisodeRequest.latest_archived_response(sections) do
        "turn-#{message.id}-response-#{attempt}-body"
      else
        _ -> nil
      end
    end
  end

  defp visible_copies(steps, messages, requests) do
    input_ids = for %{message: message} <- messages, message.actor != "Ryker", do: message.id

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

  defp delivered_message?(message) do
    message.actor == "Ryker" && message[:delivery_ref] &&
      (message[:delivered] || message[:status] == "Response sent")
  end

  # Kernel transitions are recognised by their durable id and stage, never by
  # the words a person reads for them.
  defp redundant_step?(%{id: "kernel-" <> _, stage: "Input"} = step, copies),
    do: step[:input_id] in copies.input_ids

  defp redundant_step?(%{id: "kernel-" <> _, stage: "Result"} = step, copies),
    do: step[:result_ref] in copies.result_refs

  # The message body can expire independently of its delivery receipt. Keep the
  # exact turn receipt and hide only its matching kernel lifecycle confirmation.
  defp redundant_step?(%{id: "kernel-" <> _, stage: "Delivery"} = step, copies) do
    step[:delivery_ref] in copies.delivery_refs ||
      step[:delivery_ref] in copies.confirmed_delivery_refs
  end

  defp redundant_step?(%{stage: "Delivery", state: "delivered"} = step, copies),
    do: step[:delivery_ref] in copies.delivery_refs

  # A Work update that reached the conversation is read in it, as the message
  # it became; its confirmation says nothing more.
  defp redundant_step?(%{stage: "Platform action", state: "confirmed"} = step, copies),
    do: step[:delivery_ref] in copies.delivery_refs

  defp redundant_step?(step, copies) do
    String.ends_with?(step.id, "-prepared") &&
      String.replace(step.id, ~r/^turn-(.*)-prepared$/, "request-\\1") in copies.briefing_ids
  end

  defp unix(nil), do: 9_223_372_036_854_775_807
  defp unix(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> unix()
  defp unix(at), do: DateTime.to_unix(at, :microsecond)
  defp clock_time(nil), do: "Not recorded"
  defp clock_time(at), do: Calendar.strftime(at, "%H:%M:%S")

  defp message_timestamp(%DateTime{} = at),
    do: "#{at.day} #{Calendar.strftime(at, "%b, %H:%M:%S UTC")}"

  defp message_timestamp(_at), do: "Not recorded"
  # The label says where the heading came from: Ryker's own name for the
  # request, a task's title, or the message that started it.
  defp page_label(nil, case_file), do: title_label(case_file)
  defp page_label(_task, _case_file), do: "Task"

  # A task names the request it was asked in, the way its Slack thread does.
  defp task_relation(%{title: title}), do: "Asked in " <> title

  # How long a task took, has been running, or has been open, from its
  # confirmation. A stopped task said "Running for", which read as work still
  # going on (audit F07, 2026-10-12).
  defp task_time_label(%{state: state}, _page_state) when state in [:complete, :cancelled],
    do: "Took"

  defp task_time_label(_episode, "working"), do: "Running for"
  defp task_time_label(_episode, _page_state), do: "Open for"

  defp task_time(%{state: state, created_at: from, updated_at: to})
       when state in [:complete, :cancelled],
       do: Units.duration(max(DateTime.diff(to, from, :millisecond), 0))

  defp task_time(%{created_at: from}),
    do: Units.duration(max(DateTime.diff(DateTime.utc_now(), from, :millisecond), 0))

  # A stage row in the Slack card's words: a count or #617 reads on after its
  # name, anything else after a "·".
  defp stage_text(%{"stage" => stage, "detail" => detail}) do
    label = Slack.task_phase_label(stage)

    cond do
      is_nil(detail) -> label
      String.starts_with?(detail, ["#", "←"]) -> label <> " " <> detail
      true -> label <> " · " <> detail
    end
  end

  defp title_label(%{title_kind: :episode}), do: "Request"
  defp title_label(%{title_kind: :task}), do: "Task"
  defp title_label(_case_file), do: "Initial request"

  defp base(snapshot), do: Paths.request(snapshot.episode.id)

  # A Chat request's source is the Chat itself; the header links there once.
  defp source_link(%{
         trace: %{source: %{href: href}},
         episode: %{conversation_link: %{href: href}}
       }),
       do: nil

  defp source_link(snapshot), do: snapshot.trace.source
  # The timeline's last line says in words what is happening, and only work in progress moves
  # (Andrew, 2026-10-01: it read "No visible answer yet · continue work").
  defp pending_answer_label(%{episode: %{state: :cancelled}}), do: "Stopped"
  defp pending_answer_label(%{episode: %{state: :complete}}), do: "No further reply was sent"

  defp pending_answer_label(%{episode: %{state: :waiting_for_input}}),
    do: "Waiting for your answer"

  defp pending_answer_label(%{episode: %{state: :waiting_for_event}}),
    do: "Waiting for an event"

  defp pending_answer_label(%{trace: %{case_file: %{reply: nil}}}), do: "Ryker is working on this"
  defp pending_answer_label(_), do: "Follow-up in progress"

  defp wait_state(%{episode: %{state: state}}) when state in [:cancelled, :complete], do: "done"

  defp wait_state(%{episode: %{state: state}})
       when state in [:waiting_for_input, :waiting_for_event],
       do: "waiting"

  defp wait_state(_snapshot), do: "working"

  defp wait_text(snapshot) do
    case {wait_state(snapshot), snapshot.episode.state} do
      {"working", _state} -> "New steps appear here as they happen."
      {"waiting", :waiting_for_input} -> "Answer Ryker's question in the conversation to go on."
      {"waiting", _state} -> "The work goes on when it arrives."
      {"done", _state} -> nil
    end
  end

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
      |> Enum.find(&(&1.actor == "Ryker"))

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

  defp wall_time(%{milliseconds: milliseconds}) when is_integer(milliseconds),
    do: Units.duration(milliseconds)

  defp wall_time(_wall), do: "Not measured"

  defp wall_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp wall_reason(_wall), do: nil

  defp response_label(%{measured: measured}) when measured > 1, do: "Average response"
  defp response_label(_response), do: "Response time"

  defp response_time(%{measured: measured, average_ms: milliseconds}, _wall)
       when measured > 0 and is_integer(milliseconds),
       do: Units.duration(milliseconds)

  defp response_time(_response, %{state: :active}), do: "Waiting"
  defp response_time(_response, _wall), do: "Not measured"

  defp response_note(%{measured: measured, minimum_ms: minimum, maximum_ms: maximum})
       when measured > 1 and is_integer(minimum) and is_integer(maximum),
       do: "min #{Units.duration(minimum)}, max #{Units.duration(maximum)}"

  defp response_note(_response), do: nil

  defp empty_response_metrics do
    %{
      messages: %{received: 0, sent: 0, total: 0},
      response: %{
        average_ms: nil,
        expected: 0,
        maximum_ms: nil,
        measured: 0,
        minimum_ms: nil
      },
      wall: %{state: :unknown, milliseconds: nil, reason: "Timing was not projected."}
    }
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
      |> Enum.map(&("+" <> Units.duration(max(div(unix(&1) - unix(started), 1_000), 0))))
      |> Enum.uniq()

    Enum.join(offsets, " → ")
  end

  defp cost(%{costed: _} = totals), do: Units.cost(totals)

  defp cost(_), do: "Cost not reported"
end

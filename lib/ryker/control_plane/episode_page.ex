defmodule Ryker.ControlPlane.EpisodePage do
  alias Ryker.Accounting.Pricing
  alias Ryker.ControlPlane.SlackMarkdown

  @moduledoc "One chronological case file: conversation, model requests, host decisions and delivery."
  use Phoenix.Component
  import Ryker.ControlPlane.Components

  alias Ryker.ControlPlane.{
    EpisodeRequest,
    EpisodeTrace,
    RequestContextHTML,
    RequestPage,
    SlackNames
  }

  @conversation_bands [:ready, :routing, :work, :answer]

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
    assigns = assign(assigns, :timeline_groups, timeline_groups(chapters))

    ~H"""
    <div class="episode-workbench execution-document">
      <div class="episode-page-intro">
        <.link navigate="/" class="back-to-activity">← Activity</.link>
        <div class="episode-title-row">
          <div class="episode-title-copy">
            <p class="episode-initial-label">{title_label(@snapshot.trace.case_file)}</p>
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
          <.status :if={!@startup} state={to_string(@snapshot.episode.state)} />
          <time>{timestamp(@snapshot.trace.received_at)}</time>
          <a
            :if={!@startup}
            href={outcome_anchor(@snapshot)}
          >Jump to latest outcome ↓</a>
          <a
            :if={@snapshot.trace.source}
            href={@snapshot.trace.source.href}
            target="_blank"
            rel="noopener noreferrer"
          >{@snapshot.trace.source.label} →</a>
          <a
            :if={@snapshot.episode[:conversation_link]}
            href={@snapshot.episode.conversation_link.href}
          >{@snapshot.episode.conversation_link.label} →</a>
          <a
            :if={@snapshot.episode[:transport] == "slack" && @snapshot.episode[:thread_ref]}
            href={
              Ryker.ControlPlane.Activity.conversation_path(
                @snapshot.episode.transport,
                @snapshot.episode.conversation_ref,
                @snapshot.episode.thread_ref
              )
            }
            target="_blank"
            rel="noopener noreferrer"
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
      <section :if={!@startup} class="episode-metrics" aria-label="Execution summary">
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
            Ryker.ControlPlane.Activity.conversation_path(
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
      <section :if={@snapshot.trace.stopped && !@startup} class="story-stop">
        <p class="ui-eyebrow">NEXT ACTION</p><h3>{@snapshot.trace.stopped.headline}</h3>
        <p>{@snapshot.trace.stopped.reason}</p><strong>{@snapshot.trace.stopped.action}</strong>
        <.disclosure
          :if={@snapshot.trace.stopped[:model_output]}
          class="recovery-worker-report"
          id="recovery-worker-report"
          label="Worker’s saved response"
        >
          <p class="recovery-attribution">
            {@snapshot.trace.stopped[:delivery]} This is the worker’s report, not an independently verified check result.
          </p>
          <div class="recovery-model-output">
            {Phoenix.HTML.raw(SlackMarkdown.preview(@snapshot.trace.stopped.model_output))}
          </div>
        </.disclosure>
        <a
          :if={@snapshot.trace.stopped.href}
          class="ui-button secondary"
          href={@snapshot.trace.stopped.href}
        >{@snapshot.trace.stopped[:link_label] || "Open recovery"} <.icon name={:arrow} /></a>
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
      <Ryker.ControlPlane.WorkerEvidenceCard.render episode_id={@snapshot.episode[:id]} />
      <.execution_timeline
        snapshot={@snapshot}
        timeline={@timeline}
        groups={@timeline_groups}
        params={@params}
      />
      <.disclosure
        id={"request-identity-#{@snapshot.episode.ref}"}
        label="Request identity"
        class="story-identity"
      >
        <.fact_list facts={episode_identity(@snapshot)} />
      </.disclosure>
      <.disclosure
        id={"review-history-#{@snapshot.episode.ref}"}
        label="Review history"
        class="story-review"
      >
        <p :if={@snapshot.trace.review[:at] == nil && @snapshot.trace.review[:note] in [nil, ""]}>
          Not reviewed
        </p>
        <p :if={@snapshot.trace.review[:note] not in [nil, ""]}>
          {@snapshot.trace.review[:note]
          |> Ryker.ControlPlane.InspectionRedactor.artifact(max_bytes: 2_048)
          |> Map.fetch!(:text)}
        </p>
        <.fact_list facts={review_identity(@snapshot)} />
      </.disclosure>
    </div>
    """
  end

  defp episode_identity(snapshot) do
    [
      %{label: "Request ID", value: snapshot.episode.ref, identifier: true},
      %{label: "Conversation", value: SlackNames.destination(snapshot.episode.destination)},
      %{label: "Destination ID", value: snapshot.episode.destination, identifier: true},
      %{label: "Created", value: timestamp(snapshot.episode.created_at)}
    ]
  end

  defp review_identity(snapshot) do
    case snapshot.trace.review[:at] do
      nil -> []
      at -> [%{label: "Reviewed", value: timestamp(at)}]
    end
  end

  @doc """
  The page heading for a message that has not become an episode yet.

  It is the same furniture as an episode: the title of the request, its state,
  where it came from and when. A message waiting on routing is an episode that
  has not started, not a different kind of thing with a page of its own.
  """
  attr(:title, :string, required: true)
  attr(:received_at, :any, default: nil)
  attr(:source, :any, default: nil)
  attr(:conversation_link, :map, default: nil)

  def unrouted_intro(assigns) do
    ~H"""
    <div class="episode-page-intro">
      <.link navigate="/" class="back-to-activity">← Activity</.link>
      <div class="episode-title-row">
        <h1>{@title}</h1><.status state="not_started" />
      </div>
      <p class="episode-location">
        <time :if={@received_at}>{timestamp(@received_at)}</time>
        <a :if={@source} href={@source.href} target="_blank" rel="noopener noreferrer">{@source.label} →</a>
        <a :if={@conversation_link} href={@conversation_link.href}>{@conversation_link.label} →</a>
      </p>
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

  @doc "Groups foreground phases under the message that caused them."
  def timeline_groups(chapters) do
    {background, foreground} = Enum.split_with(chapters, &background_band?(&1.band))

    conversations =
      foreground
      |> Enum.group_by(& &1.conversation_turn)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {conversation_turn, owned} ->
        %{
          band: :conversation,
          conversation_turn: conversation_turn,
          kind: :conversation,
          marker: if(conversation_turn > 0, do: "M#{conversation_turn}", else: "—"),
          phases: grouped_phases(owned),
          title:
            if(conversation_turn > 0,
              do: "Message #{conversation_turn}",
              else: "Episode setup"
            )
        }
      end)

    backgrounds =
      background
      |> Enum.group_by(& &1.band)
      |> Enum.sort_by(fn {_band, owned} -> first_step_time(owned) end, DateTime)
      |> Enum.map(fn {band, owned} ->
        %{
          band: band,
          conversation_turn: nil,
          description: chapter_description(band),
          kind: :background,
          marker: phase_number(band),
          phases: [merge_phase(owned)],
          title: chapter_title(List.first(owned))
        }
      end)

    conversations ++ backgrounds
  end

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
          aria-labelledby={
            if(group.kind == :conversation, do: "chapter-#{index}-phase-#{phase_index}")
          }
          aria-label={if(group.kind == :background, do: group.title)}
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
              @snapshot.trace.received_at
            )} from start</span>
            <.timeline_jumps
              links={phase_jumps(group, phase_index)}
              label="Stage navigation"
            />
          </div>
          <div class="phase-entries">
            <.entry :for={entry <- phase.steps} entry={entry} />
          </div>
        </section>
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

  defp message_anchor(group), do: "timeline-message-#{group.conversation_turn}"
  defp phase_anchor(group, phase), do: "#{message_anchor(group)}-#{phase.band}"

  defp message_jumps(groups, %{kind: :conversation, conversation_turn: turn}) when turn > 0 do
    messages = Enum.filter(groups, &(&1.kind == :conversation and &1.conversation_turn > 0))
    index = Enum.find_index(messages, &(&1.conversation_turn == turn))
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
    Enum.flat_map(@conversation_bands, fn band ->
      case Enum.filter(chapters, &(&1.band == band)) do
        [] -> []
        owned -> [merge_phase(owned)]
      end
    end)
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
          %{id: id} <- [Enum.find(Enum.drop(entries, index + 1), &admission_result?(&1, input))],
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

  defp first_step_time(chapters) do
    chapters
    |> Enum.flat_map(& &1.steps)
    |> Enum.map(& &1.at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> ~U[9999-12-31 23:59:59.999999Z] end)
  end

  defp calls_path(snapshot, params, page) do
    query =
      params
      |> Map.take(["events"])
      |> Map.put("calls", to_string(page))
      |> URI.encode_query()

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

  defp input_association(:not_recorded), do: "Selected inputs not recorded"
  defp input_association(ordinals) when length(ordinals) < 2, do: nil

  defp input_association(ordinals),
    do: "Inputs: " <> Enum.map_join(ordinals, " + ", &"Message #{&1}")

  defp continuation(nil), do: nil
  defp continuation(ordinal), do: "Continues Turn #{ordinal}"

  defp phase_band(:input), do: :ready
  defp phase_band(:outcome), do: :answer
  defp phase_band(band), do: band

  # How a stage ended, read from its own recorded entries. The label summarizes
  # the stage; the cards below it stay exactly as each moment recorded them.
  # Routing's cards say what it decided; the heading does not repeat it.
  defp phase_summary(%{band: :routing}), do: nil

  defp phase_summary(%{band: :answer, steps: entries}) do
    cond do
      Enum.any?(entries, &(message_direction(&1) == "out")) ->
        "Response sent"

      Enum.any?(entries, &match?(%{kind: :event, step: %{stage: "Result"}}, &1)) ->
        "No reply sent"

      true ->
        nil
    end
  end

  defp phase_summary(_phase), do: nil

  # Background sections remain separate from message-caused work. Their cards
  # retain exact timestamps even though they follow the conversation groups.
  defp background_band?(band), do: band in [:learning, :maintenance]

  defp entry(assigns) do
    ~H"""
    <article
      id={@entry.id}
      class={[
        "case-entry case-#{@entry.kind}",
        compact_entry?(@entry) && "case-checkpoint",
        message_container?(@entry) && "message-container",
        minor_entry?(@entry) && "case-minor"
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
          :if={@entry.kind == :event && @entry.step.stage in ["Search", "Selection"]}
          step={@entry.step}
        />
        <.work_setup
          :if={@entry.kind == :event && @entry.step.stage == "Work setup"}
          step={@entry.step}
        />
        <.event :if={@entry.kind == :event && !card_stage?(@entry.step.stage)} step={@entry.step} />
        <EpisodeRequest.render :if={@entry.kind == :request} request={@entry} />
      </div>
    </article>
    """
  end

  # Stages with their own card component instead of the generic event layout.
  defp card_stage?(stage),
    do:
      stage in [
        "Tool call",
        "Participation",
        "Queue",
        "Search",
        "Selection",
        "Work setup"
      ]

  defp message_container?(%{kind: :message, message: message}), do: is_nil(message[:provider])
  defp message_container?(_entry), do: false

  defp message_direction(%{kind: :message, message: %{actor: "Ryker"}}), do: "out"
  defp message_direction(%{kind: :message}), do: "in"
  defp message_direction(_entry), do: nil

  # Plumbing that went as expected is one line, not a card.
  defp minor_entry?(%{kind: :event, step: %{tone: tone}}) when tone in [:bad, :warn], do: false

  defp minor_entry?(%{kind: :event, step: %{stage: stage}})
       when stage in ["Queue", "Tool call", "Maintenance"],
       do: true

  defp minor_entry?(%{kind: :event, step: step} = entry),
    do: compact_entry?(entry) and is_nil(step[:candidate_response])

  defp minor_entry?(_entry), do: false

  @doc """
  The Getting ready cards for an input that has no Timeline of its own yet.

  The standalone input view reuses the Timeline's card components so an input
  that was never picked up explains itself exactly the way an admitted one does.
  """
  def getting_ready(assigns) do
    requests = List.wrap(assigns[:requests])

    # One sequence in time order, as on an episode page, so a retried input
    # reads attempt by attempt instead of all queue history first.
    entries =
      (Enum.map(assigns.steps, &%{id: "event-#{&1.id}", kind: :event, step: &1, at: &1.at}) ++
         requests)
      |> Enum.sort_by(&(&1[:sort_at] || &1.at), &(DateTime.compare(&1, &2) != :gt))
      |> fold_waits()
      |> merge_queue_runs()

    assigns = assign(assigns, :entries, entries)

    ~H"""
    <section
      class="case-timeline standalone-preparation"
      id="execution-timeline"
      aria-label="Complete execution timeline"
    >
      <h2 class="sr-only">Execution timeline</h2>
      <section class="trace-chapter phase-ready" aria-labelledby="standalone-getting-ready">
        <div class="chapter-heading">
          <span class="phase-number" aria-hidden="true">01</span>
          <div class="chapter-description">
            <h3 id="standalone-getting-ready">Getting ready</h3>
            <p>{chapter_description(:ready)}</p>
          </div>
        </div>
        <div class="phase-entries">
          <.entry :for={entry <- @entries} entry={entry} />
        </div>
      </section>
    </section>
    """
  end

  attr(:recovery, :map, required: true)

  def admission_recovery(assigns) do
    ~H"""
    <section class="story-stop admission-recovery" aria-labelledby="admission-recovery-heading">
      <h2 id="admission-recovery-heading">Routing needs attention</h2>
      <p>{label(@recovery.summary)}</p>
      <p>The message is safe. Retry the same routing attempt after the problem is resolved.</p>
      <.action_button path={@recovery.href} label="Review recovery" />
    </section>
    """
  end

  # The pinned setup against the session, worker and workspace the turn ran on.
  # Ready carries a success icon and no repeated word; the failure reason and
  # the current preparation step are the only sentences on the face.
  defp work_setup(assigns) do
    ~H"""
    <div class="case-event-content work-setup" data-state={@step.setup.kind}>
      <.card_heading title="Work setup">
        <:meta>
          <.success_mark :if={@step.setup.kind == :ready} label="Ready" />
          <span :if={@step.setup.kind != :ready} class={"event-state tone-#{@step.tone}"}>
            {@step.setup.label}<small :if={@step.setup.current}> · current</small>
          </span>
        </:meta>
      </.card_heading>
      <p :if={@step.summary} class="case-event-summary">{@step.summary}</p>
      <.fact_list facts={@step.setup.rows} class="setup-facts" />
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

  # A queue card is one contiguous retained custody run. Only the unsealed tail
  # may carry a current row; a later retry gets another card instead of
  # rewriting the run that preceded Routing.
  defp input_queue(assigns) do
    ~H"""
    <div class="case-event-content input-queue" data-state={@step.queue.kind}>
      <.card_heading title="Queue">
        <:detail :if={@step.queue.qualifier}>{@step.queue.qualifier}</:detail>
        <:meta>
          <span :if={@step.queue.current} class="event-state">Current</span>
          <span
            :if={
              !@step.queue.current && is_number(@step.queue.duration_ms) &&
                @step.queue.duration_ms > 0
            }
            class="action-duration"
          >
            {duration(@step.queue.duration_ms)}
          </span>
        </:meta>
      </.card_heading>
      <ol class="queue-events">
        <li :for={event <- @step.queue.events} data-kind={event.kind}>
          <div class="queue-event-heading">
            <strong>{event.label}</strong>
            <time :if={event.at} datetime={DateTime.to_iso8601(event.at)}>{precise_clock(event.at)}</time>
          </div>
          <p>{event.reason}</p>
          <a :if={event.href} href={event.href}>{event.link_label} →</a>
        </li>
      </ol>
    </div>
    """
  end

  # Ryker's own preparation before a briefing: where routing looked for earlier
  # work, or what a Work turn selected, and what was found but left out. The
  # briefing after it shows only what the model was sent.
  defp search_card(assigns) do
    ~H"""
    <div class="case-event-content search-card">
      <.card_heading title={@step.title}>
        <:meta :if={@step.search.summary}>{@step.search.summary}</:meta>
      </.card_heading>
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
        <div :if={@step.search[:methods] not in [nil, []]}>
          <dt>How</dt>
          <dd>
            <ul class="search-methods">
              <li :for={method <- @step.search.methods} data-found={to_string(method.found > 0)}>
                <span class="search-method-name">{method.name}</span>
                <span class="search-method-used">
                  <code :for={term <- method.used} title={term}>{term}</code>
                  <span :if={method.note} class="search-method-note">{method.note}</span>
                </span>
                <span class="search-method-found">
                  {method.found} found{if method.limit, do: " · limit reached"}
                </span>
              </li>
            </ul>
          </dd>
        </div>
        <div :for={{label, value} <- @step.search.facts}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
      <.disclosure id={@step.id <> "-record"} label={@step.search.record_label} class="search-record">
        <.copy_block label="Copy JSON">
          <pre class="model-document-text" tabindex="0">{@step.search.record}</pre>
        </.copy_block>
      </.disclosure>
    </div>
    """
  end

  defp precise_clock(nil), do: "Not recorded"

  defp precise_clock(at) do
    {microseconds, _precision} = at.microsecond

    Calendar.strftime(at, "%H:%M:%S") <>
      "." <> String.pad_leading(Integer.to_string(div(microseconds, 1_000)), 3, "0")
  end

  # One input, one explanation: decision first, then the processing-time
  # settings and full rule inventory that supported it. Only technical rule
  # identity stays behind a disclosure.
  defp participation(assigns) do
    ~H"""
    <div
      class="case-event-content participation"
      data-state={@step.engagement.state}
      data-rules-state={@step.rules.state}
    >
      <.card_heading title="Participation" />
      <p class="case-event-summary participation-summary">{@step.engagement.reason}</p>

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
        <p :if={@step.rules.truncated} class="action-error">
          {truncated_rule_summary(@step.rules)}
        </p>
        <ul :if={@step.rules.entries != []} class="standing-rule-list">
          <li
            :for={rule <- @step.rules.entries}
            class={"standing-rule verdict-#{rule.verdict}"}
            data-verdict={rule.verdict}
          >
            <div class="standing-rule-heading">
              <p class="standing-rule-verdict">{verdict_label(rule.verdict)}</p>
              <strong>{rule.title}</strong>
            </div>
            <p class="standing-rule-reason">{rule.reason}</p>
            <.disclosure
              :if={rule.ref}
              id={"rule-#{@step.id}-#{rule.ref}"}
              label="Rule details"
              class="standing-rule-definition"
            >
              <.fact_list facts={rule_facts(rule)} />
              <a class="standing-rule-link" href={"/rules#behavior-" <> rule.ref}>
                Open in Standing rules →
              </a>
            </.disclosure>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp verdict_label("matched"), do: "Matched"
  defp verdict_label("not_matched"), do: "Did not match"
  defp verdict_label("out_of_scope"), do: "Other channel"
  defp verdict_label("not_considered"), do: "Not evaluated"
  defp verdict_label("disabled"), do: "Paused"
  defp verdict_label("expired"), do: "Expired"
  defp verdict_label(other), do: label(other)

  defp truncated_rule_summary(rules) do
    retained = length(rules.entries)
    missing = max(rules.rule_count - retained, 0)
    verb = if missing == 1, do: "is", else: "are"

    "Only #{retained} of #{rules.rule_count} rules were retained; #{missing} #{verb} missing from this older history."
  end

  defp message(assigns) do
    ~H"""
    <.provider_header :if={@message[:provider]} provider={@message.provider} id={@message.id} />
    <.message_block
      :if={!@message[:provider]}
      title={message_title(@message)}
      sender={@message[:display_actor] || @message.actor}
      class="case-message"
    >
      <:meta>
        <time :if={@message.at} datetime={DateTime.to_iso8601(@message.at)}>
          {message_timestamp(@message.at)}
        </time>
        <span :if={@message[:status]}>{@message.status}</span>
      </:meta>
      <div>{message_text(@message)}</div>
      <:footer :if={@message[:details] || @message[:response_reference]}>
        <a
          :if={@message[:response_reference]}
          class="response-reference"
          href={@message.response_reference}
        >
          View validated response ↑
        </a>
        <.input_details :if={@message[:details]} message={@message} />
      </:footer>
    </.message_block>
    <.input_details :if={@message[:provider] && @message[:details]} message={@message} />
    <p :if={@message[:provider] && @message.provider.links != []} class="provider-links">
      <a
        :for={link <- @message.provider.links}
        href={link.href}
        target="_blank"
        rel="noopener noreferrer"
      >{link.label} ↗</a>
    </p>
    """
  end

  defp message_title(%{response_reference: reference}) when is_binary(reference),
    do: "Sent response"

  defp message_title(%{event_kind: :edit}), do: "Message edited"
  defp message_title(%{event_kind: :delete}), do: "Message deleted"
  defp message_title(%{event_kind: :event}), do: "Incoming event"
  defp message_title(_message), do: "Incoming message"

  # A recognized notification leads with provider, state, subject and a few
  # labelled facts. The state badge is text; the accent only says which
  # provider, and the provider is a format, not an authenticated sender.
  defp provider_header(assigns) do
    ~H"""
    <div class={"provider-message provider-#{@provider.provider}"} data-provider={@provider.provider}>
      <.card_heading title={@provider.name}>
        <:detail>via {source_transport(@provider)}</:detail>
        <:meta :if={@provider.state}>
          <span class={"provider-state tone-#{@provider.tone}"}>{@provider.state}</span>
        </:meta>
      </.card_heading>
      <p :if={@provider.subject} class="provider-subject">{@provider.subject}</p>
      <.fact_list :if={@provider.facts != []} facts={@provider.facts} class="provider-facts" />
      <.disclosure
        :for={group <- @provider[:groups] || []}
        label={group.label}
        class="provider-group"
        id={"provider-#{@id}-#{@provider.provider}-#{String.downcase(group.label)}"}
      >
        <.fact_list facts={group.entries} />
      </.disclosure>
    </div>
    """
  end

  defp source_transport(%{provider: :grafana}), do: "webhook"
  defp source_transport(_provider), do: "Slack"

  # What the rule looked for and where, then what the check found in this
  # message, one row per condition.
  defp rule_facts(rule) do
    [
      %{label: "Looks for", value: rule_criteria(rule.criteria) <> rule_place(rule.scope_ref)}
      | rule_evidence(rule.criteria, rule.evidence)
    ]
  end

  defp rule_criteria(%{"trigger" => trigger, "source_filter" => from}),
    do: "#{String.capitalize(trigger_name(trigger, :plural))} from #{listeners(from)}"

  defp rule_criteria(%{"source_kind" => source, "filter" => filter}),
    do: "#{source_name(source)} events matching #{Jason.encode!(filter)}"

  defp rule_place("slack:" <> _rest = scope), do: " in " <> SlackNames.destination(scope)
  defp rule_place(_scope), do: ""

  defp rule_evidence(_criteria, nil), do: []

  defp rule_evidence(%{"trigger" => trigger, "source_filter" => from}, evidence) do
    [
      %{
        label: "Sender",
        value:
          if(evidence["sender_matches"],
            do:
              "#{String.capitalize(sender_name(evidence["sender"]))}, which this rule listens to",
            else:
              "#{String.capitalize(sender_name(evidence["sender"]))}; this rule only listens to #{listeners(from)}"
          )
      },
      %{label: "Content", value: trigger_evidence(evidence, trigger)}
    ]
  end

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

  defp trigger_evidence(%{"event_class" => class, "trigger_matches" => true}, trigger)
       when is_binary(class),
       do: "Its source marked it as #{trigger_name(trigger, :one)}"

  defp trigger_evidence(%{"event_class" => class}, trigger) when is_binary(class),
    do: "Its source marked it as #{label(class)}, not #{trigger_name(trigger, :one)}"

  defp trigger_evidence(%{"trigger_text" => text}, _trigger) when is_binary(text),
    do: "Contains “#{text}”"

  defp trigger_evidence(_evidence, trigger),
    do: "Nothing in it reads as #{trigger_name(trigger, :one)}"

  defp trigger_name("terraform_plan", :plural), do: "Terraform plans"
  defp trigger_name("terraform_plan", :one), do: "a Terraform plan"
  defp trigger_name("deployment", :plural), do: "deployments"
  defp trigger_name("deployment", :one), do: "a deployment"
  defp trigger_name("operational_alert", :plural), do: "operational alerts"
  defp trigger_name("operational_alert", :one), do: "an operational alert"
  defp trigger_name(trigger, _number), do: label(trigger)

  defp listeners("human"), do: "people"
  defp listeners("app"), do: "apps and bots"
  defp listeners("any"), do: "anyone"
  defp listeners(filter), do: label(filter)

  defp sender_name("user"), do: "a person"
  defp sender_name("app"), do: "an app"
  defp sender_name("bot"), do: "a bot"
  defp sender_name("system"), do: "a system actor"
  defp sender_name(kind), do: label(kind)

  defp source_name("github"), do: "GitHub"
  defp source_name("slack"), do: "Slack"
  defp source_name(source), do: label(source)

  # Extracted metadata is visible as soon as the disclosure opens; the raw
  # envelope, the normalized input and the original message are each their own
  # collapsed body underneath, loaded when opened. Raw and normalized are never
  # shown under each other's name, and an unrecorded envelope says so.
  defp input_details(assigns) do
    ~H"""
    <.disclosure
      id={"input-details-#{@message.id}"}
      label="Details"
      class="input-details"
    >
      <.fact_list facts={@message.details.metadata} />
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
        <span :if={@artifact.state == :collapsed}>{bytes(@artifact.bytes)}</span>
        <span :if={@artifact.state == :expired}>Expired</span>
        <span :if={@artifact.state == :not_recorded}>Not recorded</span>
        <span :if={@artifact.state == :omitted}>Omitted</span>
        <span :if={@artifact[:redacted]}>Secrets redacted</span>
        <span :if={@artifact[:truncated]}>Partial display</span>
      </:meta>
      <p :if={@artifact.state == :collapsed} class="artifact-loading" role="status">Loading…</p>
      <p :if={@artifact.state == :not_recorded} class="artifact-unavailable">{@absent}</p>
      <p :if={@artifact.state == :expired} class="artifact-unavailable">
        Removed by retention. No reconstructed substitute is shown.
      </p>
      <p :if={@artifact.state == :omitted} class="artifact-unavailable">
        {omission(@artifact)}
      </p>
      <pre :if={@artifact.state == :retained}>{@artifact.text}</pre>
    </.disclosure>
    """
  end

  defp omission(%{reason: "oversized", omitted_bytes: bytes}),
    do: "The source payload was #{bytes(bytes)}, beyond the 64 KiB bound, so it was not stored."

  defp omission(%{reason: reason}), do: "The source payload was not stored (#{reason})."

  defp bytes(nil), do: "Size not recorded"
  defp bytes(count) when count < 1_024, do: "#{count} bytes"
  defp bytes(count) when count < 1_024 * 1_024, do: "#{div(count, 1_024)} KiB"
  defp bytes(count), do: "#{Float.round(count / (1_024 * 1_024), 1)} MiB"

  defp message_text(%{available: false}), do: "Source content not recorded or expired"

  defp message_text(%{transport: "slack", workspace: workspace, text: text}) when is_binary(text),
    do: text |> SlackMarkdown.preview(workspace) |> Phoenix.HTML.raw()

  defp message_text(message), do: message.text |> SlackMarkdown.preview() |> Phoenix.HTML.raw()

  defp event(assigns) do
    ~H"""
    <div class="case-event-content">
      <.card_heading title={event_title(@step)}>
        <:meta :if={show_event_state?(@step) || @step.duration_ms}>
          <span
            :if={show_event_state?(@step)}
            class={"event-state tone-#{@step.tone}"}
          >{label(@step.state)}</span>
          <span :if={@step.duration_ms}>{duration(@step.duration_ms)}</span>
        </:meta>
      </.card_heading>
      <p :if={@step.summary && @step.summary != event_title(@step)} class="case-event-summary">
        {@step.summary}
      </p>
      <p :if={@step[:current_warning]} class="action-error">
        <strong>Current scheduling status:</strong> {@step.current_warning}
      </p>
      <div :if={@step[:candidate_response]} class="candidate-evidence">
        <Ryker.ControlPlane.RequestPage.candidate_response
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
        <span :if={@artifact.state == :collapsed}>{bytes(@artifact.bytes)}</span><span :if={
          @artifact.truncated
        }>Partial display</span><span :if={@artifact.redacted}>Secrets redacted</span>
      </:meta>
      <p :if={@artifact.state == :collapsed} class="artifact-loading" role="status">Loading…</p>
      <p :if={@artifact.state in [:expired, :not_recorded]} class="artifact-unavailable">
        {if @artifact.state == :expired,
          do: "Removed by retention. No reconstructed substitute is shown.",
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

  defp bookkeeping?(step),
    do:
      step.tone not in [:bad, :warn] and
        not silent_result?(step) and
        step.stage in [
          "Preparation",
          "Routing",
          "Input",
          "Execution",
          "Result",
          "Delivery",
          "Validation"
        ]

  defp compact_entry?(%{kind: :event, step: step}), do: bookkeeping?(step)
  defp compact_entry?(_), do: false

  defp show_event_state?(%{stage: "Validation", state: state}) when state in ["accept", "reject"],
    do: false

  defp show_event_state?(step),
    do:
      step.state not in [nil, ""] &&
        step.stage not in ["Preparation", "Execution", "Evidence"] &&
        not String.contains?(
          String.downcase(event_title(step)),
          String.downcase(label(step.state))
        )

  defp event_title(%{stage: "Tool call", title: "Tool call", summary: summary})
       when is_binary(summary), do: summary

  defp event_title(step), do: if(silent_result?(step), do: "No reply sent", else: step.title)

  defp silent_result?(%{stage: "Result", details: details}),
    do: Enum.any?(details, &(&1.label == "Delivery" && &1.value == "none"))

  defp silent_result?(_step), do: false

  defp chapter_title(%{band: :learning}), do: "Learning"
  defp chapter_title(%{band: :maintenance}), do: "Maintenance"

  defp chapter_title(%{band: :ready, conversation_turn: turn}) when turn > 1,
    do: "New input received"

  defp chapter_title(%{band: :ready}), do: "Getting ready"
  defp chapter_title(%{band: :routing}), do: "Routing"
  defp chapter_title(%{band: :work}), do: "The work"
  defp chapter_title(%{band: :answer}), do: "The answer"
  defp chapter_title(chapter), do: chapter.title

  defp phase_number(:learning), do: "B1"
  defp phase_number(:maintenance), do: "B2"
  defp phase_number(:ready), do: "01"
  defp phase_number(:routing), do: "02"
  defp phase_number(:work), do: "03"
  defp phase_number(:answer), do: "04"

  defp phase_title(:ready), do: "Intake"
  defp phase_title(:routing), do: "Routing"
  defp phase_title(:work), do: "Work"
  defp phase_title(:answer), do: "Answer"
  defp phase_title(band), do: chapter_title(%{band: band})

  defp chapter_description(:ready),
    do: "The message and context that started this part of the conversation."

  defp chapter_description(:routing),
    do:
      "The model call that decides whether to respond, continue earlier work, or leave the message alone."

  defp chapter_description(:work),
    do: "The model's briefing, progress, tool calls, and results."

  defp chapter_description(:answer),
    do: "What the model returned and what Ryker decided to do."

  defp chapter_description(:learning),
    do:
      "Background learning from these messages. It runs independently of the answer and sends no reply."

  defp chapter_description(:maintenance),
    do: "What happened to the temporary worker session and workspace afterwards."

  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  defp entries(snapshot, timeline) do
    record_links =
      for step <- snapshot.trace.steps,
          step[:record_ref],
          into: %{},
          do: {step.record_ref, %{href: "#event-#{step.id}", title: step.title}}

    requests = requests_with_links(timeline.items, record_links)

    messages =
      Enum.map(snapshot.trace.case_file.conversation, fn message ->
        %{
          id: "story-message-#{message.id}",
          owner: message[:owner] || :episode,
          at: message.at,
          kind: :message,
          message: Map.put(message, :response_reference, response_reference(message, requests)),
          band: if(message.actor == "Ryker", do: :outcome, else: :input)
        }
      end)

    copies = visible_copies(snapshot.trace.steps, messages, timeline.items)

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
          step: Map.put(step, :candidate_response, responses[step.id]),
          band: step.band
        }
      end)

    # Stable sort preserves the trace's numeric sequence/lifecycle ordering on ties.
    Enum.sort_by(messages ++ steps ++ requests, &unix(&1.at || &1[:sort_at]))
  end

  defp requests_with_links(requests, record_links) do
    candidate_links =
      for %{source_kind: :admission, phase: :submission} = request <- requests,
          into: %{},
          do: {request.id, RequestContextHTML.candidate_links(request.sections, request.id)}

    Enum.map(requests, fn request ->
      request
      |> Map.put(:record_links, record_links)
      |> Map.put(
        :candidate_links,
        candidate_links[String.replace_suffix(request.id, "-result", "")] || %{}
      )
    end)
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
        response_anchor(RequestPage.latest_archived_response(sections), message.id, id)
      else
        _ -> nil
      end
    end
  end

  defp response_anchor(%{attempt: attempt}, message_id, _request_id),
    do: "#turn-#{message_id}-response-#{attempt}-body"

  defp response_anchor(_archived, _message_id, request_id), do: "##{request_id}"

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

  defp delivered_message?(message),
    do:
      message.actor == "Ryker" && message[:delivery_ref] &&
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

  defp message_timestamp(%DateTime{} = at),
    do: "#{at.day} #{Calendar.strftime(at, "%b, %H:%M:%S UTC")}"

  defp message_timestamp(_at), do: "Not recorded"
  # The label says where the heading came from: Ryker's own name for the
  # episode, a task's title, or the request that started it.
  defp title_label(%{title_kind: :episode}), do: "Episode"
  defp title_label(%{title_kind: :task}), do: "Task"
  defp title_label(_case_file), do: "Initial request"

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
    do: duration_ms(milliseconds)

  defp wall_time(_wall), do: "Not measured"

  defp wall_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp wall_reason(_wall), do: nil

  defp response_label(%{measured: measured}) when measured > 1, do: "Average response"
  defp response_label(_response), do: "Response time"

  defp response_time(%{measured: measured, average_ms: milliseconds}, _wall)
       when measured > 0 and is_integer(milliseconds),
       do: duration_ms(milliseconds)

  defp response_time(_response, %{state: :active}), do: "Waiting"
  defp response_time(_response, _wall), do: "Not measured"

  defp response_note(%{measured: measured, minimum_ms: minimum, maximum_ms: maximum})
       when measured > 1 and is_integer(minimum) and is_integer(maximum),
       do: "min #{duration_ms(minimum)}, max #{duration_ms(maximum)}"

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

  defp duration_ms(milliseconds) when is_integer(milliseconds) and milliseconds < 1_000,
    do: "< 1s"

  defp duration_ms(milliseconds) when is_integer(milliseconds),
    do: duration_seconds(round(milliseconds / 1_000))

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
end

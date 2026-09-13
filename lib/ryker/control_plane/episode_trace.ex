defmodule Ryker.ControlPlane.EpisodeTrace do
  @moduledoc """
  Builds the bounded operator story for one durable episode.

  Each chapter of the story is produced by its own module under this one and
  read here in order; this module gathers the rows they share, merges their
  steps chronologically, groups them into chapters and derives the page's
  metrics, actions and stopped state. The trace deliberately presents
  identities, lifecycle, measurements and host decisions rather than copying
  raw ingress, prompts, candidates or provider diagnostics into the control
  plane.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.{EpisodeCausality, EvidenceLinks, WorkRecovery}

  alias Ryker.ControlPlane.EpisodeTrace.{
    CaseFile,
    Input,
    Learning,
    Maintenance,
    Outcome,
    Preparation,
    ToolActivity,
    Work
  }

  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.EpisodeReview
  alias Ryker.Repo
  alias Ryker.State.Record
  alias Ryker.Work.{Activity, Session, Turn}

  @chapters [
    {:input, "What came in", "The input, continuation, or trigger that opened this work."},
    {:ready, "Getting ready", "How Ryker routed, scoped, and prepared the work."},
    {:routing, "Routing", "The routing model's briefing, activity, and decision."},
    {:work, "The work", "What ran, what it recorded, and whether the provider stayed active."},
    {:answer, "The answer", "Candidate validation, the accepted result, and any refusal."},
    {:outcome, "What came of it", "Delivery, durable side effects, waits, and follow-up work."},
    {:learning, "Learning",
     "Background learning from these messages. It runs on its own and sends no reply."},
    {:maintenance, "Maintenance",
     "What happened to the temporary session and workspace afterwards."}
  ]

  @spec project(Episode.t(), [Event.t()], [Record.t()], keyword()) :: map()
  def project(episode, events, records, options \\ [])

  def project(%Episode{} = episode, events, records, options)
      when is_list(events) and is_list(records) do
    input_rows = Input.rows(episode.id)
    inputs = Input.inputs_by_ref(input_rows)
    sessions = sessions(episode.id)
    turns = turns(episode.id)
    disclosed = Keyword.get(options, :disclosed) || MapSet.new()

    activity_page =
      Activity.page_for_episode(episode.id, Keyword.get(options, :activity_pages, 1))

    causality =
      EpisodeCausality.index(input_rows, turns, activity_page.events,
        input_refs: Input.input_refs(events, inputs)
      )

    activity =
      activity_page.events
      |> ToolActivity.steps(causality, disclosed)
      |> EvidenceLinks.attach(activity_page.events, turns, records)

    current_turn = List.last(turns)
    stopped = stopped(episode, current_turn)
    # Only collapse an entirely unstarted task, never earlier work in a resumed episode.
    startup =
      if current_blocked_turn?(episode, current_turn) and length(turns) == 1 and
           WorkRecovery.not_started?(current_turn) and
           Enum.all?(sessions, &is_nil(&1.coop_session_id)),
         do: CaseFile.task_start(episode, current_turn)

    totals = totals(episode.id, events, records, sessions, turns)
    review = review_state(episode)
    received_at = Input.first_received_at(episode)
    platform_actions = Outcome.platform_actions(episode.id)
    publications = Outcome.publications(episode.id)
    source = Input.source_link(episode, events, inputs)

    steps =
      []
      |> Kernel.++(Input.kernel_steps(events, inputs))
      |> Kernel.++(Input.association_steps(episode))
      |> Kernel.++(Preparation.steps(input_rows))
      |> Kernel.++(Preparation.setup_steps(sessions, turns))
      |> Kernel.++(Work.turn_steps(turns, sessions))
      |> Kernel.++(activity)
      |> Kernel.++(Work.slack_status_steps(episode.id))
      |> Kernel.++(Work.record_steps(records))
      |> Kernel.++(Work.coop_steps(sessions))
      |> Kernel.++(Outcome.platform_action_steps(platform_actions))
      |> Kernel.++(Outcome.incident_steps(episode.id))
      |> Kernel.++(Outcome.publication_steps(publications))
      |> Kernel.++(Outcome.schedule_steps(episode.id))
      |> Kernel.++(Learning.steps(input_rows))
      |> Kernel.++(Maintenance.steps(sessions))
      |> chronological()

    %{
      activity:
        activity_page
        |> Map.drop([:events])
        |> Map.put(
          :more,
          next_activity_page(activity_page, Keyword.get(options, :activity_pages, 1))
        ),
      actions: operator_actions(episode, current_turn, review),
      case_file: CaseFile.build(episode.id, turns, sessions, disclosed),
      startup: startup,
      causality: causality,
      chapters: chapters(steps, received_at, causality),
      follow_through: Outcome.follow_through(platform_actions, publications, source),
      history: history(episode, totals, activity_page),
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

  # Only offer another page when one exists and the bound has not been reached.
  defp next_activity_page(%{truncated: true}, pages) when pages < 10, do: pages + 1
  defp next_activity_page(_page, _pages), do: nil

  @doc """
  The Getting ready cards for one input that may have no episode yet.

  The standalone input view shows the same four cards the Timeline shows, read
  from the same rows, so an input that was never picked up explains itself the
  same way as one that was.
  """
  @spec input_preparation(Entry.t()) :: [map()]
  def input_preparation(%Entry{} = input), do: Preparation.steps([input])

  @doc """
  The heading a message carries before it becomes an episode.

  The same sentence the episode page shows for a case file: the request itself,
  shortened, and redacted the way every other retained text is.
  """
  @spec unrouted_title(Entry.t()) :: String.t()
  defdelegate unrouted_title(input), to: CaseFile

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

  # What the timeline could not show: rows past its window, and history that
  # retention removed, which is not the same as history that was never written.
  defp history(episode, totals, activity_page) do
    windows = [
      history_window("kernel events", totals.events_shown, totals.events),
      history_window("records", totals.records_shown, totals.records),
      history_window("sessions", totals.sessions_shown, totals.sessions),
      history_window("turns", totals.turns_shown, totals.turns),
      history_window("activity events", activity_page.shown, activity_page.total)
    ]

    %{
      pruned_at: episode.history_pruned_at,
      truncated: Enum.any?(windows, & &1.truncated),
      windows: windows
    }
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
    recovery = WorkRecovery.brief(turn)

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

  @doc """
  Groups chronological entries by the conversation position each one actually
  belongs to.

  A step that carries a durable owner takes its position from that owner: a
  Turn sits at the position of the earliest input it selected, wherever its
  receipts happen to land in time. Only a step with no recorded owner falls
  back to the reader's current position, and an input message still opens a
  new one. This is what keeps a Turn 1 tool result that arrives after Message 2
  filed under Turn 1 instead of being blamed on a message that did not exist
  when the work started.
  """
  def chapters(steps, started_at, causality \\ EpisodeCausality.index([], [], [])) do
    {entries, _state} =
      Enum.map_reduce(steps, {0, MapSet.new()}, &conversation_part(&1, &2, causality))

    entries
    |> Enum.chunk_by(fn {step, part, _boundary, _owner} -> {step.band, part} end)
    |> Enum.map(fn chapter_entries ->
      [{_step, conversation_turn, _boundary, _owner} | _] = chapter_entries
      chapter_steps = Enum.map(chapter_entries, &elem(&1, 0))
      starts_conversation = Enum.any?(chapter_entries, &elem(&1, 2))
      owners = chapter_entries |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

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
        owners: owners,
        turn: chapter_turn(owners, causality),
        span: chapter_span(chapter_steps, started_at),
        steps: chapter_steps
      }
    end)
  end

  # The single Work turn a chapter belongs to, or nil when it has none or several.
  defp chapter_turn(owners, causality) do
    case Enum.filter(owners, &match?({:turn, _id}, &1)) do
      [owner] -> EpisodeCausality.describe(causality, owner)
      _none_or_several -> nil
    end
  end

  defp conversation_part(step, {part, seen}, causality) do
    owner = Map.get(step, :owner) || :episode
    boundary = message_boundary?(step, seen)

    part =
      cond do
        boundary -> part + 1
        position = EpisodeCausality.position(causality, owner) -> position
        true -> part
      end

    seen = if boundary, do: MapSet.put(seen, step.id), else: seen
    {{step, part, boundary, owner}, {part, seen}}
  end

  defp message_boundary?(%{kind: :message, band: :input, id: id}, seen),
    do: not MapSet.member?(seen, id)

  defp message_boundary?(_step, _seen), do: false

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

  defp metric(label, value, detail, tone \\ nil),
    do: %{detail: to_string(detail), label: label, tone: tone, value: to_string(value)}

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
        do: WorkRecovery.brief(current_turn)

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

  defp next_action(%Episode{state: :waiting_for_input}, _turn), do: "operator input"
  defp next_action(%Episode{state: :waiting_for_event}, _turn), do: "external event"
  defp next_action(_episode, %Turn{status: :blocked}), do: "operator recovery"
  defp next_action(%Episode{owner_kind: :delivery}, _turn), do: "deliver result"
  defp next_action(%Episode{state: :complete}, _turn), do: "complete"
  defp next_action(%Episode{state: :cancelled}, _turn), do: "cancelled"
  defp next_action(_episode, nil), do: "start work"
  defp next_action(_episode, _turn), do: "continue work"
end

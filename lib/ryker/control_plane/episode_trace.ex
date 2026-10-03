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

  alias Ryker.ControlPlane.{
    EpisodeCausality,
    EpisodeResponseMetrics,
    Paths,
    RepositoryNames,
    SavedRecords
  }

  alias Ryker.ControlPlane.EpisodeTrace.{
    CaseFile,
    Input,
    Maintenance,
    Outcome,
    Preparation,
    ToolActivity,
    Work
  }

  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.EpisodeReview
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.StateTools.CallLog
  alias Ryker.Work.{Activity, Recovery, Session, Turn}

  @chapters [
    {:input, "What came in", "The input, continuation, or trigger that opened this work."},
    {:ready, "Getting ready", "How Ryker routed, scoped, and prepared the work."},
    {:routing, "Routing", "The routing model's briefing, activity, and decision."},
    {:work, "The work", "What ran, what it recorded, and whether the provider stayed active."},
    {:answer, "The answer", "Candidate validation, the accepted result, and any refusal."},
    {:outcome, "What came of it", "Delivery, durable side effects, waits, and follow-up work."},
    {:learning, "Learning",
     "Background learning from these messages, once the work they started has stopped. It sends no reply."},
    {:maintenance, "Cleanup",
     "What happened afterwards to the worker Ryker used and its working copy."}
  ]

  @spec project(Episode.t(), [Event.t()], [Record.t()], keyword()) :: map()
  def project(episode, events, records, options \\ [])

  def project(%Episode{} = episode, events, records, options)
      when is_list(events) and is_list(records) do
    input_rows = Input.rows(episode.id)
    inputs = Input.inputs_by_ref(input_rows)
    admitted = Input.admitted(events, inputs)
    entry_refs = Input.input_refs(events, inputs)
    sessions = sessions(episode.id)
    turns = turns(episode.id)
    disclosed = Keyword.get(options, :disclosed) || MapSet.new()

    activity_page =
      Activity.page_for_episode(episode.id, Keyword.get(options, :activity_pages, 1))

    # A task's pull request feedback, a schedule's run or a wait's timer is an
    # input no inbox row holds; it is counted among the messages all the same.
    causality =
      EpisodeCausality.index(
        input_rows ++ Input.admitted_inputs(admitted),
        turns,
        activity_page.events,
        input_refs: Map.merge(entry_refs, Input.admitted_refs(admitted))
      )

    response_metrics =
      EpisodeResponseMetrics.project(episode, input_rows, turns, entry_refs,
        now: Keyword.get(options, :now, DateTime.utc_now())
      )

    activity_events =
      ToolActivity.with_state_tool_calls(
        activity_page.events,
        state_tool_calls(episode.id, activity_page.events),
        causality
      )

    activity =
      activity_events
      |> ToolActivity.steps(causality, disclosed)
      |> SavedRecords.fold(activity_events, turns, records)

    current_turn = List.last(turns)
    stopped = stopped(episode, current_turn)
    # Only collapse an entirely unstarted task, never earlier work in a resumed episode.
    startup =
      if current_blocked_turn?(episode, current_turn) and length(turns) == 1 and
           Recovery.not_started?(current_turn) and
           Enum.all?(sessions, &is_nil(&1.coop_session_id)),
         do: CaseFile.task_start(episode, current_turn)

    totals = totals(episode.id, events, records, sessions, turns)
    rating = rating_state(episode, events)
    received_at = Input.first_received_at(episode)
    platform_actions = Outcome.platform_actions(episode.id)
    publications = Outcome.publications(episode.id)
    source = Input.source_link(episode, events, inputs)

    steps =
      []
      |> Kernel.++(Input.kernel_steps(events, inputs, admitted))
      |> Kernel.++(Input.association_steps(episode))
      |> Kernel.++(Preparation.steps(input_rows))
      |> Kernel.++(
        Preparation.setup_steps(sessions, turns, %{
          episode: episode,
          first_input: List.first(input_rows),
          inputs: inputs
        })
      )
      |> Kernel.++(Work.turn_steps(turns, sessions))
      |> Kernel.++(activity)
      |> Kernel.++(Work.slack_status_steps(episode.id))
      |> Kernel.++(Work.record_steps(records))
      |> Kernel.++(Work.coop_steps(sessions))
      |> Kernel.++(Outcome.platform_action_steps(platform_actions))
      |> Kernel.++(Outcome.incident_steps(episode.id))
      |> Kernel.++(Outcome.publication_steps(publications))
      |> Kernel.++(Outcome.schedule_steps(episode.id))
      |> Kernel.++(Maintenance.steps(sessions))
      |> chronological()
      |> name_repositories()

    %{
      activity:
        activity_page
        |> Map.drop([:events])
        |> Map.put(
          :more,
          next_activity_page(activity_page, Keyword.get(options, :activity_pages, 1))
        ),
      actions: operator_actions(episode, current_turn),
      case_file:
        episode.id
        |> CaseFile.build(turns, sessions, disclosed)
        |> CaseFile.with_admitted(Enum.map(admitted, & &1.message)),
      startup: startup,
      causality: causality,
      chapters: chapters(steps, received_at, causality),
      follow_through: Outcome.follow_through(platform_actions, publications, source),
      history: history(episode, totals, activity_page),
      metrics: metrics(episode, received_at, activity_page, totals, steps),
      next_action: next_action(episode, current_turn),
      received_at: received_at,
      response_metrics: response_metrics,
      rating: rating,
      source: source,
      state: page_state(episode, stopped),
      stats: stats(steps, activity_page, totals),
      steps: steps,
      stopped: stopped
    }
  end

  # The header's state says what NEXT ACTION says: work that stopped is not
  # working, whatever the episode's own state still records.
  # Steps record a repository by its ref; each reads as owner/repo, the name
  # people know it by, even after it was removed (Andrew, 2026-09-28).
  defp name_repositories(steps) do
    if Enum.any?(steps, &repository_detail?/1) do
      names = RepositoryNames.all()

      Enum.map(steps, fn
        %{details: details} = step when is_list(details) ->
          %{step | details: Enum.map(details, &name_repository(&1, names))}

        step ->
          step
      end)
    else
      steps
    end
  end

  defp repository_detail?(%{details: details}) when is_list(details),
    do: Enum.any?(details, &match?(%{label: "Repository"}, &1))

  defp repository_detail?(_step), do: false

  defp name_repository(%{label: "Repository", value: ref} = detail, names),
    do: %{detail | value: RepositoryNames.name(names, ref)}

  defp name_repository(detail, _names), do: detail

  defp page_state(%Episode{state: :working}, %{}), do: "blocked"
  defp page_state(%Episode{state: state}, _stopped), do: to_string(state)

  # Only offer another page when one exists and the bound has not been reached.
  defp next_activity_page(%{truncated: true}, pages) when pages < 10, do: pages + 1
  defp next_activity_page(_page, _pages), do: nil

  @doc """
  The preparation cards for one message that has no request of its own:
  Participation and its queue runs, read from the same rows the Timeline
  reads, so a message that never became work explains itself the same way as
  one that did.
  """
  @spec input_preparation(Entry.t()) :: [map()]
  def input_preparation(%Entry{} = input), do: Preparation.steps([input])

  # Only a call Ryker received inside the narration on this page can join it.
  defp state_tool_calls(_episode_id, []), do: []

  defp state_tool_calls(episode_id, [oldest | _newer]),
    do: CallLog.list_for_episode(episode_id, DateTime.add(oldest.occurred_at, -1, :minute))

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
      history_window("request changes", totals.events_shown, totals.events),
      history_window("records", totals.records_shown, totals.records),
      history_window("worker sessions", totals.sessions_shown, totals.sessions),
      history_window("runs", totals.turns_shown, totals.turns),
      history_window("worker updates", activity_page.shown, activity_page.total)
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
      metric("Runs", totals.turns, plural(totals.work_claims, "start attempt")),
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
      %{label: "runs", value: totals.turns},
      %{label: "records", value: totals.records},
      %{label: "activity", value: activity_page.total}
    ]
  end

  defp stopped(%Episode{state: :waiting_for_input}, _turn) do
    %{
      action: "Answer the question in the conversation",
      attempted: [],
      headline: "Waiting for a person",
      href: nil,
      reason: "Ryker asked a question and continues when someone answers it."
    }
  end

  defp stopped(%Episode{state: :waiting_for_event}, _turn) do
    %{
      action: "Nothing to do now",
      attempted: [],
      headline: "Waiting for an event",
      href: nil,
      reason:
        "Ryker paused this request and picks it up again when the event it waits for happens or its deadline passes."
    }
  end

  defp stopped(%Episode{state: :cancelled}, _turn) do
    %{
      action: "No action is required",
      attempted: [],
      headline: "Request stopped",
      href: nil,
      reason: "This request was stopped and will not continue. Its history stays on this page."
    }
  end

  defp stopped(_episode, %Turn{status: :blocked, delivery_ref: ref}) when is_binary(ref) do
    %{
      action:
        "Check why delivery failed and look at the conversation before sending the saved reply again.",
      attempted: [],
      headline: "The reply could not be delivered",
      href: Paths.failure("delivery", ref),
      reason: "The answer is already saved, so sending it again doesn't run the model."
    }
  end

  defp stopped(episode, %Turn{status: :blocked} = turn) do
    recovery = Recovery.brief(turn)

    attempts =
      [
        started(turn.work_attempt_count || 0),
        turn.candidate_attempt &&
          plural(turn.candidate_attempt, "answer checked", "answers checked"),
        turn.coop_turn_id && "The worker began the task",
        turn.validation_intent && "Ryker checked an answer"
      ]
      |> Enum.reject(&is_nil/1)

    %{
      action: recovery.next_step,
      attempted: attempts,
      headline: recovery.headline,
      model_output: recovery.model_output,
      delivery: recovery.delivery,
      not_started: recovery.not_started,
      href: recovery.setup_href || Paths.failure("work", episode.id),
      link_label: if(recovery.setup_href, do: "View required setup", else: "Open recovery"),
      reason: recovery.cause
    }
  end

  defp stopped(_episode, _turn), do: nil

  defp started(0), do: nil
  defp started(1), do: "Started once"
  defp started(count), do: "Started #{count} times"

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

  defp conversation_part(step, {frontier, seen}, causality) do
    owner = Map.get(step, :owner) || :episode
    boundary = message_boundary?(step, seen)
    owner_position = EpisodeCausality.position(causality, owner)

    part =
      cond do
        boundary && owner_position -> owner_position
        boundary -> frontier + 1
        owner_position -> owner_position
        true -> frontier
      end

    seen = if boundary, do: MapSet.put(seen, step.id), else: seen

    # A late receipt keeps its older owner's position, but it must never move
    # the chronological frontier backwards. The next unowned message boundary
    # advances from the furthest message already observed.
    {{step, part, boundary, owner}, {max(frontier, part), seen}}
  end

  defp message_boundary?(%{kind: :message, band: :input, boundary: false}, _seen), do: false

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

  # A finished request asks how it went until someone rates the ending it has
  # now: a request that continued after a rating ends again, and that ending
  # is rated on its own. What people said, ratings included, is the Feedback
  # chapter's to show.
  defp rating_state(%Episode{} = episode, events) do
    rated =
      Repo.exists?(
        from(review in EpisodeReview,
          where:
            review.episode_id == ^episode.id and
              review.semantic_version == ^episode.semantic_version
        )
      )

    back = %{"back" => Paths.request(episode.id)}

    %{
      awaiting:
        episode.state in [:complete, :cancelled] and not rated and
          not closed_here?(episode, events),
      good: Paths.query(Paths.action("episode", episode.id, "rate-good"), back),
      needs_work: Paths.query(Paths.action("episode", episode.id, "rate-needs-work"), back)
    }
  end

  # An ending the person chose here, by closing the request from its timeline
  # or its chat task card, is not waiting for them to rate it; the timeline
  # asked them to the moment after. A stopped task's close settles later, so
  # it is read from the cancel itself rather than recorded when closing.
  defp closed_here?(%Episode{state: :cancelled}, events) do
    Enum.any?(events, fn event ->
      event.kind == :episode_cancelled and
        String.starts_with?(to_string(event.payload["cancel_ref"]), [
          "control-plane:",
          "control-plane-action:"
        ])
    end)
  end

  defp closed_here?(_episode, _events), do: false

  defp operator_actions(episode, current_turn) do
    recovery =
      if current_blocked_turn?(episode, current_turn) and is_nil(current_turn.delivery_ref),
        do: Recovery.brief(current_turn)

    []
    |> maybe_action(
      recovery != nil and recovery.action == :retry,
      if(recovery, do: recovery.action_label, else: "Retry work"),
      Paths.query(Paths.action("work", episode.id, "retry"), %{
        "back" => Paths.request(episode.id)
      }),
      :primary
    )
    |> maybe_action(
      resolvable?(episode, current_turn),
      "Close as no longer needed",
      Paths.action("episode", episode.id, "resolve"),
      :danger
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

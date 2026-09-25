defmodule Ryker.ControlPlane.EpisodeTrace.Preparation do
  @moduledoc """
  "Getting ready": per input, the participation decision with its recorded
  settings and standing-rule inventory, followed by the queue position; per
  Work turn, the setup selected against the session, worker and workspace it
  actually ran on.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.InspectionRedactor
  alias Ryker.CoopFleet.Placement
  alias Ryker.Ingress.InputCustodyTransition
  alias Ryker.Repo
  alias Ryker.State.Behaviors
  alias Ryker.Work.{FailureCause, Session, Turn}

  @doc """
  Getting ready, per input and in the approved order: one Participation card,
  then each contiguous Input queue run. The first run begins when the input was
  saved; a later retry stays at its retained later time instead of reopening it.
  Retained sequence is the tie-break for equal event timestamps.

  Participation carries the complete standing-rule inventory recorded when
  that input processed, or says plainly that none was recorded.
  It never reads today's rules: a rule edited since would quietly rewrite the
  old explanation.
  """
  def steps(input_rows) do
    inventories = Behaviors.rule_inventories(Enum.map(input_rows, &"ingress-input:#{&1.id}"))
    transitions = custody_transitions(input_rows)
    now = DateTime.utc_now()

    Enum.flat_map(input_rows, fn input ->
      receipt = input.engagement_receipt
      inventory = Map.get(inventories, "ingress-input:#{input.id}")
      rules = rule_inventory(inventory)
      rules = Map.put(rules, :summary, rule_summary(rules))
      participation = participation(receipt)
      engagement = engagement(receipt, input, rules)

      participation_step =
        step("participation-#{input.id}", :ready, input.inserted_at, %{
          actor: "Ryker",
          owner: {:input, input.id},
          input_id: input.id,
          participation: participation,
          engagement: engagement,
          rules: rules,
          details: [],
          stage: "Participation",
          state: engagement.result,
          summary: engagement.reason,
          title: "Participation",
          tone: engagement.tone
        })

      [participation_step | queue_steps(input, Map.get(transitions, input.id, []), now)]
    end)
  end

  defp custody_transitions(input_rows) do
    ids = Enum.map(input_rows, & &1.id)

    Repo.all(
      from(transition in InputCustodyTransition,
        where: transition.input_id in ^ids,
        order_by: [asc: transition.input_id, asc: transition.sequence]
      )
    )
    |> Enum.group_by(& &1.input_id)
  end

  defp queue_steps(input, [], now) do
    queue = legacy_queue(input, now)
    [queue_step(input, queue, "queue-#{input.id}")]
  end

  defp queue_steps(input, transitions, now) do
    transitions = Enum.map(transitions, &normalize_save_time(&1, input.inserted_at))
    runs = queue_runs(transitions)
    tail_index = length(runs) - 1

    # The queue hands the input to routing and takes it back on every retry,
    # so each run is filed under routing, in time order with the attempts.
    runs
    |> Enum.with_index()
    |> Enum.map(fn {run, index} ->
      previous = if index > 0, do: Enum.at(runs, index - 1)
      queue = queue_run(input, run, index, index == tail_index, now, previous)
      id = if index == 0, do: "queue-#{input.id}", else: "queue-#{input.id}-#{hd(run).sequence}"
      queue_step(input, queue, id)
    end)
  end

  # `inserted_at` is the inbox's durable save time and the ledger's first event
  # records the same fact. Keeping those equal also makes historical fixtures
  # that reposition an input preserve the invariant instead of creating a
  # fictitious multi-day queue wait.
  defp normalize_save_time(%{kind: kind} = transition, inserted_at)
       when kind in [:saved, :waiting_predecessor],
       do: %{transition | occurred_at: inserted_at}

  defp normalize_save_time(transition, _inserted_at), do: transition

  defp queue_step(input, queue, id) do
    step(id, :routing, queue.started_at, %{
      actor: "Ryker",
      owner: {:input, input.id},
      input_id: input.id,
      queue: queue,
      details: [],
      stage: "Queue",
      state: nil,
      summary: nil,
      title: "Queue",
      tone: queue.tone
    })
  end

  defp queue_runs(transitions) do
    Enum.reduce(transitions, [], &append_queue_transition/2)
  end

  defp append_queue_transition(transition, []), do: [[transition]]

  defp append_queue_transition(transition, runs) do
    if queue_run_sealed?(List.last(runs)) do
      runs ++ [[transition]]
    else
      List.update_at(runs, -1, &(&1 ++ [transition]))
    end
  end

  # A run ends when routing takes the input or automatic retries stop. An
  # operator's retry is a later moment and opens a run of its own.
  defp queue_run_sealed?(run),
    do: List.last(run).kind in [:blocked, :claimed, :reclaimed, :superseded]

  defp queue_run(input, run, index, tail?, now, previous) do
    first = hd(run)
    last = List.last(run)
    current = tail? and input.status == :pending and last.kind not in [:claimed, :reclaimed]

    qualifier = queue_qualifier(first, index, previous)

    events =
      (Enum.map(run, &queue_event(&1, input)) ++ current_queue_event(input, last, current, now))
      |> recovery_link(last, tail? and input.status == :blocked, input)
      |> reattached(qualifier)

    ended_at = if current, do: nil, else: last.occurred_at

    %{
      kind: queue_kind(last.kind, current),
      qualifier: qualifier,
      current: current,
      events: events,
      started_at: first.occurred_at,
      ended_at: ended_at,
      duration_ms: nonnegative_diff(ended_at, first.occurred_at),
      tone: queue_tone(last.kind)
    }
  end

  # While the input is still stopped, its last step links to the existing
  # recovery; once rearmed there is no way back to offer.
  defp recovery_link(events, %{kind: :blocked}, true, input) do
    List.update_at(
      events,
      -1,
      &%{
        &1
        | href: "/failures/admission/#{segment("ingress-input:#{input.id}")}",
          link_label: "View recovery"
      }
    )
  end

  defp recovery_link(events, _last, _blocked?, _input), do: events

  # A wait that ran out while the worker was still answering is not a failure:
  # the same call kept running and routing picked it back up.
  defp reattached(events, "Reattached to attempt " <> _attempt) do
    Enum.map(events, fn
      %{kind: :retry_scheduled} = event ->
        %{
          event
          | label: "Waiting paused",
            reason: "The worker had not answered yet; the call kept running there."
        }

      %{kind: kind} = event when kind in [:claimed, :reclaimed] ->
        %{event | label: "Resumed", reason: "A routing worker resumed waiting for the same call."}

      event ->
        event
    end)
  end

  defp reattached(events, _qualifier), do: events

  defp queue_qualifier(_first, 0, _previous), do: nil

  defp queue_qualifier(
         %{kind: :retry_scheduled, attempt: attempt, error_code: error_code},
         _index,
         previous
       )
       when attempt > 0 do
    if List.last(previous).attempt == attempt and
         error_code in ["coop_timeout", "coop_transport_timeout"],
       do: "Reattached to attempt #{attempt}",
       else: "Retry #{attempt}"
  end

  defp queue_qualifier(%{kind: :rearmed}, _index, _previous), do: "Recovery"
  defp queue_qualifier(_first, _index, _previous), do: nil

  defp queue_kind(:blocked, _current), do: :needs_attention
  defp queue_kind(:superseded, _current), do: :superseded
  defp queue_kind(:retry_scheduled, true), do: :retry
  defp queue_kind(:waiting_predecessor, true), do: :waiting
  defp queue_kind(:saved, true), do: :waiting
  defp queue_kind(:rearmed, true), do: :waiting
  defp queue_kind(kind, _current), do: kind

  defp queue_tone(:blocked), do: :bad
  defp queue_tone(:retry_scheduled), do: :warn
  defp queue_tone(_kind), do: nil

  defp queue_event(%{kind: :saved} = transition, _input) do
    queue_event(transition, "Saved", "The input entered the routing queue.")
  end

  defp queue_event(%{kind: :waiting_predecessor} = transition, _input) do
    queue_event(
      transition,
      "Waiting for an earlier input",
      "This conversation already had an earlier message waiting to be routed.",
      href:
        transition.predecessor_input_id &&
          "/timeline/ingress-input%3A#{transition.predecessor_input_id}",
      link_label:
        transition.predecessor_input_id &&
          "“#{queue_blocker_text(transition)}” · View earlier input"
    )
  end

  defp queue_event(%{kind: kind, attempt: attempt} = transition, _input)
       when kind in [:claimed, :reclaimed] do
    reason =
      if attempt > 1,
        do: "A routing worker claimed the input for attempt #{attempt}.",
        else: "A routing worker claimed the input."

    queue_event(transition, "Picked up", reason)
  end

  defp queue_event(%{kind: :retry_scheduled} = transition, _input) do
    reason =
      "Eligible to retry at #{retry_time(transition.eligible_at)}." <>
        error_reason(transition.error_code)

    queue_event(transition, "Retry scheduled", reason)
  end

  defp queue_event(%{kind: :blocked} = transition, _input) do
    queue_event(
      transition,
      "Automatic retries stopped",
      "Routing stopped after #{transition.attempt} #{if transition.attempt == 1, do: "attempt", else: "attempts"}." <>
        stop_reason(transition)
    )
  end

  defp queue_event(%{kind: :rearmed} = transition, _input) do
    queue_event(transition, "Rearmed", "An operator returned the input to the routing queue.")
  end

  defp queue_event(%{kind: :superseded} = transition, _input) do
    queue_event(
      transition,
      "Superseded",
      "A newer revision of this message was accepted before this revision was routed."
    )
  end

  defp queue_event(transition, label, reason, options \\ []) do
    %{
      kind: transition.kind,
      label: label,
      at: transition.occurred_at,
      reason: reason,
      href: Keyword.get(options, :href),
      link_label: Keyword.get(options, :link_label)
    }
  end

  defp current_queue_event(_input, _last, false, _now), do: []

  defp current_queue_event(input, %{kind: :retry_scheduled}, true, now) do
    reason =
      if live_after?(input.next_attempt_at, now),
        do: "Waiting until the retained retry time.",
        else: "Ready for the next routing worker."

    [%{kind: :current, label: "Current", at: nil, reason: reason, href: nil, link_label: nil}]
  end

  defp current_queue_event(_input, _last, true, _now) do
    [
      %{
        kind: :current,
        label: "Current",
        at: nil,
        reason: "Waiting for a routing worker to pick it up.",
        href: nil,
        link_label: nil
      }
    ]
  end

  defp queue_blocker_text(%InputCustodyTransition{detail: text})
       when is_binary(text) and text != "",
       do: text

  defp queue_blocker_text(%InputCustodyTransition{}), do: "Earlier input"

  # A reader plans around the second a retry becomes eligible, not its microsecond.
  defp retry_time(%DateTime{} = at), do: "#{at.day} #{Calendar.strftime(at, "%b, %H:%M:%S UTC")}"
  defp retry_time(value), do: timestamp_precise(value)

  # Why retrying stopped, in the words the failure explains itself with when
  # the saved detail names a cause; otherwise the recorded code.
  defp stop_reason(transition) do
    case FailureCause.explain(transition.detail) do
      %{cause: cause} -> " " <> cause
      nil -> error_reason(transition.error_code)
    end
  end

  defp error_reason(nil), do: ""
  defp error_reason(code), do: " Reason: #{error_label(code)}."

  defp legacy_queue(input, _now) do
    current = input.status == :pending

    %{
      kind: if(current, do: :waiting, else: :not_recorded),
      qualifier: nil,
      current: current,
      events: [
        %{
          kind: :not_recorded,
          label: "Queue history unavailable",
          at: input.inserted_at,
          reason: "Detailed queue transitions were not recorded for this older input.",
          href: nil,
          link_label: nil
        }
      ],
      started_at: input.inserted_at,
      ended_at: nil,
      duration_ms: nil,
      tone: nil
    }
  end

  # Effective proactive/shadow values at processing time. An explicit
  # submission never consulted channel settings, and history without a receipt
  # says "not recorded" rather than reading today's configuration.
  defp participation(nil),
    do: %{
      state: :not_recorded,
      settings: [],
      summary: nil
    }

  defp participation(%{"settings" => %{} = settings}) do
    rows =
      for key <- ["proactive", "shadow"], %{} = setting <- [settings[key]] do
        %{
          label: participation_label(key),
          value: if(setting["value"] == true, do: "On", else: "Off")
        }
      end

    %{
      state: :recorded,
      settings: rows,
      summary: nil
    }
  end

  defp participation(%{"path" => _path}) do
    %{
      state: :not_applicable,
      settings: [],
      summary: "Channel settings did not apply."
    }
  end

  defp participation(_receipt), do: participation(nil)

  defp participation_label("proactive"), do: "Proactive replies"
  defp participation_label("shadow"), do: "Shadow evaluation"
  defp participation_label(other), do: to_string(other)

  # The receipt is authoritative evidence, but its internal result names and
  # predicate trace are not operator copy. Compile its retained path, checks,
  # Slack audience and rule inventory into one human explanation.
  defp engagement(nil, _input, _rules),
    do: %{
      state: :not_recorded,
      result: "",
      tone: nil,
      reason:
        "The participation decision and channel settings were not recorded for this message."
    }

  defp engagement(%{"result" => result} = receipt, input, rules) do
    %{
      state: :recorded,
      result: result,
      tone: if(result == "process", do: :good),
      reason: engagement_reason(receipt, input, rules)
    }
  end

  defp engagement(_receipt, input, rules), do: engagement(nil, input, rules)

  defp engagement_reason(%{"path" => "conversation_lab"}, _input, _rules),
    do: "Ryker processed this message because it was sent directly through Chat."

  defp engagement_reason(%{"path" => "slack_shortcut"}, _input, _rules),
    do: "Ryker processed this message because it was submitted through a Slack shortcut."

  defp engagement_reason(receipt, input, rules) do
    cause = engagement_cause(receipt, input, rules)

    if receipt["execution_mode"] == "shadow" or receipt["result"] == "evaluate_only" do
      shadow_reason(cause)
    else
      live_reason(cause)
    end
  end

  defp engagement_cause(receipt, input, rules) do
    receipt["checks"]
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(:recorded, &engagement_check_cause(&1, input, rules))
  end

  defp engagement_check_cause(
         %{"check" => "direct_or_mention", "outcome" => "yes"},
         input,
         _rules
       ),
       do: direct_or_mention_cause(input.slack_audience)

  defp engagement_check_cause(
         %{"check" => "existing_episode_thread", "outcome" => "yes"},
         _input,
         _rules
       ),
       do: :existing_episode

  defp engagement_check_cause(
         %{"check" => "standing_rule", "outcome" => "matched"},
         _input,
         rules
       ),
       do: matched_rule_cause(rules)

  defp engagement_check_cause(
         %{"check" => "proactive_participation", "outcome" => "on"},
         _input,
         _rules
       ),
       do: :proactive

  defp engagement_check_cause(
         %{"check" => "shadow_evaluation", "outcome" => "on"},
         _input,
         _rules
       ),
       do: :shadow

  defp engagement_check_cause(_check, _input, _rules), do: nil

  defp direct_or_mention_cause(:direct), do: :direct
  defp direct_or_mention_cause(:mention), do: :mention
  defp direct_or_mention_cause(_audience), do: :direct_or_mention

  defp matched_rule_cause(%{entries: entries}) do
    case Enum.find(entries, &(&1.verdict == "matched")) do
      %{title: title} when is_binary(title) and title != "" -> {:rule, title}
      _missing -> :rule
    end
  end

  defp live_reason(:direct), do: "Ryker processed this direct message."
  defp live_reason(:mention), do: "Ryker processed this message because it was mentioned."

  defp live_reason(:direct_or_mention),
    do: "Ryker processed this message because it was sent directly to or mentioned Ryker."

  defp live_reason(:existing_episode),
    do: "Ryker processed this message because it continued an existing episode."

  defp live_reason({:rule, title}),
    do: "Ryker processed this message because the standing rule “#{bounded(title, 160)}” matched."

  defp live_reason(:rule),
    do: "Ryker processed this message because a standing rule matched."

  defp live_reason(:proactive),
    do:
      "Ryker processed this message even though it was not mentioned because proactive replies were on."

  defp live_reason(_cause), do: "Ryker processed this message."

  defp shadow_reason(cause) do
    qualifier =
      case cause do
        :direct ->
          " and it qualified because it was a direct message"

        :mention ->
          " and it qualified because Ryker was mentioned"

        :direct_or_mention ->
          " and it qualified because Ryker was addressed directly"

        :existing_episode ->
          " and it qualified because it continued an existing episode"

        {:rule, title} ->
          " and it qualified because the standing rule “#{bounded(title, 160)}” matched"

        :rule ->
          " and it qualified because a standing rule matched"

        :proactive ->
          " and it qualified because proactive replies were on"

        _cause ->
          ""
      end

    "Ryker evaluated this message without replying because Shadow evaluation was on#{qualifier}."
  end

  defp rule_inventory(nil), do: %{state: :not_recorded, entries: [], truncated: false}

  defp rule_inventory(inventory) do
    entries =
      inventory.entries
      |> Enum.map(fn entry ->
        %{
          ref: entry["ref"],
          title: entry["title"] || entry["ref"],
          status: entry["status"],
          revision: entry["revision"],
          scope_ref: entry["scope_ref"],
          verdict: entry["verdict"],
          reason: InspectionRedactor.artifact(entry["reason"] || "", max_bytes: 400).text,
          criteria: entry["criteria"],
          evidence: entry["evidence"]
        }
      end)
      |> Enum.sort_by(&{&1.verdict != "matched", &1.title})

    %{
      state: :recorded,
      recorded_at: inventory.recorded_at,
      rule_count: inventory.rule_count,
      matched_count: inventory.matched_count,
      truncated: inventory.truncated,
      entries: entries
    }
  end

  defp rule_summary(%{state: :not_recorded}),
    do: "Standing-rule history was not recorded for this message."

  defp rule_summary(%{rule_count: 0}),
    do: "No standing rules."

  defp rule_summary(%{rule_count: total, matched_count: matched}),
    do: "#{total} #{if(total == 1, do: "rule", else: "rules")} · #{matched} matched"

  @doc """
  One Work setup card per Work turn, before its briefing: the pinned setup
  versus the actual session, worker and workspace it ran on. A pinned
  episode that no turn has claimed yet gets one card on its session row,
  which proves configuration was selected and nothing more.
  """
  def setup_steps(sessions, turns) do
    work_sessions = Enum.filter(sessions, &(&1.execution_kind == :work))
    sessions_by_id = Map.new(work_sessions, &{&1.id, &1})
    placements = placements(work_sessions)
    now = DateTime.utc_now()

    turn_cards =
      turns
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, ordinal} ->
        session = Map.get(sessions_by_id, turn.session_id)

        earlier =
          Enum.filter(turns, fn other ->
            other.session_id == turn.session_id and other.id != turn.id and
              DateTime.compare(other.inserted_at, turn.inserted_at) == :lt
          end)

        setup =
          work_setup(turn, ordinal, session, earlier, Map.get(placements, turn.session_id), now)

        step("setup-#{turn.id}", :ready, turn.inserted_at, %{
          actor: "Ryker",
          owner: {:turn, turn.id},
          setup: setup,
          details: [],
          stage: "Work setup",
          state: setup.label,
          summary: setup.summary,
          title: "Work setup",
          tone: setup.tone
        })
      end)

    session_cards =
      if turns == [] do
        Enum.map(work_sessions, fn session ->
          setup = selected_setup(session)

          step("setup-#{session.id}", :ready, session.inserted_at, %{
            actor: "Ryker",
            setup: setup,
            details: [],
            stage: "Work setup",
            state: setup.label,
            summary: setup.summary,
            title: "Work setup",
            tone: nil
          })
        end)
      else
        []
      end

    turn_cards ++ session_cards
  end

  defp placements([]), do: %{}

  defp placements(sessions) do
    ids = Enum.map(sessions, & &1.id)

    Repo.all(
      from(placement in Placement,
        where: placement.session_id in ^ids,
        order_by: [asc: placement.session_id, desc: placement.generation, desc: placement.id]
      )
    )
    |> Enum.uniq_by(& &1.session_id)
    |> Map.new(&{&1.session_id, &1})
  end

  # Ready needs evidence that preparation completed: a bound remote turn is
  # that evidence, because Coop accepts a turn only into a prepared session. A
  # live lease without a bound session is preparation in progress at the one
  # step the rows record. Anything else is "selected", with its outcome
  # unrecorded rather than guessed from today's worker health.
  # Two facts a reader can use: whether the model started fresh or kept the
  # earlier round, and what code it could see. The worker and its execution
  # policy are the same on every card of a one-worker install, so they are
  # named only when setup failed and they are part of the explanation.
  defp work_setup(turn, ordinal, session, earlier_turns, placement, now) do
    session_state = session_state(session, earlier_turns)
    outcome = setup_outcome(turn, session, now)

    Map.merge(outcome, %{
      ordinal: ordinal,
      rows:
        compact_details([
          {"Session", session_state.detail},
          {"Code", setup_code(turn, session)},
          {"Current step", outcome.current_step}
        ]),
      diagnostics: setup_diagnostics(outcome.kind, turn, session, placement)
    })
  end

  # Ready needs evidence that preparation completed, which is a bound remote
  # turn: Coop accepts a turn only into a prepared session. A live lease with
  # no bound session is preparation in progress at the one step the rows
  # record. Anything else is "selected", with its outcome unrecorded rather
  # than guessed from today's worker health.
  defp setup_outcome(turn, session, now) do
    {kind, label, summary, tone, current_step} =
      cond do
        turn.status == :blocked and is_nil(turn.coop_turn_id) ->
          {:blocked, "Blocked", setup_failure(turn.last_error_code), :bad, nil}

        is_binary(turn.coop_turn_id) or not is_nil(turn.remote_queued_at) ->
          {:ready, "Ready", nil, :good, nil}

        turn.status == :pending and is_binary(turn.lease_ref) and
            live_after?(turn.lease_expires_at, now) ->
          {:preparing, "Preparing", nil, nil, preparing_step(session, turn)}

        true ->
          {:selected, "Setup selected", "Preparation outcome not recorded.", nil, nil}
      end

    %{
      kind: kind,
      label: label,
      summary: summary,
      tone: tone,
      current: kind != :ready,
      current_step: current_step
    }
  end

  defp setup_diagnostics(kind, _turn, _session, _placement) when kind != :blocked, do: []

  defp setup_diagnostics(:blocked, turn, nil, _placement),
    do:
      compact_details([
        {"Turn ID", turn.turn_ref, identifier: true},
        {"Work claims", turn.work_attempt_count}
      ])

  defp setup_diagnostics(:blocked, turn, session, placement) do
    compact_details([
      {"Worker", setup_worker(session, placement)},
      {"Execution policy", session.policy},
      {"Turn ID", turn.turn_ref, identifier: true},
      {"Session ID", session.id, identifier: true},
      {"Remote session", session.coop_session_id, identifier: true},
      {"Remote turn", turn.coop_turn_id, identifier: true},
      {"Work claims", turn.work_attempt_count}
    ])
  end

  defp selected_setup(session) do
    %{
      kind: :selected,
      label: "Setup selected",
      summary: "Waiting for a Work claim. Preparation has not started.",
      tone: nil,
      current: true,
      ordinal: nil,
      current_step: nil,
      rows:
        compact_details([
          {"Session", "Not created yet"},
          {"Code", setup_code(nil, session)}
        ]),
      diagnostics: []
    }
  end

  # New, reused or replaced is read from generations and earlier turns on the
  # same row. The rotation reason is not retained anywhere, so a replacement
  # says "Reason not recorded" rather than borrowing today's session state.
  defp session_state(nil, _earlier_turns),
    do: %{detail: "Not recorded"}

  defp session_state(session, earlier_turns) do
    cond do
      earlier_turns != [] ->
        %{detail: "Continued · the model still has what it saw in the previous round"}

      session.generation > 1 or session.create_generation > 1 ->
        %{detail: "New, replacing an earlier session · the reason was not recorded"}

      true ->
        %{detail: "New · the model starts with only this briefing"}
    end
  end

  # What the recorded code means, in one sentence. A missing per-worker
  # breakdown stays missing: "no eligible capacity" is not "every worker was
  # busy", and the rows cannot say which it was.
  defp setup_failure("coop_worker_capacity_unavailable"),
    do: "No eligible worker with available capacity was found."

  defp setup_failure(code) when code in ~w(coop_unavailable coop_transport_error),
    do: "The worker connection failed before the session was ready."

  defp setup_failure(nil), do: "Preparation stopped; the recorded error has no code."
  defp setup_failure(code), do: "Preparation stopped: " <> error_label(code) <> "."

  # The repository-backed task this session was pinned for, when there is one.
  # A pinned task is a binding, not proof of a Coop task timeline.

  defp setup_worker(_session, %Placement{worker_id: worker}) when is_binary(worker), do: worker
  defp setup_worker(%Session{coop_session_id: id}, nil) when is_binary(id), do: "Local Coop"
  defp setup_worker(_session, _placement), do: nil

  defp preparing_step(%Session{coop_session_id: nil}, _turn), do: "Creating worker session"
  defp preparing_step(_session, %Turn{submission: nil}), do: "Preparing the briefing"
  defp preparing_step(_session, _turn), do: "Submitting the frozen briefing"

  # A session without a repository still gets Coop's empty scratch workspace,
  # named "primary"; that is not code the reader would recognise.
  defp setup_code(_turn, %Session{repository_ref: nil}), do: "No repository"

  defp setup_code(%Turn{operational_pruned_at: nil, submission: %{} = submission}, session) do
    case get_in(submission, ["context", "workspace"]) do
      %{"primary" => %{} = primary} = workspace ->
        companions = workspace |> Map.get("companions", []) |> Enum.filter(&is_map/1)
        Enum.map_join([primary | companions], ", ", &repository_access(&1, session))

      _absent ->
        session.repository_ref
    end
  end

  defp setup_code(_turn, %Session{repository_ref: repository}), do: repository
  defp setup_code(_turn, _session), do: nil

  defp repository_access(%{"name" => "primary"} = primary, session),
    do: repository_access(%{primary | "name" => session.repository_ref}, session)

  defp repository_access(%{"name" => name, "read_only" => true}, _session),
    do: "#{name} · read only"

  defp repository_access(%{"name" => name, "read_only" => false}, _session),
    do: "#{name} · can change it"

  defp repository_access(%{"name" => name}, _session), do: name
  defp repository_access(_repository, _session), do: "unnamed repository"
end

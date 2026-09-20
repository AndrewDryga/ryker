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
  alias Ryker.Work.{Session, Turn}

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
    step(id, :ready, queue.started_at, %{
      actor: "Ryker",
      owner: {:input, input.id},
      input_id: input.id,
      queue: queue,
      details: [],
      stage: "Input queue",
      state: nil,
      summary: nil,
      title: "Input queue",
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

  defp queue_run_sealed?(run),
    do: List.last(run).kind in [:claimed, :reclaimed, :superseded]

  defp queue_run(input, run, index, tail?, now, previous) do
    first = hd(run)
    last = List.last(run)
    current = tail? and input.status == :pending and last.kind not in [:claimed, :reclaimed]

    events =
      Enum.map(run, &queue_event(&1, input)) ++ current_queue_event(input, last, current, now)

    ended_at = if current, do: nil, else: last.occurred_at

    %{
      kind: queue_kind(last.kind, current),
      qualifier: queue_qualifier(first, index, previous),
      current: current,
      events: events,
      started_at: first.occurred_at,
      ended_at: ended_at,
      duration_ms: nonnegative_diff(ended_at, first.occurred_at),
      tone: queue_tone(last.kind),
      recovery_href:
        if(last.kind == :blocked,
          do: "/failures/admission/#{segment("ingress-input:#{input.id}")}"
        ),
      technical: queue_technical(input)
    }
  end

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
      "Eligible to retry at #{timestamp_precise(transition.eligible_at)}." <>
        error_reason(transition.error_code)

    queue_event(transition, "Retry scheduled", reason)
  end

  defp queue_event(%{kind: :blocked} = transition, _input) do
    queue_event(
      transition,
      "Automatic retries stopped",
      "Routing stopped after #{transition.attempt} attempts." <>
        error_reason(transition.error_code)
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

    [%{label: "Current", at: nil, reason: reason, href: nil, link_label: nil}]
  end

  defp current_queue_event(_input, _last, true, _now) do
    [
      %{
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

  defp error_reason(nil), do: ""
  defp error_reason(code), do: " Reason: #{error_label(code)}."

  defp queue_technical(input) do
    compact_details([
      {"Input ID", "ingress-input:#{input.id}"},
      {"Source revision", input.revision},
      {"Event identity", input.dedupe_key},
      {"Content fingerprint", short_digest(input.event_fingerprint)}
    ])
  end

  defp legacy_queue(input, _now) do
    current = input.status == :pending

    %{
      kind: if(current, do: :waiting, else: :not_recorded),
      qualifier: nil,
      current: current,
      events: [
        %{
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
      tone: nil,
      recovery_href: nil,
      technical: queue_technical(input)
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
          reason: InspectionRedactor.artifact(entry["reason"] || "", max_bytes: 400).text
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
    do: "No standing rules"

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
          setup = selected_setup(session, Map.get(placements, session.id))

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
  defp work_setup(turn, ordinal, session, earlier_turns, placement, now) do
    session_state = session_state(session, earlier_turns)
    workspace = setup_workspace(turn)
    worker = setup_worker(session, placement)
    outcome = setup_outcome(turn, session, now)

    Map.merge(outcome, %{
      ordinal: ordinal,
      rows:
        compact_details([
          {"Session", session_state.face},
          {"Worker", worker},
          {"Profile", session && session.policy},
          {"Workspace", workspace.face},
          {"Current step", outcome.current_step}
        ]),
      details: setup_details(turn, session, session_state, worker, workspace),
      technical: setup_technical(turn, session, placement)
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

  defp setup_details(turn, session, session_state, worker, workspace) do
    compact_details([
      {"Session", session_state.detail},
      {"Profile", session && session.policy},
      {"Selected from", "Not recorded"},
      {"Worker", worker},
      {"Repository access", workspace.access},
      {"Ryker tools", if(is_binary(turn.state_tools_endpoint), do: "Bound to this work turn")},
      {"Bound task", session && setup_task(session.workspace_task)},
      {"Preparation checks", "Individual check results not recorded"}
    ])
  end

  defp setup_technical(turn, nil, _placement),
    do: compact_details([{"Turn", turn.turn_ref}, {"Work claims", turn.work_attempt_count}])

  defp setup_technical(turn, session, placement) do
    compact_details([
      {"Turn", turn.turn_ref},
      {"Session", session.id},
      {"Session generation", session.generation},
      {"Create generation", session.create_generation},
      {"Remote session", session.coop_session_id},
      {"Remote turn", turn.coop_turn_id},
      {"Policy digest", short_digest(session.policy_digest)},
      {"Authority digest", short_digest(session.authority_digest)},
      {"Repository", session.repository_ref},
      {"Placement worker", placement && placement.worker_id},
      {"Placement generation", placement && placement.generation},
      {"Work claims", turn.work_attempt_count}
    ])
  end

  defp selected_setup(session, placement) do
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
          {"Session", "Not created"},
          {"Profile", session.policy}
        ]),
      details:
        compact_details([
          {"Profile", session.policy},
          {"Selected from", "Not recorded"},
          {"Worker", setup_worker(session, placement)},
          {"Repository", session.repository_ref}
        ]),
      technical:
        compact_details([
          {"Session", session.id},
          {"Session generation", session.generation},
          {"Policy digest", short_digest(session.policy_digest)},
          {"Authority digest", short_digest(session.authority_digest)}
        ])
    }
  end

  # New, reused or replaced is read from generations and earlier turns on the
  # same row. The rotation reason is not retained anywhere, so a replacement
  # says "Reason not recorded" rather than borrowing today's session state.
  defp session_state(nil, _earlier_turns),
    do: %{face: "Not recorded", detail: "Not recorded"}

  defp session_state(session, earlier_turns) do
    cond do
      earlier_turns != [] ->
        %{
          face: "Reused from previous work round",
          detail: "Reused from previous work round · Generation #{session.generation}"
        }

      session.generation > 1 or session.create_generation > 1 ->
        %{
          face: "Replaced · Reason not recorded",
          detail: "Replaced · Generation #{session.generation} · Reason not recorded"
        }

      true ->
        %{face: "New", detail: "New · Generation #{session.generation}"}
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
  defp setup_task(%{} = task) do
    title =
      if is_binary(task["title"]),
        do: InspectionRedactor.artifact(task["title"], max_bytes: 200).text

    repository =
      case task do
        %{"repository" => repository} when is_binary(repository) -> repository
        %{"primary" => %{"name" => name}} when is_binary(name) -> name
        _task -> nil
      end

    [title, repository] |> Enum.reject(&is_nil/1) |> Enum.join(" · ") |> present()
  end

  defp setup_task(_task), do: nil

  defp setup_worker(_session, %Placement{worker_id: worker}) when is_binary(worker), do: worker
  defp setup_worker(%Session{coop_session_id: id}, nil) when is_binary(id), do: "Local Coop"
  defp setup_worker(_session, _placement), do: nil

  defp preparing_step(%Session{coop_session_id: nil}, _turn), do: "Creating worker session"
  defp preparing_step(_session, %Turn{submission: nil}), do: "Preparing the briefing"
  defp preparing_step(_session, _turn), do: "Submitting the frozen briefing"

  defp setup_workspace(%Turn{operational_pruned_at: pruned, submission: submission})
       when not is_nil(pruned) or not is_map(submission),
       do: %{face: nil, access: nil}

  defp setup_workspace(%Turn{submission: submission}) do
    case get_in(submission, ["context", "workspace"]) do
      %{"primary" => %{} = primary} = workspace ->
        companions = workspace |> Map.get("companions", []) |> Enum.filter(&is_map/1)
        count = 1 + length(companions)

        %{
          face: "Prepared · #{plural(count, "repository", "repositories")}",
          access: Enum.map_join([primary | companions], " · ", &repository_access/1)
        }

      _absent ->
        %{face: nil, access: nil}
    end
  end

  defp repository_access(%{"name" => name, "read_only" => true}), do: "#{name} read-only"
  defp repository_access(%{"name" => name, "read_only" => false}), do: "#{name} writable"
  defp repository_access(%{"name" => name}), do: "#{name} access not recorded"
  defp repository_access(_repository), do: "unnamed repository"
end

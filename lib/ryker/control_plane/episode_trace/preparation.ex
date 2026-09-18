defmodule Ryker.ControlPlane.EpisodeTrace.Preparation do
  @moduledoc """
  "Getting ready": per input, the participation decision with its recorded
  settings and standing-rule inventory, followed by the queue position; per
  Work turn, the setup selected against the session, worker and workspace it
  actually ran on.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.Admission.Attempt
  alias Ryker.ControlPlane.{InspectionRedactor, SourceText}
  alias Ryker.CoopFleet.Placement
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.State.Behaviors
  alias Ryker.Work.{Session, Turn}

  @doc """
  Getting ready, per input and in the approved order: one Participation card,
  then the Input queue. Both sit at the moment the input was accepted; list
  order is the tie-break, so the sequence survives identical timestamps.

  Participation carries the complete standing-rule inventory recorded when
  that input processed, or says plainly that none was recorded.
  It never reads today's rules: a rule edited since would quietly rewrite the
  old explanation.
  """
  def steps(input_rows) do
    inventories = Behaviors.rule_inventories(Enum.map(input_rows, &"ingress-input:#{&1.id}"))
    attempts = first_attempts(input_rows)
    now = DateTime.utc_now()

    Enum.flat_map(input_rows, fn input ->
      receipt = input.engagement_receipt
      inventory = Map.get(inventories, "ingress-input:#{input.id}")
      rules = rule_inventory(inventory)
      rules = Map.put(rules, :summary, rule_summary(rules))
      participation = participation(receipt)
      engagement = engagement(receipt)
      queue = queue(input, Map.get(attempts, input.id), now)

      [
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
        }),
        step("queue-#{input.id}", :ready, input.inserted_at, %{
          actor: "Ryker",
          owner: {:input, input.id},
          input_id: input.id,
          queue: queue,
          details: [],
          stage: "Input queue",
          state: queue.label,
          summary: queue.summary,
          title: "Input queue",
          tone: queue.tone
        })
      ]
    end)
  end

  # The earliest admission attempt is the routing claim that first prepared
  # context for the input. Nothing else retains a claim time: claiming clears
  # the retry fields and updated_at moves on every other write.
  defp first_attempts(input_rows) do
    ids = Enum.map(input_rows, & &1.id)

    Repo.all(
      from(attempt in Attempt,
        where: attempt.input_id in ^ids,
        order_by: [asc: attempt.inserted_at, asc: attempt.id]
      )
    )
    |> Enum.group_by(& &1.input_id)
    |> Map.new(fn {input_id, [first | _rest]} -> {input_id, first} end)
  end

  # Saved or not, waiting for what, handed to routing or not. Terminal rows
  # read their durable status; a pending row reads the live queue, and
  # everything derived from the live queue is labelled current because it will
  # not be true for long.
  defp queue(input, first_attempt, now) do
    claimed_at = first_attempt && first_attempt.inserted_at
    wait_ms = if claimed_at, do: nonnegative_diff(claimed_at, input.inserted_at)
    state = queue_state(input, now)

    Map.merge(state, %{
      saved_at: input.inserted_at,
      claimed_at: claimed_at,
      wait_ms: wait_ms,
      claims: input.attempt_count,
      facts: queue_facts(input, state, claimed_at, wait_ms),
      technical: queue_technical(input, state)
    })
  end

  # What happened to this input while it waited: when it arrived, who claimed
  # it, how long that took, and whether it is coming back. The lease belongs
  # here too — it is the claim, not an identifier.
  defp queue_facts(input, state, claimed_at, wait_ms) do
    held? = state.kind == :handed and state.current

    compact_details([
      {"Arrived", timestamp_precise(input.inserted_at)},
      {"Source occurrence", queue_occurrence(input)},
      {"Routing claim", if(claimed_at, do: timestamp_precise(claimed_at), else: "Not recorded")},
      {"Queue wait", format_ms(wait_ms) || "Not recorded"},
      {"Queue claims", input.attempt_count},
      {"Held by", if(held?, do: input.lease_owner)},
      {"Hold expires", if(held?, do: timestamp_precise(input.lease_expires_at))},
      {"Eligible for retry after",
       if(state.kind == :retry, do: timestamp_precise(input.next_attempt_at))},
      {"Last routing error", if(input.status != :decided, do: error_label(input.last_error_code))}
    ])
  end

  # The identifiers somebody debugging this input needs to find it elsewhere.
  # No adapter records a source acknowledgement, so there is no row for one.
  defp queue_technical(input, _state) do
    compact_details([
      {"Input / revision", "ingress-input:#{input.id} · revision #{input.revision}"},
      {"Identity", input.dedupe_key},
      {"Event fingerprint", short_digest(input.event_fingerprint)},
      {"Execution mode", capitalize(human(input.execution_mode))},
      {"Execution generation", input.execution_generation},
      {"Validation generation", input.validation_generation}
    ])
  end

  defp queue_state(%Entry{status: :decided}, _now) do
    %{
      kind: :handed,
      label: "Handed to routing",
      summary: "A routing worker picked up this input.",
      current: false,
      tone: :good,
      blocker: nil,
      recovery_href: nil
    }
  end

  defp queue_state(%Entry{status: :superseded}, _now) do
    %{
      kind: :superseded,
      label: "Superseded",
      summary:
        "Input remains saved. A newer revision of this message was already accepted, so this revision's routing choice was not applied.",
      current: false,
      tone: nil,
      blocker: nil,
      recovery_href: nil
    }
  end

  defp queue_state(%Entry{status: :blocked} = input, _now) do
    %{
      kind: :needs_attention,
      label: "Needs attention",
      summary:
        "Input remains saved. Automatic retries have stopped." <>
          error_sentence(input.last_error_code),
      current: false,
      tone: :bad,
      blocker: nil,
      recovery_href: "/failures/admission/#{segment(Inbox.ref(input))}"
    }
  end

  defp queue_state(%Entry{status: :pending} = input, now) do
    cond do
      is_binary(input.lease_ref) and live_after?(input.lease_expires_at, now) ->
        %{
          kind: :handed,
          label: "Handed to routing",
          summary: "A routing worker holds this input.",
          current: true,
          tone: nil,
          blocker: nil,
          recovery_href: nil
        }

      live_after?(input.next_attempt_at, now) ->
        %{
          kind: :retry,
          label: "Waiting to retry",
          summary:
            "Input remains saved." <>
              error_sentence(input.last_error_code) <>
              " Eligible for retry after #{timestamp_precise(input.next_attempt_at)}; a predecessor or an unavailable worker can still delay it.",
          current: true,
          tone: :warn,
          blocker: nil,
          recovery_href: nil
        }

      true ->
        queue_waiting(input, Inbox.queue_predecessor(input, now))
    end
  end

  defp queue_waiting(_input, nil) do
    %{
      kind: :waiting,
      label: "Waiting",
      summary: "Saved; waiting for routing pickup.",
      current: true,
      tone: nil,
      blocker: nil,
      recovery_href: nil
    }
  end

  defp queue_waiting(_input, %Entry{} = predecessor) do
    %{
      kind: :waiting,
      label: "Waiting",
      summary: "Waiting for an earlier input in this conversation.",
      current: true,
      tone: nil,
      blocker: %{
        text: queue_blocker_text(predecessor),
        href: "/timeline/ingress-input%3A#{predecessor.id}"
      },
      recovery_href: nil
    }
  end

  defp queue_blocker_text(%Entry{operational_pruned_at: nil, content: content}) do
    case SourceText.from_content(content) do
      text when is_binary(text) and text != "" ->
        InspectionRedactor.artifact(text, max_bytes: 120).text

      _absent ->
        "Earlier input"
    end
  end

  defp queue_blocker_text(_predecessor), do: "Earlier input"

  defp queue_occurrence(%Entry{event_kind: :message}), do: "New input"
  defp queue_occurrence(%Entry{event_kind: :edit}), do: "Edited message · new revision"
  defp queue_occurrence(%Entry{event_kind: :delete}), do: "Deleted message · new revision"
  defp queue_occurrence(%Entry{event_kind: kind}), do: capitalize(human(kind))

  # Effective proactive/shadow values with the source each one won from. An
  # explicit submission never consulted channel settings, and history without
  # a receipt says "not recorded" rather than reading today's configuration.
  defp participation(nil),
    do: %{
      state: :not_recorded,
      settings: [],
      summary: "Effective participation settings were not recorded for this input."
    }

  defp participation(%{"settings" => %{} = settings}) do
    rows =
      for key <- ["proactive", "shadow"], %{} = setting <- [settings[key]] do
        %{
          label: participation_label(key),
          value: if(setting["value"] == true, do: "On", else: "Off"),
          source: setting_source_label(setting["source"])
        }
      end

    %{
      state: :recorded,
      settings: rows,
      summary: Enum.map_join(rows, " · ", &"#{&1.label} #{&1.value}")
    }
  end

  defp participation(%{"path" => path}) do
    %{
      state: :not_applicable,
      settings: [],
      summary: "Not applicable: #{path_label(path)} bypasses channel participation settings."
    }
  end

  defp participation(_receipt), do: participation(nil)

  defp participation_label("proactive"), do: "Proactive"
  defp participation_label("shadow"), do: "Shadow"
  defp participation_label(other), do: to_string(other)

  defp setting_source_label("channel"), do: "Saved channel setup"
  defp setting_source_label("configuration"), do: "Channel configuration"
  defp setting_source_label("workspace"), do: "Workspace setting"
  defp setting_source_label("deployment"), do: "Deployment default"
  defp setting_source_label("incident_room"), do: "Incident room policy"
  defp setting_source_label("watch_channels"), do: "Watched channel list"
  defp setting_source_label(nil), do: "Source not recorded"
  defp setting_source_label(other), do: human(to_string(other))

  defp path_label("conversation_lab"), do: "an explicit direct-conversation submission"
  defp path_label("slack_shortcut"), do: "an explicit Slack shortcut"
  defp path_label("slack_event"), do: "a Slack event"
  defp path_label(other), do: human(to_string(other))

  # The decision as it was made: result, plain reason, and every predicate the
  # gate reached. A predicate it never reached is "not checked" -- the receipt
  # does not know its answer and neither does anyone else.
  defp engagement(nil),
    do: %{
      state: :not_recorded,
      result: "",
      tone: nil,
      reason: "The engagement decision was not recorded for this input.",
      path: nil,
      checks: []
    }

  defp engagement(%{"result" => result} = receipt) do
    # A receipt is retained JSON written by an older version of the gate. One
    # whose shape no longer parses is one card's absence; crashing here would
    # take the whole page with it.
    checks =
      receipt["checks"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn check ->
        %{
          label: engagement_check_label(check["check"]),
          outcome: check_outcome(check["outcome"])
        }
      end)

    %{
      state: :recorded,
      result: engagement_result(result),
      tone: if(result == "process", do: :good),
      reason: bounded(to_string(receipt["reason"] || ""), 400),
      path: path_label(receipt["path"]),
      execution_mode: receipt["execution_mode"],
      checks: checks
    }
  end

  defp engagement(_receipt), do: engagement(nil)

  defp engagement_result(result) when is_map(result) or is_list(result), do: "Not recorded"
  defp engagement_result("process"), do: "Process"
  defp engagement_result("evaluate_only"), do: "Evaluate only"
  defp engagement_result("not_engaged"), do: "Not picked up"
  defp engagement_result(other), do: human(to_string(other))

  defp engagement_check_label("direct_or_mention"), do: "Direct message / mention"
  defp engagement_check_label("existing_episode_thread"), do: "Existing episode thread"
  defp engagement_check_label("standing_rule"), do: "Standing rule"
  defp engagement_check_label("proactive_participation"), do: "Proactive participation"
  defp engagement_check_label("shadow_evaluation"), do: "Shadow evaluation"
  defp engagement_check_label(other), do: other |> to_string() |> human()

  defp check_outcome(nil), do: "Not checked"
  defp check_outcome("yes"), do: "Yes"
  defp check_outcome("no"), do: "No"
  defp check_outcome("matched"), do: "Matched"
  defp check_outcome("not_matched"), do: "Not matched"
  defp check_outcome("on"), do: "On"
  defp check_outcome("off"), do: "Off"
  defp check_outcome(other), do: human(to_string(other))

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
    do: "Standing-rule evaluation was not recorded for this input."

  defp rule_summary(%{rule_count: 0}),
    do: "No standing rules existed when this input was processed."

  defp rule_summary(%{rule_count: total, matched_count: matched}),
    do:
      "#{matched} matched · #{total - matched} other · rules as they existed when this input was processed."

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

    %{kind: kind, label: label, summary: summary, tone: tone, current_step: current_step}
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

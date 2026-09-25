defmodule Ryker.ControlPlane.FailureExplanation do
  @moduledoc """
  What one failure means, in the words every surface uses for it.

  The Failures list, a failure's own page and the confirmation page of its
  recovery action all describe the same stopped operation. They read this
  module, so a button, the sentence under it and the page that confirms it
  cannot disagree about what the action does or whether it will work.

  Every explanation answers, in order: what stopped, who it affects, what
  Ryker already tried and why it stopped trying on its own, what each option
  does, and whether a retry should work right now. The last answer comes from
  facts the projection read cheaply (is the worker that holds a session
  reporting and still running its policy version, is Ryker back in the
  channel, was Slack reconnected since), and says what it depends on when
  those facts cannot settle it.

  Outlooks:

    * `:ready`: what stopped it has cleared; a retry should work.
    * `:unknown`: a person has to judge; the text says what a retry depends on.
    * `:fix_first`: a retry fails until something a person can change changes;
      the row offers that change, not the retry.
    * `:stuck`: a retry fails and nothing on this page can change that; the
      page says so plainly instead of offering a button.
    * `:automatic`: Ryker is still retrying on its own.

  Raw error bodies never appear here: they may carry provider bodies, source
  text or credentials. The Technical details list the saved code, allowlisted
  protocol facts and a digest of the stored diagnostic.
  """

  alias Ryker.ControlPlane.{ShortTime, SlackNames}

  @type outlook :: :ready | :unknown | :fix_first | :stuck | :automatic

  @slack_settings "/integrations/slack"
  @github_settings "/integrations/github"
  @emisar_settings "/integrations/emisar"
  @workers "/working-copies"

  @doc "The explanation of one failure row, read at `now`."
  @spec explain(map(), DateTime.t()) :: map()
  def explain(row, now \\ DateTime.utc_now()) do
    story = story(row, now)
    retry = retry_option(row, story)
    fix = story[:fix]
    level = story.outlook

    %{
      title: story.title,
      lede: story.lede,
      impact: story.impact,
      outlook: level,
      state: state(level, story),
      summary: story.summary,
      happened: story.happened,
      affects: story.affects,
      tried: story.tried,
      options_lede: options_lede(level),
      options:
        [retry, fix && fix_option(fix, level), story[:alternative], leave_option(story, level)]
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&if(&1[:recommended], do: 0, else: 1)),
      next: next(level, retry, fix, story),
      button: button(level, retry, fix)
    }
  end

  @doc """
  The confirmation page's question and sentence for `action` on this row, in
  the same words the row and the failure's page use for it: what the step
  does, then whether it should work now.
  """
  @spec confirmation(map(), String.t()) :: {:ok, String.t(), String.t()} | :error
  def confirmation(%{action: action} = row, action_name)
      when action in [:rearm, :retry] and is_binary(action_name) do
    if Atom.to_string(action) == action_name do
      story = story(row, DateTime.utc_now())
      {:ok, story.retry.question, story.retry.effect <> " " <> story.outlook_note}
    else
      :error
    end
  end

  def confirmation(_row, _action), do: :error

  @doc "The failure's own page."
  @spec path(map()) :: String.t()
  def path(row), do: "/failures/#{segment(row.kind)}/#{segment(row.ref)}"

  @doc "Where the recovery action's confirmation lives, when the failure has one."
  @spec action_path(map()) :: String.t() | nil
  def action_path(%{action: action} = row) when action in [:rearm, :retry],
    do: "/actions/#{segment(row.kind)}/#{segment(row.ref)}/#{action}"

  def action_path(_row), do: nil

  @doc "The request the failure belongs to: a link when it has one, words when it has none."
  @spec request(map()) :: %{text: String.t(), href: String.t()} | %{text: String.t()} | nil
  def request(%{execution_kind: :learning}), do: %{text: "Background learning"}

  def request(%{episode_ref: ref} = row) when is_binary(ref),
    do: %{text: Map.get(row, :request_title) || "Open the request", href: timeline(ref)}

  def request(%{kind: "admission", ref: ref}), do: %{text: "The message", href: timeline(ref)}
  def request(_row), do: nil

  @doc "Where it happened, in words: a channel name, a direct conversation, GitHub."
  @spec place(map()) :: String.t() | nil
  def place(row) do
    case Map.get(row, :destination) do
      "slack:" <> _ = destination ->
        destination |> String.split(" / ", parts: 2) |> hd() |> SlackNames.destination()

      "control_plane:" <> _ ->
        "Direct conversation"

      "control-plane:" <> _ ->
        "Direct conversation"

      "github:" <> _ ->
        "GitHub"

      "webhook:" <> _ ->
        "Webhook"

      _other ->
        nil
    end
  end

  @doc ~s("1 attempt", "3 attempts", or nothing when Ryker never tried.)
  @spec attempts(map()) :: String.t() | nil
  def attempts(row) do
    case Map.get(row, :attempt_count, 0) do
      count when is_integer(count) and count > 0 -> plural(count, "attempt", "attempts")
      _none -> nil
    end
  end

  @doc ~s(How long ago, short: "10 h", "3 d", "under a minute".)
  @spec age(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def age(at, now) do
    seconds = max(DateTime.diff(now, utc(at), :second), 0)

    cond do
      seconds < 60 -> "under a minute"
      seconds < 3_600 -> "#{div(seconds, 60)} min"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h"
      true -> "#{div(seconds, 86_400)} d"
    end
  end

  @doc """
  The Technical details: codes, references and allowlisted protocol facts for
  support, never the stored diagnostic itself.
  """
  @spec technical(map()) :: [map()]
  def technical(row) do
    worker = Map.get(row, :worker)

    [
      fact("Kind", kind_name(row.kind)),
      fact("Error code", error_code(row)),
      fact("Slack said", row[:provider_error]),
      fact("Worker response", http_status(row[:diagnosis])),
      fact("Stopped at", stopped_step(row)),
      identifier("Worker", worker_id(worker)),
      fact("Worker now", worker_now(worker)),
      fact("Policy", row[:policy]),
      identifier("Record", row.ref),
      identifier("Request", row[:episode_ref]),
      identifier("Source", source(row[:source])),
      identifier("Conversation", row[:destination]),
      identifier("Diagnostic reference", row[:detail]),
      fact("Stopped", exact_time(row[:updated_at]))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp fact(_label, nil), do: nil
  defp fact(label, value), do: %{label: label, value: value}

  defp identifier(_label, nil), do: nil
  defp identifier(label, value), do: %{label: label, value: to_string(value), identifier: true}

  defp source("no repository"), do: nil
  defp source(source), do: source

  defp http_status(%{http_status: status}), do: "HTTP #{status}"
  defp http_status(_diagnosis), do: nil

  defp stopped_step(%{cleanup_phase: phase}) when not is_nil(phase), do: phase_name(phase)
  defp stopped_step(%{setup_step: step}) when not is_nil(step), do: sentence(setup_step(step))
  defp stopped_step(_row), do: nil

  defp worker_id(%{id: id}), do: id
  defp worker_id(_worker), do: nil

  defp exact_time(nil), do: nil
  defp exact_time(at), do: ShortTime.full(utc(at))

  @doc "The cleanup steps and how far this cleanup got, for the Technical details."
  @spec cleanup_steps(map()) :: [map()]
  def cleanup_steps(%{kind: "retention", cleanup_phase: phase} = row) when not is_nil(phase) do
    [
      step("Close the worker session", :close_pending, phase, not is_nil(row[:closed_at])),
      step(
        "Check which files are safe to remove",
        :plan_pending,
        phase,
        phase == :discard_pending or not is_nil(row[:discarded_at])
      ),
      step("Remove the files", :discard_pending, phase, not is_nil(row[:discarded_at]))
    ]
  end

  def cleanup_steps(_row), do: []

  defp step(label, _stage, _phase, true), do: %{label: label, state: "done", status: "Done"}

  defp step(label, phase, phase, false),
    do: %{label: label, state: "stopped", status: "Stopped here"}

  defp step(label, _stage, _phase, false),
    do: %{label: label, state: "pending", status: "Not reached"}

  @doc false
  def kind_name("admission"), do: "Reading a message"
  def kind_name("delivery"), do: "Delivery"
  def kind_name("emisar"), do: "Approval watch"
  def kind_name("learning"), do: "Learning"
  def kind_name("publication"), do: "Pull request"
  def kind_name("retention"), do: "Cleanup"
  def kind_name("slack_incident"), do: "Incident room setup"
  def kind_name("slack_interaction"), do: "Slack message update"
  def kind_name("stopping"), do: "Stopping a task"
  def kind_name("work"), do: "Task"
  def kind_name(kind), do: kind |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # ---------------------------------------------------------------------------
  # Options

  defp retry_option(%{action: action} = row, %{retry: retry} = story)
       when action in [:rearm, :retry] do
    %{
      label: retry.label,
      path: action_path(row),
      effect: retry.effect,
      outlook: retry_state(story.outlook),
      note: story.outlook_note,
      recommended: story.outlook in [:ready, :unknown]
    }
  end

  defp retry_option(_row, _story), do: nil

  defp fix_option(fix, level) do
    %{
      label: fix.label,
      href: fix[:href],
      link: fix[:link],
      effect: fix.effect,
      recommended: level in [:fix_first, :stuck] or fix[:person] == true
    }
  end

  # Leaving it is the recommendation only when nothing else can help.
  defp leave_option(story, level),
    do: %{
      label: "Leave it",
      effect: story.if_left,
      recommended: level == :automatic or (level == :stuck and is_nil(story[:fix]))
    }

  defp options_lede(:ready), do: "What stopped it has cleared, so a retry should work."
  defp options_lede(:unknown), do: "Whether a retry works depends on the cause below."
  defp options_lede(:fix_first), do: "A retry fails until the problem below is fixed."
  defp options_lede(:stuck), do: "A retry would stop the same way."
  defp options_lede(:automatic), do: "Ryker is still trying on its own."

  # The row's line under its facts: what the button does, or what has to
  # change before any button would help. A person's step on another page
  # (granting learning a start where its attempts can be read) is the button.
  defp next(_level, nil, %{person: true} = fix, _story),
    do: %{lead: fix.label <> ":", text: fix.effect}

  defp next(level, retry, _fix, _story) when level in [:ready, :unknown] and not is_nil(retry),
    do: %{lead: retry.label <> ":", text: retry.effect}

  defp next(:fix_first, _retry, %{} = fix, _story),
    do: %{lead: "First:", text: fix.effect}

  defp next(:stuck, _retry, %{} = fix, _story),
    do: %{lead: "Instead:", text: fix.effect}

  defp next(:automatic, _retry, _fix, story),
    do: %{lead: "Ryker is still trying.", text: story.outlook_note}

  defp next(_level, _retry, _fix, story),
    do: %{lead: "Nothing to do here.", text: story[:nothing] || story.outlook_note}

  defp button(_level, nil, %{person: true, href: href} = fix) when is_binary(href),
    do: %{label: fix[:link] || fix.label, href: href}

  defp button(level, %{} = retry, _fix) when level in [:ready, :unknown],
    do: %{label: retry.label, path: retry.path}

  defp button(:fix_first, _retry, %{href: href} = fix) when is_binary(href),
    do: %{label: fix[:link] || fix.label, href: href}

  defp button(_level, _retry, _fix), do: nil

  defp state(:ready, _story), do: {:warn, "Retry should work"}
  defp state(:unknown, _story), do: {:warn, "Needs you"}
  defp state(:fix_first, _story), do: {:warn, "Fix needed first"}
  defp state(:stuck, %{impact: :housekeeping}), do: {:off, "Retry won't help"}
  defp state(:stuck, _story), do: {:bad, "Retry won't help"}
  defp state(:automatic, _story), do: {:busy, "Retrying on its own"}

  defp retry_state(:ready), do: {:on, "Should work"}
  defp retry_state(:unknown), do: {:warn, "Might work"}
  defp retry_state(:fix_first), do: {:warn, "Fails until fixed"}
  defp retry_state(:stuck), do: {:bad, "Will fail"}
  defp retry_state(:automatic), do: {:busy, "Ryker is retrying"}

  # ---------------------------------------------------------------------------
  # Stories: one per kind of failure.

  defp story(%{kind: "retention"} = row, now), do: retention(row, now)
  defp story(%{kind: "stopping"} = row, now), do: stopping(row, now)
  defp story(%{kind: "work"} = row, now), do: work(row, now)
  defp story(%{kind: "admission"} = row, now), do: admission(row, now)
  defp story(%{kind: "delivery", incident_room: %{}} = row, now), do: room_reply(row, now)
  defp story(%{kind: "delivery"} = row, now), do: delivery(row, now)
  defp story(%{kind: "slack_interaction"} = row, now), do: interaction(row, now)
  defp story(%{kind: "slack_incident"} = row, now), do: incident(row, now)
  defp story(%{kind: "emisar"} = row, now), do: emisar(row, now)
  defp story(%{kind: "publication"} = row, now), do: publication(row, now)
  defp story(%{kind: "learning"} = row, now), do: learning(row, now)
  defp story(row, now), do: generic(row, now)

  # A cause is {why in one sentence, the longer why, outlook, what the outlook
  # depends on} plus an optional fix.
  defp cause(short, long, outlook, note, fix \\ nil),
    do: %{short: short, long: long, outlook: outlook, note: note, fix: fix}

  # --- Cleanup ---------------------------------------------------------------

  # A session's cleanup has three steps, each on the worker that holds the
  # session: close it, ask what is safe to remove, remove it. That worker takes
  # them whatever policy version it runs now. The dispatcher retries an
  # unreachable, busy or slow worker forever (with backoff up to five minutes,
  # and at once when the worker reports again), waits the same way for a
  # worker that is away or handing the session over, ends the cleanup with a
  # receipt when the worker was removed from Ryker or no longer knows the
  # session, retries a step the worker keeps changing under it eight times,
  # and stops at the first refusal a retry cannot change. Nothing re-arms a
  # blocked cleanup but a person (Retention.Operator.rearm/3).
  defp retention(row, now) do
    thing = retained_thing(row)
    cause = retention_cause(row)

    %{
      title: retention_title(row),
      impact: :housekeeping,
      lede: "#{retention_owner(row)} #{outlook_short(cause.outlook)}",
      summary: "#{retention_owner(row)} #{cause.short}",
      happened: [retention_happened(row, thing), cause.long],
      affects: [
        retention_affects(row),
        "Until cleanup finishes, the worker may keep this session’s files on its disk."
      ],
      tried: [tried(row, now), cause[:tried] || cleanup_stop_reason()],
      if_left:
        "Nothing gets worse. Ryker will not try this cleanup again by itself, and the session’s files stay on the worker until it is cleaned up.",
      nothing:
        "A retry would stop the same way. Leaving it costs only the session’s files on the worker.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: %{
        label: "Try cleanup again",
        question: "Try cleaning up this #{thing} again?",
        effect:
          "Ryker runs the cleanup step that stopped (#{phase_step(row[:cleanup_phase])}) once more, for this #{thing} only. Nothing else changes."
      }
    }
  end

  defp retention_title(%{cleanup_phase: :close_pending}), do: "Closing a worker session stopped"

  defp retention_title(%{execution_kind: :learning}),
    do: "Cleanup after background learning stopped"

  defp retention_title(%{source: repository})
       when is_binary(repository) and repository != "no repository",
       do: "Removing a working copy of #{repository} stopped"

  defp retention_title(_row), do: "Removing a worker session’s files stopped"

  defp retained_thing(%{execution_kind: :learning}), do: "learning session"

  defp retained_thing(%{source: repository})
       when is_binary(repository) and repository != "no repository",
       do: "working copy"

  defp retained_thing(_row), do: "worker session"

  defp retention_owner(%{execution_kind: :learning}),
    do: "Nobody is waiting on it: background learning runs on its own."

  defp retention_owner(%{execution_kind: :admission}),
    do: "Nobody is waiting on it: the message was already read."

  defp retention_owner(%{request_state: :complete}),
    do: "Nobody is waiting on it: the request finished."

  defp retention_owner(%{request_state: :cancelled}),
    do: "Nobody is waiting on it: the request was stopped."

  defp retention_owner(_row), do: "The request is not held up by this."

  defp retention_affects(%{execution_kind: :learning}),
    do:
      "Nobody. Background learning runs without a requester, and this cleanup came after its work."

  defp retention_affects(%{request_state: :complete}),
    do: "Nobody. The request is complete; this is Ryker tidying up after it."

  defp retention_affects(%{request_state: :cancelled}),
    do: "Nobody. The request was stopped; this is Ryker tidying up after it."

  defp retention_affects(_row),
    do:
      "The request is not waiting on this cleanup. It only tidies up a session the request no longer uses."

  defp retention_happened(row, thing) do
    after_what =
      case row do
        %{execution_kind: :learning} -> "After background learning finished with it"
        %{request_state: :complete} -> "After the request finished"
        %{request_state: :cancelled} -> "After the request was stopped"
        _row -> "When the request no longer needed it"
      end

    "#{after_what}, Ryker began cleaning up the #{thing}: close the worker session, check which of its files are safe to remove, then remove them. It stopped at the step to #{phase_step(row[:cleanup_phase])}."
  end

  defp phase_step(:close_pending), do: "close the worker session"
  defp phase_step(:plan_pending), do: "check which files are safe to remove"
  defp phase_step(:discard_pending), do: "remove the files"
  defp phase_step(_phase), do: "clean up"

  defp phase_name(phase), do: phase |> phase_step() |> String.capitalize()

  defp cleanup_stop_reason,
    do:
      "Ryker keeps retrying cleanup on its own while a worker is offline, busy or slow to answer. It stops at once when the worker refuses for a reason a retry cannot change, so it never removes files it cannot prove belong to this session."

  defp retention_cause(%{diagnosis: %{reason: :missing_ownership}}) do
    cause(
      "Ryker cannot prove this older session’s files belong to it, so it stopped rather than risk deleting another run’s files.",
      "The worker has no record linking this run to its folder. Sessions started before that record existed cannot prove which folder is theirs, and a retry cannot create the record.",
      :stuck,
      "It will stop the same way: a retry cannot supply the missing ownership record. Leave the folder in place; freeing this space needs a cleanup fix in Coop, not a change to the request or your settings."
    )
  end

  # Placement used to refuse cleanup once the worker holding the session ran
  # another version of its policy or setup, and the dispatcher blocked it for
  # a person. Cleanup now goes to that worker whatever it runs, waits while it
  # is away and ends with a receipt once it was removed, so a retry resolves
  # every block of this kind still on the page.
  defp retention_cause(%{summary: "coop_session_replacement_required"} = row),
    do: holder_cause(Map.get(row, :worker))

  # An unreachable or slow worker no longer blocks cleanup, but cleanups that
  # stopped before that change still carry these codes; the worker's state
  # now decides them.
  defp retention_cause(%{summary: code} = row)
       when code in [
              "coop_unavailable",
              "coop_transport_error",
              "coop_worker_command_timeout",
              "coop_worker_capacity_unavailable"
            ] do
    short =
      if code == "coop_worker_command_timeout",
        do: "The worker did not take or finish the cleanup step in time.",
        else: "The worker could not be reached."

    case row[:worker] do
      %{reporting: true} = worker ->
        cause(short, short, :ready, "It should work: worker #{worker.id} is reporting again.")

      %{id: id} ->
        cause(short, short, :fix_first, "It fails until worker #{id} reports again.", %{
          label: "Bring worker #{id} back",
          href: @workers,
          link: "See workers",
          effect: "Start worker #{id} again and check that it reports, then try again."
        })

      nil ->
        cause(
          short,
          short,
          :unknown,
          "It works once the worker that holds the session reports again."
        )
    end
  end

  defp retention_cause(%{summary: "coop_session_replacement_pending"}) do
    cause(
      "A worker was still handing this session over when cleanup ran.",
      "The session’s worker was releasing it to another placement at that moment, so cleanup could not reach it.",
      :ready,
      "It should work: a handover ends within a minute, and cleanup now waits for one instead of stopping."
    )
  end

  defp retention_cause(%{summary: code} = row)
       when code in ["retention_generation_spent", "coop_mutation_response_unresolved"] do
    Map.put(
      cause(
        "The worker kept changing the session while Ryker tried to clean it up.",
        "Each time Ryker asked the worker to finish the step, the session had changed or its answer could not be confirmed.",
        :unknown,
        "It starts the step again from the session’s current state. It should work if the worker has settled; if it stops again, the worker needs checking."
      ),
      :tried,
      "Ryker tried #{attempt_words(row)}, the most it tries on its own for this, and then stopped so it would not keep acting on a session it could not pin down."
    )
  end

  defp retention_cause(%{diagnosis: %{code: "session_not_found"}}) do
    cause(
      "The worker no longer knows this session.",
      "The worker answered that it has no session with this identity, so there is nothing Ryker can ask it to close or remove.",
      :ready,
      "It should work: Ryker now records a session its worker no longer knows as already gone instead of stopping on it. Any files left behind are the worker’s to remove."
    )
  end

  defp retention_cause(%{diagnosis: %{code: code}}) when is_binary(code) do
    cause(
      "The worker refused this cleanup step (#{words(code)}).",
      "The worker refused the step with “#{words(code)}”. Ryker keeps the session as it is rather than guess what the worker meant.",
      :unknown,
      "It works only if what the worker objected to has changed since. If it stops again, check the session on the worker."
    )
  end

  defp retention_cause(%{summary: "coop_protocol_error"}) do
    cause(
      "The worker’s answer did not match this session, so Ryker stopped rather than risk removing the wrong files.",
      "The worker answered about a session whose identity, owner or state did not match what Ryker recorded for this one.",
      :unknown,
      "It works only if the session has since settled on the worker. If it stops again, check the session on the worker."
    )
  end

  defp retention_cause(_row) do
    cause(
      "Cleanup stopped before Ryker could confirm it finished.",
      "The saved error does not name a cause Ryker recognises. The Technical details keep its code.",
      :unknown,
      "Whether it works depends on the cause, which the saved error does not name."
    )
  end

  defp holder_cause(%{enrolled: false} = worker) do
    cause(
      "Its worker #{worker.id} was removed from Ryker, so nothing Ryker can reach is left to clean up.",
      "Only the worker that holds a session can close or remove it, and worker #{worker.id} is no longer enrolled: its certificates and placements were revoked for good.",
      :ready,
      "It should work: Ryker records the session as unreachable and stops tracking it. Anything still on worker #{worker.id} is outside Ryker’s reach."
    )
  end

  defp holder_cause(%{id: id}) do
    cause(
      "Its worker #{id} still holds this session, and cleanup no longer needs the policy version it started with.",
      "When this stopped, Ryker cleaned up a session only under the exact policy version and setup it started with, and worker #{id} had moved on. Closing and removing a session do no policy work, so cleanup now goes to the worker that holds it whatever that worker runs.",
      :ready,
      "It should work: Ryker sends the cleanup to worker #{id}, and waits for it if it is away."
    )
  end

  defp holder_cause(nil) do
    cause(
      "The worker that held this session could not take it back then.",
      "Ryker has no record of which worker held this session.",
      :unknown,
      "It works if the worker that holds this session reports; Ryker waits for it instead of stopping again."
    )
  end

  # --- Stopping a task -------------------------------------------------------

  # A stop settles only on its worker's answer that the run stopped, or on
  # that worker's removal from Ryker, so it retries on its own without end (one
  # second doubling to a minute). One still unconfirmed after
  # Work.Cancellation.stalled_after_attempts/0 attempts is listed here. It has
  # no retry of its own; what a person can change is the worker.
  defp stopping(row, now) do
    cause = stopping_cause(row, now)

    %{
      title: stopping_title(row),
      impact: :people,
      lede: "#{stopping_affected(row)} #{outlook_short(cause.outlook)}",
      summary: "#{stopping_affected(row)} #{cause.short}",
      happened: [stopping_happened(row), cause.long],
      affects: [stopping_affects(row)],
      tried: [
        tried(row, now),
        "Ryker keeps trying on its own, once a minute. It never counts a run as stopped without its worker’s answer, unless that worker was removed from Ryker."
      ],
      if_left:
        "Ryker keeps trying. The stop finishes by itself as soon as the worker answers, or once the worker is removed from Ryker.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix
    }
  end

  defp stopping_title(%{stop_intent: "transfer"}),
    do: "A new message is waiting for the last run to stop"

  defp stopping_title(%{stop_intent: "cancel"}),
    do: "Closing a request is waiting for its run to stop"

  defp stopping_title(_row), do: "Stopping a task is waiting for its worker"

  defp stopping_affected(%{stop_intent: "transfer"}),
    do: "The newest message waits until the last run stops."

  defp stopping_affected(%{stop_intent: "cancel"}),
    do: "The request stays open until its run stops."

  defp stopping_affected(_row), do: "The task cannot run again until its run stops."

  defp stopping_happened(row) do
    asked =
      case row[:stop_intent] do
        "transfer" ->
          "A new message arrived while a run was still working on this request, so Ryker asked that run’s worker to stop it first."

        "cancel" ->
          "The request was closed while a run was still working on it, so Ryker asked that run’s worker to stop it."

        _block ->
          "Ryker was asked to stop the run working on this request."
      end

    asked <>
      " A run counts as stopped only when its worker says so, and that answer has not come."
  end

  defp stopping_affects(%{stop_intent: "transfer"}),
    do:
      "The person who wrote the newest message has no answer yet: Ryker takes it up only after the last run stops."

  defp stopping_affects(%{stop_intent: "cancel"}),
    do: "The request stays open, and its run may still be using the worker."

  defp stopping_affects(_row),
    do:
      "The person who asked has no answer, and the task cannot be run again until its run stops."

  defp stopping_cause(%{worker: %{enrolled: false} = worker}, _now) do
    cause(
      "Its worker #{worker.id} was removed from Ryker, so nothing that run does can reach Ryker any more.",
      "A removed worker’s certificates and placements are revoked for good, and the run’s access to Ryker went with them.",
      :automatic,
      "Ryker records the stop on its next attempt, within a minute."
    )
  end

  defp stopping_cause(%{worker: %{id: id} = worker} = row, now) do
    if holder_reporting?(worker, now) do
      cause(
        "Its worker #{id} is reporting but has not confirmed the run stopped.",
        "Each attempt ended with “#{words(row.summary)}”. The Technical details keep the code.",
        :automatic,
        "Ryker keeps asking worker #{id}; the stop finishes as soon as it answers."
      )
    else
      cause(
        "Its worker #{id} is not reporting, and only that worker can confirm the run stopped.",
        "Worker #{id} holds this run and has not reported#{seen(worker)}.",
        :fix_first,
        "It finishes once worker #{id} reports again, or once it is removed from Ryker.",
        %{
          label: "Bring worker #{id} back",
          href: @workers,
          link: "See workers",
          effect:
            "Start worker #{id} again; once it reports, Ryker stops the run and carries on by itself. If worker #{id} is gone for good, remove it from Ryker and the stop finishes by itself."
        }
      )
    end
  end

  defp stopping_cause(_row, _now) do
    cause(
      "Its worker has not confirmed the run stopped.",
      "Ryker has no record of which worker holds this run.",
      :automatic,
      "Ryker keeps trying on its own."
    )
  end

  # A draining worker still takes the stops for the runs it holds.
  defp holder_reporting?(%{reporting: true}, _now), do: true

  defp holder_reporting?(%{draining: true, last_seen_at: at}, now) when not is_nil(at),
    do: DateTime.diff(now, utc(at), :second) <= 60

  defp holder_reporting?(_worker, _now), do: false

  # Placement decides whether a worker takes a session back, under a lock; the
  # projection read the same facts so the page can say it first.
  defp replacement_cause(nil, _row, _verb) do
    cause(
      "The worker that held this session can no longer take it back.",
      "Only the worker that holds a session can work on it, and Ryker has no record of which worker that was.",
      :stuck,
      "It will stop the same way: no worker holds this session."
    )
  end

  defp replacement_cause(%{enrolled: false} = worker, _row, verb) do
    cause(
      "The worker that held this session was removed from Ryker.",
      "Only the worker that holds a session can #{verb}. Worker #{worker.id} held this one and is no longer enrolled.",
      :stuck,
      "It will stop the same way: worker #{worker.id} is gone."
    )
  end

  defp replacement_cause(%{policy_offered: false} = worker, row, verb) do
    policy = policy_name(row)

    cause(
      "Its worker no longer offers the #{policy} policy, so it cannot take the session back.",
      "Only the worker that holds a session can #{verb}, and only under the policy the session runs under. Worker #{worker.id} no longer offers #{policy}.",
      :stuck,
      "It will stop the same way unless worker #{worker.id} offers #{policy} again."
    )
  end

  defp replacement_cause(%{policy_current: false} = worker, row, verb) do
    policy = policy_name(row)

    cause(
      "Its worker now runs a newer version of the #{policy} policy, and only the version the session started with can #{verb}.",
      "The session is still on worker #{worker.id}. Since it started, that worker was updated to a newer version of the #{policy} policy. A session is only ever handled under the exact policy version it started with, so the worker cannot take it back.",
      :stuck,
      "It will stop the same way unless a worker runs the exact #{policy} version this session started with."
    )
  end

  defp replacement_cause(%{setup_current: false} = worker, _row, _verb) do
    cause(
      "Its worker’s setup changed since the session started, so it cannot take the session back.",
      "The session is still on worker #{worker.id}, but the worker’s sandbox, permissions or repositories changed since it started. A session is only handled under the setup it started with.",
      :stuck,
      "It will stop the same way unless worker #{worker.id} gets its earlier setup back."
    )
  end

  defp replacement_cause(%{draining: true} = worker, _row, verb) do
    cause(
      "Its worker #{worker.id} is being drained and takes no work back.",
      "Only the worker that holds a session can #{verb}. Worker #{worker.id} holds this one and is draining: it finishes what it runs and accepts nothing new.",
      :fix_first,
      "It fails while worker #{worker.id} is draining.",
      %{
        label: "Let worker #{worker.id} take work again",
        href: @workers,
        link: "See workers",
        effect: "End the drain on worker #{worker.id}, then try again."
      }
    )
  end

  defp replacement_cause(%{reporting: false} = worker, _row, verb) do
    cause(
      "Its worker #{worker.id} is not reporting, and only that worker can take the session back.",
      "Only the worker that holds a session can #{verb}. Worker #{worker.id} holds this one and has not reported#{seen(worker)}.",
      :fix_first,
      "It fails until worker #{worker.id} reports again. Then it should work.",
      %{
        label: "Bring worker #{worker.id} back",
        href: @workers,
        link: "See workers",
        effect: "Start worker #{worker.id} again and check that it reports, then try again."
      }
    )
  end

  defp replacement_cause(%{free_slot: false} = worker, _row, verb) do
    cause(
      "Its worker #{worker.id} was full.",
      "Only the worker that holds a session can #{verb}, and worker #{worker.id} had no free slot for it.",
      :unknown,
      "It should work once worker #{worker.id} has a free slot. It is still full now."
    )
  end

  defp replacement_cause(worker, _row, verb) do
    cause(
      "Its worker could not take the session back then, but it can now.",
      "Only the worker that holds a session can #{verb}. When Ryker tried, worker #{worker.id} could not take it back; it is reporting now and still runs this session’s exact policy.",
      :ready,
      "It should work: worker #{worker.id} is reporting and still runs this session’s exact policy version."
    )
  end

  # --- Tasks -----------------------------------------------------------------

  # A task retries a worker that is unreachable, slow or failing with a server
  # error up to eight times (1 s doubling to 60 s, about two minutes), and stops
  # at once for anything a retry cannot change. Saving a finished result never
  # retries on its own. A reply in the thread restarts a stopped task, and
  # nothing expires: the request stays open until someone acts.
  defp work(row, now) do
    brief = Map.get(row, :work_recovery) || %{}
    cause = work_cause(row, brief)
    completion = brief[:kind] == :completion

    retry = %{
      label: brief[:action_label] || "Run the task again",
      question: work_question(brief),
      effect: brief[:retry_effect] || "Ryker runs the task again."
    }

    %{
      title: work_title(row, brief),
      impact: :people,
      lede: "#{work_affected(brief)} #{outlook_short(cause.outlook)}",
      summary: "#{work_affected(brief)} #{cause.short}",
      happened: Enum.reject([work_happened(row, brief), cause.long], &is_nil/1),
      affects:
        Enum.reject(
          [work_affects(brief), if(brief[:not_started], do: brief[:workspace])],
          &is_nil/1
        ),
      tried: [tried(row, now), work_tried(row, brief)],
      if_left: work_left(row, brief),
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: retry,
      # Closing belongs to the request's own page, which confirms it against
      # the request's current owner.
      alternative:
        if(is_binary(row[:episode_ref]) and not completion and not paused?(row),
          do: %{
            label: "Close the request",
            href: timeline(row.episode_ref),
            link: "Open the request",
            effect:
              "If the task is no longer needed, “Close as no longer needed” on the request’s page closes it. Nothing is deleted and nothing is sent to the person who asked."
          }
        )
    }
  end

  # A task paused for its incident room resumes on its own when the room is
  # active again, or is closed by Ryker when the room was deleted, so the row
  # offers no close of its own.
  defp paused?(%{stop_code: "destination_paused" <> _}), do: true
  defp paused?(_row), do: false

  defp work_title(_row, %{not_started: true}), do: "Code changes could not start"
  defp work_title(_row, %{kind: :completion}), do: "Saving a finished task stopped"

  defp work_title(_row, %{action: nil, model_output: output}) when is_binary(output),
    do: "Saving a finished task’s changes stopped"

  defp work_title(_row, %{action: nil, setup_href: href}) when is_binary(href),
    do: "Task could not make repository changes"

  defp work_title(%{stop_code: "operator_stop"}, _brief), do: "Task stopped by a person"

  # Slack deletes a channel for good: a task paused for a deleted room never
  # resumes, and Ryker closes its request the way Close request does.
  defp work_title(
         %{stop_code: "destination_paused" <> _, paused_room: %{channel_state: :deleted}},
         _brief
       ),
       do: "Task closing: its incident room was deleted"

  defp work_title(%{stop_code: "destination_paused" <> _}, _brief),
    do: "Task paused while its room is closed"

  defp work_title(_row, _brief), do: "Task stopped before it finished"

  defp work_question(%{not_started: true}), do: "Start this task?"
  defp work_question(%{kind: :completion}), do: "Finish saving this task’s result?"

  defp work_question(%{resume: resume}) when is_map(resume),
    do: "Continue this task on another worker?"

  defp work_question(_brief), do: "Run this task again?"

  defp work_affected(%{kind: :completion}),
    do: "The work is done, but the answer has not been sent."

  defp work_affected(_brief), do: "The person who asked has no answer yet."

  defp work_affects(%{kind: :completion}),
    do:
      "The person who asked is waiting for an answer the worker already wrote. It stays saved, unsent, until the result is saved."

  defp work_affects(_brief),
    do:
      "The person who asked has no answer yet, and nothing was posted to say the task stopped. The request stays open."

  defp work_happened(%{stop_code: "operator_stop"}, _brief),
    do: "Someone pressed Stop on this task while it was running."

  defp work_happened(_row, %{kind: :completion}),
    do:
      "The worker finished the task and wrote its answer. Ryker then began saving the result, and that stopped."

  defp work_happened(_row, %{not_started: true}),
    do: "Ryker could not start the approved code changes, so no files changed and no checks ran."

  # The recovery brief's own headline names the failure more exactly than a
  # generic sentence, except for its own generic one.
  defp work_happened(_row, %{headline: headline})
       when is_binary(headline) and headline != "The task stopped before it could finish",
       do: headline <> "."

  defp work_happened(_row, _brief), do: "The task stopped before the worker finished it."

  defp work_tried(_row, %{kind: :completion}),
    do:
      "Ryker does not retry saving a finished result on its own: it stops at the first failure so finished work is never redone or lost."

  defp work_tried(%{stop_code: "work_retry_exhausted" <> _}, _brief),
    do:
      "Ryker retried eight times over about two minutes, the most it tries on its own, and then stopped. A reply in the thread also starts the task again."

  defp work_tried(%{stop_code: "operator_stop"}, _brief),
    do:
      "Ryker does not restart a task someone stopped. A reply in the thread, or the button below, starts it again."

  defp work_tried(
         %{stop_code: "destination_paused" <> _, paused_room: %{channel_state: :deleted}},
         _brief
       ),
       do:
         "Ryker closes the request on its own, the way Close request does, and says so in the alert thread the room was opened from."

  defp work_tried(%{stop_code: "destination_paused" <> _}, _brief),
    do: "Ryker resumes it on its own when the incident room is active again."

  defp work_tried(_row, _brief),
    do:
      "Ryker retries a worker that is unreachable or slow up to eight times. It stopped at once here because a retry could not change the cause. A reply in the thread also starts the task again."

  defp work_left(_row, %{kind: :completion}),
    do:
      "The finished answer stays saved but unsent, the worker keeps the session open, and the request stays open. Ryker will not retry on its own."

  defp work_left(
         %{stop_code: "destination_paused" <> _, paused_room: %{channel_state: :deleted}},
         _brief
       ),
       do: "Ryker closes the request on its own and tells the alert thread. Its history stays."

  defp work_left(%{stop_code: "destination_paused" <> _}, _brief),
    do: "Ryker resumes the task when the incident room is active again."

  defp work_left(_row, _brief),
    do:
      "The request stays open and the person gets no answer. Ryker will not retry on its own, but a new reply in the thread starts the task again. The worker keeps the stopped run’s files until the request ends."

  defp work_cause(_row, %{not_started: true, action: nil} = brief) do
    cause(
      "The code-editing setup cannot save a recoverable copy of the work.",
      brief[:cause],
      :fix_first,
      "It fails until the code-editing setup can save work.",
      setup_fix(brief)
    )
  end

  defp work_cause(_row, %{not_started: true} = brief) do
    cause(
      "The code-editing setup could not save a recoverable copy of the work then.",
      brief[:cause],
      :unknown,
      "The connection can save work now, so it should work if a compatible coding worker is available."
    )
  end

  defp work_cause(_row, %{action: nil, setup_href: href} = brief) when is_binary(href) do
    cause(
      "The worker connection cannot save the working copy.",
      brief[:cause],
      :fix_first,
      "It fails until the code-editing setup can save work.",
      setup_fix(brief)
    )
  end

  defp work_cause(_row, %{action: nil} = brief) do
    cause(
      "The finished changes exist only in a closed working copy, so a retry cannot pick them up.",
      Enum.join(Enum.reject([brief[:cause], brief[:next_step]], &is_nil/1), " "),
      :stuck,
      "A retry would start over from the repository and lose the finished changes. Preserve the working copy first."
    )
  end

  defp work_cause(row, %{kind: :completion} = brief) do
    case row[:summary] do
      "coop_session_replacement_required" ->
        replacement_cause(Map.get(row, :worker), row, "save the result")

      code
      when code in ["coop_unavailable", "coop_transport_error", "coop_worker_command_timeout"] ->
        session_worker_cause(row, brief[:cause] || "The worker connection failed while saving.")

      _other ->
        cause(
          brief[:cause] || "Saving the finished result stopped.",
          brief[:next_step],
          :unknown,
          "It works if what stopped the saving has been fixed. The model does not run again either way."
        )
    end
  end

  defp work_cause(%{stop_code: "operator_stop"}, _brief) do
    cause(
      "Someone pressed Stop on it.",
      nil,
      :ready,
      "It should work: nothing is broken, the task was stopped on purpose."
    )
  end

  defp work_cause(
         %{stop_code: "destination_paused" <> _, paused_room: %{channel_state: :deleted}},
         _brief
       ) do
    cause(
      "Its incident room was deleted in Slack, so the task can never resume there.",
      "The task posts into an incident room, and Slack deletes a channel for good.",
      :automatic,
      "Ryker closes the request on its own; nothing here needs doing."
    )
  end

  defp work_cause(%{stop_code: "destination_paused" <> _}, _brief) do
    cause(
      "Its incident room is archived or Ryker left it, so the task waits.",
      "The task posts into an incident room that is not active right now.",
      :automatic,
      "It resumes on its own when the room is active again."
    )
  end

  # A worker that could not be reached, answered too slowly or failed with a
  # server error is a question of whether a worker reports now; a refusal the
  # worker named is not, whatever the fleet looks like.
  defp work_cause(%{stop_code: "work_retry_exhausted:" <> inner} = row, _brief)
       when inner in [
              "coop_unavailable",
              "coop_transport_error",
              "coop_worker_command_timeout",
              "coop_error"
            ] do
    {short, long} =
      case inner do
        "coop_worker_command_timeout" ->
          {"The worker did not take or finish its commands in time.",
           "Each time Ryker gave the worker the task’s next step, the worker did not pick it up or finish it in time."}

        "coop_error" ->
          {"The worker kept failing with a server error.",
           "Each time Ryker asked the worker for the task’s next step, the worker answered with a server error."}

        _unreachable ->
          {"The worker could not be reached.",
           "Each time Ryker asked the worker for the task’s next step, it could not reach the worker or confirm what it did."}
      end

    fleet_cause(row, short, long)
  end

  defp work_cause(%{stop_code: "coop_worker_capacity_unavailable"} = row, _brief) do
    fleet_cause(
      row,
      "No worker was free to take it, so it never started on one.",
      "No reporting worker offered this task’s policy with a free slot when Ryker tried."
    )
  end

  defp work_cause(row, brief) do
    explained = brief[:explained] && brief[:cause]

    cause(
      explained || stop_words(row[:stop_code]),
      if(explained, do: brief[:next_step], else: brief[:cause]),
      :unknown,
      work_depends(row, brief)
    )
  end

  defp work_depends(%{stop_code: "work_turn_terminal"}, %{explained: true, cause: cause})
       when is_binary(cause) do
    if String.contains?(cause, "sign-in"),
      do:
        "It works once the worker is signed in to its model account again. Ryker cannot see that from here.",
      else: "It works if the condition the worker named has been corrected."
  end

  defp work_depends(_row, %{explained: true}),
    do: "It works if the condition named above has been corrected."

  defp work_depends(_row, _brief),
    do: "Whether it works depends on the cause, which the saved error does not name."

  defp stop_words("work_turn_terminal"),
    do: "The worker ended the task early: it failed, was cancelled or ran out of budget."

  defp stop_words("coop_protocol_error"),
    do: "The worker’s answer did not match what Ryker recorded for this task."

  defp stop_words("coop_worker_storage_refused"),
    do: "The worker refused new work because its disk is full."

  defp stop_words("coop_session_replacement_pending"),
    do: "The worker was handing the task’s session over when it ran."

  defp stop_words("coop_workspace_checkpoint_required"),
    do: "No saved copy of the working files was available to continue from."

  defp stop_words(_code), do: "The task stopped before Ryker could confirm why."

  defp setup_fix(brief),
    do: %{
      label: "Fix the code-editing setup",
      href: brief[:setup_href] || "/settings/advanced#code-editing",
      link: "Open code-editing setup",
      effect: brief[:next_step] || "Connect a worker that can save working copies, then retry."
    }

  # Whether any worker is reporting decides a retry for a task that stopped
  # because no worker answered.
  defp fleet_cause(row, short, long) do
    case row[:fleet] do
      %{reporting: count} when is_integer(count) and count > 0 ->
        cause(
          short,
          long,
          :ready,
          "It should work: #{plural(count, "worker is", "workers are")} reporting now."
        )

      %{reporting: 0} ->
        cause(short, long, :fix_first, "It fails until a worker reports again.", %{
          label: "Bring a worker back",
          href: @workers,
          link: "See workers",
          effect:
            "No worker is reporting right now. Start one and check that it reports, then try again."
        })

      _unknown ->
        cause(short, long, :unknown, "It works once a worker is reporting and free.")
    end
  end

  defp session_worker_cause(row, short) do
    case row[:worker] do
      %{reporting: true} = worker ->
        cause(
          short,
          nil,
          :ready,
          "It should work: worker #{worker.id}, which holds the finished work, is reporting."
        )

      %{id: id} ->
        cause(short, nil, :fix_first, "It fails until worker #{id} reports again.", %{
          label: "Bring worker #{id} back",
          href: @workers,
          link: "See workers",
          effect:
            "Worker #{id} holds the finished work. Start it again and check that it reports, then try again."
        })

      nil ->
        cause(
          short,
          nil,
          :unknown,
          "It works once the worker that holds the finished work reports."
        )
    end
  end

  # --- Reading a message -----------------------------------------------------

  # Reading a message runs a short routing turn on a worker. Ryker retries
  # failures that might pass up to eight times (1 s doubling to 60 s), holding
  # later messages in the channel behind it meanwhile, then blocks so they can
  # go ahead. A run the worker stopped is one of them: each retry reads the
  # message again with a fresh run. A failed model run, or an answer that
  # cannot be confirmed, blocks at once. Nothing expires.

  defp admission(row, now) do
    cause = admission_cause(row)

    %{
      title: "Reading a message stopped",
      impact: :people,
      lede: "The person who wrote it has no answer. #{outlook_short(cause.outlook)}",
      summary: "The person who wrote it has no answer. #{cause.short}",
      happened: [
        "A new message arrived#{place_words(row)}. Ryker began deciding how to respond to it, whether to reply, react or start a task, and stopped before it decided.",
        cause.long
      ],
      affects: [
        "The person who wrote the message has had no reply and no reaction. In Slack, Ryker’s “thinking” status simply went away.",
        "Later messages in the same channel are not held up by it."
      ],
      tried: [tried(row, now), cause[:tried] || admission_tried(row)],
      if_left:
        "The message stays unanswered. Nothing expires and Ryker will not retry it by itself. The worker may keep the short session it used for it.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: admission_retry(row, now)
    }
  end

  defp admission_retry(row, now),
    do: %{
      label: "Read the message again",
      question: "Read this message again?",
      effect:
        "Ryker decides again how to respond to the same message: it picks up the same run if the worker still has it, or decides afresh from the conversation as it is now. Any reply goes to the original thread, however late#{late(row, now)}. While it runs, newer messages in the channel wait behind it."
    }

  defp admission_tried(%{summary: "coop_turn_stopped"}),
    do:
      "Ryker read it again with a fresh run eight times over about two minutes, holding newer messages in the channel behind this one. The worker stopped every run, so Ryker stopped so they could go ahead."

  defp admission_tried(%{summary: code})
       when code in [
              "coop_unavailable",
              "coop_transport_error",
              "coop_worker_command_timeout",
              "coop_worker_capacity_unavailable",
              "context_stale",
              "admission_rejected"
            ],
       do:
         "Ryker retried eight times over about two minutes, holding newer messages in the channel behind this one, then stopped so they could go ahead."

  defp admission_tried(_row),
    do:
      "Ryker stopped at once: a retry could not change the cause, and waiting would have held up newer messages in the channel."

  # Every run reading it was stopped on the worker through the whole retry
  # budget. Why is on the worker; a retry starts one more fresh run.
  defp admission_cause(%{summary: "coop_turn_stopped"}) do
    cause(
      "The worker kept stopping the runs reading it.",
      "Each run reading this message was cancelled, interrupted or ran out of budget on the worker before it decided how to respond.",
      :unknown,
      "It works if the worker lets a run finish now. If it stops the same way, something on the worker is cancelling or restarting its runs, or their budget is too small."
    )
  end

  defp admission_cause(%{summary: code})
       when code in ["coop_operation_uncertain", "coop_error", "operation_uncertain"] do
    cause(
      "The worker could not confirm whether its run had finished.",
      "Ryker asked the worker for the result of the run reading this message, and the worker could not say for certain what happened.",
      :unknown,
      "It works once the worker has settled that run. If it stops the same way, ask the person to post again."
    )
  end

  defp admission_cause(%{summary: code})
       when code in ["coop_protocol_error", "admission_execution_failed"] do
    cause(
      "The worker’s answer did not match the run Ryker recorded.",
      "The decision the worker returned did not match the run Ryker started for this message, so Ryker did not act on it.",
      :unknown,
      "It works if the worker’s state has settled. If it stops the same way, ask the person to post again."
    )
  end

  defp admission_cause(%{summary: code} = row)
       when code in [
              "coop_unavailable",
              "coop_transport_error",
              "coop_worker_command_timeout",
              "coop_worker_capacity_unavailable"
            ] do
    fleet_cause(
      row,
      "No worker could take it.",
      "Reading a message runs on a worker, and none could take it when Ryker tried."
    )
  end

  defp admission_cause(%{summary: code}) when code in ["context_stale", "admission_rejected"] do
    cause(
      "The conversation changed while Ryker was deciding.",
      "New activity in the conversation made the decision out of date before Ryker could act on it.",
      :ready,
      "It should work: a retry decides again from the conversation as it is now."
    )
  end

  defp admission_cause(%{cause: cause}) when is_binary(cause) do
    cause(
      cause,
      "The model run that reads the message failed, and the worker had already tried its fallbacks.",
      :unknown,
      if(String.contains?(cause, "sign-in"),
        do:
          "It works once the worker is signed in to its model account again. Ryker cannot see that from here.",
        else: "It works if the condition named above has been corrected."
      )
    )
  end

  defp admission_cause(_row) do
    cause(
      "It stopped before Ryker could confirm why.",
      "The saved error does not name a cause Ryker recognises. The Technical details keep its code.",
      :unknown,
      "Whether it works depends on the cause, which the saved error does not name."
    )
  end

  # --- Delivery --------------------------------------------------------------

  # Delivery retries Slack or network trouble up to eight times (1 s doubling
  # to 60 s) and stops at once when Slack refuses in a way a retry cannot
  # change. A retry sends the same saved content; it searches the thread
  # first, so a reply never appears twice. Nothing expires.
  defp delivery(row, now) do
    kind = Map.get(row, :delivery_kind) || delivery_kind(row)
    cause = slack_cause(row, delivery_code_cause(row))
    parts = delivery_parts(kind)

    %{
      title: parts.title,
      impact: :people,
      lede: "#{parts.affected} #{outlook_short(cause.outlook)}",
      summary: "#{parts.affected} #{cause.short}",
      happened: [parts.happened <> place_words(row) <> ".", cause.long],
      affects: parts.affects,
      tried: [
        tried(row, now),
        "Ryker retries Slack or network trouble up to eight times over about two minutes, and stops at once when Slack refuses in a way a retry cannot change."
      ],
      if_left: parts.left,
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: %{
        label: parts.label,
        question: parts.question,
        effect: parts.effect <> late_sentence(row, now, kind)
      }
    }
  end

  defp delivery_kind(%{source: "reaction delivery"}), do: :reaction
  defp delivery_kind(%{source: "platform_action delivery"}), do: :platform_action
  defp delivery_kind(_row), do: :message

  defp delivery_parts(:reaction),
    do: %{
      title: "Adding a reaction stopped",
      affected: "The person got no acknowledgement.",
      happened:
        "Ryker decided to acknowledge a message with a reaction instead of a reply, and adding the reaction stopped",
      affects: [
        "The person who wrote the message saw no reply and no reaction. Nothing else is waiting on it."
      ],
      left: "The reaction is never added. Nothing else is affected.",
      label: "Add the reaction again",
      question: "Add this reaction again?",
      effect:
        "Ryker adds the same reaction to the same message. Slack ignores it if the reaction is already there."
    }

  defp delivery_parts(:platform_action),
    do: %{
      title: "A step the task asked for stopped",
      affected: "A message or reaction the task asked for did not happen.",
      happened:
        "While working, the task asked Ryker to post a message or add a reaction, and that stopped",
      affects: [
        "The step never happened. The task itself carried on and knows the step did not go through."
      ],
      left: "The step never happens. The task has already moved on without it.",
      label: "Do the step again",
      question: "Do this step again?",
      effect:
        "Ryker performs the same saved step, a message or a reaction, once more at the same place. The model does not run again."
    }

  defp delivery_parts(_message),
    do: %{
      title: "Posting a reply stopped",
      affected: "The reply is written, but the person has not received it.",
      happened: "The reply was written and saved, and posting it stopped",
      affects: [
        "The person who asked has not received the reply. In Slack the thread still says Ryker is preparing a response.",
        "The request stays open, and new messages in it wait behind this reply."
      ],
      left:
        "The reply is never posted. The request stays open, Slack keeps showing that Ryker is preparing a response, and new messages in the request keep waiting.",
      label: "Post the reply again",
      question: "Post this reply again?",
      effect:
        "Ryker posts the same saved reply to the same thread. The model does not run again, and Ryker checks the thread first, so the reply never appears twice."
    }

  defp delivery_code_cause(%{summary: code}) do
    case code do
      "delivery_rate_limited" ->
        {"Slack kept asking Ryker to slow down.", :unknown,
         "It usually works once Slack stops limiting Ryker, within minutes."}

      "delivery_uncertain" ->
        {"Slack did not confirm the post.", :unknown,
         "It should work if Slack is answering normally. Ryker checks the thread first, so it never posts twice."}

      "delivery_transport_unavailable" ->
        {"Ryker could not reach Slack.", :unknown, "It works once Ryker can reach Slack again."}

      "delivery_credentials_unavailable" ->
        {"Ryker had no Slack sign-in to post with.", :auth, nil}

      "slack_reconciliation_incomplete" ->
        {"The thread is too long for Ryker to check for an earlier copy, so it did not post, to avoid posting twice.",
         :stuck,
         "It will stop the same way: the thread is still too long to check. Answer in the thread yourself if the reply still matters."}

      "slack_incident_room_inactive" ->
        {"The incident room it posts to is archived, or Ryker was removed from it.", :fix_first,
         "It fails until the room is active and Ryker is in it again."}

      code when code in ["slack_workspace_not_configured", "delivery_adapter_not_configured"] ->
        {"Slack is not set up for this workspace.", :auth, nil}

      _other ->
        {"Slack refused the post, or the saved reply did not pass a check.", :unknown,
         "Whether it works depends on the cause. The Technical details keep the saved code."}
    end
  end

  # --- Slack words shared by replies, message updates and incident rooms -----

  @auth_errors ~w(invalid_auth token_revoked token_expired account_inactive not_authed)
  @gone_errors ~w(message_not_found thread_not_found cant_update_message edit_window_closed channel_not_found)
  @policy_errors ~w(restricted_action no_permission team_access_not_granted ekm_access_denied)
  @busy_errors ~w(ratelimited fatal_error internal_error request_timeout service_unavailable)

  # Slack's own refusal decides the cause when the saved error carries one;
  # otherwise the kind's own reading of its code does. Each ends in whether a
  # retry should work now, read from what changed since.
  defp slack_cause(row, fallback),
    do: slack_refusal(row[:provider_error], row, Map.get(row, :slack) || %{}, fallback)

  defp slack_refusal("not_in_channel", row, slack, _fallback), do: not_in_channel(row, slack)

  defp slack_refusal(code, row, slack, _fallback) when code in @auth_errors,
    do: slack_auth(row, slack, "Slack no longer accepts Ryker’s sign-in (#{words(code)}).")

  defp slack_refusal("missing_scope", row, slack, _fallback),
    do:
      slack_auth(
        row,
        slack,
        "Ryker’s Slack app is missing a permission it needs for this.",
        "Reinstall the Slack app with the permissions Ryker asks for"
      )

  defp slack_refusal("is_archived", row, _slack, _fallback) do
    cause(
      "The channel is archived.",
      "Slack refused because the channel was archived.",
      :fix_first,
      "It fails until the channel is unarchived.",
      %{
        label: "Unarchive the channel",
        effect: "Unarchive #{place(row) || "the channel"} in Slack, then try again.",
        href: slack_url(row),
        link: "Open in Slack"
      }
    )
  end

  defp slack_refusal(code, _row, _slack, _fallback) when code in @gone_errors do
    cause(
      "The channel, thread or message it belongs to was deleted.",
      "Slack answered that the #{gone_thing(code)} no longer exists.",
      :stuck,
      "It will stop the same way: what it belongs to is gone. Answer the person another way if it still matters."
    )
  end

  defp slack_refusal(code, _row, _slack, _fallback) when code in @policy_errors do
    cause(
      "A Slack workspace setting stops Ryker from doing this there.",
      "Slack refused with “#{words(code)}”: the workspace’s settings do not allow it.",
      :fix_first,
      "It fails until a Slack admin allows it.",
      %{
        label: "Ask a Slack admin to allow it",
        effect: "A Slack workspace admin has to allow Ryker to post there, then try again."
      }
    )
  end

  defp slack_refusal(code, _row, _slack, _fallback) when code in @busy_errors do
    cause(
      "Slack kept failing or asking Ryker to slow down.",
      "Slack answered “#{words(code)}” every time Ryker tried.",
      :unknown,
      "It usually works once Slack answers normally again, within minutes."
    )
  end

  defp slack_refusal(_none, row, slack, fallback), do: from_code(row, slack, fallback)

  defp from_code(row, slack, {short, :auth, _note}), do: slack_auth(row, slack, short)

  defp from_code(row, _slack, {short, :fix_first, note}) do
    cause(short, short, :fix_first, note, %{
      label: "Make the room active again",
      effect: "Unarchive the room’s channel in Slack or invite Ryker back, then try again.",
      href: slack_url(row),
      link: "Open in Slack"
    })
  end

  defp from_code(_row, _slack, {short, outlook, note}), do: cause(short, short, outlook, note)

  defp not_in_channel(row, slack) do
    where = place(row) || "the channel"

    if slack[:membership] == :joined do
      cause(
        "Ryker was not in #{where}, but it is again now.",
        "Slack refused because Ryker was not a member of #{where}. It has been added back since.",
        :ready,
        "It should work: Ryker is in #{where} again."
      )
    else
      cause(
        "Ryker is not in #{where}.",
        "Slack refused because Ryker is not a member of #{where}.",
        :fix_first,
        "It fails until Ryker is in #{where} again.",
        %{
          label: "Invite Ryker to the channel",
          href: slack_url(row),
          link: "Open in Slack",
          effect:
            "In Slack, invite Ryker to #{where} (type /invite @Ryker there), then try again."
        }
      )
    end
  end

  defp slack_auth(row, slack, short, label \\ "Reconnect Slack") do
    if renewed_since?(slack[:renewed_at], row[:updated_at]) do
      cause(
        short,
        short <> " Slack’s sign-in was saved again after that.",
        :ready,
        "It should work: Slack was reconnected after this stopped."
      )
    else
      cause(
        short,
        short,
        :fix_first,
        "It fails until Slack is connected again with a working sign-in.",
        %{
          label: label,
          href: @slack_settings,
          link: "Open Slack settings",
          effect: "#{label} in Slack settings, then try again."
        }
      )
    end
  end

  defp gone_thing("channel_not_found"), do: "channel"
  defp gone_thing("thread_not_found"), do: "thread"
  defp gone_thing(_code), do: "message"

  defp renewed_since?(%DateTime{} = renewed, %DateTime{} = stopped),
    do: DateTime.compare(renewed, stopped) == :gt

  defp renewed_since?(_renewed, _stopped), do: false

  # Slack's own link to a channel, which opens it in the Slack app.
  defp slack_url(%{destination: "slack:" <> rest}) do
    case rest |> String.split(" / ", parts: 2) |> hd() |> String.split(":", parts: 2) do
      [workspace, channel] -> slack_channel_url(workspace, channel)
      _other -> nil
    end
  end

  defp slack_url(_row), do: nil

  defp slack_channel_url(workspace, channel) do
    if Regex.match?(~r/\A[A-Z0-9]+\z/, workspace) and Regex.match?(~r/\A[A-Z0-9]+\z/, channel),
      do:
        "https://slack.com/app_redirect?" <>
          URI.encode_query(%{team: workspace, channel: channel})
  end

  # --- Slack message updates -------------------------------------------------

  # After someone presses a button on a Ryker message, Ryker rebuilds that
  # message from what is true now. Every failure is retried eight times
  # (1 s doubling to 64 s), then the update stops and Slack tells the person
  # the message may be out of date. Blocked records are deleted with other
  # audit data after the retention window.
  defp interaction(row, now) do
    control = control_name(row[:action_id])
    cause = slack_cause(row, interaction_code_cause(row))

    {happened, affected} =
      case row[:outcome] do
        :invalid ->
          {"Someone pressed #{control} on a Ryker message, but it was out of date and did nothing. Ryker then tried to refresh the message so it would stop showing it.",
           "The message still shows a button that no longer works."}

        _confirmed ->
          {"Someone pressed #{control} on a Ryker message and their choice was saved. Ryker then tried to update the message to show it.",
           "The choice was saved, but the message still shows the old buttons."}
      end

    %{
      title: "Updating a Slack message stopped",
      impact: :people,
      lede: "#{affected} #{outlook_short(cause.outlook)}",
      summary: "#{affected} #{cause.short}",
      happened: [happened, cause.long],
      affects: [
        affected <>
          " Slack told the person who pressed it that the message might be out of date.",
        "Pressing an old button again does nothing twice: Ryker checks every press first."
      ],
      tried: [
        tried(row, now),
        "Ryker retries every failed update eight times over about two minutes, then stops so it does not keep editing a message it cannot update."
      ],
      if_left:
        "The message keeps its old buttons, and this record is deleted with other audit data after the retention period.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: %{
        label: "Update the message again",
        question: "Update this Slack message again?",
        effect:
          "Ryker rebuilds the same Slack message from what is true now and replaces it. It never posts a new message."
      }
    }
  end

  defp control_name("ryker_confirm_behavior"), do: "Confirm on a rule"
  defp control_name("ryker_confirm_memory"), do: "Confirm on a fact"
  defp control_name("ryker_confirm_schedule"), do: "Confirm on a schedule"
  defp control_name("ryker_confirm_automation"), do: "Confirm on an automation"
  defp control_name("ryker_delete_schedule"), do: "Delete on a schedule"
  defp control_name("ryker_delete_behavior"), do: "Delete on a rule"
  defp control_name("ryker_forget_memory"), do: "Forget on a fact"
  defp control_name("ryker_resume_behavior"), do: "Resume on a rule"
  defp control_name("choice_question_answer"), do: "an answer to a question"
  defp control_name("typed_question_answer"), do: "a typed answer to a question"
  defp control_name(_action), do: "a button"

  defp interaction_code_cause(%{summary: code}) do
    case code do
      code when code in ["slack_interaction_repaint_error", "delivery_rate_limited"] ->
        {"Slack kept refusing the update or asking Ryker to slow down.", :unknown,
         "It usually works once Slack answers normally again, within minutes."}

      "delivery_transport_unavailable" ->
        {"Ryker could not reach Slack.", :unknown, "It works once Ryker can reach Slack again."}

      "delivery_credentials_unavailable" ->
        {"Ryker had no Slack sign-in to update the message with.", :auth, nil}

      _other ->
        {"Ryker could not rebuild or update the message.", :unknown,
         "Whether it works depends on the cause. The Technical details keep the saved code."}
    end
  end

  # --- Incident rooms --------------------------------------------------------

  # A room is set up step by step, each step keeping a receipt, so a retry
  # continues where it stopped and never makes a second channel or post.
  # Eight failures in total block it, and some problems block at once. The
  # invite list, name and topic are fixed when the room is requested. A room
  # whose channel is deleted is never blocked: Ryker closes it on its own.
  defp incident(row, now) do
    title = row[:title] || "the incident"
    cause = incident_cause(row)

    %{
      title: "Setting up an incident room stopped",
      impact: :people,
      lede: "No investigation is running for “#{title}” yet. #{outlook_short(cause.outlook)}",
      summary: "No investigation is running for “#{title}” yet. #{cause.short}",
      happened: [
        "#{if row[:automatic], do: "An alert rule", else: "Someone"} asked for an incident room for “#{title}”#{place_words(row)}. Ryker sets a room up in steps: create the channel, post its first message, invite people, set the topic, pin the card, then tell the original thread. It stopped at the step to #{setup_step(row[:setup_step])}.",
        cause.long
      ],
      affects: [
        "The investigation starts only when the room is ready, so nothing is being investigated. Nobody in Slack was told that setup stopped.",
        "The room counts toward the limit on open incident rooms until it is set up, or until its channel is deleted in Slack, which closes it."
      ],
      tried: [
        tried(row, now),
        "Ryker tries up to eight times in all, over about two minutes, and stops at once for problems a retry cannot fix, such as a person who cannot be invited."
      ],
      if_left:
        "The room stays half set up, no investigation starts, and it keeps counting toward the limit on open rooms. The buttons on the original message do nothing. If its channel is deleted in Slack, Ryker closes the room and frees its place.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: %{
        label: "Continue setting up the room",
        question: "Continue setting up this incident room?",
        effect:
          "Ryker continues from the step that stopped and keeps everything already done. It never creates a second channel or posts twice. The invite list, name and topic stay as they were when the room was requested."
      }
    }
  end

  defp setup_step(:channel), do: "create the channel"
  defp setup_step(:root), do: "post the room’s first message"
  defp setup_step(:audience), do: "invite people"
  defp setup_step(:topic), do: "set the topic"
  defp setup_step(:pin), do: "pin the room’s card"
  defp setup_step(:handoff), do: "tell the original thread"
  defp setup_step(:finalize), do: "start the investigation"
  defp setup_step(_step), do: "set it up"

  defp incident_cause(%{summary: code})
       when code in ["incident_audience_member_invalid", "incident_audience_group_empty"] do
    cause(
      if(code == "incident_audience_group_empty",
        do: "The group of people to invite has no members.",
        else: "Someone on the invite list cannot be invited."
      ),
      "The invite list includes a person Slack will not add to the room: deactivated, a guest, a bot, or from another workspace, or a group with nobody in it. The list was fixed when the room was requested, so changing it now does not change this room.",
      :stuck,
      "It will stop the same way unless that person can be invited again. Fix the channel’s invite list, then ask for a new room.",
      nil
    )
  end

  defp incident_cause(%{summary: code})
       when code in ["incident_offer_not_found", "incident_offer_stale"] do
    cause(
      "The incident offer it came from is no longer current.",
      "The room was requested from an offer that has since changed or closed, so Ryker cannot start its investigation.",
      :stuck,
      "It will stop the same way: the offer is gone. Ask for a new incident room if one is still needed."
    )
  end

  defp incident_cause(%{channel_state: state} = row) when state in [:archived, :unavailable] do
    cause(
      if(state == :archived,
        do: "Its channel was archived.",
        else: "Ryker was removed from its channel."
      ),
      "Setup can only continue in an active channel Ryker is a member of.",
      :fix_first,
      "It fails until the channel is active and Ryker is in it again. A retry before that waits silently.",
      %{
        label: if(state == :archived, do: "Unarchive the room", else: "Invite Ryker back"),
        effect:
          if(state == :archived,
            do: "Unarchive the room’s channel in Slack, then continue.",
            else: "Invite Ryker back into the room’s channel in Slack, then continue."
          ),
        href: room_path(row),
        link: "Open in Slack"
      }
    )
  end

  defp incident_cause(row) do
    slack_cause(
      row,
      {"Slack refused a setup step or kept failing.", :unknown,
       "Whether it works depends on the cause. It continues from where it stopped, so trying costs nothing."}
    )
  end

  defp room_path(%{channel_ref: channel} = row) when is_binary(channel) do
    case row[:destination] do
      "slack:" <> rest -> slack_channel_url(rest |> String.split(":", parts: 2) |> hd(), channel)
      _other -> nil
    end
  end

  defp room_path(_row), do: nil

  # A reply owed to an incident room Slack deleted can never be posted there.
  # Ryker moves it, words unchanged, to the alert thread the room was opened
  # from and posts it there on its own, so until it is moved there is nothing
  # to do and nothing to retry. Once moved it posts there like any reply: the
  # row names that thread, and Slack's answer there decides what a retry does.
  defp room_reply(%{incident_room: %{reply: :in_room, channel_name: name}} = row, now) do
    parts = delivery_parts(:message)

    cause =
      cause(
        "Its incident room ##{name} was deleted in Slack.",
        "Slack deletes a channel for good, so Ryker posts the reply in the alert thread the room was opened from instead.",
        :automatic,
        "Ryker moves it to the alert thread and posts it there on its own; nothing here needs doing."
      )

    %{
      title: parts.title,
      impact: :people,
      lede: "#{parts.affected} #{outlook_short(cause.outlook)}",
      summary: "#{parts.affected} #{cause.short}",
      happened: [parts.happened <> place_words(row) <> ".", cause.long],
      affects: parts.affects,
      tried: [
        tried(row, now),
        "Ryker does not post into a deleted room again: it moves the reply to the alert thread and posts it there."
      ],
      if_left:
        "Ryker moves the reply to the alert thread the room was opened from and posts it there on its own.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: %{label: parts.label, question: parts.question, effect: parts.effect}
    }
  end

  defp room_reply(%{incident_room: %{reply: :moved, channel_name: name}} = row, now) do
    story = delivery(row, now)

    moved =
      "It was written for the incident room ##{name}, which was deleted in Slack, so Ryker posts it in the alert thread the room was opened from instead."

    %{story | happened: List.insert_at(story.happened, 1, moved)}
  end

  # --- Approvals -------------------------------------------------------------

  # Ryker watches an approval request it made in Emisar, read-only, until
  # Emisar reports a final result, then continues the task. Outages retry
  # forever with backoff up to five minutes; a refusal a retry cannot change
  # stops the watch. Emisar keeps working without Ryker: approvers can still
  # approve and the action can still run. A watch whose task was closed is
  # closed by the monitor and never listed; replacing the account's token
  # starts watching again every watch Emisar stopped for refusing the old one.
  #
  # A task can also wait on a watch that is not stopped but cannot move: the
  # account's approval monitoring is off, or Ryker has no usable token for it.
  # Nothing listed those, so tasks waited for good. There is nothing to retry
  # there; the fix is the account, and the watch goes on by itself after it.
  defp emisar(%{stall: stall} = row, now) when stall in [:monitoring_off, :token_unavailable] do
    live = Map.get(row, :emisar) || %{}
    stalled = emisar_stall(stall, row, now)

    %{
      title: stalled.title,
      impact: :people,
      lede: stalled.lede,
      summary: stalled.summary,
      happened: [
        "A task asked Emisar to run #{action_words(row)}, and Emisar held it for approval. The task waits until Ryker sees a final result.",
        stalled.long
      ],
      affects:
        Enum.reject(
          [
            "The person who asked sees the approval card frozen and hears nothing more. The task waits.",
            "Approvers can still approve or deny in Emisar, and the action may run; Ryker just will not see or report it.",
            expired_words(live[:expires_at], now)
          ],
          &is_nil/1
        ),
      tried: stalled.tried,
      if_left:
        "The task waits and the card stays frozen. The approval runs its course in Emisar without Ryker reporting it.",
      outlook: :fix_first,
      outlook_note: stalled.note,
      fix: emisar_fix(stalled.fix)
    }
  end

  defp emisar(row, now) do
    live = Map.get(row, :emisar) || %{}
    cause = emisar_cause(row, live)
    expired = expired_words(live[:expires_at], now)

    %{
      title: "Watching an approval stopped",
      impact: :people,
      lede: "Ryker no longer follows this approval. #{outlook_short(cause.outlook)}",
      summary: "Ryker no longer follows this approval, so the task waits. #{cause.short}",
      happened: [
        "A task asked Emisar to run #{action_words(row)}, and Emisar held it for approval. Ryker was watching the request so it could tell the person who asked and continue the task, and the watch stopped.",
        cause.long
      ],
      affects:
        Enum.reject(
          [
            "The person who asked sees the approval card frozen and hears nothing more. The task waits.",
            "Approvers can still approve or deny in Emisar, and the action may run; Ryker just will not see or report it.",
            expired
          ],
          &is_nil/1
        ),
      tried: [
        if(Map.get(row, :attempt_count, 0) > 0,
          do: tried(row, now),
          else: "Ryker stopped at the first refusal."
        ),
        "Ryker keeps retrying on its own while Emisar is unreachable or busy. It stops when Emisar refuses in a way a retry cannot change."
      ],
      if_left:
        "The task waits and the card stays frozen. The approval runs its course in Emisar without Ryker reporting it.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      retry: %{
        label: "Watch the approval again",
        question: "Start watching this approval again?",
        effect:
          "Ryker starts watching the same approval request in Emisar again. It only reads: it does not approve, deny or run anything. When Emisar reports a final result, Ryker tells the person who asked and continues the task."
      }
    }
  end

  defp emisar_stall(:monitoring_off, _row, _now) do
    %{
      title: "Nobody is watching an approval",
      lede:
        "A task waits for this approval, but approval monitoring is off for its Emisar account.",
      summary:
        "A task waits for this approval, but approval monitoring is off for its Emisar account, so Ryker is not watching it.",
      long:
        "Approval monitoring is off for this Emisar account, so Ryker does not check on the request and will not see the decision.",
      tried: [
        "Ryker does not check on approvals for an account whose monitoring is off. It picks this one up by itself once monitoring is on again."
      ],
      note:
        "It stays like this until approval monitoring is on for the account. Then Ryker picks the approval up by itself; there is nothing to retry here.",
      fix:
        "Turn on approval monitoring for this Emisar account. Ryker then picks the approval up by itself."
    }
  end

  defp emisar_stall(:token_unavailable, row, now) do
    %{
      title: "Ryker cannot check on an approval",
      lede:
        "A task waits for this approval, but Ryker has no usable token for its Emisar account.",
      summary:
        "A task waits for this approval, but Ryker has no usable Emisar token for its account, so it cannot check on it.",
      long:
        "The account's token was removed from Ryker or can no longer be read, so every check on the request fails before it reaches Emisar.",
      tried: [
        if(Map.get(row, :attempt_count, 0) > 0,
          do: tried(row, now),
          else: "Ryker has not been able to check on it yet."
        ),
        "Ryker keeps checking every few minutes, and every check fails the same way until the token is replaced."
      ],
      note:
        "It keeps failing until the account's token is replaced. Then the next check goes out at once; there is nothing to retry here.",
      fix:
        "Replace the token for this Emisar account. Ryker then checks the approval again by itself."
    }
  end

  # A task that was closed, or whose wait was answered, closes its watch and is
  # never listed; one that is doing something else for now still refuses it.
  defp emisar_cause(%{request_state: state}, _live)
       when not is_nil(state) and state != :waiting_for_event do
    cause(
      "The task is no longer waiting for it.",
      "The task that asked for this approval has moved on, so there is nothing to continue from it now.",
      :stuck,
      "It will be refused: the task no longer waits for this approval."
    )
  end

  # Monitoring switched off for the connection turns any retry into one that
  # nothing would watch, whatever stopped it.
  defp emisar_cause(row, live) do
    base = emisar_refusal(row[:summary], row, live)

    if live[:monitored] == false and base.outlook in [:ready, :unknown] do
      cause(
        base.short,
        base.long,
        :fix_first,
        "Approval monitoring is off for this Emisar connection, so nothing would watch it.",
        emisar_fix("Turn on approval monitoring for this connection, then watch again.")
      )
    else
      base
    end
  end

  defp emisar_refusal("emisar_approval_identity_mismatch", _row, _live) do
    cause(
      "Emisar reported a different run for this request.",
      "Emisar answered with a run whose identity does not match the request Ryker made, so Ryker stopped rather than report the wrong result.",
      :stuck,
      "It will stop the same way: the identity will not match."
    )
  end

  defp emisar_refusal(code, row, live) when code in ["emisar_http_401", "emisar_http_403"],
    do: emisar_token(row, live)

  defp emisar_refusal("emisar_http_404", _row, _live) do
    cause(
      "Emisar no longer knows this request.",
      "Emisar answered “not found” for the approval request.",
      :unknown,
      "It works only if the Emisar address is wrong and has been corrected since."
    )
  end

  defp emisar_refusal("emisar_review_unreadable", _row, _live) do
    cause(
      "Emisar’s answer has a shape this version of Ryker cannot read.",
      "Emisar sent a review in a format Ryker does not accept.",
      :stuck,
      "It will stop the same way until Ryker is upgraded to read it."
    )
  end

  defp emisar_refusal("invalid_emisar_client", _row, _live) do
    cause(
      "The Emisar connection is not set up correctly.",
      "Ryker could not build a client for this Emisar connection.",
      :fix_first,
      "It fails until the Emisar connection is fixed.",
      emisar_fix("Check the Emisar connection in Emisar settings, then watch again.")
    )
  end

  defp emisar_refusal("emisar_approval_presentation_failed", _row, _live) do
    cause(
      "Ryker could not update the approval card.",
      "Emisar answered, but updating the card in the conversation failed in a way a retry cannot change.",
      :unknown,
      "It works if the conversation and Slack connection are healthy now."
    )
  end

  defp emisar_refusal(_code, _row, _live) do
    cause(
      "Emisar refused, or answered in a way Ryker did not expect.",
      "The watch stopped on an answer Ryker cannot act on.",
      :unknown,
      "Whether it works depends on the cause. The Technical details keep the saved code."
    )
  end

  defp emisar_token(row, live) do
    if renewed_since?(live[:token_changed_at], row[:updated_at]) do
      cause(
        "Emisar refused Ryker’s token then, and the token was replaced since.",
        "Emisar refused Ryker’s token when it checked on the approval.",
        :ready,
        "It should work: the Emisar token was replaced after this stopped."
      )
    else
      cause(
        "Emisar refused Ryker’s token.",
        "Emisar refused Ryker’s token when it checked on the approval: it was revoked or lacks access.",
        :fix_first,
        "It fails until Ryker has a working Emisar token.",
        emisar_fix(
          "Replace the Emisar token in Emisar settings. Ryker then watches the approval again by itself."
        )
      )
    end
  end

  defp emisar_fix(effect),
    do: %{
      label: "Fix the Emisar connection",
      href: @emisar_settings,
      link: "Open Emisar settings",
      effect: effect
    }

  defp action_words(%{action_id: action}) when is_binary(action), do: "“#{action}”"
  defp action_words(_row), do: "an action"

  defp expired_words(%DateTime{} = expires, now) do
    if DateTime.compare(expires, now) == :lt,
      do:
        "The approval window ended #{ShortTime.text(expires, now)}; Emisar has settled it without Ryker."
  end

  defp expired_words(_expires, _now), do: nil

  # --- Pull requests ---------------------------------------------------------

  # Publishing retries on its own about once a minute, with no limit, until it
  # succeeds, so there is no retry button here. What a person can change is
  # the cause: most of the time the repository setup. A worker session that
  # closed for good is the one cause nothing can change: Ryker discards that
  # publication itself, with the reason, and it leaves this page.
  defp publication(row, now) do
    cause = publication_cause(row)

    %{
      title: "Opening a pull request stopped",
      impact: :people,
      lede:
        "The change is ready, but no pull request exists yet. #{outlook_short(cause.outlook)}",
      summary: "The change is ready, but no pull request exists yet. #{cause.short}",
      happened: [
        "A code task finished a change in #{repository_words(row)}. Ryker reviews such a change and then opens a draft pull request for it, and that stopped.",
        cause.long
      ],
      affects: [
        "The person who asked has no pull request. The task card in the conversation says it needs attention.",
        "Until it is published, the worker keeps the task’s working copy."
      ],
      tried: [
        tried(row, now),
        "Ryker keeps retrying on its own about once a minute, with no limit, and succeeds by itself once the cause is fixed. If the worker session that holds the change closes for good, Ryker stops and ends the pull request on its own, saying why."
      ],
      if_left:
        cause[:left] || "Ryker keeps retrying about once a minute until the cause is fixed.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix: cause.fix,
      alternative:
        row[:episode_ref] &&
          %{
            label: "Open the task",
            href: timeline(row.episode_ref),
            link: "Open the request",
            effect:
              "The task card in the conversation has Retry, Review latest state and Discard for this pull request."
          }
    }
  end

  defp publication_cause(%{summary: "publication_repository_not_configured"} = row) do
    if match?(%{configured: true}, row[:publishing]) do
      cause(
        "The repository was not set up for pull requests, and it is now.",
        "Ryker could not publish to #{repository_words(row)}: pull requests were not set up for it. They are now.",
        :automatic,
        "It should go through on Ryker’s next attempt, within a minute."
      )
    else
      cause(
        "Pull requests are not set up for #{repository_words(row)}.",
        "Ryker can only open pull requests in a repository with a connected GitHub App, pull requests turned on, and a checkout to publish from. #{sentence(repository_words(row))} is missing one of them.",
        :fix_first,
        "It goes through on its own once the repository is set up; nothing else is needed.",
        %{
          label: "Set up pull requests",
          href: @github_settings,
          link: "Open GitHub settings",
          effect:
            "Connect the GitHub App to #{repository_words(row)} and turn on pull requests in GitHub settings. Ryker publishes on its next attempt."
        }
      )
    end
  end

  # A closed session no longer arrives here: that answer ends the publication.
  # What is left is an answer Ryker could not read.
  defp publication_cause(%{summary: "publication_coop_protocol_error"}) do
    cause(
      "The worker’s answer about the change did not match what Ryker expected.",
      "Ryker reviews a change in the worker session that made it. The worker’s answer about that session or its review did not match what Ryker recorded, so Ryker did not use it.",
      :automatic,
      "Ryker keeps retrying on its own. If it never succeeds, open the task and discard it or review the latest state."
    )
  end

  defp publication_cause(%{summary: "publication_credentials_unavailable"}) do
    cause(
      "Ryker has no working GitHub access to publish with.",
      "GitHub refused Ryker’s app credentials for this repository: the app was removed, suspended or lost access.",
      :fix_first,
      "It goes through on its own once GitHub access is restored.",
      %{
        label: "Restore GitHub access",
        href: @github_settings,
        link: "Open GitHub settings",
        effect:
          "Reconnect the GitHub App, or install it on this repository again. Ryker publishes on its next attempt."
      }
    )
  end

  defp publication_cause(%{summary: code})
       when code in [
              "publication_branch_already_exists",
              "publication_branch_changed",
              "publication_existing_pull_request_changed",
              "publication_pull_request_mismatch"
            ] do
    cause(
      "Its branch or pull request changed on GitHub.",
      "Someone changed the branch or pull request on GitHub after Ryker created it, so Ryker stopped rather than overwrite their work.",
      :fix_first,
      "Ryker stopped retrying this. Choose on the task card whether to review the latest state or discard.",
      nil
    )
  end

  defp publication_cause(%{summary: code}) when code in ["publication_patch_contains_secret"] do
    cause(
      "The change looks like it contains a secret.",
      "Ryker will not publish a change that appears to contain a secret.",
      :stuck,
      "It will stop the same way. Discard the change from the task card, or ask for it again without the secret."
    )
  end

  defp publication_cause(_row) do
    cause(
      "Something failed while reviewing or publishing the change.",
      "The saved error does not name a cause Ryker can describe. The Technical details keep its code.",
      :automatic,
      "Ryker keeps retrying on its own. If it never succeeds, open the task and discard or review it again."
    )
  end

  defp repository_words(%{source: repository})
       when is_binary(repository) and repository != "no repository",
       do: "the #{repository} repository"

  defp repository_words(_row), do: "the repository"

  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  # --- Learning --------------------------------------------------------------

  # Only a batch that nothing will move lands here; one still reconciling a
  # run moves on by itself and is not listed. Replies never wait on learning.
  defp learning(row, now) do
    cause = learning_cause(row)
    messages = plural(row[:input_count] || 0, "message", "messages")

    %{
      title: "Learning from a conversation stopped",
      impact: :housekeeping,
      lede:
        "Ryker is not learning from #{messages} in this conversation. #{outlook_short(cause.outlook)}",
      summary: "Ryker is not learning from #{messages} in this conversation. #{cause.short}",
      happened: [
        "Ryker reads conversations in the background and keeps what is worth remembering as learned topics. Reading #{messages} here stopped.",
        cause.long
      ],
      affects: [
        "Ryker is not learning from these messages; replies are unaffected.",
        "Newer messages in this conversation are learned as usual."
      ],
      tried: [
        tried(row, now),
        "Ryker does not start again on its own: a start can be a model call, and this batch has used what it was given."
      ],
      if_left: "These messages stay unlearned. Nothing else changes.",
      outlook: cause.outlook,
      outlook_note: cause.note,
      fix:
        if cause.outlook != :stuck do
          %{
            person: true,
            label: "Grant one more start",
            href: row[:learning_path],
            link: "Open its attempts",
            effect:
              "The Learning page shows why each attempt stopped. Grant one more start there and Ryker reads these messages again under the current learning policy."
          }
        end
    }
  end

  defp learning_cause(%{summary: "learning_retry_exhausted"}),
    do:
      cause(
        "Every start it was given was used.",
        "Each attempt ended without a change Ryker could save.",
        :unknown,
        "Another start works if what stopped the attempts has changed; each attempt says what that was."
      )

  defp learning_cause(%{summary: code})
       when code in ~w(knowledge_target_unavailable knowledge_match_ambiguous),
       do:
         cause(
           "The learned topic it would change was unclear or no longer valid.",
           "The messages matched a learned topic Ryker could not safely change: either more than one topic fit, or the one that fit no longer had valid sources.",
           :unknown,
           "Another start may pick a different topic; the attempt says which one it could not change."
         )

  defp learning_cause(%{summary: "learning_capacity_exceeded"}),
    do:
      cause(
        "These messages and the history they build on are too large to learn from at once.",
        "One learning request has a size limit, and these messages with the topic history they extend go over it.",
        :stuck,
        "Another start reads the same messages and stops the same way."
      )

  defp learning_cause(_row),
    do:
      cause(
        "Learning could not finish.",
        "The attempts stopped without a change Ryker could save.",
        :unknown,
        "Each attempt on the Learning page says what stopped it."
      )

  # --- Anything else ---------------------------------------------------------

  defp generic(row, now) do
    %{
      title: "#{kind_name(row.kind)} stopped",
      impact: :people,
      lede: "This stopped before Ryker could confirm it finished.",
      summary: "This stopped before Ryker could confirm it finished.",
      happened: ["The operation stopped before Ryker could confirm it had finished."],
      affects: ["Open the request to see who is waiting on it."],
      tried: [tried(row, now)],
      if_left: "It stays stopped. Ryker does not retry it by itself.",
      outlook: :unknown,
      outlook_note: "Whether it works depends on the cause, which the saved error does not name.",
      retry: %{
        label: "Try again",
        question: "Try this again?",
        effect: "Ryker runs the step that stopped once more. Nothing else changes."
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Shared words

  defp tried(row, now) do
    when_text =
      case Map.get(row, :updated_at) do
        nil -> ""
        at -> ", most recently #{ShortTime.text(at, now)}"
      end

    case Map.get(row, :attempt_count, 0) do
      count when not is_integer(count) or count <= 0 -> "Ryker has no count of its attempts."
      1 -> "Ryker tried once#{when_text}."
      count -> "Ryker tried #{count} times#{when_text}."
    end
  end

  defp attempt_words(row) do
    case Map.get(row, :attempt_count, 0) do
      1 -> "once"
      count -> "#{count} times"
    end
  end

  defp outlook_short(:ready), do: "A retry should work now."
  defp outlook_short(:unknown), do: "Check the cause before retrying."
  defp outlook_short(:fix_first), do: "A retry fails until the cause is fixed."
  defp outlook_short(:stuck), do: "A retry would stop the same way."
  defp outlook_short(:automatic), do: "Ryker is still retrying on its own."

  # A reply that goes out much later than it was written says so on the
  # confirmation, because Slack will show it without a note.
  defp late(%{updated_at: at}, now) when not is_nil(at) do
    if DateTime.diff(now, utc(at), :second) >= 3_600,
      do: " (it stopped #{age(at, now)} ago)",
      else: ""
  end

  defp late(_row, _now), do: ""

  defp late_sentence(%{updated_at: at}, now, :message) when not is_nil(at) do
    if DateTime.diff(now, utc(at), :second) >= 3_600,
      do: " It arrives #{age(at, now)} late, with no note saying so.",
      else: ""
  end

  defp late_sentence(_row, _now, _kind), do: ""

  defp place_words(row) do
    case place(row) do
      nil -> ""
      "Direct conversation" -> " in a direct conversation"
      "GitHub" -> " on GitHub"
      "Webhook" -> " from a webhook"
      name -> " in #{name}"
    end
  end

  defp error_code(%{kind: "work"} = row), do: row[:stop_code] || row.summary
  defp error_code(row), do: get_in(row, [:diagnosis, :code]) || row.summary

  defp seen(%{last_seen_at: %DateTime{} = at}), do: " since #{ShortTime.full(at)}"
  defp seen(_worker), do: " yet"

  defp worker_now(nil), do: nil
  defp worker_now(%{enrolled: false}), do: "Removed from Ryker"

  defp worker_now(%{reporting: true} = worker),
    do:
      "Reporting" <>
        if(worker[:policy_current] == false, do: "; its policy version changed", else: "")

  defp worker_now(%{last_seen_at: %DateTime{} = at}),
    do: "Not reporting since #{ShortTime.full(at)}"

  defp worker_now(_worker), do: "Not reporting"

  defp policy_name(%{policy: policy}) when is_binary(policy), do: policy
  defp policy_name(_row), do: "session’s"

  defp words(code), do: String.replace(code, "_", " ")

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, _one, many), do: "#{count} #{many}"

  defp timeline(ref), do: "/timeline/" <> segment(ref)
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end

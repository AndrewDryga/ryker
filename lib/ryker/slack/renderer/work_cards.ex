defmodule Ryker.Slack.Renderer.WorkCards do
  @moduledoc """
  The incident-room and task cards: one pinned or threaded status anchor per
  piece of work, with the exact controls the host authorized for it.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  alias Ryker.Slack.Renderer.TaskPublication
  alias Ryker.Slack.TaskCardDetails
  alias Ryker.State.InvestigationPayload

  @goal_states InvestigationPayload.goal_states()
  # A room that set more goals than this is not asking a responder to read them
  # all on a phone; the projection sends the first eight, each compacted.
  @incident_goals 8
  @goal_outcome 200
  @incident_statuses ~w(provisioning investigating action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)
  @task_statuses ~w(queued working waiting_for_input waiting_for_event action_required stopping reviewing ready_to_publish published completed cancelled)
  @task_fields ~w(action_needed confirmed_at confirmed_by controls episode_state publication repository resume_ref session_generation stages status summary task_ref title ui_revision updated_at work_state)
  # The work document is shared with the control-plane card, which owns diff
  # reading. `view_diff` stays a valid document control there and never becomes
  # a Slack control: Slack links out and never pages a patch.
  @work_controls ~w(stop resume view_diff close timeline evidence handoff recovery postmortem)
  @work_buttons ~w(stop resume close)
  @record_controls ~w(timeline evidence handoff recovery postmortem)

  @spec incident_room(map()) :: {:ok, map()} | {:error, term()}
  def incident_room(
        %{
          "action_needed" => action_needed,
          "alert" => alert,
          "controls" => controls,
          "episode_state" => episode_state,
          "goals" => goals,
          "opened_at" => opened_at,
          "opened_by" => opened_by,
          "repository" => repository,
          "room_ref" => room_ref,
          "session_generation" => session_generation,
          "severity" => severity,
          "signals" => signals,
          "source" => source,
          "status" => status,
          "summary" => summary,
          "title" => title,
          "ui_revision" => ui_revision,
          "updated_at" => updated_at
        } = room
      )
      when map_size(room) == 18 and is_map(source) and status in @incident_statuses do
    with :ok <- incident_reference(room_ref),
         :ok <- bounded_text(opened_by, 1_024),
         :ok <- bounded_text(repository, 256),
         :ok <- bounded_text(title, 200),
         :ok <- bounded_text(summary, 2_000),
         :ok <- bounded_text(severity, 120),
         :ok <- optional_bounded_text(action_needed, 2_000),
         :ok <- bounded_text(episode_state, 120),
         :ok <- incident_source(source),
         :ok <- incident_alert(alert),
         :ok <- incident_signals(signals),
         :ok <- incident_goals(goals),
         :ok <- incident_generation(session_generation),
         :ok <- work_controls(controls),
         :ok <- positive_integer(ui_revision),
         :ok <- iso8601(opened_at),
         :ok <- iso8601(updated_at) do
      short = room_ref |> String.split(":") |> List.last() |> String.slice(0, 8)
      label = incident_status_label(status)
      signal_text = incident_signal_text(signals)

      session_text =
        if session_generation, do: Integer.to_string(session_generation), else: "pending"

      text =
        "Incident #{short}: #{title}. #{label}. #{summary}" <>
          if(action_needed, do: " Action needed: #{action_needed}", else: "")

      blocks =
        [
          section("*Incident · #{escape(title)}*\n_Status: #{escape(label)}_"),
          section(escape(summary)),
          section(
            "Severity: *#{escape(severity)}* · Signals: #{escape(signal_text)}\nRepository: `#{escape(repository)}` · Episode: `#{escape(episode_state)}` · Session: `#{session_text}`"
          ),
          incident_alert_block(alert),
          incident_goals_block(goals),
          incident_action_block(action_needed),
          work_controls_block(room_ref, controls, :incident),
          section(
            "Source: channel `#{escape(source["channel_ref"])}` · message `#{escape(source["message_ref"])}`#{incident_thread(source["thread_ref"])}\nOpened by: `#{escape(opened_by)}` · Incident: `#{escape(short)}`"
          ),
          section(
            "_Opened #{escape(opened_at)} · Updated #{escape(updated_at)}. This pinned card is the durable status anchor; the linked episode owns the work and authority._"
          )
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, %{"blocks" => blocks, "text" => text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :incident_room}}
    end
  end

  def incident_room(_room), do: {:error, {:invalid_slack_render, :incident_room}}

  # "What have we actually established" is the whole question on an incident
  # card, and it carried only a prose summary. Each goal with where it stands,
  # bounded, in the order the investigation set them.
  defp incident_goals_block([]), do: nil

  defp incident_goals_block(goals) do
    rendered =
      Enum.map_join(goals, "\n", fn goal ->
        "#{TaskCardDetails.goal_glyph(goal["state"])} #{escape(goal["outcome"])}#{incident_goal_detail(goal["detail"])}"
      end)

    section("*What this investigation is establishing*\n#{rendered}")
  end

  defp incident_goal_detail(nil), do: ""
  defp incident_goal_detail(detail), do: " · #{escape(detail)}"

  @spec task_card(map()) :: {:ok, map()} | {:error, term()}
  def task_card(
        %{
          "action_needed" => action_needed,
          "confirmed_at" => confirmed_at,
          "confirmed_by" => confirmed_by,
          "controls" => controls,
          "episode_state" => episode_state,
          "publication" => publication,
          "repository" => repository,
          "session_generation" => session_generation,
          "stages" => _stages,
          "status" => status,
          "summary" => summary,
          "task_ref" => task_ref,
          "title" => title,
          "ui_revision" => ui_revision,
          "updated_at" => updated_at,
          "work_state" => work_state
        } = task
      )
      when status in @task_statuses do
    repository_url = Map.get(task, "repository_url")

    with true <- Map.keys(task) -- (@task_fields ++ ~w(question_url repository_url request)) == [],
         :ok <- work_controls(controls),
         :ok <- resume_reference(task["resume_ref"], controls),
         true <- TaskCardDetails.valid?(task),
         :ok <- task_reference(task_ref),
         :ok <- bounded_text(confirmed_by, 1_024),
         :ok <- bounded_text(episode_state, 120),
         :ok <- bounded_text(repository, 256),
         :ok <- bounded_text(summary, 2_000),
         :ok <- bounded_text(title, 200),
         :ok <- optional_bounded_text(action_needed, 2_000),
         :ok <- optional_bounded_text(work_state, 120),
         :ok <- optional_https_url(repository_url),
         :ok <- incident_generation(session_generation),
         :ok <- TaskPublication.validate(publication),
         :ok <- positive_integer(ui_revision),
         :ok <- iso8601(confirmed_at),
         :ok <- iso8601(updated_at) do
      label = task_status_label(status)

      # Slack truncates a notification, so what survives is the front of this
      # string. It used to open with eight characters of the task ref, which
      # names the work to nobody; the title is how a person recognizes it.
      text =
        "#{title}: #{label}. #{summary}" <>
          if(action_needed, do: " Action needed: #{action_needed}", else: "")

      blocks =
        ([section("*#{escape(title)}*")] ++
           TaskCardDetails.blocks(task) ++
           [fact_fields([{"Repository", %{"ref" => repository, "url" => repository_url}}])] ++
           TaskPublication.blocks(task_ref, repository, publication) ++
           [
             incident_action_block(action_needed),
             work_controls_block(task_ref, controls, :task, task["resume_ref"]),
             context("_Updated #{display_time(updated_at)}_")
           ])
        |> Enum.reject(&is_nil/1)

      {:ok, %{"blocks" => blocks, "text" => text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :task_card}}
    end
  end

  def task_card(_task), do: {:error, {:invalid_slack_render, :task_card}}

  defp task_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Atask-card:[A-Za-z0-9_.:-]{1,240}\z/, value),
      do: :ok,
      else: {:error, :invalid_task_reference}
  end

  defp work_controls(controls) when is_list(controls) do
    if controls == Enum.uniq(controls) and length(controls) <= length(@work_controls) and
         Enum.all?(controls, &(&1 in @work_controls)),
       do: :ok,
       else: {:error, :invalid_work_controls}
  end

  defp work_controls(_controls), do: {:error, :invalid_work_controls}

  # A resume button is only as safe as the fingerprint it carries, so the card
  # may not offer the control without one, and may not carry one it cannot use.
  defp resume_reference(nil, controls) do
    if "resume" in controls, do: {:error, :invalid_work_controls}, else: :ok
  end

  defp resume_reference(reference, controls) when is_binary(reference) do
    with true <- "resume" in controls,
         [work_ref, fingerprint] <- String.split(reference, "|", parts: 2),
         :ok <- task_reference(work_ref),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint) do
      :ok
    else
      _invalid -> {:error, :invalid_work_controls}
    end
  end

  defp resume_reference(_reference, _controls), do: {:error, :invalid_work_controls}

  defp work_controls_block(work_ref, controls, kind, resume_ref \\ nil)

  defp work_controls_block(_work_ref, [], _kind, _resume_ref), do: nil

  defp work_controls_block(work_ref, controls, kind, resume_ref) do
    buttons =
      controls
      |> Enum.filter(&(&1 in @work_buttons))
      |> Enum.map(&work_button(&1, if(&1 == "resume", do: resume_ref, else: work_ref), kind))

    records = Enum.filter(controls, &(&1 in record_controls(kind)))

    elements =
      buttons ++
        evidence_button(work_ref, controls, kind) ++
        if records == [], do: [], else: [work_record_overflow(work_ref, records)]

    actions("#{work_ref}:controls", elements)
  end

  # What an investigation found is the subject of its card, so an incident opens
  # its evidence in one tap. A task's records are the aside to its work and stay
  # in the menu.
  defp record_controls(:incident), do: @record_controls -- ["evidence"]
  defp record_controls(_kind), do: @record_controls

  defp evidence_button(work_ref, controls, :incident) do
    if "evidence" in controls,
      do: [plain_button("ryker_work_record", "Open evidence", "#{work_ref}|evidence")],
      else: []
  end

  defp evidence_button(_work_ref, _controls, _kind), do: []

  defp work_button("stop", work_ref, _kind) do
    button(
      "ryker_stop_work",
      "Stop current run",
      work_ref,
      "danger",
      "Stop current run",
      "Cancel only the active agent turn. The task, session context, queue, and working copy remain available for a later correction.",
      "Stop run"
    )
  end

  # Resuming carries the recovery fingerprint of the turn the card was rendered
  # against, so a stale card cannot restart work that has already moved on.
  defp work_button("resume", resume_ref, _kind) do
    button(
      "ryker_resume_work",
      "Resume task",
      resume_ref,
      "primary",
      "Resume this task?",
      "Continue from the stopped run, in the same session and working copy. Nothing already done is repeated.",
      "Resume task"
    )
  end

  defp work_button("close", work_ref, :incident) do
    button(
      "ryker_close_work",
      "Close incident",
      work_ref,
      "danger",
      "Close incident",
      "Stop remaining agent work and close this incident. Its durable record and retained repository state remain available.",
      "Close incident"
    )
  end

  defp work_button("close", work_ref, :task) do
    button(
      "ryker_close_work",
      "Close task",
      work_ref,
      "danger",
      "Close task",
      "Stop remaining agent work and close this task. Its durable record and retained repository state remain available.",
      "Close task"
    )
  end

  defp work_record_overflow(work_ref, records) do
    %{
      "action_id" => "ryker_work_record",
      "options" => Enum.map(records, &work_record_option(work_ref, &1)),
      "type" => "overflow"
    }
  end

  defp work_record_option(work_ref, kind) do
    label =
      case kind do
        "timeline" -> "Timeline"
        "evidence" -> "Evidence"
        "handoff" -> "Handoff summary"
        "recovery" -> "Review recovery"
        "postmortem" -> "Postmortem draft"
      end

    %{"text" => plain_text(label), "value" => "#{work_ref}|#{kind}"}
  end

  defp task_status_label("queued"), do: "Queued"
  defp task_status_label("working"), do: "Working"
  defp task_status_label("waiting_for_input"), do: "Waiting for input"
  defp task_status_label("waiting_for_event"), do: "Waiting for verification"
  defp task_status_label("action_required"), do: "Action required"
  defp task_status_label("stopping"), do: "Stopping current work"
  # Every publication status folded in here is a step before the change is
  # public. "Review or publication in progress" named the host's two internal
  # phases and left the reader unable to say when they would see it.
  defp task_status_label("reviewing"), do: "Checking the change before it is published"
  defp task_status_label("ready_to_publish"), do: "Reviewed and ready for operator publication"
  defp task_status_label("published"), do: "Draft pull request published"
  defp task_status_label("completed"), do: "Completed"
  defp task_status_label("cancelled"), do: "Closed"

  defp incident_status_label("provisioning"), do: "Provisioning"
  defp incident_status_label("investigating"), do: "Investigating"
  defp incident_status_label("action_required"), do: "Action required"
  defp incident_status_label("waiting_for_input"), do: "Waiting for input"
  defp incident_status_label("waiting_for_event"), do: "Waiting for verification"
  defp incident_status_label("stopping"), do: "Stopping current work"
  defp incident_status_label("resolved"), do: "Resolved"
  defp incident_status_label("cancelled"), do: "Cancelled"
  defp incident_status_label("paused"), do: "Paused"

  defp incident_alert(nil), do: :ok

  defp incident_alert(%{"impact" => impact, "verdict" => verdict} = alert)
       when map_size(alert) == 2 do
    with :ok <- bounded_text(impact, 1_000) do
      bounded_text(verdict, 120)
    end
  end

  defp incident_alert(_alert), do: {:error, :invalid_incident_alert}

  defp incident_alert_block(nil), do: nil

  defp incident_alert_block(%{"impact" => impact, "verdict" => verdict}) do
    section("*Latest alert assessment · #{escape(verdict)}*\n#{escape(impact)}")
  end

  defp incident_action_block(nil), do: nil
  defp incident_action_block(value), do: section(":warning: *Action needed*\n#{escape(value)}")

  defp incident_signals(%{"firing" => firing, "total" => total} = signals)
       when map_size(signals) == 2 do
    if Enum.all?([firing, total], &(is_nil(&1) or (is_integer(&1) and &1 >= 0))),
      do: :ok,
      else: {:error, :invalid_incident_signals}
  end

  defp incident_signals(_signals), do: {:error, :invalid_incident_signals}

  defp incident_goals(goals) when is_list(goals) and length(goals) <= @incident_goals do
    if Enum.all?(goals, &incident_goal?/1), do: :ok, else: {:error, :invalid_incident_goals}
  end

  defp incident_goals(_goals), do: {:error, :invalid_incident_goals}

  defp incident_goal?(
         %{"detail" => detail, "id" => id, "outcome" => outcome, "state" => state} = goal
       )
       when map_size(goal) == 4 and state in @goal_states do
    bounded_text(id, 120) == :ok and bounded_text(outcome, @goal_outcome) == :ok and
      optional_bounded_text(detail, @goal_outcome) == :ok
  end

  defp incident_goal?(_goal), do: false

  defp incident_signal_text(%{"firing" => nil, "total" => nil}), do: "not supplied"

  defp incident_signal_text(%{"firing" => firing, "total" => total}),
    do: "#{firing || 0} firing / #{total || 0} total"

  defp incident_generation(nil), do: :ok
  defp incident_generation(value), do: positive_integer(value)

  defp incident_thread(nil), do: ""
  defp incident_thread(value), do: " · thread `#{escape(value)}`"

  defp incident_source(
         %{
           "channel_ref" => channel_ref,
           "message_ref" => message_ref,
           "thread_ref" => thread_ref
         } = source
       )
       when map_size(source) == 3 do
    with :ok <- bounded_text(channel_ref, 256),
         :ok <- bounded_text(message_ref, 1_024) do
      optional_bounded_text(thread_ref, 1_024)
    end
  end

  defp incident_source(_source), do: {:error, :invalid_incident_source}

  defp incident_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Aincident-room:[0-9a-f-]{36}\z/, value),
      do: :ok,
      else: {:error, {:invalid_slack_render, :incident_room}}
  end
end

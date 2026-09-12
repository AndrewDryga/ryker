defmodule Responder.Slack.Renderer do
  @moduledoc """
  Renders host-owned state records into bounded Slack Block Kit.

  Model prose is emitted through Slack's standard `markdown` block while it
  fits Slack's cumulative Markdown bound. Oversized prose remains complete in
  inert plain-text sections. Interactive controls are created only from
  validated durable records, so model output cannot invent action IDs, button
  values, or confirmation flows.
  """

  alias Responder.Emisar.ApprovalStatus
  alias Responder.Publication.Card, as: PublicationCard
  alias Responder.Slack.{Mentions, ReplyRecords, TaskCardDetails}
  alias Responder.State.{InvestigationPayload, RecordPayload}

  @maximum_message_characters 20_000
  @maximum_markdown_characters 12_000
  @maximum_section_characters 3_000
  @maximum_blocks 50
  @maximum_records 64
  @maximum_button_characters 75
  @reference ~r/\A(?:record|publication):[A-Za-z0-9_.:-]{1,240}\z/
  @investigation_kinds ~w(evidence coverage finding progress goal goal_state alert_assessment)
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
  @confirmation_kinds ~w(automation_change_offer guidance_offer memory_offer preference_offer schedule_offer standing_assignment_offer)
  @saved_entity_kinds ~w(schedule standing_rule preference guidance memory)
  @saved_entity_statuses ~w(active paused disabled completed expired deleted superseded)
  @publication_controls ~w(publish open check retry update discard)
  @setup_statuses ~w(asking confirming saved cancelled expired)
  @setup_steps ~w(participation repository alerts audience confirm)

  @doc false
  @spec presentation_contract() :: map()
  def presentation_contract do
    record_states =
      [
        "emisar_approval:open",
        "task_offer:open",
        "task_offer:confirmed",
        "publication_offer:open",
        "automation_change_offer:open",
        "schedule_offer:open",
        "memory_offer:open",
        "slack_post_offer:open",
        "slack_post_offer:confirmed",
        "preference_offer:open",
        "guidance_offer:open",
        "standing_assignment_offer:open",
        "input_request:open",
        "input_request:answered",
        "input_request:dismissed",
        "input_request:superseded",
        "event_wait:open",
        "publication_review:open",
        "publication_result:confirmed"
      ] ++
        Enum.map(@confirmation_kinds, &"#{&1}:confirmed") ++
        Enum.flat_map(@investigation_kinds, fn kind ->
          ["#{kind}:open", "#{kind}:confirmed"]
        end)

    %{
      incident_statuses: @incident_statuses,
      record_states: record_states,
      setup_statuses: @setup_statuses,
      setup_steps: @setup_steps,
      task_statuses: @task_statuses
    }
  end

  @spec render(map()) :: {:ok, map()} | {:error, term()}
  def render(%{"emisar_approval_status" => status} = document) when map_size(document) == 1 do
    render_emisar_approval_status(status)
  end

  def render(%{"incident_room" => room} = document) when map_size(document) == 1 do
    render_incident_room(room)
  end

  def render(%{"task_card" => task} = document) when map_size(document) == 1 do
    render_task_card(task)
  end

  def render(%{"channel_setup" => setup} = document) when map_size(document) == 1 do
    with {:ok, blocks, text} <- render_channel_setup(setup) do
      {:ok, %{"blocks" => blocks, "text" => text}}
    end
  end

  def render(%{"channel_welcome" => welcome} = document) when map_size(document) == 1 do
    render_channel_welcome(welcome)
  end

  def render(%{"channel_settings" => view} = document) when map_size(document) == 1 do
    render_channel_settings(view)
  end

  def render(%{"saved_entity" => entity} = document) when map_size(document) == 1 do
    case saved_entity(entity) do
      :ok ->
        {:ok, %{"blocks" => saved_entity_blocks(entity), "text" => saved_entity_text(entity)}}

      {:error, _reason} ->
        {:error, {:invalid_slack_render, :saved_entity}}
    end
  end

  def render(%{"message" => message} = document) when map_size(document) == 1,
    do: render(%{"message" => message, "records" => []})

  def render(
        %{
          "message" => message,
          "records" => records,
          "slack_mentions" => authority
        } = document
      )
      when map_size(document) == 3 do
    with :ok <- message(message),
         :ok <- records(records),
         {:ok, text} <- Mentions.render(message, authority),
         {:ok, record_blocks} <- render_records(records),
         :ok <- block_count(text, record_blocks) do
      {:ok,
       %{
         "blocks" => message_blocks(text) ++ record_blocks,
         "text" => text
       }}
    else
      {:error, {:invalid_slack_mentions, _reason}} ->
        {:error, {:invalid_slack_render, :mentions}}

      {:error, _reason} = error ->
        error
    end
  end

  def render(%{"message" => message, "records" => records} = document)
      when map_size(document) == 2 do
    with :ok <- message(message),
         :ok <- records(records),
         {:ok, record_blocks} <- render_records(records) do
      text = neutralize_control_syntax(message)

      with :ok <- block_count(text, record_blocks) do
        {:ok,
         %{
           "blocks" => message_blocks(text) ++ record_blocks,
           "text" => text
         }}
      end
    end
  end

  def render(_document), do: {:error, {:invalid_slack_render, :document}}

  defp render_emisar_approval_status(status) do
    case ApprovalStatus.prepare(status) do
      {:ok, status} ->
        review = ApprovalStatus.review_summary(status)

        {:ok,
         %{
           "blocks" =>
             emisar_review_blocks(
               status,
               review,
               "emisar-approval:#{status["request_id"]}"
             ),
           "text" => emisar_review_text(status, review)
         }}

      _invalid ->
        {:error, {:invalid_slack_render, :emisar_approval_status}}
    end
  end

  # One governed-review message, whether it is being posted from the durable
  # record or repainted from the authoritative poll. Both render the same card,
  # so the operator watches one message change rather than reading two designs.
  defp emisar_review_blocks(status, review, block_ref) do
    review_facts = status["review"] || %{}

    rationale = [
      section("*Emisar review*"),
      emisar_rationale("Reason", review_facts["reason"]),
      emisar_rationale("Evidence", review_facts["evidence"]),
      emisar_rationale("Expected outcome", review_facts["expected"])
    ]

    # The immutable refs stay one authorized link away: this card leads with the
    # human decision, not with machine provenance.
    identity = [
      section("*Runner*\n`#{mrkdwn(status["runner_ref"])}`"),
      emisar_status_block(status, review),
      emisar_review_actions(status, block_ref)
    ]

    Enum.reject(
      rationale ++ emisar_command_blocks(status, review_facts) ++ identity,
      &is_nil/1
    )
  end

  defp emisar_rationale(_heading, nil), do: nil
  defp emisar_rationale(heading, text), do: section("*#{heading}*\n#{mrkdwn(text)}")

  # `Command to run` is said only for a trusted, secret-masked preview Emisar
  # stands behind, and `Executed command` only for a real run receipt. With
  # neither, the card names the action it is reviewing and says how many
  # arguments stayed in Emisar — it never reconstructs a command line.
  defp emisar_command_blocks(_status, %{"command" => %{} = command}) do
    heading = if command["kind"] == "executed", do: "Executed command", else: "Command to run"

    [
      section("*#{heading}*"),
      code_block(command["text"]),
      if(command["truncated"], do: context("Command truncated · the full command is in Emisar."))
    ]
  end

  defp emisar_command_blocks(status, review_facts) do
    [
      section("*Action*"),
      code_block(status["action_id"]),
      emisar_argument_note(review_facts["argument_count"])
    ]
  end

  defp emisar_argument_note(count) when is_integer(count) and count > 0,
    do: context("#{count} #{plural(count, "argument", "arguments")} in Emisar.")

  defp emisar_argument_note(_count), do: nil

  # Current status first, one blank line, then the decisions oldest first — one
  # event per line, with a terminal decision left where it happened.
  defp emisar_status_block(status, nil),
    do: section("*Status*\n#{mrkdwn(ApprovalStatus.label(status["status"]))}")

  defp emisar_status_block(_status, %{summary: summary, history: history}) do
    section(
      "*Status*\n" <>
        Enum.join([mrkdwn(summary) | history_lines(history)], "\n")
    )
  end

  defp history_lines([]), do: []
  defp history_lines(history), do: ["" | Enum.map(history, &mrkdwn/1)]

  # Review happens in Emisar, so its link is the card's primary action while a
  # decision is still open; afterwards the same message links the decided record.
  defp emisar_review_actions(status, block_ref) do
    open? = pending_review?(status)

    buttons =
      [
        status["approval_url"] &&
          url_button(
            "responder_open_emisar_approval",
            if(open?, do: "Review in Emisar", else: "Open in Emisar"),
            status["request_id"],
            status["approval_url"]
          )
          |> maybe_button_style(if(open?, do: "primary")),
        status["run_url"] &&
          url_button(
            "responder_open_emisar_run",
            "Open exact run",
            status["run_id"],
            status["run_url"]
          )
      ]
      |> Enum.reject(&is_nil/1)

    actions(block_ref, buttons)
  end

  defp pending_review?(%{"review" => %{"status" => status}}), do: status == "pending"
  defp pending_review?(%{"status" => status}), do: status == "pending_approval"

  defp emisar_review_text(status, nil),
    do: "Emisar review · #{status["action_id"]} · #{ApprovalStatus.label(status["status"])}"

  defp emisar_review_text(status, %{summary: summary}),
    do: "Emisar review · #{status["action_id"]} · #{summary}"

  defp code_block(text) do
    %{
      "type" => "rich_text",
      "elements" => [
        %{
          "type" => "rich_text_preformatted",
          "elements" => [
            %{"type" => "text", "text" => truncate(text, @maximum_section_characters)}
          ]
        }
      ]
    }
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp render_incident_room(
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
          section("*Incident · #{mrkdwn(title)}*\n_Status: #{mrkdwn(label)}_"),
          section(mrkdwn(summary)),
          section(
            "Severity: *#{mrkdwn(severity)}* · Signals: #{mrkdwn(signal_text)}\nRepository: `#{mrkdwn(repository)}` · Episode: `#{mrkdwn(episode_state)}` · Session: `#{session_text}`"
          ),
          incident_alert_block(alert),
          incident_goals_block(goals),
          incident_action_block(action_needed),
          work_controls_block(room_ref, controls, :incident),
          section(
            "Source: channel `#{mrkdwn(source["channel_ref"])}` · message `#{mrkdwn(source["message_ref"])}`#{incident_thread(source["thread_ref"])}\nOpened by: `#{mrkdwn(opened_by)}` · Incident: `#{mrkdwn(short)}`"
          ),
          section(
            "_Opened #{mrkdwn(opened_at)} · Updated #{mrkdwn(updated_at)}. This pinned card is the durable status anchor; the linked episode owns the work and authority._"
          )
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, %{"blocks" => blocks, "text" => text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :incident_room}}
    end
  end

  defp render_incident_room(_room), do: {:error, {:invalid_slack_render, :incident_room}}

  # "What have we actually established" is the whole question on an incident
  # card, and it carried only a prose summary. Each goal with where it stands,
  # bounded, in the order the investigation set them.
  defp incident_goals_block([]), do: nil

  defp incident_goals_block(goals) do
    rendered =
      Enum.map_join(goals, "\n", fn goal ->
        "#{TaskCardDetails.goal_glyph(goal["state"])} #{mrkdwn(goal["outcome"])}#{incident_goal_detail(goal["detail"])}"
      end)

    section("*What this investigation is establishing*\n#{rendered}")
  end

  defp incident_goal_detail(nil), do: ""
  defp incident_goal_detail(detail), do: " · #{mrkdwn(detail)}"

  defp render_task_card(
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
         :ok <- task_publication(publication),
         :ok <- work_controls(controls),
         :ok <- positive_integer(ui_revision),
         :ok <- iso8601(confirmed_at),
         :ok <- iso8601(updated_at) do
      label = task_status_label(status)

      short = task_ref |> String.split(":") |> List.last() |> String.slice(0, 8)

      text =
        "Engineering task #{short}: #{title}. #{label}. #{summary}" <>
          if(action_needed, do: " Action needed: #{action_needed}", else: "")

      blocks =
        ([section("*#{mrkdwn(title)}*")] ++
           TaskCardDetails.blocks(task) ++
           [fact_fields([{"Repository", %{"ref" => repository, "url" => repository_url}}])] ++
           task_publication_blocks(task_ref, repository, publication) ++
           [
             incident_action_block(action_needed),
             work_controls_block(task_ref, controls, :task, task["resume_ref"]),
             TaskCardDetails.context("_Updated #{display_time(updated_at)}_")
           ])
        |> Enum.reject(&is_nil/1)

      {:ok, %{"blocks" => blocks, "text" => text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :task_card}}
    end
  end

  defp render_task_card(_task), do: {:error, {:invalid_slack_render, :task_card}}

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
      do: [plain_button("responder_work_record", "Open evidence", "#{work_ref}|evidence")],
      else: []
  end

  defp evidence_button(_work_ref, _controls, _kind), do: []

  defp work_button("stop", work_ref, _kind) do
    button(
      "responder_stop_work",
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
      "responder_resume_work",
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
      "responder_close_work",
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
      "responder_close_work",
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
      "action_id" => "responder_work_record",
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
  defp task_status_label("reviewing"), do: "Review or publication in progress"
  defp task_status_label("ready_to_publish"), do: "Reviewed and ready for operator publication"
  defp task_status_label("published"), do: "Draft pull request published"
  defp task_status_label("completed"), do: "Completed"
  defp task_status_label("cancelled"), do: "Closed"

  defp task_publication(nil), do: :ok

  defp task_publication(
         %{
           "branch" => branch,
           "controls" => controls,
           "publication_ref" => publication_ref,
           "pull_request_number" => number,
           "pull_request_url" => url,
           "recovery_generation" => recovery_generation,
           "status" => status,
           "unverified" => unverified
         } = publication
       )
       when map_size(publication) == 8 do
    with :ok <- bounded_text(status, 120),
         :ok <- optional_bounded_text(branch, 512),
         :ok <- publication_controls(controls),
         :ok <- optional_publication_reference(publication_ref),
         :ok <- optional_positive_integer(number),
         :ok <- optional_positive_integer(recovery_generation),
         :ok <- optional_bounded_text(unverified, 500),
         :ok <- optional_https_url(url) do
      publication_control_identity(
        controls,
        publication_ref,
        number,
        url,
        recovery_generation
      )
    end
  end

  defp task_publication(_publication), do: {:error, :invalid_task_publication}

  defp task_publication_blocks(_task_ref, _repository, nil), do: []

  defp task_publication_blocks(task_ref, repository, %{
         "branch" => branch,
         "controls" => controls,
         "publication_ref" => publication_ref,
         "pull_request_number" => number,
         "pull_request_url" => url,
         "recovery_generation" => recovery_generation,
         "status" => status,
         "unverified" => unverified
       }) do
    detail =
      if is_binary(url) and is_integer(number),
        do: " · <#{url}|Open draft PR ##{number}>",
        else: ""

    summary =
      section(
        "#{publication_status_message(status, controls, unverified)}#{detail}#{publication_branch_line(status, branch)}"
      )

    buttons =
      Enum.map(controls, fn
        "publish" ->
          button(
            "responder_task_publish",
            "Create draft PR",
            "#{task_ref}|#{publication_ref}",
            "primary",
            "Create draft pull request",
            publish_confirmation(repository, unverified),
            "Create draft PR"
          )

        "open" ->
          url_button("responder_open_publication", "Open PR", publication_ref, url)

        "check" ->
          plain_button(
            "responder_task_check",
            "Check delivery",
            "#{task_ref}|#{publication_ref}"
          )

        "retry" ->
          button(
            "responder_task_retry_publication",
            "Retry publication",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            "primary",
            "Retry publication workflow",
            "Retry this exact failed publication generation without changing its frozen review state?",
            "Retry"
          )

        "update" ->
          button(
            "responder_task_update_publication",
            "Review latest state",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            nil,
            "Review latest repository state",
            "Invalidate this exact review and run a new review against the latest repository state?",
            "Review latest"
          )

        "discard" ->
          button(
            "responder_task_discard_publication",
            "Discard candidate",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            "danger",
            "Discard publication candidate",
            "Discard this exact publication generation? Its review and remote evidence remain retained, but Responder will stop updating it.",
            "Discard"
          )
      end)

    if buttons == [],
      do: [summary],
      else: [summary, actions("#{task_ref}:publication", buttons)]
  end

  # A draft-authorized task never rests in "reviewed": its checks passing is
  # enough for the draft the confirming person already granted. What is left
  # here is a candidate nobody granted a draft for.
  defp publication_status_message("reviewed", _controls, _unverified),
    do:
      "The changes passed their checks. I don't have a draft-PR grant for this task, so open the draft when you want one."

  defp publication_status_message("blocked", controls, unverified) do
    if "publish" in controls and is_binary(unverified) do
      "I couldn't finish the checks (#{unverified}). The exact change is saved, so I can open it as an explicitly unverified draft pull request, or check the latest state again."
    else
      "PR creation is blocked. Review the latest state to check the changes again, or discard this candidate to stop publishing it."
    end
  end

  defp publication_status_message("published", _controls, nil),
    do: "Draft PR created. Open it to review the changes."

  # A draft opened because a check could not run stays explicitly unverified
  # after it exists. Saying only "open it to review the changes" is how an
  # unrun gate reads as a checked change one message later.
  defp publication_status_message("published", _controls, unverified),
    do:
      "Draft PR created from the saved change, but the checks still haven't finished (#{unverified}). It isn't verified, and a draft doesn't merge or deploy anything."

  defp publication_status_message("published_ready", _controls, _unverified),
    do: "Draft PR created. Sending the publication update."

  defp publication_status_message("discarded", _controls, _unverified),
    do: "PR preparation stopped. The review history is saved."

  defp publication_status_message(status, controls, _unverified) do
    cond do
      "retry" in controls -> "PR preparation stopped after an error. Retry the saved step below."
      status == "publish_pending" -> "Creating the draft PR. Waiting for GitHub to confirm."
      true -> "Checking the changes before creating a PR."
    end
  end

  defp publish_confirmation(repository, nil),
    do:
      "Publish the exact reviewed candidate to #{repository} as a draft pull request? This does not merge or deploy it."

  defp publish_confirmation(repository, unverified),
    do:
      "Open a draft pull request in #{repository} from this exact saved change? The checks did not finish (#{unverified}). A draft does not waive them, and it does not merge or deploy anything."

  # Which branch is stuck is a fact the host holds and the card withheld, so
  # "PR creation is blocked" sent the reader to a web console this installation
  # publishes no URL for. Only the blocked state needs it: every other state
  # either links the pull request or has no branch worth naming yet.
  defp publication_branch_line("blocked", branch) when is_binary(branch) and branch != "",
    do: " · `#{branch}`"

  defp publication_branch_line(_status, _branch), do: ""

  defp publication_controls(controls) when is_list(controls) do
    if controls == Enum.uniq(controls) and length(controls) <= length(@publication_controls) and
         Enum.all?(controls, &(&1 in @publication_controls)),
       do: :ok,
       else: {:error, :invalid_publication_controls}
  end

  defp publication_controls(_controls), do: {:error, :invalid_publication_controls}

  defp publication_control_identity(
         controls,
         publication_ref,
         number,
         url,
         recovery_generation
       ) do
    valid =
      Enum.all?(controls, fn
        "publish" ->
          is_binary(publication_ref)

        "open" ->
          is_binary(publication_ref) and is_integer(number) and is_binary(url)

        "check" ->
          is_binary(publication_ref) and is_integer(number) and is_binary(url)

        action when action in ~w(retry update discard) ->
          is_binary(publication_ref) and is_integer(recovery_generation)
      end)

    if valid, do: :ok, else: {:error, :invalid_publication_controls}
  end

  defp optional_publication_reference(nil), do: :ok

  defp optional_publication_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/, value),
      do: :ok,
      else: {:error, :invalid_publication_reference}
  end

  defp optional_positive_integer(nil), do: :ok
  defp optional_positive_integer(value), do: positive_integer(value)

  defp optional_https_url(nil), do: :ok

  defp optional_https_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        bounded_text(value, 2_048)

      _invalid ->
        {:error, :invalid_https_url}
    end
  end

  defp optional_https_url(_value), do: {:error, :invalid_https_url}

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
    section("*Latest alert assessment · #{mrkdwn(verdict)}*\n#{mrkdwn(impact)}")
  end

  defp incident_action_block(nil), do: nil
  defp incident_action_block(value), do: section(":warning: *Action needed*\n#{mrkdwn(value)}")

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
  defp incident_thread(value), do: " · thread `#{mrkdwn(value)}`"

  defp positive_integer(value) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, :invalid_datetime}
    end
  end

  defp iso8601(_value), do: {:error, :invalid_datetime}

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

  defp saved_entity_blocks(entity) do
    title = "*#{mrkdwn(entity["title"])}*"

    body =
      case entity["instructions"] do
        nil -> title
        instructions -> "#{title}\n#{mrkdwn(instructions)}"
      end

    [section(body), fact_fields(Enum.map(entity["facts"], &List.to_tuple/1))] ++
      [context(saved_entity_context(entity))] ++ saved_entity_controls(entity)
  end

  defp saved_entity_text(entity) do
    facts =
      Enum.map_join(entity["facts"], "\n", fn [label, value] ->
        "#{heading(label)}: #{fact_text(value)}"
      end)

    "#{entity["notice"]}: #{entity["title"]}\n#{entity["instructions"] || ""}\n#{facts}"
  end

  defp saved_entity_context(entity) do
    saved_by =
      case entity["saved_by"] do
        "slack:user:" <> user_ref -> "saved by #{mention(user_ref)}"
        other -> "saved by `#{mrkdwn(other)}`"
      end

    "#{mrkdwn(entity["notice"])} · #{saved_by} · #{display_time(entity["saved_at"])}"
  end

  defp saved_entity_controls(%{"removable" => false}), do: []

  defp saved_entity_controls(%{"kind" => "memory", "ref" => ref, "title" => title}) do
    [
      actions("#{ref}:controls", [
        button(
          "responder_forget_memory",
          "Forget memory",
          ref,
          "danger",
          "Forget this memory?",
          "I'll stop recalling “#{title}”. Messages I already sent and the original conversation stay as they are.",
          "Forget memory"
        )
      ])
    ]
  end

  defp saved_entity_controls(
         %{
           "kind" => kind,
           "ref" => ref,
           "revision" => revision,
           "title" => title
         } = entity
       ) do
    {label, action_id, value, consequence} =
      case kind do
        "schedule" ->
          {"Delete schedule", "responder_delete_schedule", "schedule-control:#{ref}:#{revision}",
           "Stop future runs of “#{title}”. Already-started work and its history remain."}

        "standing_rule" ->
          {"Delete rule", "responder_delete_behavior", "behavior-control:#{ref}:#{revision}",
           "Stop reacting to “#{title}”. Work it already started and its history remain."}

        "preference" ->
          {"Delete preference", "responder_delete_behavior",
           "behavior-control:#{ref}:#{revision}",
           "Stop applying “#{title}”. Replies I already sent stay as they are."}

        "guidance" ->
          {"Delete guidance", "responder_delete_behavior", "behavior-control:#{ref}:#{revision}",
           "Stop following “#{title}”. Replies I already sent stay as they are."}
      end

    [
      actions(
        "#{ref}:controls",
        resume_control(entity) ++
          [button(action_id, label, value, "danger", "#{label}?", consequence, label)]
      )
    ]
  end

  # A paused rule governs nothing until someone restarts it, and App Home was
  # the only surface that could — one most readers of a channel's list cannot
  # act in. It sits beside the entity's own control, never instead of it.
  defp resume_control(%{"resumable" => true, "ref" => ref, "revision" => revision} = entity) do
    [
      button(
        "responder_resume_behavior",
        "Resume",
        "behavior-control:#{ref}:#{revision}",
        nil,
        "Resume this rule?",
        "I'll start reacting to “#{entity["title"]}” again from now on. Nothing that happened while it was paused is replayed.",
        "Resume"
      )
    ]
  end

  defp resume_control(_entity), do: []

  defp saved_entity(
         %{
           "facts" => facts,
           "instructions" => instructions,
           "kind" => kind,
           "notice" => notice,
           "ref" => ref,
           "removable" => removable,
           "resumable" => resumable,
           "revision" => revision,
           "saved_at" => saved_at,
           "saved_by" => saved_by,
           "status" => status,
           "title" => title
         } = entity
       )
       when map_size(entity) == 12 do
    valid =
      kind in @saved_entity_kinds and status in @saved_entity_statuses and
        is_boolean(removable) and is_boolean(resumable) and
        saved_entity_texts?(title, instructions, notice, saved_by) and
        match?({:ok, _, 0}, DateTime.from_iso8601(saved_at)) and
        saved_entity_ref?(kind, ref, revision) and saved_entity_facts?(facts)

    if valid, do: :ok, else: {:error, :invalid_saved_entity}
  end

  defp saved_entity(_entity), do: {:error, :invalid_saved_entity}

  defp saved_entity_texts?(title, instructions, notice, saved_by) do
    text?(title) and String.length(title) <= 300 and
      (is_nil(instructions) or (text?(instructions) and String.length(instructions) <= 2_000)) and
      text?(notice) and text?(saved_by)
  end

  defp saved_entity_ref?("memory", "memory:" <> _rest = ref, nil), do: entity_ref?(ref)

  defp saved_entity_ref?("schedule", "schedule:" <> _rest = ref, revision),
    do: entity_ref?(ref) and positive?(revision)

  defp saved_entity_ref?(kind, "behavior:" <> _rest = ref, revision)
       when kind in ~w(standing_rule preference guidance),
       do: entity_ref?(ref) and positive?(revision)

  defp saved_entity_ref?(_kind, _ref, _revision), do: false

  defp entity_ref?(ref), do: Regex.match?(~r/\A[a-z]+:[A-Za-z0-9_.:-]{1,240}\z/, ref)

  defp positive?(value), do: is_integer(value) and value > 0

  defp saved_entity_facts?(facts) when is_list(facts) and length(facts) <= 10 do
    Enum.all?(facts, fn
      [label, %{"channel_ref" => channel_ref} = value] when map_size(value) == 1 ->
        text?(label) and is_binary(channel_ref)

      [label, value] ->
        text?(label) and text?(value) and String.length(value) <= 1_000

      _other ->
        false
    end)
  end

  defp saved_entity_facts?(_facts), do: false

  defp render_channel_welcome(
         %{
           "bot_user_ref" => bot_user_ref,
           "configuration_ref" => configuration_ref,
           "notice" => notice,
           "revision" => revision,
           "settings" => settings
         } = welcome
       )
       when map_size(welcome) == 5 and is_integer(revision) and revision > 0 do
    with {:ok, _uuid} <- Ecto.UUID.cast(configuration_ref),
         :ok <- slack_user(bot_user_ref),
         :ok <- optional_notice(notice),
         :ok <- channel_settings(settings) do
      paragraphs = welcome_paragraphs(settings, bot_user_ref, notice)
      value = "#{configuration_ref}|#{revision}"

      blocks =
        Enum.map(paragraphs, &section/1) ++
          [actions("welcome:#{configuration_ref}", welcome_buttons(settings, value))]

      {:ok, %{"blocks" => blocks, "text" => welcome_text(settings, notice)}}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_welcome}}
    end
  end

  defp render_channel_welcome(_welcome), do: {:error, {:invalid_slack_render, :channel_welcome}}

  defp render_channel_settings(
         %{
           "audience" => audience,
           "bot_user_ref" => bot_user_ref,
           "configuration_ref" => configuration_ref,
           "revision" => revision,
           "settings" => settings
         } = view
       )
       when map_size(view) == 5 and audience in ~w(private thread) do
    with :ok <- slack_user(bot_user_ref),
         :ok <- optional_configuration_identity(configuration_ref, revision),
         :ok <- channel_settings(settings) do
      facts = settings_facts(settings)

      blocks =
        [section("*#{heading("Channel settings")}*"), fact_fields(facts)] ++
          settings_context(settings) ++
          settings_controls(audience, configuration_ref, revision)

      text =
        Enum.map_join(facts, "\n", fn {label, value} ->
          "#{heading(label)}: #{fact_text(value)}"
        end)

      {:ok, %{"blocks" => blocks, "text" => "Channel settings\n" <> text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_settings}}
    end
  end

  defp render_channel_settings(_view), do: {:error, {:invalid_slack_render, :channel_settings}}

  # Welcome and settings prose is generated from the same effective-settings
  # projection, so the hello, the post-Q&A re-render and settings on request
  # can never disagree about what Responder does in a channel.
  defp welcome_paragraphs(settings, bot_user_ref, notice) do
    [
      "Hey there, I'm your AI teammate. I'm here to help with work in this channel.",
      repository_access(settings),
      "*#{heading("How to work with me")}*\n" <>
        conversation_sentence(settings, bot_user_ref) <>
        "\n\n" <> alert_sentence(settings),
      "*#{heading("What I can help with")}*\n" <>
        "• *Tasks* — “Add per-worker memory metrics to the website.” I'll plan the work, implement it, run checks and open a draft PR.\n" <>
        "• *Scheduled tasks* — “Check our infrastructure every morning and flag any issues.”\n" <>
        "• *Standing rules* — “Review new Terraform deployments, summarize the plan and release changes, and watch applies for failures.”",
      welcome_closing(settings, notice)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp welcome_text(settings, notice) do
    [
      "Hey there, I'm your AI teammate. I'm here to help with work in this channel.",
      participation_summary(settings),
      alert_summary(settings),
      notice_fallback(notice)
    ]
    |> compact_lines()
  end

  defp repository_access(%{"repositories" => []}),
    do:
      "I don't have access to any repos, so please connect one (or more) if you want me to work on coding tasks."

  defp repository_access(%{"repositories" => [repository]} = settings),
    do:
      "I have access to 1 repository: #{repository_link(repository)}." <>
        default_repository_sentence(settings)

  defp repository_access(%{"repositories" => repositories} = settings) do
    links = Enum.map(repositories, &repository_link/1)
    {head, [last]} = Enum.split(links, -1)

    "I have access to #{length(repositories)} repositories: #{Enum.join(head, ", ")} and #{last}." <>
      default_repository_sentence(settings)
  end

  defp default_repository_sentence(%{"default_repository" => nil}), do: ""

  defp default_repository_sentence(%{"default_repository" => ref, "repositories" => repositories}) do
    case Enum.find(repositories, &(&1["ref"] == ref)) do
      nil ->
        ""

      repository ->
        " I'll use #{repository_link(repository)} for coding tasks when you don't name one."
    end
  end

  defp conversation_sentence(%{"observation" => %{"on" => true}}, bot_user_ref),
    do:
      "I'm watching quietly for now — reading along to learn how this channel works, and staying out of the conversation. Mention #{mention(bot_user_ref)} whenever you want me in it."

  defp conversation_sentence(%{"participation" => %{"value" => "proactive"}}, bot_user_ref),
    do:
      "Talk to me like any other teammate. I'll read the messages I can access here to build useful knowledge and join conversations when I can help. You can also mention #{mention(bot_user_ref)} directly."

  defp conversation_sentence(_settings, bot_user_ref),
    do:
      "Talk to me like any other teammate. I'll read the messages I can access here to build useful knowledge. In conversations, I'll reply when you mention #{mention(bot_user_ref)}."

  defp alert_sentence(%{"observation" => %{"on" => true}}),
    do:
      "Alerts posted here go into that reading too, and I'll wait to be asked before looking into one."

  defp alert_sentence(%{"alert_policy" => "reply"}),
    do:
      "When an alert is posted here, I'll investigate proactively in its thread and share what I find."

  defp alert_sentence(%{"alert_policy" => "offer"} = settings),
    do:
      "When an alert needs investigation, I'll offer to investigate in its thread or create a dedicated incident room. If you choose a room, I'll invite #{audience_phrase(settings)}."

  defp alert_sentence(%{"alert_policy" => "automatic"} = settings),
    do:
      "When an alert needs investigation, I'll automatically create an incident room and invite #{audience_phrase(settings)}."

  defp welcome_closing(settings, notice) do
    [override_sentence(settings), notice_line(notice)] |> compact_lines()
  end

  # The fallback line is read aloud and shown in notifications, where a mention
  # is noise rather than a link.
  defp notice_fallback(nil), do: nil

  defp notice_fallback(%{"at" => at}) do
    {:ok, changed_at, 0} = DateTime.from_iso8601(at)
    "Settings changed at #{Calendar.strftime(changed_at, "%H:%M UTC")}."
  end

  defp notice_fallback(notice), do: neutralize_control_syntax(notice)

  defp notice_line(nil),
    do: "You're ready to go. Use the buttons below if you'd like to change how I work."

  defp notice_line(%{"actor_ref" => actor, "at" => at}) do
    {:ok, changed_at, 0} = DateTime.from_iso8601(at)
    "*Settings changed by #{mention(actor)} at #{Calendar.strftime(changed_at, "%H:%M UTC")}*"
  end

  defp notice_line(notice), do: "*#{neutralize_control_syntax(notice)}*"

  defp override_sentence(%{"participation" => %{"source" => "channel", "value" => value}})
       when value in ~w(proactive shadow) do
    setting = if value == "shadow", do: "shadow", else: "proactive"

    "This channel has its own `#{setting}` setting, so it no longer follows the installation default. `/responder #{setting} inherit` returns it to the default."
  end

  defp override_sentence(_settings), do: nil

  defp welcome_buttons(%{"participation" => %{"source" => "incident_room"}}, value),
    do: [plain_button("responder_welcome_configure", "Configure channel", value)]

  defp welcome_buttons(%{"participation" => %{"value" => "shadow"}}, value),
    do: [plain_button("responder_welcome_configure", "Configure channel", value)]

  defp welcome_buttons(%{"participation" => %{"value" => "proactive"}}, value),
    do: [
      plain_button("responder_welcome_mentions_only", "Mentions only", value),
      plain_button("responder_welcome_configure", "Customize", value)
    ]

  defp welcome_buttons(_settings, value),
    do: [
      "responder_welcome_be_proactive"
      |> plain_button("Be proactive", value)
      |> maybe_button_style("primary"),
      plain_button("responder_welcome_configure", "Customize", value)
    ]

  defp settings_facts(settings) do
    [
      {"Conversations", participation_summary(settings)},
      {"Alerts", alert_summary(settings)},
      {"Repositories", repositories_fact(settings)},
      {"Default repository", default_repository_fact(settings)},
      {"Incident invitations", {:markup, String.capitalize(audience_phrase(settings))}},
      {"Observation mode", observation_fact(settings)}
    ]
  end

  defp participation_summary(%{"observation" => %{"on" => true}}), do: "Observe without replying"

  defp participation_summary(%{"participation" => %{"value" => "proactive"}}),
    do: "Join when useful"

  defp participation_summary(_settings), do: "Reply when mentioned"

  defp alert_summary(%{"observation" => %{"on" => true}}), do: "No proactive investigations"
  defp alert_summary(%{"alert_policy" => "reply"}), do: "Investigate in the existing thread"
  defp alert_summary(%{"alert_policy" => "offer"}), do: "Offer an in-place task or incident room"

  defp alert_summary(%{"alert_policy" => "automatic"}),
    do: "Create an incident room automatically"

  defp repositories_fact(%{"repositories" => []}), do: "None connected"
  defp repositories_fact(%{"repositories" => repositories}), do: repositories

  defp default_repository_fact(%{"default_repository" => nil}), do: "None"

  defp default_repository_fact(%{"default_repository" => ref, "repositories" => repositories}),
    do: Enum.find(repositories, %{"ref" => ref, "url" => nil}, &(&1["ref"] == ref))

  defp observation_fact(%{"observation" => %{"on" => true, "source" => "incident_room"}}),
    do: "On (incident room)"

  defp observation_fact(%{"observation" => %{"on" => true}}), do: "On"
  defp observation_fact(_settings), do: "Off"

  defp audience_phrase(%{"invitations" => invitations}) do
    chosen =
      Enum.map(invitations["user_refs"], &mention/1) ++
        Enum.map(invitations["user_group_refs"], &group_mention/1)

    case chosen do
      [] -> "no one automatically — you can add people yourself"
      chosen -> join_names(chosen)
    end
  end

  defp join_names([name]), do: name

  defp join_names(names) do
    {head, [last]} = Enum.split(names, -1)
    Enum.join(head, ", ") <> " and " <> last
  end

  defp settings_context(settings) do
    origin =
      case settings do
        %{"participation" => %{"source" => "channel"}, "customized_by" => nil} ->
          "a `/responder` setting saved for this channel"

        %{"participation" => %{"source" => "incident_room"}} ->
          "this is an incident room"

        %{"customized_by" => nil} ->
          "defaults; nobody has customized this channel yet"

        %{"customized_by" => actor_ref} ->
          "saved by #{mention(actor_ref)}"
      end

    [context("Effective settings · #{origin}")]
  end

  defp settings_controls(_audience, nil, _revision), do: []

  # The private command reply can only carry Configure channel: list controls
  # post cards into a thread, and an ephemeral reply has no thread to post in.
  defp settings_controls(audience, configuration_ref, revision) do
    value = "#{configuration_ref}|#{revision}"

    lists =
      if audience == "thread",
        do: [
          plain_button("responder_welcome_view_schedules", "View schedules", value),
          plain_button("responder_welcome_view_rules", "View standing rules", value)
        ],
        else: []

    [
      actions("settings:#{configuration_ref}", [
        "responder_welcome_configure"
        |> plain_button("Configure channel", value)
        |> maybe_button_style("primary")
        | lists
      ])
    ]
  end

  @settings_sources ~w(channel incident_room installation)

  defp channel_settings(
         %{
           "alert_policy" => alert_policy,
           "configuration_ref" => configuration_ref,
           "customized_by" => customized_by,
           "default_repository" => default_repository,
           "invitations" => invitations,
           "observation" => observation,
           "participation" => participation,
           "repositories" => repositories,
           "revision" => revision
         } = settings
       )
       when map_size(settings) == 9 do
    valid =
      alert_policy in ~w(reply offer automatic) and
        settings_participation?(participation) and
        settings_observation?(observation) and
        settings_invitations?(invitations) and
        settings_repositories?(repositories, default_repository) and
        (is_nil(customized_by) or slack_reference?(customized_by)) and
        optional_configuration_identity(configuration_ref, revision) == :ok

    if valid, do: :ok, else: {:error, :invalid_channel_settings}
  end

  defp channel_settings(_settings), do: {:error, :invalid_channel_settings}

  defp settings_participation?(%{"source" => source, "value" => value} = participation)
       when map_size(participation) == 2,
       do: source in @settings_sources and value in ~w(mentions proactive shadow)

  defp settings_participation?(_participation), do: false

  defp settings_observation?(%{"on" => on, "source" => source} = observation)
       when map_size(observation) == 2,
       do: is_boolean(on) and source in @settings_sources

  defp settings_observation?(_observation), do: false

  defp settings_invitations?(%{"user_group_refs" => groups, "user_refs" => users} = invitations)
       when map_size(invitations) == 2 and is_list(groups) and is_list(users),
       do: Enum.all?(users ++ groups, &slack_reference?/1)

  defp settings_invitations?(_invitations), do: false

  defp settings_repositories?(repositories, default_repository)
       when is_list(repositories) and length(repositories) <= 32 do
    Enum.all?(repositories, &repository?/1) and
      (is_nil(default_repository) or
         Enum.any?(repositories, &(&1["ref"] == default_repository)))
  end

  defp settings_repositories?(_repositories, _default_repository), do: false

  defp optional_configuration_identity(nil, nil), do: :ok

  defp optional_configuration_identity(configuration_ref, revision)
       when is_integer(revision) and revision > 0 do
    case Ecto.UUID.cast(configuration_ref) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_channel_settings}
    end
  end

  defp optional_configuration_identity(_configuration_ref, _revision),
    do: {:error, :invalid_channel_settings}

  defp optional_notice(nil), do: :ok

  # Who changed the settings is a host fact, so it is carried as one: free text
  # is escaped against invented mentions, and this exact pair is the only shape
  # that may render a real one.
  defp optional_notice(%{"actor_ref" => actor, "at" => at} = notice) when map_size(notice) == 2 do
    with :ok <- slack_user(actor),
         {:ok, _at, 0} <- DateTime.from_iso8601(at) do
      :ok
    else
      _invalid -> {:error, :invalid_notice}
    end
  end

  defp optional_notice(notice) do
    if text?(notice) and String.length(notice) <= 200, do: :ok, else: {:error, :invalid_notice}
  end

  defp repository?(%{"ref" => ref, "url" => url} = repository) when map_size(repository) == 2,
    do: text?(ref) and byte_size(ref) <= 256 and (is_nil(url) or optional_https_url(url) == :ok)

  defp repository?(_repository), do: false

  defp slack_user(value),
    do: if(slack_reference?(value), do: :ok, else: {:error, :invalid_slack_user})

  defp slack_reference?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Z0-9]{1,64}\z/, value)

  # A repository is a typed link: label and URL are separate values. Ordinary
  # text is escaped and never becomes clickable Slack markup.
  defp repository_link(%{"ref" => ref, "url" => nil}), do: "`#{mrkdwn(ref)}`"

  defp repository_link(%{"ref" => ref, "url" => url}),
    do: "<#{mrkdwn(url)}|#{ref |> mrkdwn() |> String.replace("|", "&#124;")}>"

  defp mention(user_ref), do: "<@#{user_ref}>"
  defp group_mention(group_ref), do: "<!subteam^#{group_ref}>"

  # All owned structural headings share one colonless renderer.
  defp heading(label), do: label |> String.trim() |> String.trim_trailing(":")

  defp fact_fields(facts) do
    %{
      "fields" =>
        Enum.map(facts, fn {label, value} ->
          %{"text" => "*#{heading(label)}*\n#{fact_markdown(value)}", "type" => "mrkdwn"}
        end),
      "type" => "section"
    }
  end

  # Fact values are escaped text unless the host typed them: a repository link,
  # a channel reference, or markup it assembled itself from validated refs.
  defp fact_markdown(values) when is_list(values),
    do: Enum.map_join(values, "\n", &fact_markdown/1)

  defp fact_markdown(%{"ref" => _ref} = repository), do: repository_link(repository)
  defp fact_markdown(%{"channel_ref" => channel_ref}), do: channel_mention(channel_ref)
  defp fact_markdown({:markup, text}), do: text
  defp fact_markdown(value), do: mrkdwn(value)

  defp fact_text(values) when is_list(values), do: Enum.map_join(values, ", ", &fact_text/1)
  defp fact_text(%{"ref" => ref}), do: ref
  defp fact_text(%{"channel_ref" => channel_ref}), do: channel_mention(channel_ref)
  defp fact_text({:markup, text}), do: text
  defp fact_text(value), do: neutralize_control_syntax(value)

  defp channel_mention(channel_ref) do
    if slack_reference?(channel_ref), do: "<##{channel_ref}>", else: "`#{mrkdwn(channel_ref)}`"
  end

  defp render_channel_setup(
         %{
           "bot_user_ref" => bot_user_ref,
           "draft" => draft,
           "expires_at" => expires_at,
           "revision" => revision,
           "session_ref" => session_ref,
           "status" => status,
           "step" => step
         } = setup
       )
       when map_size(setup) == 7 and status in @setup_statuses and step in @setup_steps and
              is_integer(revision) and revision > 0 and is_map(draft) do
    with :ok <- slack_user(bot_user_ref),
         {:ok, _uuid} <- Ecto.UUID.cast(session_ref),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(expires_at),
         {:ok, blocks, text} <-
           setup_blocks(status, step, draft, session_ref, %{
             bot_user_ref: bot_user_ref,
             expires_at: expires_at
           }) do
      {:ok, blocks, text}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_setup}}
    end
  end

  defp render_channel_setup(_setup), do: {:error, {:invalid_slack_render, :channel_setup}}

  # Every step explains each option before asking for a choice. The bold label
  # is the exact button label; the sentence says what Responder will do.
  defp setup_blocks("asking", "participation", _draft, session_ref, presentation) do
    text = "When should I join conversations?"

    explanation =
      [
        "*#{heading("1 · Conversations")}*",
        text,
        "",
        "*Mentions only* — I'll read along to learn about your team's work, but I'll only join a conversation when you mention #{mention(presentation.bot_user_ref)}.",
        "",
        "*Be proactive* — I'll read the messages in this channel and join in when I think you could use my help. You can still mention me whenever you need me.",
        "",
        "*Observe only* — I'll keep reading and learning, but I won't reply, even if you mention me. I also won't start alert investigations while this is on."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(explanation),
       actions("setup:#{session_ref}", [
         setup_button(
           "responder_setup_participation_mentions",
           "Mentions only",
           session_ref,
           nil
         ),
         setup_button(
           "responder_setup_participation_proactive",
           "Be proactive",
           session_ref,
           nil
         ),
         setup_button("responder_setup_participation_shadow", "Observe only", session_ref, nil)
       ])
     ], text}
  end

  defp setup_blocks(
         "asking",
         "repository",
         %{"repository_options" => repositories},
         session_ref,
         _presentation
       )
       when is_list(repositories) and length(repositories) in 1..32 do
    buttons =
      repositories
      |> Enum.with_index()
      |> Enum.map(fn {repository, index} ->
        setup_button(
          "responder_setup_repository_#{index}",
          truncate(repository, @maximum_button_characters),
          session_ref,
          nil
        )
      end)

    text = "Which repo should I use for coding tasks when you don't name one?"

    explanation =
      [
        "*#{heading("2 · Repositories")}*",
        text,
        "",
        Enum.map_join(repositories, "   ", &"*#{mrkdwn(&1)}*"),
        "",
        "You can still ask me to work in any other connected repo. This only sets the default; it doesn't give me access to anything new."
      ]

    {:ok, [section(Enum.join(explanation, "\n"))] ++ setup_action_groups(session_ref, buttons),
     text}
  end

  defp setup_blocks("asking", "alerts", _draft, session_ref, _presentation) do
    text = "When an alert needs attention, should I open an incident room for it?"

    explanation =
      [
        "*#{heading("3 · Alerts")}*",
        text,
        "",
        "*Investigate here* — I'll look into it in the alert's own thread and share what I find. This is the default.",
        "",
        "*Offer a room* — I'll start in the thread, and offer a room when the alert looks big enough to need one.",
        "",
        "*Always open a room* — every alert I investigate gets its own room, and I'll work there."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(explanation),
       actions("setup:#{session_ref}", [
         setup_button("responder_setup_alerts_reply", "Investigate here", session_ref, nil),
         setup_button("responder_setup_alerts_offer", "Offer a room", session_ref, nil),
         setup_button(
           "responder_setup_alerts_automatic",
           "Always open a room",
           session_ref,
           "danger"
         )
       ])
     ], text}
  end

  defp setup_blocks("asking", "audience", _draft, session_ref, _presentation) do
    text = "Who should I invite when I open an incident room?"

    explanation =
      [
        "*#{heading("4 · Invitations")}*",
        text,
        "",
        "Reply in this thread with the people or user groups you want in the room, as @mentions. I'll remember them for the next one in this channel, and you can change them any time.",
        "",
        "If you'd rather invite people yourself each time, choose *Nobody automatically*."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(explanation),
       actions(
         "setup:#{session_ref}",
         setup_button("responder_setup_audience_none", "Nobody automatically", session_ref, nil)
       )
     ], text}
  end

  defp setup_blocks("confirming", "confirm", draft, session_ref, presentation) do
    case setup_draft?(draft) do
      true -> setup_confirmation(draft, session_ref, presentation)
      false -> {:error, {:invalid_slack_render, :channel_setup}}
    end
  end

  defp setup_blocks("saved", _step, _draft, _session_ref, _presentation),
    do:
      {:ok, [section("*Settings saved.* I've updated my welcome message to match.")],
       "Settings saved. I've updated my welcome message to match."}

  defp setup_blocks("cancelled", _step, _draft, _session_ref, _presentation),
    do:
      {:ok, [section("*Setup cancelled.* Your settings haven't changed.")],
       "Setup cancelled. Your settings haven't changed."}

  defp setup_blocks("expired", _step, _draft, _session_ref, _presentation),
    do:
      {:ok,
       [
         section(
           "*Setup expired.* Your settings haven't changed. Use *Customize* on my welcome message to start again."
         )
       ], "Setup expired. Your settings haven't changed."}

  defp setup_blocks(_status, _step, _draft, _session_ref, _presentation),
    do: {:error, {:invalid_slack_render, :channel_setup}}

  defp setup_confirmation(draft, session_ref, presentation) do
    text = "Here's how I'll work in this channel:"

    summary =
      [
        "*#{heading("5 · Confirm")}*",
        text,
        "• " <> draft_participation_sentence(draft["participation"], presentation.bot_user_ref),
        "• " <> draft_alert_sentence(draft["alert_policy"]),
        "• I'll use *#{mrkdwn(draft["repository_ref"])}* for coding tasks when you don't name a repo.",
        "• If I create an incident room, I'll invite #{draft_audience_phrase(draft)}.",
        "",
        "*Save settings* — I'll start using these choices and update my welcome message to match.",
        "",
        "*Start over* — Go back to the first question and change your choices before saving.",
        "",
        "*Cancel* — I'll leave your current settings as they are."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(summary),
       actions("setup:#{session_ref}", [
         setup_button("responder_setup_save", "Save settings", session_ref, "primary"),
         setup_button("responder_setup_restart", "Start over", session_ref, nil),
         setup_button("responder_setup_cancel", "Cancel", session_ref, "danger")
       ])
     ], text}
  end

  defp draft_participation_sentence("mentions", bot_user_ref),
    do: "I'll reply when you mention #{mention(bot_user_ref)}."

  defp draft_participation_sentence("proactive", _bot_user_ref),
    do: "I'll join conversations when I think you could use my help."

  defp draft_participation_sentence("shadow", _bot_user_ref),
    do: "I'll observe without replying or starting alert investigations."

  defp draft_alert_sentence("reply"),
    do: "When an alert needs investigation, I'll work in its thread."

  defp draft_alert_sentence("offer"),
    do:
      "When an alert needs investigation, I'll ask whether to work in its thread or create an incident room."

  defp draft_alert_sentence("automatic"),
    do: "When an alert needs investigation, I'll create an incident room automatically."

  defp draft_audience_phrase(draft) do
    audience_phrase(%{
      "invitations" => %{
        "user_group_refs" => draft["invite_user_group_refs"],
        "user_refs" => draft["invite_user_refs"]
      }
    })
  end

  defp setup_draft?(draft) do
    draft["participation"] in ~w(mentions proactive shadow) and
      draft["alert_policy"] in ~w(reply offer automatic) and
      is_binary(draft["repository_ref"]) and draft["repository_ref"] != "" and
      is_list(draft["invite_user_refs"]) and is_list(draft["invite_user_group_refs"]) and
      Enum.all?(draft["invite_user_refs"] ++ draft["invite_user_group_refs"], &slack_reference?/1)
  end

  defp setup_action_groups(session_ref, buttons) do
    buttons
    |> Enum.chunk_every(5)
    |> Enum.with_index()
    |> Enum.map(fn {group, index} -> actions("setup:#{session_ref}:#{index}", group) end)
  end

  defp setup_button(action_id, label, session_ref, style) do
    %{
      "action_id" => action_id,
      "text" => plain_text(label),
      "type" => "button",
      "value" => session_ref
    }
    |> maybe_button_style(style)
  end

  defp records(values) when is_list(values) and length(values) <= @maximum_records do
    if Enum.count(values, &(is_map(&1) and &1["kind"] not in @investigation_kinds)) <= 20,
      do: :ok,
      else: {:error, {:invalid_slack_render, :records}}
  end

  defp records(_values), do: {:error, {:invalid_slack_render, :records}}

  defp block_count(text, record_blocks) do
    if length(message_blocks(text)) + length(record_blocks) <= @maximum_blocks,
      do: :ok,
      else: {:error, {:invalid_slack_render, :blocks}}
  end

  defp render_records(records) do
    result =
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, blocks} ->
        case render_record(record) do
          {:ok, rendered} -> {:cont, {:ok, blocks ++ rendered}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, blocks} <- result, do: {:ok, blocks ++ source_blocks(records)}
  end

  defp render_record(
         %{"kind" => "evidence", "presentation" => %{"source_url" => url} = meta} = record
       )
       when map_size(record) == 5 and map_size(meta) == 1 do
    if ReplyRecords.safe_url?(url),
      do: render_record(Map.delete(record, "presentation")),
      else: {:error, {:invalid_slack_render, :record}}
  end

  defp render_record(
         %{"kind" => "event_wait", "presentation" => %{"next_check_at" => at} = meta} = record
       )
       when map_size(record) == 5 and map_size(meta) == 1 and is_binary(at) do
    with {:ok, _blocks} <- render_record(Map.delete(record, "presentation")),
         {:ok, _time, 0} <- DateTime.from_iso8601(at) do
      if record["status"] == "open",
        do: {:ok, event_wait_blocks(record["payload"], at)},
        else: {:ok, []}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(%{"kind" => kind} = record)
       when kind in ["publication_review", "publication_result"] do
    case PublicationCard.prepare_record(record) do
      {:ok, payload} -> {:ok, publication_blocks(kind, record["ref"], payload)}
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  # A confirmed offer keeps the saved entity's full detail and its exact
  # removal control on the message; the host attaches the entity projection
  # because the offer payload alone no longer describes what was saved.
  defp render_record(
         %{
           "kind" => kind,
           "payload" => payload,
           "presentation" => %{"entity" => entity} = presentation,
           "ref" => ref,
           "status" => "confirmed"
         } = record
       )
       when map_size(record) == 5 and map_size(presentation) == 1 and
              kind in @confirmation_kinds do
    with :ok <- reference(ref),
         {:ok, _prepared} <- RecordPayload.prepare(kind, payload, ref),
         :ok <- saved_entity(entity) do
      {:ok, saved_entity_blocks(entity)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "emisar_approval",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <-
           RecordPayload.prepare("emisar_approval", payload, ref) do
      {:ok, emisar_approval_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "task_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("task_offer", payload, ref) do
      {:ok, task_offer_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "task_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => "confirmed"
         } = record
       )
       when map_size(record) in [4, 5] do
    presentation = Map.get(record, "presentation", %{})

    with :ok <- reference(ref),
         :ok <- incident_room_presentation(presentation),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("task_offer", payload, ref) do
      {:ok, confirmed_task_offer_blocks(prepared, presentation)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "publication_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("publication_offer", payload, ref) do
      {:ok, publication_offer_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "automation_change_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <-
           RecordPayload.prepare("automation_change_offer", payload, ref),
         {:ok, blocks} <- automation_change_offer_blocks(ref, prepared) do
      {:ok, blocks}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "schedule_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("schedule_offer", payload, ref) do
      {:ok, schedule_offer_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "memory_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("memory_offer", payload, ref) do
      {:ok, memory_offer_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "slack_post_offer",
           "payload" => payload,
           "ref" => ref,
           "status" => status
         } = record
       )
       when map_size(record) in [4, 5] and status in ["open", "confirmed"] do
    # The host adds `message_url` once the post has actually landed; it is the
    # one key on this card the model never authored.
    url = Map.get(record, "message_url")

    with true <- Map.keys(record) -- ~w(kind payload ref status message_url) == [],
         :ok <- reference(ref),
         :ok <- optional_https_url(url),
         {:ok, %{payload: prepared}} <-
           RecordPayload.prepare("slack_post_offer", payload, ref) do
      {:ok, slack_post_offer_blocks(ref, Map.put(prepared, "message_url", url), status)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{"kind" => kind, "payload" => payload, "ref" => ref, "status" => "open"} = record
       )
       when map_size(record) == 4 and
              kind in ["preference_offer", "guidance_offer", "standing_assignment_offer"] do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare(kind, payload, ref) do
      {:ok, behavior_offer_blocks(kind, ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{"kind" => kind, "payload" => payload, "ref" => ref, "status" => status} = record
       )
       when map_size(record) == 4 and kind in @investigation_kinds and
              status in ["open", "confirmed", "superseded", "dismissed"] do
    with :ok <- reference(ref),
         {:ok, _prepared} <- RecordPayload.prepare(kind, payload, ref) do
      {:ok, []}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "input_request",
           "payload" => payload,
           "ref" => ref,
           "status" => status
         } = record
       )
       when map_size(record) == 4 and status in ["open", "answered", "dismissed", "superseded"] do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("input_request", payload, ref) do
      if status == "open" do
        {:ok, input_request_blocks(ref, prepared)}
      else
        {:ok,
         [
           %{"type" => "section", "text" => plain_text(prepared["question"])},
           context(question_status(status))
         ]}
      end
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "event_wait",
           "payload" => payload,
           "ref" => ref,
           "status" => status
         } = record
       )
       when map_size(record) == 4 and status in ["open", "answered", "superseded", "dismissed"] do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("event_wait", payload, ref) do
      {:ok, if(status == "open", do: event_wait_blocks(prepared), else: [])}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(_record), do: {:error, {:invalid_slack_render, :record}}

  defp task_offer_blocks(ref, %{"kind" => "engineering", "repository" => repository} = offer) do
    summary =
      ["*#{mrkdwn(offer["title"])}*\nRepository: `#{mrkdwn(repository)}`#{offer_source(offer)}"] ++
        offer_brief(offer)

    [
      section(Enum.join(summary, "\n")),
      actions(ref, engineering_button(ref, repository))
    ]
  end

  # One offer owns both incident paths; the host starts exactly one of them.
  defp task_offer_blocks(ref, %{
         "kind" => "incident",
         "repository" => repository,
         "title" => title
       }) do
    summary =
      case repository do
        nil -> "*#{mrkdwn(title)}*"
        value -> "*#{mrkdwn(title)}*\nRepository: `#{mrkdwn(value)}`"
      end

    [
      section(summary),
      actions(ref, [investigate_button(ref), incident_button(ref)])
    ]
  end

  # What the task will do, from the fields the host validated. The offer's
  # `prompt` is the worker's own instruction and never appears here: this card
  # carries a button that grants authority, and d98b1d9f keeps model-authored
  # instructions off that surface. Checks, limits and the exact source say what
  # is being authorized without quoting what the worker was told.
  defp offer_brief(%{"success_checks" => checks, "authority_limits" => limits} = offer)
       when is_list(checks) and is_list(limits) do
    [
      offer_list("Checks", checks, 4),
      offer_list("Will not", limits, 4),
      offer_sources(offer["source_refs"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp offer_brief(_offer), do: []

  defp offer_list(_label, [], _limit), do: nil

  defp offer_list(label, values, limit) do
    shown = values |> Enum.take(limit) |> Enum.map_join("; ", &truncate(mrkdwn(&1), 200))
    remainder = length(values) - min(length(values), limit)
    more = if remainder > 0, do: " · #{remainder} more", else: ""
    "*#{label}:* #{shown}#{more}"
  end

  defp offer_sources(refs) when is_list(refs) and refs != [],
    do: "*Evidence:* #{length(refs)} sources"

  defp offer_sources(_refs), do: nil

  defp offer_source(%{"repository_source" => %{"kind" => kind, "name" => name}})
       when is_binary(kind) and is_binary(name),
       do: " · #{mrkdwn(kind)} `#{mrkdwn(name)}`"

  defp offer_source(_offer), do: ""

  defp confirmed_task_offer_blocks(%{"kind" => "engineering", "title" => title}, _presentation),
    do: [section("*#{mrkdwn(title)}*\n✓ Task started in this thread.")]

  defp confirmed_task_offer_blocks(%{"title" => title}, %{"incident_room" => %{"url" => url}})
       when is_binary(url) do
    [
      section("*#{mrkdwn(title)}*\n✓ Incident room created."),
      actions(
        "incident-room-link",
        url_button("responder_open_incident_room", "Open incident room", "room", url)
      )
    ]
  end

  defp confirmed_task_offer_blocks(%{"title" => title}, %{"incident_room" => _room}),
    do: [section("*#{mrkdwn(title)}*\n◷ Incident room requested · creating the channel")]

  defp confirmed_task_offer_blocks(%{"title" => title}, _presentation),
    do: [section("*#{mrkdwn(title)}*\n✓ Investigating in this thread.")]

  defp incident_room_presentation(presentation) when map_size(presentation) == 0, do: :ok

  defp incident_room_presentation(%{"incident_room" => %{"url" => url} = room} = presentation)
       when map_size(presentation) == 1 and map_size(room) == 1,
       do: optional_https_url(url)

  defp incident_room_presentation(_presentation),
    do: {:error, :invalid_incident_room_presentation}

  # The first card of a governed review, before the monitor has polled anything.
  # It is the SAME card the authoritative status repaints, so the operator sees
  # one message gain its decisions rather than two different designs.
  defp emisar_approval_blocks(ref, payload) do
    status = Map.merge(payload, %{"remote_error" => nil, "review" => nil, "run_url" => nil})

    emisar_review_blocks(status, ApprovalStatus.review_summary(status), ref)
  end

  defp engineering_button(ref, repository) do
    confirmation =
      "Start this task for #{repository} in an isolated working copy where Emisar can edit, test, and commit?"

    button(
      "responder_start_engineering_task",
      "Start task",
      ref,
      "primary",
      "Start engineering task",
      confirmation,
      "Start task"
    )
  end

  defp investigate_button(ref) do
    button(
      "responder_investigate_incident",
      "Investigate",
      ref,
      "primary",
      "Investigate in this thread",
      "Start read-only investigation work in this thread. No incident room is created and nobody is invited.",
      "Investigate"
    )
  end

  defp incident_button(ref) do
    button(
      "responder_open_incident",
      "Create incident room",
      ref,
      "danger",
      "Create incident room",
      "Create a coordinated incident room for this work and invite the configured responders?",
      "Create room"
    )
  end

  defp publication_offer_blocks(ref, %{"body" => body, "title" => title}) do
    summary =
      "*#{mrkdwn(title)}*\n#{mrkdwn(body)}\n_No branch or pull request has been published._"

    [
      section(summary),
      actions(
        ref,
        button(
          "responder_review_publication",
          "Review changes",
          ref,
          "primary",
          "Review committed changes",
          "Run the trusted read-only Coop review for this exact committed workspace? This does not publish a branch or pull request.",
          "Run review"
        )
      )
    ]
  end

  defp schedule_offer_blocks(ref, payload) do
    scope =
      case payload["repository"] do
        nil -> payload["authority"]
        repository -> "#{payload["authority"]} · #{repository}"
      end

    expiry = payload["expires_at"] || "no expiry"

    summary =
      [
        "*#{mrkdwn(payload["title"])}*",
        mrkdwn(payload["task"]),
        "When: `#{mrkdwn(schedule_description(payload["recurrence"]))}`",
        "Timezone: `#{mrkdwn(payload["timezone"])}` · Catch-up: `#{payload["catch_up"]}`",
        "Scope: `#{mrkdwn(scope)}` · Expires: `#{mrkdwn(expiry)}`",
        "_This is only an offer; no schedule exists yet._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        button(
          "responder_confirm_schedule",
          "Schedule this",
          ref,
          "primary",
          "Create recurring work",
          "Create this exact schedule at the shown destination and authority ceiling? Each occurrence rechecks current policy.",
          "Schedule this"
        )
      )
    ]
  end

  defp automation_change_offer_blocks(ref, payload) do
    review =
      [
        "Automation #{payload["action"]} · #{payload["automation_id"]} · revision #{payload["revision"]}",
        "",
        "Before",
        Jason.encode!(payload["before"], pretty: true),
        "",
        "After",
        Jason.encode!(payload["after"], pretty: true),
        "",
        "Nothing changes until an operator confirms this exact revision."
      ]
      |> Enum.join("\n")

    {:ok,
     plain_message_blocks(review) ++
       [
         actions(
           ref,
           button(
             "responder_confirm_automation",
             automation_change_label(payload["action"]),
             ref,
             automation_change_style(payload["action"]),
             "Confirm automation change",
             "Apply this exact before/after change? The host will reject it if the automation revision or destination changed.",
             "Apply change"
           )
         )
       ]}
  end

  defp automation_change_label("update"), do: "Update automation"
  defp automation_change_label("pause"), do: "Pause automation"
  defp automation_change_label("resume"), do: "Resume automation"
  defp automation_change_label("delete"), do: "Delete automation"

  defp automation_change_style(action) when action in ~w(pause delete), do: "danger"
  defp automation_change_style(_action), do: "primary"

  defp schedule_description(%{"kind" => "once", "at" => at}), do: "once at #{at}"

  defp schedule_description(%{
         "kind" => "interval",
         "every_seconds" => seconds,
         "starts_at" => starts_at
       }),
       do: "every #{seconds}s" <> if(starts_at, do: " from #{starts_at}", else: "")

  defp schedule_description(%{"kind" => "daily", "time" => time}), do: "daily at #{time}"

  defp schedule_description(%{"kind" => "weekly", "weekday" => weekday, "time" => time}),
    do: "every #{weekday} at #{time}"

  defp schedule_description(%{"kind" => "monthly", "day" => day, "time" => time}),
    do: "monthly on day #{day} at #{time}"

  defp slack_post_offer_blocks(ref, payload, "open") do
    destination = payload["destination_ref"]

    summary =
      [
        "*Additional Slack post requires confirmation*",
        "Destination: `#{mrkdwn(destination)}`",
        mrkdwn(payload["message"]),
        "_No message has been posted. Only the original requester can authorize this exact destination and message._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        button(
          "responder_confirm_slack_post",
          "Post this message",
          ref,
          "primary",
          "Confirm additional Slack post",
          "Post this exact message to #{destination}?",
          "Post message"
        )
      )
    ]
  end

  defp slack_post_offer_blocks(_ref, payload, "confirmed") do
    [section(confirmed_slack_post_summary(payload))]
  end

  # Until the host could build a message link this card said the worker was
  # "sending or reconciling" the post forever, even long after it had landed.
  # The link is the only honest way to say it is sent.
  defp confirmed_slack_post_summary(%{"message_url" => url} = payload) when is_binary(url) do
    "*Additional Slack post sent*\nDestination: `#{mrkdwn(payload["destination_ref"])}` · <#{url}|Open message>"
  end

  defp confirmed_slack_post_summary(payload) do
    "*Additional Slack post confirmed*\nDestination: `#{mrkdwn(payload["destination_ref"])}`\n_The durable delivery worker is sending or reconciling this exact message._"
  end

  defp behavior_offer_blocks("preference_offer", ref, payload) do
    repository = if payload["repository"], do: " · `#{mrkdwn(payload["repository"])}`", else: ""

    summary =
      [
        "*Behavior preference*",
        "`#{payload["key"]}=#{payload["value"]}`",
        "Scope: `#{payload["scope"]}`#{repository} · Expires: `#{payload["expires_in"]}`",
        "_This is only an offer; behavior has not changed._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Confirm preference")]
  end

  defp behavior_offer_blocks("guidance_offer", ref, payload) do
    repository = if payload["repository"], do: " · `#{mrkdwn(payload["repository"])}`", else: ""

    summary =
      [
        "*Remember guidance · #{mrkdwn(payload["subject"])}*",
        mrkdwn(payload["text"]),
        "Scope: `#{payload["scope"]}`#{repository} · Visibility: `#{payload["visibility"]}` · Expires: `#{payload["expires_in"]}`",
        "_Advisory only: this cannot trigger work, prove a fact, or grant authority._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Remember this")]
  end

  defp behavior_offer_blocks(
         "standing_assignment_offer",
         ref,
         %{"source_kind" => source_kind} = payload
       ) do
    repository = payload["repository"] || "no repository binding"
    expiry = payload["expires_at"] || "until disabled"

    summary =
      [
        "*Source-event automation · #{mrkdwn(payload["title"])}*",
        mrkdwn(payload["task"]),
        "Source event: `#{mrkdwn(source_kind)}` · Filter: `#{mrkdwn(Jason.encode!(payload["filter"]))}`",
        "Context/delivery: `#{mrkdwn(payload["context_channel"])}` · Repository: `#{mrkdwn(repository)}`",
        "Catch-up: `#{payload["catch_up"]}` · Expires: `#{mrkdwn(expiry)}`",
        "_Read-only initiative in this channel; it cannot approve, publish, deploy, or mutate infrastructure._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Enable automation")]
  end

  defp behavior_offer_blocks("standing_assignment_offer", ref, payload) do
    repository = payload["repository"] || "no repository binding"

    summary =
      [
        "*Standing assignment*",
        mrkdwn(payload["task"]),
        "Trigger: `#{payload["trigger"]}` → `#{payload["action"]}`",
        "Source: `#{payload["source_filter"]}` · Repository: `#{mrkdwn(repository)}` · Expires: `#{payload["expires_in"]}`",
        "_Read-only initiative in this channel; it cannot approve, publish, deploy, or mutate infrastructure._"
      ]
      |> compact_lines()

    [section(summary), behavior_actions(ref, "Enable assignment")]
  end

  defp memory_offer_blocks(ref, payload) do
    repository = if payload["repository"], do: " · `#{mrkdwn(payload["repository"])}`", else: ""

    summary =
      [
        "*Remember operational mapping · #{mrkdwn(payload["subject"])}*",
        mrkdwn(payload["value"]),
        "Kind: `#{payload["kind"]}` · Scope: `#{payload["scope"]}`#{repository}",
        "Visibility: `#{payload["visibility"]}` · Expires: `#{payload["expires_in"]}`",
        "_Potentially stale hint only: live evidence, current repositories, and host policy take precedence._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        button(
          "responder_confirm_memory",
          "Remember this",
          ref,
          "primary",
          "Remember operational mapping",
          "Store this exact scoped mapping with its shown visibility, provenance, and expiry?",
          "Remember this"
        )
      )
    ]
  end

  defp behavior_actions(ref, label) do
    actions(
      ref,
      button(
        "responder_confirm_behavior",
        label,
        ref,
        "primary",
        label,
        "Confirm this exact bounded behavior, scope, and expiry?",
        label
      )
    )
  end

  defp publication_blocks("publication_review", ref, payload) do
    findings = payload["policy_findings"] ++ payload["reasons"]

    detail =
      [
        "*#{mrkdwn(payload["title"])}*",
        "Repository: `#{mrkdwn(payload["repository"])}`",
        "Gate: `#{mrkdwn(payload["gate"])}` · Rebase: `#{mrkdwn(payload["rebase"])}`",
        "Candidate tree: `#{payload["candidate_tree"]}`",
        "Patch: #{payload["patch_bytes"]} bytes",
        publication_findings(findings)
      ]
      |> compact_lines()

    blocks = [section(detail)]

    cond do
      payload["draft_authorized"] ->
        blocks ++
          [section("I'm opening the draft pull request for this candidate now.")]

      payload["publishable"] ->
        blocks ++
          [
            actions(
              ref,
              button(
                "responder_publish_draft",
                "Publish draft PR",
                ref,
                "primary",
                "Publish reviewed draft PR",
                "Publish only this exact reviewed candidate as a draft pull request? Merge and deployment remain separate external decisions.",
                "Publish draft"
              )
            )
          ]

      true ->
        blocks
    end
  end

  defp publication_blocks("publication_result", ref, payload) do
    [
      section(
        [
          "*Draft pull request published · #{mrkdwn(payload["title"])}*",
          "Repository: `#{mrkdwn(payload["repository"])}`",
          "PR: #{mrkdwn(payload["pull_request_url"])}",
          "Commit: `#{payload["commit_sha"]}`"
        ]
        |> compact_lines()
      ),
      actions(ref, [
        url_button(
          "responder_open_publication",
          "Open PR",
          ref,
          payload["pull_request_url"]
        ),
        button(
          "responder_check_publication",
          "Check delivery",
          ref,
          nil,
          "Check publication delivery",
          "Refresh this exact pull request, checks, merge, and correlated delivery state?",
          "Check now"
        )
      ])
    ]
  end

  defp publication_findings([]), do: nil

  defp publication_findings(findings),
    do: "Blocked by: " <> Enum.map_join(findings, ", ", &mrkdwn/1)

  defp input_request_blocks(ref, %{"choices" => choices, "question" => question} = payload) do
    question_block = %{
      "text" => plain_text(question),
      "type" => "section"
    }

    introduction = [question_block] ++ remembered_answer_notice(payload["remember"])

    case choices do
      [] ->
        introduction

      choices ->
        {details, options} = question_options(ref, choices)
        introduction ++ details ++ question_controls(ref, options)
    end
  end

  defp question_options(ref, choices) do
    numbered? = Enum.any?(choices, &(String.length(&1) > @maximum_button_characters))

    options =
      choices
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        label = if numbered?, do: "Option #{index + 1}", else: choice
        %{"text" => plain_text(label), "value" => "#{ref}|#{index}"}
      end)

    details =
      if numbered? do
        text =
          choices
          |> Enum.with_index(1)
          |> Enum.map_join("\n\n", fn {choice, index} -> "Option #{index}\n#{choice}" end)

        [%{"type" => "section", "text" => plain_text(text)}]
      else
        []
      end

    {details, options}
  end

  defp question_controls(ref, options) when length(options) <= 5 do
    elements =
      options
      |> Enum.with_index()
      |> Enum.map(fn {option, index} ->
        Map.merge(option, %{"type" => "button", "action_id" => "responder_answer_input_#{index}"})
      end)

    [%{"block_id" => ref, "elements" => elements, "type" => "actions"}]
  end

  defp question_controls(ref, options) do
    [
      %{
        "type" => "actions",
        "block_id" => ref,
        "elements" => [
          %{
            "type" => "radio_buttons",
            "action_id" => "responder_question_choice",
            "options" => options
          }
        ]
      },
      %{
        "type" => "actions",
        "block_id" => "#{ref}:submit",
        "elements" => [
          %{
            "type" => "button",
            "action_id" => "responder_submit_input",
            "text" => plain_text("Submit answer"),
            "value" => ref
          }
        ]
      },
      context("Choose one, then submit. You can also reply in this thread.")
    ]
  end

  defp remembered_answer_notice(%{"subject" => subject, "applicability" => applicability}) do
    [
      %{
        "type" => "context",
        "elements" => [
          plain_text(
            "I'll remember an operator's answer across conversations for #{subject} — #{applicability}."
          )
        ]
      }
    ]
  end

  defp remembered_answer_notice(_intent), do: []

  defp question_status("answered"), do: "Answered · reply retained separately"
  defp question_status("dismissed"), do: "Question closed"
  defp question_status("superseded"), do: "Replaced by a newer question"

  defp event_wait_blocks(payload, next_check \\ nil)
  defp event_wait_blocks(%{"deadline_at" => nil}, _next_check), do: []

  defp event_wait_blocks(%{"deadline_at" => deadline, "event_matcher" => matcher}, next_check) do
    next_check = next_check || scheduled_check(matcher)

    text =
      [
        earlier_check?(next_check, deadline) && "Next check #{slack_date(next_check)}",
        "Monitoring deadline #{slack_date(deadline)}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" · ")

    [context(text)]
  end

  defp scheduled_check(%{"type" => "source_event"} = matcher), do: matcher["poll_after"]
  defp scheduled_check(%{"type" => "at"} = matcher), do: matcher["at"]
  defp scheduled_check(_matcher), do: nil

  defp earlier_check?(nil, _deadline), do: false

  defp earlier_check?(at, deadline) do
    {:ok, at, 0} = DateTime.from_iso8601(at)
    {:ok, deadline, 0} = DateTime.from_iso8601(deadline)
    DateTime.compare(at, deadline) == :lt
  end

  defp slack_date(value) do
    {:ok, at, 0} = DateTime.from_iso8601(value)
    fallback = Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    "<!date^#{DateTime.to_unix(at)}^{date_short_pretty} at {time}|#{fallback}>"
  end

  defp source_blocks(records) do
    superseded =
      records
      |> Enum.filter(&(&1["kind"] == "evidence" and &1["status"] in ["open", "confirmed"]))
      |> Enum.flat_map(&(get_in(&1, ["payload", "supersedes"]) || []))
      |> MapSet.new()

    records
    |> Enum.filter(&(&1["kind"] == "evidence" and &1["status"] in ["open", "confirmed"]))
    |> Enum.reject(&MapSet.member?(superseded, &1["ref"]))
    |> Enum.flat_map(&source_link/1)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Enum.chunk_while("Sources", &source_chunk/2, fn
      "Sources" -> {:cont, []}
      text -> {:cont, text, []}
    end)
    |> Enum.map(&context/1)
  end

  defp source_chunk(link, text) do
    next = text <> " · " <> link

    if String.length(next) <= 3_000,
      do: {:cont, next},
      else: {:cont, text, "Sources · " <> link}
  end

  defp source_link(%{"payload" => payload} = record) do
    # Only the host-resolved receipt may become a link; the record's own source_id
    # is the model's claim about a destination, not proof that a tool returned it.
    url = get_in(record, ["presentation", "source_url"])
    label = payload["target"] || payload["source_name"]
    label = if label == payload["source_id"], do: "Source", else: label
    label = mrkdwn(label)

    if ReplyRecords.safe_url?(url) do
      link = "<#{mrkdwn(url)}|#{String.replace(label, "|", "&#124;")}>"
      if String.length(link) <= 2_980, do: [{url, link}], else: []
    else
      []
    end
  end

  defp context(text),
    do: %{"type" => "context", "elements" => [%{"type" => "mrkdwn", "text" => text}]}

  defp compact_lines(lines), do: lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")

  defp button(action_id, label, value, style, title, confirmation, confirm_label) do
    %{
      "action_id" => action_id,
      "confirm" => %{
        "confirm" => plain_text(confirm_label),
        "deny" => plain_text("Cancel"),
        "text" => plain_text(confirmation),
        "title" => plain_text(title)
      },
      "text" => plain_text(label),
      "type" => "button",
      "value" => value
    }
    |> maybe_button_style(style)
  end

  defp plain_button(action_id, label, value) do
    %{
      "action_id" => action_id,
      "text" => plain_text(label),
      "type" => "button",
      "value" => value
    }
  end

  defp url_button(action_id, label, value, url) do
    %{
      "action_id" => action_id,
      "text" => plain_text(label),
      "type" => "button",
      "url" => url,
      "value" => value
    }
  end

  defp maybe_button_style(button, nil), do: button
  defp maybe_button_style(button, style), do: Map.put(button, "style", style)

  defp message_blocks(text) do
    if String.length(text) <= @maximum_markdown_characters do
      [%{"text" => text, "type" => "markdown"}]
    else
      plain_message_blocks(text)
    end
  end

  defp plain_message_blocks(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(@maximum_section_characters)
    |> Enum.map(fn graphemes ->
      %{
        "text" => plain_text(Enum.join(graphemes)),
        "type" => "section"
      }
    end)
  end

  defp section(text) do
    %{
      "text" => %{"text" => truncate(text, @maximum_section_characters), "type" => "mrkdwn"},
      "type" => "section"
    }
  end

  defp actions(ref, buttons) when is_list(buttons) do
    %{
      "block_id" => ref,
      "elements" => buttons,
      "type" => "actions"
    }
  end

  defp actions(ref, button), do: actions(ref, [button])

  defp plain_text(text), do: %{"emoji" => true, "text" => text, "type" => "plain_text"}

  defp message(value) do
    if text?(value) and String.length(value) <= @maximum_message_characters,
      do: :ok,
      else: {:error, {:invalid_slack_render, :message}}
  end

  defp reference(value) do
    if is_binary(value) and Regex.match?(@reference, value),
      do: :ok,
      else: {:error, {:invalid_slack_render, :record}}
  end

  defp incident_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Aincident-room:[0-9a-f-]{36}\z/, value),
      do: :ok,
      else: {:error, {:invalid_slack_render, :incident_room}}
  end

  defp bounded_text(value, maximum) do
    if text?(value) and byte_size(value) <= maximum,
      do: :ok,
      else: {:error, {:invalid_slack_render, :incident_room}}
  end

  defp optional_bounded_text(nil, _maximum), do: :ok
  defp optional_bounded_text(value, maximum), do: bounded_text(value, maximum)

  defp text?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != ""
  end

  defp neutralize_control_syntax(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp mrkdwn(text), do: neutralize_control_syntax(text)

  defp display_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> Calendar.strftime(at, "%d %b, %H:%M UTC")
      _ -> mrkdwn(value)
    end
  end

  defp truncate(text, maximum) do
    graphemes = String.graphemes(text)

    if length(graphemes) <= maximum,
      do: text,
      else: graphemes |> Enum.take(maximum - 1) |> Enum.join() |> Kernel.<>("…")
  end
end

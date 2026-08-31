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
  alias Responder.Slack.{Mentions, WorkDiff}
  alias Responder.State.RecordPayload

  @maximum_message_characters 20_000
  @maximum_markdown_characters 12_000
  @maximum_section_characters 3_000
  @maximum_blocks 50
  @maximum_records 20
  @maximum_button_characters 75
  @reference ~r/\A(?:record|publication):[A-Za-z0-9_.:-]{1,240}\z/
  @investigation_kinds ~w(evidence coverage finding progress goal goal_state alert_assessment)
  @incident_statuses ~w(provisioning investigating action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)
  @task_statuses ~w(working waiting_for_input waiting_for_event action_required stopping reviewing ready_for_review ready_to_publish published completed cancelled)
  @work_controls ~w(stop view_diff close timeline evidence handoff postmortem)
  @record_controls ~w(timeline evidence handoff postmortem)
  @publication_controls ~w(readiness publish open check)
  @setup_statuses ~w(asking confirming saved cancelled expired)
  @setup_steps ~w(participation repository alerts audience confirm)

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

  def render(%{"work_diff" => diff} = document) when map_size(document) == 1 do
    render_work_diff(diff)
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
        label = ApprovalStatus.label(status["status"])

        summary =
          "Governed action #{status["action_id"]}: #{label}. " <>
            "Approval and policy decisions remain authoritative in Emisar."

        details =
          [
            "*Governed action · #{mrkdwn(status["action_id"])}*",
            "_Status: #{mrkdwn(label)}_",
            "Run: `#{mrkdwn(status["run_id"])}` · Runner: `#{mrkdwn(status["runner_ref"])}`",
            "Pack: `#{mrkdwn(status["pack_ref"])}`",
            approval_error_line(status["remote_error"]),
            "_Slack cannot approve this action._"
          ]
          |> compact_lines()

        buttons =
          [
            url_button(
              "responder_open_emisar_approval",
              "Review in Emisar",
              status["request_id"],
              status["approval_url"]
            ),
            status["run_url"] &&
              url_button(
                "responder_open_emisar_run",
                "Open exact run",
                status["run_id"],
                status["run_url"]
              )
          ]
          |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           "blocks" => [
             section(details),
             actions("emisar-approval:#{status["request_id"]}", buttons)
           ],
           "text" => summary
         }}

      _invalid ->
        {:error, {:invalid_slack_render, :emisar_approval_status}}
    end
  end

  defp approval_error_line(nil), do: nil
  defp approval_error_line(error), do: "Error: #{mrkdwn(error)}"

  defp render_work_diff(
         %{
           "message" => diff_message,
           "patch_bytes" => _patch_bytes,
           "patch_digest" => patch_digest,
           "patch_has_more" => patch_has_more,
           "patch_next_offset" => patch_next_offset,
           "patch_offset" => patch_offset,
           "work_ref" => work_ref
         } = diff
       )
       when map_size(diff) == 7 do
    with true <- valid_work_diff?(diff),
         :ok <- message(diff_message) do
      render_work_diff_document(
        diff_message,
        work_ref,
        patch_digest,
        patch_offset,
        patch_next_offset,
        patch_has_more
      )
    else
      _invalid -> {:error, {:invalid_slack_render, :work_diff}}
    end
  end

  defp render_work_diff(_diff), do: {:error, {:invalid_slack_render, :work_diff}}

  defp valid_work_diff?(diff) do
    Enum.all?([
      valid_work_ref?(diff["work_ref"]),
      valid_digest?(diff["patch_digest"]),
      non_negative_integer?(diff["patch_bytes"]),
      valid_offset?(diff["patch_offset"], 0, diff["patch_bytes"]),
      valid_offset?(diff["patch_next_offset"], diff["patch_offset"], diff["patch_bytes"]),
      is_boolean(diff["patch_has_more"]),
      diff["patch_has_more"] == diff["patch_next_offset"] < diff["patch_bytes"]
    ])
  end

  defp valid_work_ref?(value) do
    is_binary(value) and
      Regex.match?(~r/\A(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}\z/, value)
  end

  defp valid_digest?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_offset?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp render_work_diff_document(
         message,
         work_ref,
         digest,
         offset,
         next_offset,
         has_more
       ) do
    buttons = diff_page_buttons(work_ref, digest, offset, next_offset, has_more)
    block_ref = "work-diff:" <> String.slice(digest, 0, 24)

    {:ok,
     %{
       "blocks" => message_blocks(message) ++ [actions(block_ref, buttons)],
       "text" => message
     }}
  end

  defp diff_page_buttons(work_ref, digest, offset, next_offset, has_more) do
    previous_offset = max(offset - WorkDiff.page_bytes(), 0)

    [
      if(offset > 0, do: diff_page_button("Previous", work_ref, digest, previous_offset)),
      diff_page_button("Refresh", work_ref, digest, offset),
      if(has_more, do: diff_page_button("Next", work_ref, digest, next_offset))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp diff_page_button(label, work_ref, patch_digest, patch_offset) do
    value = "#{work_ref}|#{patch_digest}|#{patch_offset}"
    plain_button("responder_diff_page", label, value)
  end

  defp render_incident_room(
         %{
           "action_needed" => action_needed,
           "alert" => alert,
           "controls" => controls,
           "episode_state" => episode_state,
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
       when map_size(room) == 17 and is_map(source) and status in @incident_statuses do
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
           "status" => status,
           "summary" => summary,
           "task_ref" => task_ref,
           "title" => title,
           "ui_revision" => ui_revision,
           "updated_at" => updated_at,
           "work_state" => work_state
         } = task
       )
       when map_size(task) == 15 and status in @task_statuses do
    with :ok <- task_reference(task_ref),
         :ok <- bounded_text(confirmed_by, 1_024),
         :ok <- bounded_text(episode_state, 120),
         :ok <- bounded_text(repository, 256),
         :ok <- bounded_text(summary, 2_000),
         :ok <- bounded_text(title, 200),
         :ok <- optional_bounded_text(action_needed, 2_000),
         :ok <- optional_bounded_text(work_state, 120),
         :ok <- incident_generation(session_generation),
         :ok <- task_publication(publication),
         :ok <- work_controls(controls),
         :ok <- positive_integer(ui_revision),
         :ok <- iso8601(confirmed_at),
         :ok <- iso8601(updated_at) do
      label = task_status_label(status)

      session_text =
        if session_generation, do: Integer.to_string(session_generation), else: "pending"

      short = task_ref |> String.split(":") |> List.last() |> String.slice(0, 8)

      text =
        "Engineering task #{short}: #{title}. #{label}. #{summary}" <>
          if(action_needed, do: " Action needed: #{action_needed}", else: "")

      blocks =
        ([
           section("*Engineering task · #{mrkdwn(title)}*\n_Status: #{mrkdwn(label)}_"),
           section(mrkdwn(summary)),
           section(
             "Repository: `#{mrkdwn(repository)}` · Episode: `#{mrkdwn(episode_state)}` · Work: `#{mrkdwn(work_state || "not started")}` · Session: `#{session_text}`"
           )
         ] ++
           task_publication_blocks(task_ref, publication) ++
           [
             incident_action_block(action_needed),
             work_controls_block(task_ref, controls, :task),
             section(
               "_Confirmed by `#{mrkdwn(confirmed_by)}` at #{mrkdwn(confirmed_at)} · Updated #{mrkdwn(updated_at)}. Reply in this thread to continue the same isolated task._"
             )
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

  defp work_controls_block(_work_ref, [], _kind), do: nil

  defp work_controls_block(work_ref, controls, kind) do
    buttons =
      controls
      |> Enum.filter(&(&1 in ~w(stop view_diff close)))
      |> Enum.map(&work_button(&1, work_ref, kind))

    records = Enum.filter(controls, &(&1 in @record_controls))

    elements =
      if records == [],
        do: buttons,
        else: buttons ++ [work_record_overflow(work_ref, records)]

    actions("#{work_ref}:controls", elements)
  end

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

  defp work_button("view_diff", work_ref, _kind),
    do: plain_button("responder_view_diff", "View diff", work_ref)

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
        "postmortem" -> "Postmortem draft"
      end

    %{"text" => plain_text(label), "value" => "#{work_ref}|#{kind}"}
  end

  defp task_status_label("working"), do: "Working"
  defp task_status_label("waiting_for_input"), do: "Waiting for input"
  defp task_status_label("waiting_for_event"), do: "Waiting for verification"
  defp task_status_label("action_required"), do: "Action required"
  defp task_status_label("stopping"), do: "Stopping current work"
  defp task_status_label("reviewing"), do: "Review or publication in progress"
  defp task_status_label("ready_for_review"), do: "Changes ready for a readiness check"
  defp task_status_label("ready_to_publish"), do: "Reviewed and ready for operator publication"
  defp task_status_label("published"), do: "Draft pull request published"
  defp task_status_label("completed"), do: "Completed"
  defp task_status_label("cancelled"), do: "Closed"

  defp task_publication(nil), do: :ok

  defp task_publication(
         %{
           "controls" => controls,
           "publication_ref" => publication_ref,
           "pull_request_number" => number,
           "pull_request_url" => url,
           "review_offer_ref" => review_offer_ref,
           "status" => status
         } = publication
       )
       when map_size(publication) == 6 do
    with :ok <- bounded_text(status, 120),
         :ok <- publication_controls(controls),
         :ok <- optional_publication_reference(publication_ref),
         :ok <- optional_publication_offer_reference(review_offer_ref),
         :ok <- optional_positive_integer(number),
         :ok <- optional_https_url(url) do
      publication_control_identity(controls, publication_ref, review_offer_ref, number, url)
    end
  end

  defp task_publication(_publication), do: {:error, :invalid_task_publication}

  defp task_publication_blocks(_task_ref, nil), do: []

  defp task_publication_blocks(task_ref, %{
         "controls" => controls,
         "publication_ref" => publication_ref,
         "pull_request_number" => number,
         "pull_request_url" => url,
         "review_offer_ref" => review_offer_ref,
         "status" => status
       }) do
    detail =
      if is_binary(url) and is_integer(number),
        do: " · <#{url}|Open draft PR ##{number}>",
        else: ""

    summary = section("Publication: `#{mrkdwn(status)}`#{detail}")

    buttons =
      Enum.map(controls, fn
        "readiness" ->
          plain_button(
            "responder_task_readiness",
            "Run readiness check",
            "#{task_ref}|#{review_offer_ref}"
          )

        "publish" ->
          button(
            "responder_task_publish",
            "Create draft PR",
            "#{task_ref}|#{publication_ref}",
            "primary",
            "Create draft pull request",
            "Publish the exact reviewed candidate as a draft pull request? This does not merge or deploy it.",
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
      end)

    if buttons == [],
      do: [summary],
      else: [summary, actions("#{task_ref}:publication", buttons)]
  end

  defp publication_controls(controls) when is_list(controls) do
    if controls == Enum.uniq(controls) and length(controls) <= length(@publication_controls) and
         Enum.all?(controls, &(&1 in @publication_controls)),
       do: :ok,
       else: {:error, :invalid_publication_controls}
  end

  defp publication_controls(_controls), do: {:error, :invalid_publication_controls}

  defp publication_control_identity(controls, publication_ref, review_offer_ref, number, url) do
    valid =
      Enum.all?(controls, fn
        "readiness" -> is_nil(publication_ref) and is_binary(review_offer_ref)
        "publish" -> is_binary(publication_ref)
        "open" -> is_binary(publication_ref) and is_integer(number) and is_binary(url)
        "check" -> is_binary(publication_ref) and is_integer(number) and is_binary(url)
      end)

    if valid, do: :ok, else: {:error, :invalid_publication_controls}
  end

  defp optional_publication_reference(nil), do: :ok

  defp optional_publication_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/, value),
      do: :ok,
      else: {:error, :invalid_publication_reference}
  end

  defp optional_publication_offer_reference(nil), do: :ok

  defp optional_publication_offer_reference(value) do
    if is_binary(value) and
         Regex.match?(~r/\Arecord:publication_offer:[A-Za-z0-9_.:-]{1,220}\z/, value),
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

  defp render_channel_setup(
         %{
           "draft" => draft,
           "expires_at" => expires_at,
           "revision" => revision,
           "session_ref" => session_ref,
           "status" => status,
           "step" => step
         } = setup
       )
       when map_size(setup) == 6 and status in @setup_statuses and step in @setup_steps and
              is_integer(revision) and revision > 0 and is_map(draft) do
    with {:ok, _uuid} <- Ecto.UUID.cast(session_ref),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(expires_at),
         {:ok, blocks, text} <- setup_blocks(status, step, draft, session_ref, expires_at) do
      {:ok, blocks, text}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_setup}}
    end
  end

  defp render_channel_setup(_setup), do: {:error, {:invalid_slack_render, :channel_setup}}

  defp setup_blocks("asking", "participation", %{"customizing" => false}, session_ref, expires_at) do
    text =
      "Configure Emisar for this channel. Nothing is saved until an operator confirms it."

    blocks = [
      section("*Welcome to Emisar*\n#{text}\nSetup expires: `#{mrkdwn(expires_at)}`"),
      actions("setup:#{session_ref}", [
        setup_button(
          "responder_setup_safe_defaults",
          "Use safe defaults",
          session_ref,
          "primary"
        ),
        setup_button("responder_setup_be_proactive", "Be proactive", session_ref, nil),
        setup_button("responder_setup_customize", "Customize", session_ref, nil)
      ]),
      section(
        "_Setup changes listening, context, alert escalation, and room invitations only. It never grants write, approval, publish, deploy, or infrastructure authority._"
      )
    ]

    {:ok, blocks, text}
  end

  defp setup_blocks("asking", "participation", _draft, session_ref, expires_at) do
    text = "How should Emisar participate here?"

    {:ok,
     [
       section("*Channel setup · participation*\n#{text}\nExpires: `#{mrkdwn(expires_at)}`"),
       actions("setup:#{session_ref}", [
         setup_button(
           "responder_setup_participation_mentions",
           "Mentions only",
           session_ref,
           nil
         ),
         setup_button(
           "responder_setup_participation_proactive",
           "Proactive",
           session_ref,
           nil
         ),
         setup_button("responder_setup_participation_shadow", "Shadow", session_ref, nil)
       ])
     ], text}
  end

  defp setup_blocks(
         "asking",
         "repository",
         %{"repository_options" => repositories},
         session_ref,
         _expires_at
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

    text = "Which configured repository or repository set provides code context?"

    {:ok,
     [section("*Channel setup · code context*\n#{text}")] ++
       setup_action_groups(session_ref, buttons), text}
  end

  defp setup_blocks("asking", "alerts", _draft, session_ref, _expires_at) do
    text = "How should authenticated Slack app alerts escalate?"

    {:ok,
     [
       section("*Channel setup · app alerts*\n#{text}"),
       actions("setup:#{session_ref}", [
         setup_button("responder_setup_alerts_reply", "Reply in place", session_ref, nil),
         setup_button("responder_setup_alerts_offer", "Offer incident", session_ref, nil),
         setup_button(
           "responder_setup_alerts_automatic",
           "Automatic incident",
           session_ref,
           "danger"
         )
       ]),
       section("_Human health questions never auto-create incidents._")
     ], text}
  end

  defp setup_blocks("asking", "audience", _draft, session_ref, _expires_at) do
    text = "Who else should be invited to incident rooms from this channel?"

    {:ok,
     [
       section(
         "*Channel setup · additional audience*\n#{text}\nReply with Slack member or user-group mentions, or choose operators only."
       ),
       actions(
         "setup:#{session_ref}",
         setup_button("responder_setup_audience_none", "Operators only", session_ref, nil)
       )
     ], text}
  end

  defp setup_blocks("confirming", "confirm", draft, session_ref, expires_at) do
    case setup_draft?(draft) do
      true -> setup_confirmation(draft, session_ref, expires_at)
      false -> {:error, {:invalid_slack_render, :channel_setup}}
    end
  end

  defp setup_blocks("saved", _step, draft, _session_ref, _expires_at) do
    text = "Channel configuration saved."

    {:ok,
     [
       section(
         "*Channel configuration saved*\nParticipation: `#{mrkdwn(draft["participation"])}` · Context: `#{mrkdwn(draft["repository_ref"])}` · Alerts: `#{mrkdwn(draft["alert_policy"])}`"
       )
     ], text}
  end

  defp setup_blocks("cancelled", _step, _draft, _session_ref, _expires_at),
    do:
      {:ok, [section("*Channel setup cancelled*\nNo settings were changed.")],
       "Channel setup cancelled."}

  defp setup_blocks("expired", _step, _draft, _session_ref, _expires_at),
    do:
      {:ok, [section("*Channel setup expired*\nNo settings were changed.")],
       "Channel setup expired."}

  defp setup_blocks(_status, _step, _draft, _session_ref, _expires_at),
    do: {:error, {:invalid_slack_render, :channel_setup}}

  defp setup_confirmation(draft, session_ref, expires_at) do
    audience =
      case draft["invite_user_refs"] ++ draft["invite_user_group_refs"] do
        [] -> "configured operators only"
        refs -> Enum.map_join(refs, ", ", &"`#{mrkdwn(&1)}`")
      end

    text = "Review the channel configuration. Nothing is saved yet."

    summary =
      [
        "*Channel setup · confirm*",
        text,
        "Participation: `#{mrkdwn(draft["participation"])}`",
        "Code context: `#{mrkdwn(draft["repository_ref"])}`",
        "App alerts: `#{mrkdwn(draft["alert_policy"])}`",
        "Additional audience: #{audience}",
        "Expires: `#{mrkdwn(expires_at)}`",
        "_Saving never grants repository writes, approvals, publication, deployment, or infrastructure mutation._"
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(summary),
       actions("setup:#{session_ref}", [
         setup_button("responder_setup_save", "Save configuration", session_ref, "primary"),
         setup_button("responder_setup_restart", "Start over", session_ref, nil),
         setup_button("responder_setup_cancel", "Cancel", session_ref, "danger")
       ])
     ], text}
  end

  defp setup_draft?(draft) do
    draft["participation"] in ~w(mentions proactive shadow) and
      draft["alert_policy"] in ~w(reply offer automatic) and
      is_binary(draft["repository_ref"]) and draft["repository_ref"] != "" and
      is_list(draft["invite_user_refs"]) and is_list(draft["invite_user_group_refs"])
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

  defp records(values) when is_list(values) and length(values) <= @maximum_records, do: :ok
  defp records(_values), do: {:error, {:invalid_slack_render, :records}}

  defp block_count(text, record_blocks) do
    if length(message_blocks(text)) + length(record_blocks) <= @maximum_blocks,
      do: :ok,
      else: {:error, {:invalid_slack_render, :blocks}}
  end

  defp render_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, blocks} ->
      case render_record(record) do
        {:ok, rendered} -> {:cont, {:ok, blocks ++ rendered}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render_record(%{"kind" => kind} = record)
       when kind in ["publication_review", "publication_result"] do
    case PublicationCard.prepare_record(record) do
      {:ok, payload} -> {:ok, publication_blocks(kind, record["ref"], payload)}
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
       when map_size(record) == 4 and status in ["open", "confirmed"] do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <-
           RecordPayload.prepare("slack_post_offer", payload, ref) do
      {:ok, slack_post_offer_blocks(ref, prepared, status)}
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
              status in ["open", "confirmed"] do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare(kind, payload, ref) do
      {:ok, [section(investigation_text(kind, prepared))]}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "input_request",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("input_request", payload, ref) do
      {:ok, input_request_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{
           "kind" => "event_wait",
           "payload" => payload,
           "ref" => ref,
           "status" => "open"
         } = record
       )
       when map_size(record) == 4 do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("event_wait", payload, ref) do
      {:ok, event_wait_blocks(prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(_record), do: {:error, {:invalid_slack_render, :record}}

  defp task_offer_blocks(ref, %{
         "kind" => "engineering",
         "repository" => repository,
         "title" => title
       }) do
    summary = "*#{mrkdwn(title)}*\nRepository: `#{mrkdwn(repository)}`"

    [
      section(summary),
      actions(ref, engineering_button(ref, repository))
    ]
  end

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
      actions(ref, incident_button(ref))
    ]
  end

  defp emisar_approval_blocks(ref, payload) do
    summary =
      [
        "*Approval required in Emisar*",
        "`#{mrkdwn(payload["action_id"])}` is paused before execution on `#{mrkdwn(payload["runner_ref"])}`.",
        "Pack: `#{mrkdwn(payload["pack_ref"])}` · Expires: `#{mrkdwn(payload["expires_at"])}`",
        "_Review the exact target, arguments, blast radius, and policy decision in Emisar. Slack cannot approve this action._"
      ]
      |> compact_lines()

    [
      section(summary),
      actions(
        ref,
        url_button(
          "responder_open_emisar_approval",
          "Review approval in Emisar",
          payload["request_id"],
          payload["approval_url"]
        )
      )
    ]
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

  defp incident_button(ref) do
    button(
      "responder_open_incident",
      "Open incident room",
      ref,
      "danger",
      "Open incident room",
      "Open a coordinated incident room for this work?",
      "Open incident"
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
    [
      section(
        "*Additional Slack post confirmed*\nDestination: `#{mrkdwn(payload["destination_ref"])}`\n_The durable delivery worker is sending or reconciling this exact message._"
      )
    ]
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

    if payload["publishable"] do
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
    else
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

  defp input_request_blocks(ref, %{"choices" => choices, "question" => question}) do
    question_block = %{
      "text" => plain_text(question),
      "type" => "section"
    }

    case choices do
      [] ->
        [question_block]

      choices ->
        elements =
          choices
          |> Enum.with_index()
          |> Enum.map(fn {choice, index} ->
            %{
              "action_id" => "responder_answer_input",
              "text" => plain_text(truncate(choice, @maximum_button_characters)),
              "type" => "button",
              "value" => "#{ref}|#{index}"
            }
          end)

        [question_block, %{"block_id" => ref, "elements" => elements, "type" => "actions"}]
    end
  end

  defp event_wait_blocks(%{"deadline_at" => deadline_at, "verification" => verification}) do
    text = "#{mrkdwn(verification)}\nWaiting until: `#{mrkdwn(deadline_at)}`"
    [section(text)]
  end

  defp investigation_text("evidence", payload) do
    relation = payload["relation"] || "observed"
    target = optional_line("Target", payload["target"])

    [
      "*Evidence · #{mrkdwn(relation)}*",
      mrkdwn(payload["observation"]),
      "Source: #{mrkdwn(payload["source_name"])}",
      target
    ]
    |> compact_lines()
  end

  defp investigation_text("coverage", payload) do
    [
      "*Coverage · #{mrkdwn(payload["layer"])} · #{mrkdwn(payload["status"])}*",
      mrkdwn(payload["detail"]),
      "Source: #{mrkdwn(payload["source"])}"
    ]
    |> compact_lines()
  end

  defp investigation_text("finding", payload) do
    [
      "*Finding · #{mrkdwn(payload["status"])}*",
      mrkdwn(payload["what"]),
      optional_line("Scope", payload["scope"]),
      optional_line("Reason", payload["reason"])
    ]
    |> compact_lines()
  end

  defp investigation_text("progress", payload) do
    [
      "*Progress · #{mrkdwn(payload["phase"])}*",
      mrkdwn(payload["summary"]),
      optional_line("Next update", payload["next_due_at"])
    ]
    |> compact_lines()
  end

  defp investigation_text("goal", payload) do
    required = if payload["required"], do: "required", else: "optional"

    [
      "*Goal · #{required} · #{mrkdwn(payload["id"])}*",
      mrkdwn(payload["requested_outcome"]),
      "Done when: #{mrkdwn(payload["completion_contract"])}"
    ]
    |> compact_lines()
  end

  defp investigation_text("goal_state", payload) do
    [
      "*Goal update · #{mrkdwn(payload["state"])} · #{mrkdwn(payload["goal_id"])}*",
      optional_line("Detail", payload["detail"])
    ]
    |> compact_lines()
  end

  defp investigation_text("alert_assessment", payload) do
    [
      "*Alert assessment · #{mrkdwn(payload["verdict"])}*",
      mrkdwn(payload["impact"]),
      optional_line("Cause", payload["cause"]),
      optional_line("Next action", payload["immediate_action"]),
      optional_line("Verify", payload["verification"])
    ]
    |> compact_lines()
  end

  defp compact_lines(lines), do: lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")

  defp optional_line(_label, nil), do: nil
  defp optional_line(label, value), do: "#{label}: #{mrkdwn(value)}"

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

  defp truncate(text, maximum) do
    graphemes = String.graphemes(text)

    if length(graphemes) <= maximum,
      do: text,
      else: graphemes |> Enum.take(maximum - 1) |> Enum.join() |> Kernel.<>("…")
  end
end

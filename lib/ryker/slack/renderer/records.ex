defmodule Ryker.Slack.Renderer.Records do
  @moduledoc """
  Renders the durable records attached to a reply: offers awaiting a human
  decision, questions and their answers, event waits, publication reviews and
  the source links evidence records earned.

  Interactive controls come only from validated records, so model output can
  never invent an action id, a button value or a confirmation flow.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  alias Ryker.Publication.Card, as: PublicationCard
  alias Ryker.Slack.Renderer.{EmisarReview, Offers, SavedEntityCard}
  alias Ryker.Slack.ReplyRecords
  alias Ryker.State.RecordPayload

  @maximum_records 64
  @reference ~r/\A(?:record|publication):[A-Za-z0-9_.:-]{1,240}\z/
  @investigation_kinds ~w(evidence coverage finding progress goal goal_state alert_assessment)
  @confirmation_kinds ~w(automation_change_offer guidance_offer memory_offer preference_offer schedule_offer standing_assignment_offer)
  # Every open offer renders from its prepared payload alone; the Slack post
  # offer is the exception because the host adds the landed message's URL.
  @offer_kinds ~w(task_offer publication_offer) ++ @confirmation_kinds

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(values) when is_list(values) and length(values) <= @maximum_records do
    if Enum.count(values, &(is_map(&1) and &1["kind"] not in @investigation_kinds)) <= 20,
      do: :ok,
      else: {:error, {:invalid_slack_render, :records}}
  end

  def validate(_values), do: {:error, {:invalid_slack_render, :records}}

  @spec render([map()]) :: {:ok, [map()]} | {:error, term()}
  def render(records) do
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
         :ok <- SavedEntityCard.validate(entity) do
      {:ok, SavedEntityCard.blocks(entity)}
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
      {:ok, EmisarReview.approval_blocks(ref, prepared)}
    else
      _invalid -> {:error, {:invalid_slack_render, :record}}
    end
  end

  defp render_record(
         %{"kind" => kind, "payload" => payload, "ref" => ref, "status" => "open"} = record
       )
       when map_size(record) == 4 and kind in @offer_kinds do
    with :ok <- reference(ref),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare(kind, payload, ref) do
      {:ok, Offers.blocks(kind, ref, prepared)}
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
         :ok <- Offers.incident_room_presentation(presentation),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("task_offer", payload, ref) do
      {:ok, Offers.confirmed_task_offer(prepared, presentation)}
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
      {:ok, Offers.slack_post_offer(ref, Map.put(prepared, "message_url", url), status)}
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
       when map_size(record) in [4, 5] and
              status in ["open", "answered", "dismissed", "superseded"] do
    presentation = Map.get(record, "presentation", %{})

    with :ok <- reference(ref),
         :ok <- remembered_presentation(presentation),
         {:ok, %{payload: prepared}} <- RecordPayload.prepare("input_request", payload, ref) do
      if status == "open" do
        {:ok, input_request_blocks(ref, prepared)}
      else
        {:ok,
         [
           %{"type" => "section", "text" => plain_text(prepared["question"])},
           context(question_status(status))
         ] ++ remembered_blocks(presentation["memory"])}
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

  defp publication_blocks("publication_review", ref, payload) do
    findings = payload["policy_findings"] ++ payload["reasons"]

    detail =
      [
        "*#{escape(payload["title"])}*",
        "Repository: `#{escape(payload["repository"])}`",
        "Gate: `#{escape(payload["gate"])}` · Rebase: `#{escape(payload["rebase"])}`",
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
                "ryker_publish_draft",
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
          "*Draft pull request published · #{escape(payload["title"])}*",
          "Repository: `#{escape(payload["repository"])}`",
          "PR: #{escape(payload["pull_request_url"])}",
          "Commit: `#{payload["commit_sha"]}`"
        ]
        |> compact_lines()
      ),
      actions(ref, [
        url_button(
          "ryker_open_publication",
          "Open PR",
          ref,
          payload["pull_request_url"]
        ),
        button(
          "ryker_check_publication",
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
    do: "Blocked by: " <> Enum.map_join(findings, ", ", &escape/1)

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
    numbered? = Enum.any?(choices, &(String.length(&1) > maximum_button_characters()))

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
        Map.merge(option, %{"type" => "button", "action_id" => "ryker_answer_input_#{index}"})
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
            "action_id" => "ryker_question_choice",
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
            "action_id" => "ryker_submit_input",
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
    label = escape(label)

    if ReplyRecords.safe_url?(url) do
      link = "<#{escape(url)}|#{String.replace(label, "|", "&#124;")}>"
      if String.length(link) <= 2_980, do: [{url, link}], else: []
    else
      []
    end
  end

  defp reference(value) do
    if is_binary(value) and Regex.match?(@reference, value),
      do: :ok,
      else: {:error, {:invalid_slack_render, :record}}
  end

  # The host knows whether the answer was saved; before this the model wrote
  # "Remembered X" in prose, which a reader cannot check and which the
  # instructions had to keep policing. This is a receipt, never a control.
  defp remembered_presentation(presentation) when map_size(presentation) == 0, do: :ok

  defp remembered_presentation(%{"memory" => memory} = presentation)
       when map_size(presentation) == 1 and map_size(memory) == 3 do
    case memory do
      %{"applicability" => applicability, "subject" => subject, "value" => value}
      when is_binary(applicability) and is_binary(subject) and is_binary(value) ->
        :ok

      _other ->
        {:error, :invalid_remembered_presentation}
    end
  end

  defp remembered_presentation(_presentation), do: {:error, :invalid_remembered_presentation}

  defp remembered_blocks(nil), do: []

  defp remembered_blocks(%{
         "applicability" => applicability,
         "subject" => subject,
         "value" => value
       }),
       do: [
         section(
           "✓ Remembered *#{escape(subject)}* as `#{escape(value)}` for #{escape(applicability)}."
         )
       ]
end

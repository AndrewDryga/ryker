defmodule Responder.GitHub.Renderer do
  @moduledoc """
  Host-owned Markdown projection for typed records delivered to GitHub.

  GitHub has no Block Kit controls. The projection therefore preserves the
  durable question, wait, evidence, or offer in readable Markdown and never
  invents an approval action. Governed Emisar approvals link only to their
  already-validated authoritative URL.
  """

  alias Responder.Emisar.ApprovalStatus
  alias Responder.State.RecordPayload

  @maximum_records 64
  @investigation_kinds ~w(evidence coverage finding progress goal goal_state alert_assessment)
  @offer_kinds ~w(task_offer publication_offer schedule_offer memory_offer preference_offer guidance_offer standing_assignment_offer)

  @spec render(map()) :: {:ok, String.t()} | {:error, term()}
  def render(%{"emisar_approval_status" => status} = document) when map_size(document) == 1 do
    case ApprovalStatus.prepare(status) do
      {:ok, status} ->
        label = ApprovalStatus.label(status["status"])

        error =
          if status["remote_error"],
            do: "\n\n**Error:** #{escape(status["remote_error"])}",
            else: ""

        run =
          if status["run_url"],
            do: "[Open the exact run](#{status["run_url"]})",
            else: "Exact run: `#{escape(status["run_id"])}`"

        {:ok,
         """
         ### Governed action — #{escape(label)}

         `#{escape(status["action_id"])}` on `#{escape(status["runner_ref"])}`. Pack: `#{escape(status["pack_ref"])}`.

         #{run} · [Review in Emisar](#{status["approval_url"]})#{error}

         GitHub cannot approve this action.
         """
         |> String.trim()}

      _invalid ->
        {:error, {:invalid_github_render, :emisar_approval_status}}
    end
  end

  def render(%{"message" => message} = document) when is_binary(message) do
    case document do
      %{"message" => ^message} when map_size(document) == 1 ->
        {:ok, message}

      %{"message" => ^message, "records" => records}
      when map_size(document) == 2 and is_list(records) and length(records) <= @maximum_records ->
        with {:ok, sections} <- render_records(records) do
          {:ok, Enum.join([message | sections], "\n\n")}
        end

      _invalid ->
        {:error, {:invalid_github_render, :document}}
    end
  end

  def render(_document), do: {:error, {:invalid_github_render, :document}}

  defp render_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, rendered} ->
      case render_record(record) do
        {:ok, section} -> {:cont, {:ok, rendered ++ [section]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render_record(
         %{"kind" => kind, "payload" => payload, "ref" => ref, "status" => status} = record
       )
       when map_size(record) == 4 and is_binary(kind) and is_map(payload) and is_binary(ref) and
              status in ["open", "confirmed"] do
    case RecordPayload.prepare(kind, payload, ref) do
      {:ok, %{payload: prepared}} -> record_markdown(kind, prepared, ref, status)
      _invalid -> {:error, {:invalid_github_render, :record}}
    end
  end

  defp render_record(_record), do: {:error, {:invalid_github_render, :record}}

  defp record_markdown("emisar_approval", payload, _ref, "open") do
    {:ok,
     """
     ### Approval required in Emisar

     `#{escape(payload["action_id"])}` is paused before execution on `#{escape(payload["runner_ref"])}`. Pack: `#{escape(payload["pack_ref"])}`. Expires: `#{escape(payload["expires_at"])}`.

     [Review the exact request in Emisar](#{payload["approval_url"]}). GitHub cannot approve this action.
     """
     |> String.trim()}
  end

  defp record_markdown("input_request", payload, _ref, "open") do
    choices = payload["choices"] |> Enum.map_join("\n", &"- #{escape(&1)}")

    {:ok,
     """
     ### Input needed

     #{escape(payload["question"])}

     #{choices}

     Reply in this thread with the choice or answer. The question does not grant new authority.
     """
     |> String.trim()}
  end

  defp record_markdown("event_wait", payload, _ref, "open") do
    {:ok,
     """
     ### Waiting for an external event

     #{escape(payload["verification"])}

     Deadline: `#{escape(payload["deadline_at"])}`
     """
     |> String.trim()}
  end

  defp record_markdown("evidence", payload, _ref, _status) do
    source = "#{payload["source_type"]}: #{payload["source_name"]}"

    {:ok,
     "**Evidence — #{escape(payload["claim_id"])}:** #{escape(payload["observation"])}\n\nSource: #{escape(source)}"}
  end

  defp record_markdown("coverage", payload, _ref, _status) do
    {:ok,
     "**Coverage — #{escape(payload["layer"])} / #{escape(payload["status"])}:** #{escape(payload["detail"])}"}
  end

  defp record_markdown("finding", payload, _ref, _status) do
    {:ok, "**Finding — #{escape(payload["status"])}:** #{escape(payload["what"])}"}
  end

  defp record_markdown("progress", payload, _ref, _status) do
    {:ok, "**Progress — #{escape(payload["phase"])}:** #{escape(payload["summary"])}"}
  end

  defp record_markdown("goal", payload, _ref, _status) do
    marker = if payload["required"], do: "required", else: "optional"

    {:ok,
     "**Goal — #{escape(payload["id"])} (#{marker}):** #{escape(payload["requested_outcome"])}"}
  end

  defp record_markdown("goal_state", payload, _ref, _status) do
    detail = if payload["detail"], do: " — #{escape(payload["detail"])}", else: ""
    {:ok, "**Goal #{escape(payload["goal_id"])}:** `#{escape(payload["state"])}`#{detail}"}
  end

  defp record_markdown("alert_assessment", payload, _ref, _status) do
    {:ok, "**Alert assessment — #{escape(payload["verdict"])}:** #{escape(payload["impact"])}"}
  end

  defp record_markdown("task_offer", payload, _ref, "open") do
    repository = if payload["repository"], do: " in `#{escape(payload["repository"])}`", else: ""

    {:ok,
     "### Proposed #{escape(payload["kind"])} task\n\n**#{escape(payload["title"])}**#{repository}\n\nStarting it requires an explicit operator confirmation in a supported Responder control surface."}
  end

  defp record_markdown("publication_offer", payload, _ref, "open") do
    {:ok,
     "### Publication review offered\n\n**#{escape(payload["title"])}**\n\nNo branch or pull request is published until an operator reviews the committed workspace."}
  end

  defp record_markdown("schedule_offer", payload, _ref, "open") do
    {:ok,
     "### Schedule offered\n\n**#{escape(payload["title"])}**\n\nThis is an inert offer. An operator must confirm the exact cadence and authority before it becomes active."}
  end

  defp record_markdown(kind, payload, _ref, "open") when kind in @offer_kinds do
    title = payload["summary"] || payload["subject"] || payload["key"] || payload["task"] || kind

    {:ok,
     "**Responder offer — #{escape(title)}:** This durable behavior remains inert until an operator confirms it."}
  end

  defp record_markdown(kind, _payload, _ref, _status) when kind in @investigation_kinds,
    do: {:error, {:invalid_github_render, :record}}

  defp record_markdown(_kind, _payload, _ref, _status),
    do: {:error, {:invalid_github_render, :record}}

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end

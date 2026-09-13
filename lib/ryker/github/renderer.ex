defmodule Ryker.GitHub.Renderer do
  @moduledoc """
  Host-owned Markdown projection for typed records delivered to GitHub.

  The projection preserves each durable question, wait, evidence, or offer in
  readable Markdown. Confirmable inert offers carry a host-owned textual
  command; governed Emisar and publication approvals stay on their existing
  authoritative surfaces.
  """

  alias Ryker.Emisar.ApprovalStatus
  alias Ryker.State.RecordPayload

  @maximum_records 64
  @investigation_kinds ~w(evidence coverage finding progress goal goal_state alert_assessment)
  @offer_kinds ~w(task_offer publication_offer schedule_offer automation_change_offer memory_offer preference_offer guidance_offer standing_assignment_offer)
  @confirmable_offer_kinds ~w(automation_change_offer memory_offer preference_offer guidance_offer standing_assignment_offer)

  @spec render(map()) :: {:ok, String.t()} | {:error, term()}
  def render(%{"emisar_approval_status" => status} = document) when map_size(document) == 1 do
    case ApprovalStatus.prepare(status) do
      {:ok, status} ->
        run =
          if status["run_url"],
            do: "[Open the exact run](#{status["run_url"]})",
            else: "Exact run: `#{escape(status["run_id"])}`"

        {:ok,
         """
         ### Governed action — #{escape(ApprovalStatus.label(status["status"]))}

         `#{escape(status["action_id"])}` on `#{escape(status["runner_ref"])}`. Pack: `#{escape(status["pack_ref"])}`.
         #{review_markdown(status)}
         #{run} · [Review in Emisar](#{status["approval_url"]})#{error_markdown(status)}

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

  # The same review Slack reports, in Markdown: current status first, then the
  # decisions oldest first. A run no human reviewed states nothing here.
  defp review_markdown(status) do
    case ApprovalStatus.review_summary(status) do
      nil ->
        ""

      %{summary: summary, history: history} ->
        Enum.map_join([summary | history], "\n", &("\n" <> escape(&1))) <> "\n"
    end
  end

  defp error_markdown(%{"remote_error" => error}) when is_binary(error),
    do: "\n\n**Error:** #{escape(error)}"

  defp error_markdown(_status), do: ""

  defp render_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, rendered} ->
      case render_record(record) do
        {:ok, ""} -> {:cont, {:ok, rendered}}
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

  defp record_markdown("event_wait", %{"deadline_at" => nil}, _ref, "open"), do: {:ok, ""}

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

  defp record_markdown("task_offer", %{"kind" => "engineering"} = payload, ref, "open") do
    repository = if payload["repository"], do: " in `#{escape(payload["repository"])}`", else: ""

    {:ok,
     "### Proposed engineering task\n\n**#{escape(payload["title"])}**#{repository}#{confirmation(ref)}"}
  end

  defp record_markdown("task_offer", payload, _ref, "open") do
    repository = if payload["repository"], do: " in `#{escape(payload["repository"])}`", else: ""

    {:ok,
     "### Proposed #{escape(payload["kind"])} task\n\n**#{escape(payload["title"])}**#{repository}\n\nStarting it requires an explicit operator confirmation in a supported Ryker control surface."}
  end

  defp record_markdown("publication_offer", payload, _ref, "open") do
    {:ok,
     "### Publication review offered\n\n**#{escape(payload["title"])}**\n\nNo branch or pull request is published until an operator reviews the committed workspace."}
  end

  defp record_markdown("schedule_offer", payload, ref, "open") do
    {:ok,
     "### Schedule offered\n\n**#{escape(payload["title"])}**\n\nThis is an inert offer.#{confirmation(ref)}"}
  end

  defp record_markdown(kind, payload, ref, "open") when kind in @confirmable_offer_kinds do
    title = payload["summary"] || payload["subject"] || payload["key"] || payload["task"] || kind

    {:ok,
     "**Ryker offer — #{escape(title)}:** This durable behavior remains inert.#{confirmation(ref)}"}
  end

  defp record_markdown(kind, _payload, _ref, "open") when kind in @offer_kinds,
    do: {:error, {:invalid_github_render, :record}}

  defp record_markdown(kind, _payload, _ref, _status) when kind in @investigation_kinds,
    do: {:error, {:invalid_github_render, :record}}

  defp record_markdown(_kind, _payload, _ref, _status),
    do: {:error, {:invalid_github_render, :record}}

  defp confirmation(ref) do
    "\n\nTo confirm this exact offer, reply in this discussion with:\n\n`/ryker confirm #{escape(ref)}`\n\nOnly a configured GitHub actor can confirm it. Replaying the command is safe."
  end

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

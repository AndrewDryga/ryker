defmodule Responder.ControlPlane.WorkRecovery do
  @moduledoc "A shared recovery brief: host facts and attributed final output, never raw diagnostics or thoughts."
  alias Responder.ControlPlane.{CodeEditingSetup, InspectionRedactor}
  alias Responder.Work.{Custody, Turn}

  @checkpoint_api_errors [
    "invalid_work_executor: {:invalid_work_executor, :workspace_checkpoint_api}",
    "{:invalid_work_executor, :workspace_checkpoint_api}"
  ]

  # The saved error keeps a Coop refusal as the third element of an inspected
  # tuple, wherever the retry ladder nested it. An unterminated literal is a
  # truncated detail, and a half sentence is not a cause.
  @coop_refusal ~r/:coop_operation_failed, "(?:[^"\\]|\\.)*", "((?:[^"\\]|\\.)*)"/

  def project(
        %Turn{} = turn,
        workspace_recovery,
        checkpoint_supported? \\ CodeEditingSetup.checkpoint_supported?()
      ) do
    saved = saved_output(turn)
    closed = get_in(turn.cancellation_receipt, ["session_state"]) in ["closed", "discarded"]
    unsupported = turn.last_error_detail in @checkpoint_api_errors

    finalizing = completion_pending?(turn)

    stranded = workspace_recovery == {:error, :work_completed_workspace_recovery_required}

    {headline, cause, next_step} = explanation(turn, unsupported, finalizing, closed, saved)

    brief = %{
      kind: if(finalizing, do: :completion, else: :execution),
      headline: headline,
      cause: cause,
      next_step: if(stranded, do: stranded_recovery(), else: next_step),
      fingerprint: Custody.recovery_fingerprint(turn),
      model_output: saved,
      delivery:
        if(is_nil(turn.external_receipt),
          do: "This response has not been sent.",
          else: "A delivery receipt is recorded; check the conversation before sending again."
        ),
      workspace: workspace_status(unsupported, finalizing, closed),
      setup_href: if(unsupported, do: "/configuration#code-editing"),
      not_started: not_started?(turn),
      action: recovery_action(stranded, unsupported, checkpoint_supported?),
      action_label: if(finalizing, do: "Resume saving result", else: "Retry work"),
      retry_effect:
        if(finalizing,
          do:
            "Reconciles the same completed turn, saves its workspace and releases the retained reply. It does not run the model again.",
          else:
            "Starts a new logical turn after reconciling the stopped worker. Inspect and preserve unfinished changes first."
        )
    }

    startup_explanation(brief, checkpoint_supported?)
  end

  defp completion_pending?(%Turn{completion_receipt: receipt, result_ref: nil, delivery_ref: nil})
       when is_map(receipt), do: true

  defp completion_pending?(_), do: false

  @doc """
  What a finished worker left the host holding, or `nil` when nothing is held.

  The recovery page and the Slack card must describe one failure from one set of
  facts, so this decides it once: `:workspace` when the connection could not
  snapshot the working copy, `:reply` when finalization stopped before the saved
  answer was released. A turn that never started holds nothing — there is no
  working copy to restore and no answer to release.
  """
  @spec workspace_hold(term()) ::
          %{closed: boolean(), held: :reply | :workspace, report: String.t() | nil} | nil
  def workspace_hold(%Turn{status: :blocked} = turn) do
    cond do
      not_started?(turn) -> nil
      completion_pending?(turn) -> hold(turn, :reply)
      turn.last_error_detail in @checkpoint_api_errors -> hold(turn, :workspace)
      true -> nil
    end
  end

  def workspace_hold(_turn), do: nil

  defp hold(turn, held) do
    %{
      closed: get_in(turn.cancellation_receipt, ["session_state"]) in ["closed", "discarded"],
      held: held,
      report: saved_output(turn)
    }
  end

  defp recovery_action(true, _, _), do: nil
  defp recovery_action(_, true, false), do: nil
  defp recovery_action(_, _, _), do: :retry

  defp startup_explanation(%{not_started: true} = brief, checkpoint_supported?) do
    %{
      brief
      | headline: "I couldn’t start the code changes",
        cause:
          "The code-editing service could not save a recoverable copy of its work. I stopped before editing any files.",
        next_step:
          if(checkpoint_supported?,
            do:
              "The connection now supports saving work. An administrator should check that a compatible coding worker is available, then retry this task.",
            else:
              "An administrator needs to fix the code-editing setup. Retrying before that will fail for the same reason."
          ),
        workspace: "No files changed. No checks ran.",
        delivery: "No task reply was sent.",
        action_label: "Retry task",
        retry_effect: "Starts the approved task. No coding work ran in this attempt."
    }
  end

  defp startup_explanation(brief, _checkpoint_supported?), do: brief

  def not_started?(%Turn{status: :blocked, last_error_detail: error} = turn)
      when error in @checkpoint_api_errors, do: retained_absent_submission?(turn)

  def not_started?(_), do: false

  # Absence alone is not evidence: retention also clears submission and result
  # fields. The explicit absent-session receipt proves no start even after a
  # close or retry replaces the turn's status and error, but not after pruning.
  def retained_absent_submission?(%Turn{
        operational_pruned_at: nil,
        submission: nil,
        submission_fingerprint: nil,
        coop_turn_id: nil,
        remote_started_at: nil,
        remote_finished_at: nil,
        candidate: nil,
        validation_intent: nil,
        completion_receipt: nil,
        result_ref: nil,
        delivery_ref: nil,
        external_receipt: nil,
        cancellation_receipt: %{
          "kind" => "absent_turn",
          "remote_session_id" => nil,
          "submit_operation_ref" => nil
        }
      }),
      do: true

  def retained_absent_submission?(_), do: false

  defp explanation(_turn, true, _finalizing, closed, saved) do
    headline =
      if saved,
        do: "The worker finished, but its workspace could not be saved",
        else: "This worker cannot safely run repository changes"

    next_step =
      if closed,
        do:
          "Preserve the existing working copy and task notes. Configure a checkpoint-capable fleet worker, then restore the work into a correctly bound workspace. The closed session cannot be fixed by a normal retry.",
        else:
          "Configure a checkpoint-capable fleet worker before starting repository work. The direct worker adapter cannot save these changes."

    {headline,
     "The configured worker connection does not support workspace snapshots. This is a host configuration problem, not a failed code check.",
     next_step}
  end

  defp explanation(turn, false, true, _closed, _saved) do
    {cause, step} = completion_failure(turn.last_error_detail || "")

    {"The worker finished, but saving its result stopped", cause,
     step <> " Then resume saving this result; do not rerun the completed task."}
  end

  defp explanation(turn, false, false, _closed, _saved) do
    case turn.last_error_code do
      code when code in ~w(coop_unavailable coop_transport_error) ->
        {"The worker connection failed", "The host could not confirm the worker operation.",
         "Restore the worker connection and inspect the last confirmed step before retrying."}

      _ ->
        {cause, step} = execution_failure(turn.last_error_detail || "")
        {"The task stopped before it could finish", cause, step}
    end
  end

  # The saved error usually names the blocker outright, and the code alone never
  # can. Reading only the code answered "no specific cause" to a refusal the host
  # was holding word for word, leaving the operator with nothing to do. Say the
  # cause, and never repeat the enum, the session identifier or the raw tuple.
  defp execution_failure(detail) do
    cond do
      refusal = coop_refusal(detail) ->
        {"The worker rejected the operation: " <> refusal,
         "Correct the condition the worker named, then retry this task."}

      String.contains?(detail, "coop_worker_capacity_unavailable") ->
        {"No eligible worker with available capacity was found, so this task was never placed on one.",
         "Make a worker for this repository available again — enrolled, reporting and not draining — then retry this task."}

      String.contains?(detail, "work_remote_operation_in_flight") ->
        {"The host still treats an earlier worker operation for this session as unresolved, so it will not start another one.",
         "Confirm on the worker whether that operation finished and let the host reconcile it before retrying."}

      true ->
        {"The saved error does not establish a specific cause. The worker’s final response, if available below, may describe a separate task blocker.",
         "Inspect the saved response and technical details. Correct the underlying problem and preserve unfinished changes before retrying."}
    end
  end

  # The refusal is a provider's own sentence inside an inspected tuple, so it is
  # unescaped back out of that literal, then redacted and bounded like any other
  # untrusted text the page displays.
  defp coop_refusal(detail) do
    case Regex.run(@coop_refusal, detail, capture: :all_but_first) do
      [escaped] ->
        escaped
        |> Macro.unescape_string()
        |> InspectionRedactor.artifact(max_bytes: 500)
        |> Map.fetch!(:text)

      nil ->
        nil
    end
  end

  defp completion_failure(detail) do
    cond do
      String.starts_with?(detail, ["{:coop_unavailable,", "{:coop_transport_error,"]) ->
        {"The worker connection failed while Responder was saving the completed result.",
         "Restore the worker connection and confirm the same completed session is accessible."}

      String.starts_with?(detail, "{:coop_session_replacement_required,") ->
        {"The completed worker session is no longer available on its recorded worker.",
         "Recover the original session and workspace; replacing it would lose the completed task's identity."}

      String.starts_with?(detail, "{:coop_protocol_error,") ->
        {"The worker response did not match the completed turn's recorded state or receipt.",
         "Inspect the same worker turn and reconcile the state mismatch before continuing."}

      true ->
        {"A host finalization step failed before the completed reply could be released. The recorded error does not establish a more specific cause.",
         "Inspect the failed finalization step and correct its underlying cause."}
    end
  end

  defp stranded_recovery,
    do:
      "Preserve the existing working copy and task notes. Configure a checkpoint-capable fleet worker, then restore the work into a correctly bound workspace. The closed session cannot be fixed by a normal retry."

  defp workspace_status(true, _finalizing, true),
    do:
      "The worker session was closed. No recoverable workspace snapshot was confirmed; do not delete its working copy."

  defp workspace_status(_unsupported, true, _closed),
    do:
      "Responder did not cancel the completed worker. Workspace recovery has not yet been confirmed. Repository tasks require a saved workspace before delivery."

  defp workspace_status(_unsupported, _finalizing, _closed),
    do:
      "Workspace recovery has not been confirmed. Keep any unfinished changes until they are safely recovered."

  defp saved_output(%Turn{
         operational_pruned_at: nil,
         validation_intent: %{
           "verdict" => "accept",
           "result" => %{"delivery_document" => %{"message" => message}}
         }
       })
       when is_binary(message),
       do: InspectionRedactor.artifact(message, max_bytes: 32_000).text

  defp saved_output(_turn), do: nil
end

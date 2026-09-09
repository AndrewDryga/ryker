defmodule Responder.ControlPlane.WorkRecovery do
  @moduledoc "A shared recovery brief: host facts and attributed final output, never raw diagnostics or thoughts."
  alias Responder.ControlPlane.InspectionRedactor
  alias Responder.Work.{Custody, Turn}

  @checkpoint_api_errors [
    "invalid_work_executor: {:invalid_work_executor, :workspace_checkpoint_api}",
    "{:invalid_work_executor, :workspace_checkpoint_api}"
  ]

  def project(%Turn{} = turn, workspace_recovery) do
    saved = saved_output(turn)
    closed = get_in(turn.cancellation_receipt, ["session_state"]) in ["closed", "discarded"]
    unsupported = turn.last_error_detail in @checkpoint_api_errors

    finalizing =
      is_map(turn.completion_receipt) and is_nil(turn.result_ref) and is_nil(turn.delivery_ref)

    stranded = workspace_recovery == {:error, :work_completed_workspace_recovery_required}

    {headline, cause, next_step} = explanation(turn, unsupported, finalizing, closed, saved)

    %{
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
      action: if(stranded, do: nil, else: :retry),
      action_label: if(finalizing, do: "Resume saving result", else: "Retry work"),
      retry_effect:
        if(finalizing,
          do:
            "Reconciles the same completed turn, saves its workspace and releases the retained reply. It does not run the model again.",
          else:
            "Starts a new logical turn after reconciling the stopped worker. Inspect and preserve unfinished changes first."
        )
    }
  end

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
        {"The task stopped before it could finish",
         "The saved error does not establish a specific cause. The worker’s final response, if available below, may describe a separate task blocker.",
         "Inspect the saved response and technical details. Correct the underlying problem and preserve unfinished changes before retrying."}
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

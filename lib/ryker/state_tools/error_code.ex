defmodule Ryker.StateTools.ErrorCode do
  @moduledoc """
  The one table that turns a state-tool failure into the code the model reads.

  Every tool result error is a stable string. Most are a bare code; a few carry
  the correction the model needs in the same string, because the tool result is
  the only channel it has. A reason without a clause is reported as
  `temporarily_unavailable`, which the model treats as retryable, so a new
  non-retryable reason must get a clause here before it can reach a tool.
  """

  @spec code(term()) :: String.t()
  def code(:unauthorized), do: "unauthorized"
  def code(:invalid_arguments), do: "invalid_arguments"

  def code(:invalid_automation_source),
    do:
      "invalid_arguments: source_kind must name an authenticated input adapter: github, slack, or webhook. Terraform and Grafana are vendors, not input adapters. A notification posted in Slack uses slack. Read a real matching notification before choosing its exact content filter; do not invent filter fields or silently subscribe to every message."

  def code(:invalid_final_arguments),
    do:
      ~s(invalid_arguments: validate_final requires {"candidate":{"decision_reason":null,"delivery":"reply","message":"Your answer","outcome":{"state":"complete","record_refs":[],"artifact_refs":[]}}}. Keep the candidate wrapper and every outcome field. Use the actual host-issued refs. For delivery none, message must be null and decision_reason must explain the silence. Nothing was accepted; correct the call before returning.)

  def code(:task_repository_required),
    do:
      "repository_required: engineering tasks require a non-null configured target. Use work.repository_ref or the relevant supplied work.workspace.companions[].name. This is an inert proposal, not execution. Never substitute generic primary, an unrelated companion, or an unoffered path/GitHub slug. Ask for configuration only if no matching supplied target exists."

  def code(:task_repository_source_unscoped),
    do:
      "invalid_arguments: repository_source selects a branch, pull request or commit inside the task's own configured repository, so it requires a non-null repository. It never changes this session's workspace."

  def code(:invalid_repository_reference),
    do:
      "invalid_repository_reference: use a configured repository reference supported by this task interface: 1-256 letters, digits, underscores, dots, colons, or hyphens. A GitHub slug or checkout path is not automatically a configured reference."

  # Creation permitted what validation forbids: `waiting_for_input` requires
  # exactly one open input wait, so a second open question leaves no valid
  # final at all. Episode 0b0c3590 asked again on each rejected attempt until
  # the answer an operator had typed could never be delivered.
  def code(:question_already_open),
    do:
      "question_already_open: this episode already has an unanswered question. Wait for that answer, or supersede the open request instead of opening a second one."

  def code(:no_addressee),
    do:
      "no_addressee: nobody has spoken in this conversation, so a question would wait unanswered. Continue with the evidence you can gather, use wait_for when you are waiting on a system rather than a person, and say plainly in the reply what is unresolved and what would settle it."

  def code(:not_configured), do: "not_configured"
  def code(:not_found), do: "not_found"
  def code(:deadline_elapsed), do: "deadline_elapsed"
  def code(:unknown_tool), do: "unknown_tool"
  def code(:automation_change_offer_invalid), do: "invalid_arguments"
  def code(:automation_not_future), do: "invalid_arguments"
  def code(:automation_status_conflict), do: "operation_conflict"
  def code({:automation_revision_conflict, _revision}), do: "operation_conflict"
  def code(:state_record_unauthorized), do: "unauthorized"
  def code(:state_tools_binding_not_authorized), do: "unauthorized"
  def code(:state_record_confirmation_unsupported), do: "confirmation_unsupported"
  def code(:state_record_shadow_forbidden), do: "unauthorized"
  def code(:state_record_operation_conflict), do: "operation_conflict"
  def code(:state_record_subject_conflict), do: "operation_conflict"
  def code(:conversation_summary_unauthorized), do: "unauthorized"
  def code(:invalid_memory_cursor), do: "invalid_memory_cursor"
  def code(:invalid_memory_time_filter), do: "invalid_memory_time_filter"
  def code(:memory_search_budget_exceeded), do: "memory_search_budget_exceeded"
  def code(:memory_search_result_too_large), do: "memory_search_result_too_large"
  def code(:answer_memory_unauthorized), do: "answer_memory_unauthorized"
  def code(:answer_memory_conflict), do: "answer_memory_conflict"
  def code(:invalid_answer_memory), do: "invalid_answer_memory"
  def code(:memory_capacity_reached), do: "memory_capacity_reached"
  def code(:work_memory_source_capacity_exceeded), do: "memory_source_capacity_exceeded"
  def code({:invalid_schedule, _field}), do: "invalid_arguments"
  def code({:invalid_state_record, _field}), do: "invalid_arguments"
  def code({:invalid_emisar_approval, _field}), do: "invalid_arguments"
  def code(_reason), do: "temporarily_unavailable"
end

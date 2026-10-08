defmodule Ryker.StateTools.ErrorCode do
  @moduledoc """
  The one table that turns a state-tool failure into the code the model reads.

  Every tool result error is a stable string. Most are a bare code; a few carry
  the correction the model needs in the same string, because the tool result is
  the only channel it has. A reason without a clause is reported as
  `temporarily_unavailable`, which the model treats as retryable, so a new
  non-retryable reason must get a clause here before it can reach a tool.
  """
  alias Ryker.StateTools.Catalog

  @spec code(term()) :: String.t()
  def code(:unauthorized), do: "unauthorized"
  def code(:invalid_arguments), do: "invalid_arguments"

  def code(:invalid_automation_source) do
    "invalid_arguments: source_kind must name an authenticated input adapter: github, slack, or webhook. Terraform and Grafana are vendors, not input adapters. A notification posted in Slack uses slack. Read a real matching notification before choosing its exact content filter; do not invent filter fields or silently subscribe to every message."
  end

  # QA, 2026-09-25: propose_automation failed four times on "every weekday at
  # 9:00" and the model settled for Mondays; a weekly trigger's list of days
  # was also kept as its one weekday. A day-set error has to say which
  # recurrence expresses which days, or the model cannot correct it.
  def code(:invalid_schedule_trigger) do
    "invalid_arguments: a time trigger takes one recurrence and only that recurrence's fields. Use recurrence daily for every day, recurrence weekdays for Monday to Friday, and recurrence weekly with one weekday for a single day, each with time; monthly takes day and time, once takes at, and interval takes every_seconds. For any other set of days, such as Monday, Wednesday and Friday, propose one weekly schedule per day in the same call. Nothing was proposed."
  end

  def code(:automation_proposal_limit) do
    "invalid_arguments: propose_automation takes at most #{Catalog.maximum_automation_proposals()} proposals per call. Monday to Friday at one time is a single proposal with recurrence weekdays, and every day is one with recurrence daily. Nothing was proposed."
  end

  def code(:invalid_final_arguments) do
    ~s(invalid_arguments: validate_final requires {"candidate":{"decision_reason":null,"delivery":"reply","message":"Your answer","outcome":{"state":"complete","record_refs":[],"artifact_refs":[]}}}. Keep the candidate wrapper and every outcome field. Use the actual host-issued refs. For delivery none, message must be null and decision_reason must explain the silence. Nothing was accepted; correct the call before returning.)
  end

  def code(:automation_repository_not_writable) do
    "invalid_arguments: repository must be null or one this work can change: work.repository_ref, or another repository of this environment that is not read-only. Nothing was proposed."
  end

  def code(:task_repository_required) do
    "repository_required: engineering tasks require a non-null configured target, any repository of this environment: work.repository_ref or the relevant supplied work.workspace.companions[].name, whichever the task changes. This is an inert proposal, not execution. Never substitute generic primary, an unrelated companion, or an unoffered path/GitHub slug. Ask for configuration only if no matching supplied target exists."
  end

  def code(:task_repository_source_unscoped) do
    "invalid_arguments: repository_source selects a branch, pull request or commit inside the task's own configured repository, so it requires a non-null repository. It never changes this session's workspace."
  end

  def code(:invalid_repository_reference) do
    "invalid_repository_reference: use a configured repository reference supported by this task interface: 1-256 letters, digits, underscores, dots, colons, or hyphens. A GitHub slug or checkout path is not automatically a configured reference."
  end

  # Creation permitted what validation forbids: `waiting_for_input` requires
  # exactly one open input wait, so a second open question leaves no valid
  # final at all. Episode 0b0c3590 asked again on each rejected attempt until
  # the answer an operator had typed could never be delivered.
  def code(:question_already_open) do
    "question_already_open: this episode already has an unanswered question. Wait for that answer, or supersede the open request instead of opening a second one."
  end

  def code(:question_beside_timer) do
    "question_beside_timer: this task waits on a timer, which wakes it only while it holds the task's wait, and a question would hold it instead. Ask in your reply without request_input: a person's answer wakes the task and ends the timer. Or ask once the timer has fired."
  end

  def code(:timer_beside_question) do
    "timer_beside_question: this task waits on an unanswered question, which holds the task's wait until a person answers, so a timer or a deadline set now would never fire. Set it after the answer, or watch for the event without a deadline."
  end

  def code(:no_addressee) do
    "no_addressee: nobody has spoken in this conversation, so a question would wait unanswered. Continue with the evidence you can gather, use wait_for when you are waiting on a system rather than a person, and say plainly in the reply what is unresolved and what would settle it."
  end

  # A final naming a record this work never created was answered
  # `temporarily_unavailable`, so the model retried the same call; three checks
  # of one reply failed that way on 2026-09-26.
  def code(:state_record_not_found) do
    "invalid_arguments: outcome.record_refs names a record this work did not create. Use only the refs your tools returned, or leave record_refs empty. Nothing was accepted."
  end

  def code(:not_configured), do: "not_configured"
  def code(:not_found), do: "not_found"
  def code(:source_not_available), do: "source_not_available"
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

  def code(:answer_memory_question_not_found) do
    "invalid_arguments: question_ref must name a question this conversation asked and a person answered. Nothing was remembered."
  end

  def code(:answer_memory_not_requested) do
    "invalid_arguments: this question was asked without remember, so its answer is not saved. Nothing was remembered."
  end

  def code(:answer_memory_revised) do
    "answer_memory_revised: the person edited their answer after giving it. Nothing was remembered."
  end

  def code(:answer_memory_conflict), do: "answer_memory_conflict"
  def code(:invalid_answer_memory), do: "invalid_answer_memory"

  def code(:answer_memory_private_source) do
    "answer_memory_private_source: an answer is remembered for every conversation, so only one given in a public channel is kept. Nothing was remembered."
  end

  def code(:answer_memory_not_in_answer) do
    "answer_memory_not_in_answer: value must be words the person's answer says, trimmed to the fact, with nothing added. Nothing was remembered."
  end

  def code(:memory_capacity_reached), do: "memory_capacity_reached"
  def code(:work_memory_source_capacity_exceeded), do: "memory_source_capacity_exceeded"
  # Each field the schema refused, by JSON Pointer, with why: the model fixes
  # those fields instead of guessing (Emisar's actionable validation).
  def code({:invalid_arguments, %{issues: issues, count: count, truncated: truncated}}) do
    listed =
      Enum.map_join(issues, " ", fn issue ->
        "#{issue.path} (#{issue.code}): #{issue.message}."
      end)

    shown =
      if truncated,
        do: "#{count} issues, the first #{length(issues)} shown.",
        else: issue_count(count)

    "invalid_arguments: #{shown} #{listed} Nothing was changed; correct these fields and call again."
  end

  def code({:invalid_schedule, field}) when is_atom(field) do
    "invalid_arguments: #{field} was refused: missing where required, too long, or not valid. Nothing was proposed."
  end

  # Which field the record refused, so the model can shorten or correct that
  # one instead of repeating the same call.
  def code({:invalid_state_record, :payload}) do
    "invalid_arguments: the record would be too large to keep; shorten its longest text. Nothing was recorded."
  end

  def code({:invalid_state_record, field}) when is_atom(field) do
    "invalid_arguments: #{field} was refused: missing where required, too long, or not valid. Nothing was recorded."
  end

  def code({:invalid_emisar_approval, field}) when is_atom(field) do
    "invalid_arguments: #{field} was refused: missing where required, too long, or not valid. Nothing was recorded."
  end

  def code(_reason), do: "temporarily_unavailable"

  defp issue_count(1), do: "1 issue."
  defp issue_count(count), do: "#{count} issues."

  @doc """
  What a state-tool error means, for the person reading the timeline.

  The model reads the code and any correction it carries; a person reads this
  sentence, and the exact error stays in the call's Error disclosure.
  """
  @spec explain(term()) :: String.t()
  def explain(error) when is_binary(error),
    do: error |> String.split(":", parts: 2) |> hd() |> String.trim() |> explanation()

  def explain(_error), do: "Ryker refused the call."

  defp explanation("unauthorized"),
    do: "Ryker refused the call because this run was not allowed to make it."

  defp explanation("invalid_arguments"),
    do: "Ryker rejected the call because its arguments did not match what the tool accepts."

  defp explanation("repository_required"),
    do: "Ryker rejected the task because it did not name a configured repository."

  defp explanation("invalid_repository_reference"),
    do: "Ryker rejected the call because the repository it named is not one Ryker has."

  defp explanation("question_already_open"),
    do: "Ryker refused a second question while the first one is still unanswered."

  defp explanation("question_beside_timer"),
    do: "Ryker refused the question because the task waits on a timer that would no longer fire."

  defp explanation("timer_beside_question"),
    do: "Ryker refused the timer because the task waits on a question, and it would never fire."

  defp explanation("no_addressee"),
    do: "Ryker refused the question because nobody has spoken in this conversation."

  defp explanation("not_configured"),
    do: "Ryker refused the call because this tool is not set up here."

  defp explanation("not_found"), do: "Ryker could not find what the call referred to."

  defp explanation("deadline_elapsed"),
    do: "Ryker refused the wait because its deadline had already passed."

  defp explanation("unknown_tool"), do: "Ryker does not offer this tool here."

  defp explanation("operation_conflict") do
    "Ryker refused the call because it conflicts with something this run had already recorded."
  end

  defp explanation("confirmation_unsupported"),
    do: "Ryker refused the offer because nobody here can confirm it."

  defp explanation(code) when code in ["invalid_memory_cursor", "invalid_memory_time_filter"],
    do: "Ryker rejected the search because its page or time filter was not valid."

  defp explanation("memory_search_budget_exceeded"),
    do: "Ryker's search of saved knowledge took too long and was stopped."

  defp explanation("source_not_available"),
    do: "Ryker refused the lookup because the message it reads is queued for a later turn."

  defp explanation("memory_search_result_too_large"),
    do: "The search matched more saved knowledge than Ryker returns at once."

  defp explanation(code)
       when code in [
              "answer_memory_unauthorized",
              "answer_memory_conflict",
              "answer_memory_not_in_answer",
              "answer_memory_private_source",
              "answer_memory_revised",
              "invalid_answer_memory"
            ],
       do: "Ryker refused to remember this answer."

  defp explanation("memory_capacity_reached"), do: "Ryker's saved knowledge is full."

  defp explanation("update_limit_reached"),
    do: "The run had already posted as many updates as it may before its answer."

  defp explanation("reaction_limit_reached"),
    do: "The run had already made as many reactions as it may."

  defp explanation("memory_source_capacity_exceeded"),
    do: "The run had already read as many saved sources as it may."

  defp explanation("internal_error"),
    do: "Ryker hit an error of its own answering the call. The error is in Ryker's log."

  defp explanation("search_unavailable") do
    "Slack lets Ryker search only for a short time after a message that mentions it, and this run had no such permission."
  end

  defp explanation("search_budget_exhausted"),
    do: "The run had already made as many Slack searches as it may."

  defp explanation("temporarily_unavailable"),
    do: "Ryker could not answer the call just then. The same call may work if tried again."

  defp explanation("invalid_fabricated_tool_response"),
    do: "The lookup returned an answer Ryker could not use."

  defp explanation(_code), do: "Ryker refused the call."
end

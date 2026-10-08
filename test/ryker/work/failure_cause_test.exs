defmodule Ryker.Work.FailureCauseTest do
  # The Failures page and a task's stages each took the cause out of an
  # explanation by hand until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.Work.FailureCause

  test "a failure's cause is in words, or nil when Ryker can name none" do
    assert FailureCause.cause("coop_worker_command_timeout: placement 7") ==
             "The worker did not take or finish one of this task's commands in time."

    assert FailureCause.cause("something nobody has seen") == nil
    assert FailureCause.cause(nil) == nil
  end

  # Two tasks stopped on 2026-10-08 after Ryker refused every answer the model
  # gave: no valid answer existed for a task waiting on two approvals
  # (79759944). Nothing here named the cause, so the Failures page said the
  # worker had ended the task early and sent its reader to the worker.
  test "a turn whose every answer Ryker refused says Ryker refused them" do
    detail =
      ~s(work_turn_terminal: {:work_turn_terminal, "failed", "output_contract_failed", ) <>
        ~s("caller rejected semantic output after 3 attempts"})

    assert %{cause: cause, next_step: next_step, depends: depends} =
             FailureCause.explain(detail)

    assert cause =~ "Ryker refused the model's answer three times"
    assert next_step =~ "shows what each answer broke"
    assert depends == "It works if the model's next answer passes Ryker's checks."
  end

  # The task 82633a80 would now run again read "stopped before Ryker could
  # confirm why" on the Failures page, though the saved error says why.
  test "a task stopped by a stale briefing says the briefing changed" do
    assert FailureCause.cause("work_knowledge_context_stale: :work_knowledge_context_stale") =~
             "briefing changed while the task ran"
  end
end

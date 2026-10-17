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

  # OpenAI's model was at capacity on 2026-10-13, and the task it stopped said on its Failures
  # page that the saved error named no cause.
  test "a task the provider couldn't serve says the provider couldn't serve the model" do
    detail =
      ~s(work_turn_terminal: {:work_turn_terminal, "failed", "acp_protocol_error", ) <>
        ~s("provider service unavailable: Selected model is at capacity. Please try a ) <>
        ~s(different model."})

    assert FailureCause.cause(detail) =~ "couldn't serve the model"
    assert FailureCause.transient?(detail)
    refute FailureCause.account_problem?(detail)
    refute FailureCause.transient?("ACP child closed before its response")
  end

  # The tenant worker's Codex adapter answered ten turns with a bare "Internal error" in 40
  # minutes on 2026-10-17 while the host's network was failing, and every message read again
  # later was answered. Ryker stopped each one for a person and named no cause.
  test "a turn the model's software failed on passes and says so" do
    for detail <- [
          ~s({:coop_turn_failed, "failed", "acp_protocol_error", "ACP request was rejected: Internal error"}),
          ~s({:coop_turn_failed, "failed", "acp_protocol_error", ) <>
            ~s("ACP request was rejected: Internal error: fetch failed"})
        ] do
      assert FailureCause.transient?(detail)
      assert FailureCause.cause(detail) =~ "failed on something it did not expect"
    end

    refute FailureCause.transient?("ACP request was rejected: Authentication required")
  end

  # The task 82633a80 would now run again read "stopped before Ryker could
  # confirm why" on the Failures page, though the saved error says why.
  test "a task stopped by a stale briefing says the briefing changed" do
    assert FailureCause.cause("work_knowledge_context_stale: :work_knowledge_context_stale") =~
             "briefing changed while the task ran"
  end
end

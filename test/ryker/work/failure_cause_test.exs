defmodule Ryker.Work.FailureCauseTest do
  # The Failures page and a task's stages each took the cause out of an
  # explanation by hand until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.ErrorDetail
  alias Ryker.Work.FailureCause

  # A sent provider failure was followed by eight pre-send failures loading its
  # lost transcript. Only the latter proves that a new conversation is needed.
  test "only exact pre-send transcript loss authorizes provider conversation recovery" do
    fixture =
      File.read!("test/ryker/work/fixtures/missing_provider_conversation.json") |> Jason.decode!()

    missing = fixture["missing_rollout"]
    assert FailureCause.provider_context_lost?(missing)
    refute FailureCause.provider_context_lost?(fixture["first_sent_failure"])

    for send_state <- ["sent", "unknown", nil] do
      refute FailureCause.provider_context_lost?(Map.put(missing, "send_state", send_state))
    end

    refute FailureCause.provider_context_lost?(Map.delete(missing, "send_state"))
    refute FailureCause.provider_context_lost?(Map.put(missing, "state", "running"))

    refute FailureCause.provider_context_lost?(
             Map.put(missing, "error_code", "acp_process_error")
           )

    for detail <- [
          "ACP request was rejected: Internal error",
          "quoted: " <> missing["error_detail"],
          missing["error_detail"] <> " (another error)",
          String.replace(
            missing["error_detail"],
            "01a00000-0000-7000-8000-000000000001",
            "not-a-thread-id"
          )
        ] do
      refute FailureCause.provider_context_lost?(Map.put(missing, "error_detail", detail))
    end

    refute FailureCause.provider_context_lost?(nil)
  end

  # A missing test dependency must name the project file to fix instead of
  # leaving a stopped task with the generic "could not confirm why" message.
  test "a project setup refusal tells the operator which declaration needs fixing" do
    for {path, reason, explanation} <- [
          {"compose.test.yml", :not_found, "missing from the task's source commit"},
          {"box.compose", :invalid_path, "file inside the repository"},
          {"box.env", :invalid_environment, "invalid environment variable or value"},
          {"box", :invalid_settings, "invalid project options"},
          {".agent/project.yaml", :invalid_yaml, "not valid project YAML"}
        ] do
      detail = ErrorDetail.detail({:coop_worker_project_setup_refused, path, reason})
      assert %{cause: cause, next_step: next_step} = FailureCause.explain(detail)
      assert cause =~ path
      assert cause =~ explanation
      assert next_step =~ ".agent/project.yaml"
      assert next_step =~ "new task"
    end
  end

  # A retained task retried its stop dozens of times while the page hid the
  # worker's saved uncertain-operation refusal behind a generic wrapper.
  test "an uncertain cancellation keeps the worker's reason distinct from a rejected operation" do
    refusal =
      "legacy remote session has no immutable fork ownership proof; recreate the session after preserving its workspace"

    detail =
      inspect(
        {:work_cancellation_unresolved,
         {:coop_operation_uncertain, "operation_uncertain", refusal}}
      )

    assert %{cause: cause} = FailureCause.explain(detail)
    assert cause == "The worker could not confirm the operation: " <> refusal
    refute cause =~ "rejected"
  end

  test "a recorded workspace refusal remains visible inside a cancellation fence" do
    fixture = File.read!("testdata/control_plane/legacy_cleanup_failure.json") |> Jason.decode!()

    detail =
      "{:work_cancellation_unresolved, {:turn_submit_fence, {:error, " <>
        fixture["error_detail"] <> "}}}"

    assert FailureCause.cause(detail) =~
             "legacy remote session has no immutable fork ownership proof"

    refute FailureCause.cause(detail) =~ ":coop_error"
  end

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

  # Coop words a sign-in the provider refused as a service outage ("provider service unavailable:
  # Failed to refresh token", 2026-09-27), and an adapter's internal error can carry the same
  # words. No wait cures either; since 2026-10-13 such a message waited about an hour on the
  # provider ladder before anyone was told the account needs a person.
  test "a sign-in the provider refused is not a failure that passes" do
    for detail <- [
          "provider service unavailable: Failed to refresh token: 400 Bad Request",
          "ACP request was rejected: Internal error: Failed to refresh token: 401 Unauthorized"
        ] do
      assert FailureCause.account_problem?(detail)
      refute FailureCause.transient?(detail)
    end
  end

  # On 2026-10-28 an HTTP 429 stopped a task and asked for credits even though
  # waiting for the provider would let it continue.
  test "provider throttles and usage limits are retryable regardless of adapter wording" do
    for {code, detail} <- [
          {"rate_limited", "exceeded retry limit, last status: 429 Too Many Requests"},
          {"acp_protocol_error",
           "provider limit prevented the turn: You've hit your usage limit."},
          {nil,
           "provider rate limited the turn: exceeded retry limit, last status: 429 Too Many Requests"}
        ] do
      assert FailureCause.rate_limited?(code, detail)
    end

    refute FailureCause.rate_limited?(
             "acp_protocol_error",
             "Failed to refresh token: 401 Unauthorized"
           )

    refute FailureCause.rate_limited?(nil, nil)
  end

  # The task 82633a80 would now run again read "stopped before Ryker could
  # confirm why" on the Failures page, though the saved error says why.
  test "a task stopped by a stale briefing says the briefing changed" do
    assert FailureCause.cause("work_knowledge_context_stale: :work_knowledge_context_stale") =~
             "briefing changed while the task ran"
  end
end

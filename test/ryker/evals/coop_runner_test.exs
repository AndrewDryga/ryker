defmodule Ryker.Evals.CoopRunnerTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.{CoopRunner, WorldCase, WorldJudgeCase}
  alias Ryker.TestSupport.FakeCoopAPI

  @digest String.duplicate("a", 64)

  defmodule FaultAPI do
    @behaviour Ryker.Coop.API

    def operation_by_key(client, key),
      do: call(client, :operation_by_key, fn fake -> FakeCoopAPI.operation_by_key(fake, key) end)

    def create_session(client, key, policy, task, source),
      do:
        call(client, :create_session, fn fake ->
          FakeCoopAPI.create_session(fake, key, policy, task, source)
        end)

    def fence_create_session({fake, _faults}, key, policy, task, source),
      do: FakeCoopAPI.fence_create_session(fake, key, policy, task, source)

    def get_session(client, session_id),
      do: call(client, :get_session, fn fake -> FakeCoopAPI.get_session(fake, session_id) end)

    def submit_turn(client, session_id, key, revision, prompt, schema),
      do:
        call(client, :submit_turn, fn fake ->
          FakeCoopAPI.submit_turn(fake, session_id, key, revision, prompt, schema)
        end)

    def fence_submit_turn({fake, _faults}, session_id, key, revision, prompt, schema),
      do: FakeCoopAPI.fence_submit_turn(fake, session_id, key, revision, prompt, schema)

    def get_turn(client, session_id, turn_id),
      do: call(client, :get_turn, fn fake -> FakeCoopAPI.get_turn(fake, session_id, turn_id) end)

    def get_output_artifact({fake, _faults}, session_id, turn_id, artifact_id),
      do: FakeCoopAPI.get_output_artifact(fake, session_id, turn_id, artifact_id)

    def cancel_turn({fake, _faults}, session_id, turn_id, key, revision),
      do: FakeCoopAPI.cancel_turn(fake, session_id, turn_id, key, revision)

    def validate_candidate(client, session_id, turn_id, key, digest, verdict),
      do:
        call(client, :validate_candidate, fn fake ->
          FakeCoopAPI.validate_candidate(fake, session_id, turn_id, key, digest, verdict)
        end)

    def close_session(client, session_id, key, revision),
      do:
        call(client, :close_session, fn fake ->
          FakeCoopAPI.close_session(fake, session_id, key, revision)
        end)

    def plan_discard({fake, _faults}, session_id, key, revision, accept_dirty, accept_unmerged),
      do:
        FakeCoopAPI.plan_discard(
          fake,
          session_id,
          key,
          revision,
          accept_dirty,
          accept_unmerged
        )

    def discard_session({fake, _faults}, session_id, key, plan_operation_id),
      do: FakeCoopAPI.discard_session(fake, session_id, key, plan_operation_id)

    defp call({fake, faults}, name, fallback) do
      case Map.get(faults, name) do
        nil -> fallback.(fake)
        {:return, result} -> result
        {:raise, message} -> raise message
        {:throw, reason} -> throw(reason)
      end
    end
  end

  test "runs one judgment through one real Coop-shaped session and scores its verdict" do
    eval = eval_case()
    {:ok, fake} = FakeCoopAPI.start_link([judgment(eval, true)])

    assert {:ok, %{failed: 0, passed: 1, total: 1, results: [result]}} =
             CoopRunner.run([eval], options(fake))

    assert result.status == :passed
    assert result.eval_id == eval.eval_id
    assert result.decision["overall_pass"] == true

    state = FakeCoopAPI.state(fake)
    assert state.closed
    assert state.discarded
    assert state.submit_count == 1
    assert length(state.validations) == 1
    assert state.schema == eval.schema
    assert state.submitted_prompt == eval.prompt
  end

  test "a well-formed failing judgment fails without another attempt or a leaked session" do
    eval = eval_case()
    {:ok, fake} = FakeCoopAPI.start_link([judgment(eval, false)])

    assert {:ok, %{failed: 1, passed: 0, results: [result]}} =
             CoopRunner.run([eval], options(fake))

    assert result.status == :failed
    assert result.reason == :quality_rubric_failed
    assert result.decision["overall_pass"] == false

    state = FakeCoopAPI.state(fake)
    assert state.closed
    assert state.discarded
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
  end

  test "async Coop operations and a one-turn exhausted policy remain a complete eval" do
    eval = eval_case()

    {:ok, fake} =
      FakeCoopAPI.start_link([judgment(eval, true)],
        async_create: true,
        async_operations_running: true,
        async_submit: true,
        exhaust_after_validation: true
      )

    assert %{status: :passed, session_id: "remote_test", turn_id: "turn_test"} =
             CoopRunner.run_case(eval, options(fake))

    state = FakeCoopAPI.state(fake)
    assert state.closed
    assert state.submit_count == 1
    assert state.session["state"] == "discarded"
    assert map_size(state.known_operations) == 2
  end

  test "byte-identical invalid candidates use distinct attempt-bound validation keys" do
    # A rejection is keyed by the attempt it answers, so the same unreadable
    # bytes offered twice are two rejections, not one idempotent replay that
    # would leave the second candidate awaiting a verdict forever.
    eval = eval_case()
    invalid = Jason.encode!(%{"criteria" => [], "overall_pass" => true})
    {:ok, fake} = FakeCoopAPI.start_link([invalid, invalid, judgment(eval, true)])

    assert {:ok, %{failed: 0, passed: 1}} = CoopRunner.run([eval], options(fake))

    state = FakeCoopAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :reject, :accept]

    [first, second, third] = state.validation_keys
    assert first != second
    assert second != third
    assert first =~ ":validate:1:"
    assert second =~ ":validate:2:"
    assert third =~ ":validate:3:"
  end

  test "a judge that never returns a readable judgment is bounded and never scored as passing" do
    # Every unreadable candidate is rejected for repair in the same turn; the
    # twentieth is the last one asked for, so a model that never repairs cannot
    # keep one eval session polling forever or turn its silence into a score.
    eval = eval_case()
    {:ok, fake} = FakeCoopAPI.start_link(List.duplicate("not-json", 20))

    assert %{decision: nil, reason: {:eval_candidate_limit, 20}, status: :failed} =
             CoopRunner.run_case(eval, options(fake))

    state = FakeCoopAPI.state(fake)
    assert state.submit_count == 1
    assert length(state.validations) == 19
    assert Enum.all?(state.validations, &(&1.verdict == :reject))
  end

  test "a crossed Coop turn identity is refused before validation" do
    eval = eval_case()

    {:ok, fake} =
      FakeCoopAPI.start_link([judgment(eval, true)],
        turn_session_id_override: "remote-crossed-session"
      )

    assert %{
             decision: nil,
             reason: {:coop_protocol_error, :turn_identity},
             status: :failed
           } = CoopRunner.run_case(eval, options(fake))

    refute FakeCoopAPI.state(fake).closed
    assert FakeCoopAPI.state(fake).validations == []
  end

  test "run_case contains invalid configuration and unexpected adapter failures" do
    eval = eval_case()

    assert %{
             decision: nil,
             reason: {:invalid_eval_runner, :options},
             status: :failed
           } = CoopRunner.run_case(eval, %{})

    {:ok, fake} = FakeCoopAPI.start_link([], fail_create: true)

    assert %{decision: nil, reason: {:coop_unavailable, :simulated}, status: :failed} =
             CoopRunner.run_case(eval, options(fake))
  end

  test "terminal and overlong remote turns fail one eval without leaking a false score" do
    eval = eval_case()
    candidate = judgment(eval, true)

    {:ok, terminal} =
      FakeCoopAPI.start_link([candidate], fail_first_turn: true, first_turn_state: "interrupted")

    assert %{
             decision: nil,
             reason: {:coop_turn_terminal_without_candidate, "interrupted"},
             status: :failed
           } = CoopRunner.run_case(eval, options(terminal))

    {:ok, slow} = FakeCoopAPI.start_link([candidate], turn_wait_polls: 3)
    slow_options = Keyword.put(options(slow), :max_polls, 2)

    assert %{decision: nil, reason: {:coop_timeout, :turn}, status: :failed} =
             CoopRunner.run_case(eval, slow_options)
  end

  test "validation receipt and close failures never become passing model judgments" do
    eval = eval_case()
    candidate = judgment(eval, true)

    {:ok, missing_receipt} =
      FakeCoopAPI.start_link([candidate], omit_validation_receipt: true)

    assert %{
             decision: nil,
             reason: {:coop_protocol_error, :validation_receipt},
             status: :failed
           } = CoopRunner.run_case(eval, options(missing_receipt))

    {:ok, close_lost} = FakeCoopAPI.start_link([candidate], fail_first_close: true)

    assert %{
             decision: nil,
             reason: {:coop_unavailable, :simulated_close_response_loss},
             status: :failed
           } = CoopRunner.run_case(eval, options(close_lost))

    {:ok, already_closed} = FakeCoopAPI.start_link([candidate], close_after_validation: true)
    assert %{status: :passed} = CoopRunner.run_case(eval, options(already_closed))
    assert FakeCoopAPI.state(already_closed).close_keys == []
  end

  test "runner identities and keyword options are exact rather than best effort" do
    eval = eval_case()
    {:ok, fake} = FakeCoopAPI.start_link([judgment(eval, true)])

    assert %{decision: nil, reason: {:invalid_eval_runner, :run_ref}, status: :failed} =
             CoopRunner.run_case(eval, Keyword.put(options(fake), :id_generator, fn -> "" end))

    duplicate_options = options(fake) ++ [policy: "other"]

    assert CoopRunner.run([eval], duplicate_options) ==
             {:error, {:invalid_eval_runner, :options}}

    assert CoopRunner.run([eval], :invalid) ==
             {:error, {:invalid_eval_runner, :options}}

    assert %{reason: {:invalid_eval_runner, :run_ref}, status: :failed} =
             CoopRunner.run_case(eval, Keyword.put(options(fake), :id_generator, fn -> 42 end))
  end

  test "every ambiguous Coop operation envelope fails without inventing an eval result" do
    operation = fn fields ->
      Map.merge(%{"id" => "op-test", "method" => "CreateRemoteSession"}, fields)
    end

    scenarios = [
      {%{create_session: {:return, {:ok, %{}}}},
       {:coop_protocol_error, :create_session_response}},
      {%{
         create_session: {:return, {:ok, %{"operation" => operation.(%{"state" => "running"})}}},
         operation_by_key: {:return, :not_found}
       }, {:coop_protocol_error, :operation_disappeared}},
      {%{
         create_session: {:return, {:ok, %{"operation" => operation.(%{"state" => "running"})}}},
         operation_by_key: {:return, {:error, :offline}}
       }, :offline},
      {%{
         create_session: {:return, {:ok, %{"operation" => operation.(%{"state" => "running"})}}},
         operation_by_key: {:return, {:ok, operation.(%{"state" => "running"})}}
       }, {:coop_timeout, :operation}},
      {%{
         create_session:
           {:return,
            {:ok,
             %{
               "operation" =>
                 operation.(%{
                   "error_code" => "policy_missing",
                   "error_detail" => "policy unavailable",
                   "state" => "failed"
                 })
             }}}
       }, {:coop_operation_failed, "policy_missing", "policy unavailable"}},
      {%{
         create_session:
           {:return,
            {:ok,
             %{
               "operation" => operation.(%{"method" => "SubmitTurn", "state" => "running"})
             }}}
       }, {:coop_protocol_error, :operation_method}},
      {%{
         create_session: {:return, {:ok, %{"operation" => %{"state" => "invented"}}}}
       }, {:coop_protocol_error, :operation_state}}
    ]

    for {faults, expected} <- scenarios do
      assert %{decision: nil, reason: ^expected, status: :failed} = run_with_faults(faults, 1)
    end
  end

  test "malformed session, turn, validation, and close responses are never scored as passing" do
    malformed_session = %{create_session: {:return, {:ok, %{"session" => %{}}}}}

    assert %{reason: {:coop_protocol_error, :session_identity}, status: :failed} =
             run_with_faults(malformed_session)

    malformed_submit = %{submit_turn: {:return, {:ok, %{}}}}

    assert %{reason: {:coop_protocol_error, :submit_turn_response}, status: :failed} =
             run_with_faults(malformed_submit)

    unknown_turn = %{
      submit_turn:
        {:return,
         {:ok,
          %{
            "turn" => %{
              "id" => "turn-test",
              "session_id" => "remote_test",
              "state" => "invented"
            }
          }}}
    }

    assert %{reason: {:coop_protocol_error, :turn_state}, status: :failed} =
             run_with_faults(unknown_turn)

    invalid_candidate = %{
      submit_turn:
        {:return,
         {:ok,
          %{
            "turn" => %{
              "candidate" => %{"attempt" => 0},
              "id" => "turn-test",
              "session_id" => "remote_test",
              "state" => "awaiting_validation"
            }
          }}}
    }

    assert %{reason: {:coop_protocol_error, :candidate}, status: :failed} =
             run_with_faults(invalid_candidate)

    assert %{reason: {:coop_protocol_error, :validation_response}, status: :failed} =
             run_with_faults(%{validate_candidate: {:return, {:ok, %{}}}})

    assert %{reason: :validation_offline, status: :failed} =
             run_with_faults(%{validate_candidate: {:return, {:error, :validation_offline}}})

    assert %{reason: {:coop_protocol_error, :close_session_response}, status: :failed} =
             run_with_faults(%{close_session: {:return, {:ok, %{}}}})

    eval = eval_case()
    {:ok, blank_turn} = FakeCoopAPI.start_link([judgment(eval, true)], turn_id_override: "")

    assert %{reason: {:coop_protocol_error, :turn_identity}, status: :failed} =
             CoopRunner.run_case(eval, options(blank_turn))
  end

  test "unexpected adapter exceptions and throws stay inside one failed eval case" do
    assert %{reason: {:world_judge_runner_exception, "adapter exploded"}, status: :failed} =
             run_with_faults(%{create_session: {:raise, "adapter exploded"}})

    assert %{
             reason: {:world_judge_runner_caught, :throw, ":adapter_threw"},
             status: :failed
           } = run_with_faults(%{create_session: {:throw, :adapter_threw}})
  end

  test "invalid runner configuration is reported before any remote model call" do
    eval = eval_case()

    assert CoopRunner.run([eval], %{}) ==
             {:error, {:invalid_eval_runner, :options}}

    assert CoopRunner.run(:invalid, %{}) ==
             {:error, {:invalid_eval_runner, :cases}}
  end

  test "a live eval refuses a repository-writable Coop policy before submitting a turn" do
    eval = eval_case()
    {:ok, fake} = FakeCoopAPI.start_link([judgment(eval, true)], repository_read_only: false)

    assert %{reason: {:coop_protocol_error, :session_repository_write_authority}, status: :failed} =
             CoopRunner.run_case(eval, options(fake))

    assert FakeCoopAPI.state(fake).submit_count == 0
  end

  test "a live eval refuses Coop policies with ambient project authority before submitting" do
    eval = eval_case()

    for option <- [:project_env, :project_mcp] do
      {:ok, fake} = FakeCoopAPI.start_link([judgment(eval, true)], [{option, true}])

      assert %{reason: {:coop_protocol_error, :session_project_authority}, status: :failed} =
               CoopRunner.run_case(eval, options(fake))

      assert FakeCoopAPI.state(fake).submit_count == 0
    end
  end

  defp eval_case do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    {:ok, judge} =
      WorldJudgeCase.new(scenario, %{
        deliveries: [%{document: %{"message" => "Healthy."}, kind: :message, target: %{}}],
        records: [],
        source_calls: []
      })

    judge
  end

  # One verdict per rubric criterion, so the judgment stays valid however the
  # scenario's rubric is edited.
  defp judgment(eval, passed?) do
    criteria =
      Enum.map(Enum.with_index(eval.rubric), fn {_criterion, index} ->
        %{"index" => index, "passed" => passed?, "reason" => "Scored against the evidence."}
      end)

    Jason.encode!(%{"criteria" => criteria, "overall_pass" => passed?})
  end

  defp options(fake) do
    [
      api: FakeCoopAPI,
      client: fake,
      id_generator: fn -> "run-eval-test" end,
      max_polls: 10,
      policy: "world-judge-test",
      policy_digest: @digest,
      poll_interval_ms: 0,
      sleep: fn 0 -> :ok end
    ]
  end

  defp run_with_faults(faults, max_polls \\ 10) do
    eval = eval_case()
    {:ok, fake} = FakeCoopAPI.start_link([judgment(eval, true)])

    eval
    |> CoopRunner.run_case(
      options({fake, faults})
      |> Keyword.put(:api, FaultAPI)
      |> Keyword.put(:max_polls, max_polls)
    )
  end
end

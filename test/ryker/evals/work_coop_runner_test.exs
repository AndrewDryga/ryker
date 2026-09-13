defmodule Ryker.Evals.WorkCoopRunnerTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.{CoopRunner, WorkCase}
  alias Ryker.TestSupport.FakeCoopAPI

  test "repairs a host-invalid final in the same Coop turn and scores the correction" do
    eval = case_by_id!("direct_question_gets_a_visible_answer")

    invalid =
      Jason.encode!(%{
        "decision_reason" => "No response is needed.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    corrected =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Verify a representative transaction before calling the deploy healthy.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    {:ok, fake} = FakeCoopAPI.start_link([invalid, corrected])

    assert {:ok, %{failed: 0, passed: 1, results: [result]}} =
             CoopRunner.run([eval], options(fake))

    assert result.status == :passed
    assert result.decision["message"] =~ "transaction"

    state = FakeCoopAPI.state(fake)
    assert state.submit_count == 1
    assert state.closed
    assert state.discarded
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]
    assert length(Enum.uniq(state.validation_keys)) == 2
  end

  test "a host-valid but behaviorally wrong final fails without another model attempt" do
    eval = case_by_id!("direct_question_gets_a_visible_answer")

    wrong =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "The deploy needs one more check.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    {:ok, fake} = FakeCoopAPI.start_link([wrong])

    assert {:ok, %{failed: 1, passed: 0, results: [result]}} =
             CoopRunner.run([eval], options(fake))

    assert result.status == :failed
    assert match?({:work_eval_mismatch, _details}, result.reason)
    assert FakeCoopAPI.state(fake).closed
    assert Enum.map(FakeCoopAPI.state(fake).validations, & &1.verdict) == [:accept]
  end

  test "byte-identical invalid candidates use distinct attempt-bound validation keys" do
    eval = case_by_id!("direct_question_gets_a_visible_answer")

    invalid =
      Jason.encode!(%{
        "decision_reason" => "No response is needed.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    corrected =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Verify the transaction path before declaring the deploy healthy.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    {:ok, fake} = FakeCoopAPI.start_link([invalid, invalid, corrected])

    assert {:ok, %{failed: 0, passed: 1}} = CoopRunner.run([eval], options(fake))

    [first, second, third] = FakeCoopAPI.state(fake).validation_keys
    assert first != second
    assert second != third
    assert first =~ ":validate:1:"
    assert second =~ ":validate:2:"
    assert third =~ ":validate:3:"
  end

  defp case_by_id!(id) do
    {:ok, cases} = WorkCase.all()
    Enum.find(cases, &(&1.eval_id == id)) || flunk("missing Work eval #{id}")
  end

  defp options(fake) do
    [
      api: FakeCoopAPI,
      client: fake,
      id_generator: fn -> "work-eval-run" end,
      max_polls: 4,
      policy: "work-eval-read-only",
      policy_digest: String.duplicate("a", 64),
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end

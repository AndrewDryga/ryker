defmodule Responder.Evals.WorldJudgeCoopRunnerTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.{CoopRunner, WorldCase, WorldJudgeCase}
  alias Responder.TestSupport.FakeCoopAPI

  test "repairs an invalid quality judgment in the same turn and preserves a failing score" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    invalid = Jason.encode!(%{"criteria" => [], "overall_pass" => true})

    failing =
      Jason.encode!(%{
        "criteria" => [
          %{"index" => 0, "passed" => true, "reason" => "Clear scoped verdict."},
          %{"index" => 1, "passed" => false, "reason" => "The answer overstates certainty."}
        ],
        "overall_pass" => false
      })

    {:ok, fake} = FakeCoopAPI.start_link([invalid, failing])

    assert {:ok, %{failed: 1, passed: 0, results: [result]}} =
             CoopRunner.run([judge], options(fake))

    assert result.status == :failed
    assert result.decision["overall_pass"] == false
    assert Enum.map(FakeCoopAPI.state(fake).validations, & &1.verdict) == [:reject, :accept]
  end

  defp report do
    %{
      deliveries: [%{document: %{"message" => "Healthy."}, kind: :message, target: %{}}],
      records: [],
      source_calls: []
    }
  end

  defp options(fake) do
    [
      api: FakeCoopAPI,
      client: fake,
      id_generator: fn -> "world-judge-run" end,
      max_polls: 4,
      policy: "world-judge-read-only",
      policy_digest: String.duplicate("a", 64),
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end

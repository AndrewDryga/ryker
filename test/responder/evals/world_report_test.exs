defmodule Responder.Evals.WorldReportTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.WorldReport

  test "a model-world result is written atomically with exact runtime provenance" do
    root =
      Path.join(System.tmp_dir!(), "responder-world-report-#{System.unique_integer([:positive])}")

    path = Path.join(root, "world.json")
    on_exit(fn -> File.rm_rf!(root) end)

    report = %{
      deliveries: [%{document: %{"message" => "Useful answer"}, target: %{transport: "slack"}}],
      episode_id: "episode-1",
      failures: [],
      lane: :candidate,
      quality: %{decision: :accept, reason: "grounded", status: :passed},
      record_history: [%{"kind" => "evidence", "ref" => "record:evidence:1"}],
      records: [%{"kind" => "evidence", "ref" => "record:evidence:1"}],
      runtime: %{
        policy: "world-eval-v1",
        policy_digest: String.duplicate("a", 64),
        tool_catalog_sha256: String.duplicate("b", 64),
        turns: [
          %{
            cost_usd: "0.42",
            input_tokens: 2_400,
            model: "gpt-5.6-sol",
            provider: "codex",
            provider_ms: 246_000
          }
        ]
      },
      repeat_index: 2,
      scenario_id: "scenario-1",
      source_calls: [
        %{
          arguments_sha256: String.duplicate("c", 64),
          outcome: :result,
          tool: "monitoring.query"
        }
      ],
      status: :passed,
      turn_id: "turn-1"
    }

    summary = %{
      baseline: nil,
      candidate: %{pass_rate: 1.0, total: 1},
      failures: [],
      paired: nil,
      passed?: true,
      thresholds: %{min_overall_pass_rate: 0.9}
    }

    assert :ok =
             WorldReport.write(path, [report],
               now: fn -> ~U[2026-08-30 12:00:00Z] end,
               summary: summary
             )

    document = path |> File.read!() |> Jason.decode!()

    assert document["version"] == 2
    assert document["kind"] == "responder_model_world"
    assert document["generated_at"] == "2026-08-30T12:00:00.000000Z"
    assert document["summary"]["passed?"]
    assert document["summary"]["candidate"]["pass_rate"] == 1.0

    assert [result] = document["results"]
    assert result["scenario_id"] == "scenario-1"
    assert result["status"] == "passed"
    assert result["lane"] == "candidate"
    assert result["repeat_index"] == 2
    assert get_in(result, ["runtime", "turns", Access.at(0), "cost_usd"]) == "0.42"
    assert get_in(result, ["runtime", "turns", Access.at(0), "input_tokens"]) == 2_400
    assert get_in(result, ["source_calls", Access.at(0), "outcome"]) == "result"
    assert get_in(result, ["deliveries", Access.at(0), "document", "message"]) == "Useful answer"
    refute File.exists?(path <> ".tmp")

    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "result files fail closed on ambiguous paths and documents" do
    assert WorldReport.write("relative.json", [], []) ==
             {:error, {:invalid_world_report, :path}}

    assert WorldReport.write(Path.join(System.tmp_dir!(), "empty.json"), [], []) ==
             {:error, {:invalid_world_report, :reports}}

    assert WorldReport.write(Path.join(System.tmp_dir!(), "bad.json"), [%{}], []) ==
             {:error, {:invalid_world_report, :report}}

    assert WorldReport.write(
             Path.join(System.tmp_dir!(), "bad-summary.json"),
             [valid_report()],
             summary: %{}
           ) == {:error, {:invalid_world_report, :summary}}

    assert WorldReport.write(
             Path.join(System.tmp_dir!(), "bad-options.json"),
             [valid_report()],
             now: fn -> DateTime.utc_now() end,
             now: fn -> DateTime.utc_now() end
           ) == {:error, {:invalid_world_report, :options}}

    assert WorldReport.write(
             Path.join(System.tmp_dir!(), "bad-clock.json"),
             [valid_report()],
             now: :invalid
           ) == {:error, {:invalid_world_report, :options}}

    assert WorldReport.result(%{valid_report() | lane: :unknown}) == {:error, :report}
    assert WorldReport.result(%{valid_report() | repeat_index: 0}) == {:error, :report}
    assert WorldReport.result(:invalid) == {:error, :report}
  end

  defp valid_report do
    %{
      deliveries: [],
      episode_id: "episode-1",
      failures: [],
      lane: :candidate,
      quality: %{status: :passed},
      record_history: [],
      records: [],
      repeat_index: 1,
      runtime: %{},
      scenario_id: "scenario-1",
      source_calls: [],
      status: :passed,
      turn_id: "turn-1"
    }
  end
end

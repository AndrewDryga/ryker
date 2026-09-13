defmodule Ryker.Evals.WorldReportTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.WorldReport

  test "a model-world result is written atomically with exact runtime provenance" do
    root =
      Path.join(System.tmp_dir!(), "ryker-world-report-#{System.unique_integer([:positive])}")

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
    assert document["kind"] == "ryker_model_world"
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

  test "typed evaluator failures remain serializable diagnostics" do
    root =
      Path.join(System.tmp_dir!(), "ryker-world-report-#{System.unique_integer([:positive])}")

    path = Path.join(root, "world.json")
    on_exit(fn -> File.rm_rf!(root) end)

    reason =
      {:coop_error, 503, "session_cleanup_error",
       "session runtime cleanup is temporarily unavailable"}

    report =
      valid_report()
      |> put_in([:quality, :reason], reason)
      |> Map.put(:execution_error, {:world_eval_failed, :event_wait_not_matched})
      |> Map.put(:cleanup_error, reason)

    assert :ok = WorldReport.write(path, [report])

    document = path |> File.read!() |> Jason.decode!()

    assert get_in(document, ["results", Access.at(0), "quality", "reason"]) ==
             inspect(reason)

    assert get_in(document, ["results", Access.at(0), "execution_error"]) ==
             inspect(report.execution_error)

    assert get_in(document, ["results", Access.at(0), "cleanup_error"]) == inspect(reason)
  end

  test "a written report reads back as the reports that produced it" do
    # A sharded matrix writes its results once per shard and merges them into
    # one report. The merge has to recover exactly what each shard observed —
    # lanes, statuses, diagnostics and the database a failed observation kept —
    # or the merged summary would be computed over something other than the
    # observations.
    root =
      Path.join(System.tmp_dir!(), "ryker-world-report-#{System.unique_integer([:positive])}")

    path = Path.join(root, "shard.json")
    on_exit(fn -> File.rm_rf!(root) end)

    preserved =
      valid_report()
      |> Map.merge(%{database: "ryker_world_eval_1_o3", repeat_index: 2, status: :failed})
      |> Map.put(:execution_error, {:world_eval_failed, :event_wait_not_matched})
      |> Map.put(:cleanup_error, {:coop_error, 503, "session_cleanup_error", "unavailable"})

    dropped = Map.merge(valid_report(), %{database: nil, lane: :baseline})
    reports = [preserved, dropped]

    assert :ok = WorldReport.write(path, reports, summary: nil)
    assert {:ok, read} = WorldReport.read(path)

    assert Enum.map(read, &Map.take(&1, [:database, :lane, :repeat_index, :scenario_id, :status])) ==
             [
               %{
                 database: "ryker_world_eval_1_o3",
                 lane: :candidate,
                 repeat_index: 2,
                 scenario_id: "scenario-1",
                 status: :failed
               },
               %{lane: :baseline, repeat_index: 1, scenario_id: "scenario-1", status: :passed}
             ]

    assert Enum.map(read, &WorldReport.result/1) == Enum.map(reports, &WorldReport.result/1)
    assert Map.has_key?(hd(read), :execution_error)
    assert Map.has_key?(hd(read), :cleanup_error)
    refute Map.has_key?(List.last(read), :execution_error)

    document = path |> File.read!() |> Jason.decode!()
    assert get_in(document, ["results", Access.at(0), "database"]) == "ryker_world_eval_1_o3"
    refute Map.has_key?(Enum.at(document["results"], 1), "database")

    assert WorldReport.read("relative.json") == {:error, {:invalid_world_report, :path}}

    assert {:error, {:invalid_world_report, {:unreadable, _path, :enoent}}} =
             WorldReport.read(Path.join(root, "absent.json"))

    File.write!(Path.join(root, "text.json"), "not json")

    assert {:error, {:invalid_world_report, :document}} =
             WorldReport.read(Path.join(root, "text.json"))

    File.write!(Path.join(root, "kind.json"), Jason.encode!(%{document | "kind" => "other"}))

    assert {:error, {:invalid_world_report, :kind}} =
             WorldReport.read(Path.join(root, "kind.json"))

    broken = put_in(document, ["results", Access.at(0), "lane"], "judge")
    File.write!(Path.join(root, "lane.json"), Jason.encode!(broken))

    assert {:error, {:invalid_world_report, :report}} =
             WorldReport.read(Path.join(root, "lane.json"))
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

defmodule Ryker.Evals.WorldCoverageTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.{WorldCase, WorldCoverage}

  @scenario_root "testdata/scenarios"

  test "reconnect credit names the source-matched replay rather than the retained unreachable fault" do
    # Terraform's retained invalid matcher stops before its second-turn fault is installed;
    # naming the scenario used to hide the missing reconnect qualification.
    assert {:ok, report} = WorldCoverage.report(@scenario_root)
    assert report.failure_axes["reconnect"] == ["terraform-run-update-stays-in-one-session"]
    assert {:ok, scenario} = WorldCase.fetch("terraform-run-update-stays-in-one-session")
    [initial, continuation] = scenario.host_replay["model_events"]
    assert hd(initial["calls"])["arguments"]["trigger"]["source_kind"] == "slack"
    assert continuation["faults"] == ["lose_submit_response"]

    negative =
      "test/ryker/evals/fixtures/terraform_invalid_source_matcher.json"
      |> File.read!()
      |> Jason.decode!()

    assert get_in(negative, [
             "model_events",
             Access.at(0),
             "calls",
             Access.at(0),
             "arguments",
             "trigger",
             "source_kind"
           ]) == "terraform"

    refute "negative-invalid-matcher" in scenario.tags
  end

  test "the required product matrix names every covered scenario and keeps every gap visible" do
    assert {:ok, %{complete?: true}} = WorldCoverage.report()
    assert {:ok, report} = WorldCoverage.report(@scenario_root)

    assert MapSet.new(Map.keys(report.jobs)) == MapSet.new(WorldCoverage.required_jobs())

    assert MapSet.new(Map.keys(report.failure_axes)) ==
             MapSet.new(WorldCoverage.required_failure_axes())

    assert report.complete?
    assert report.missing_jobs == []
    assert report.missing_failure_axes == []
    assert :ok = WorldCoverage.complete(@scenario_root)
  end

  test "coverage cannot claim an unknown or duplicate scenario" do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "ryker-world-coverage-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture)
    on_exit(fn -> File.rm_rf!(fixture) end)

    source = Path.join(@scenario_root, "universal-webhook-unknown-payload")
    destination = Path.join(fixture, "universal-webhook-unknown-payload")
    File.cp_r!(source, destination)

    coverage = coverage_document("universal-webhook-unknown-payload")
    File.write!(Path.join(fixture, "coverage.json"), Jason.encode!(coverage))
    assert {:ok, %{complete?: true}} = WorldCoverage.report(fixture)

    unknown = put_in(coverage, ["jobs", "artifacts"], ["missing-scenario"])
    File.write!(Path.join(fixture, "coverage.json"), Jason.encode!(unknown))
    assert {:error, {:invalid_world_coverage, :jobs}} = WorldCoverage.report(fixture)

    duplicate =
      put_in(
        coverage,
        ["failure_axes", "worker_loss"],
        ["universal-webhook-unknown-payload", "universal-webhook-unknown-payload"]
      )

    File.write!(Path.join(fixture, "coverage.json"), Jason.encode!(duplicate))
    assert {:error, {:invalid_world_coverage, :failure_axes}} = WorldCoverage.report(fixture)
  end

  test "coverage roots and documents fail closed" do
    assert {:error, {:invalid_world_coverage, :root}} = WorldCoverage.report(nil)

    fixture =
      Path.join(
        System.tmp_dir!(),
        "ryker-world-coverage-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture)
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.write!(Path.join(fixture, "coverage.json"), "[]")
    assert {:error, {:invalid_world_coverage, :json_object}} = WorldCoverage.report(fixture)
  end

  test "coverage files cannot hide missing cells or malformed release evidence" do
    fixture = fixture_root!()
    coverage_path = Path.join(fixture, "coverage.json")
    scenario_id = "universal-webhook-unknown-payload"

    assert {:error, {:invalid_world_coverage, :enoent}} = WorldCoverage.report(fixture)

    File.write!(coverage_path, String.duplicate(" ", 64 * 1_024 + 1))
    assert {:error, {:invalid_world_coverage, :too_large}} = WorldCoverage.report(fixture)

    incomplete = %{
      "version" => 1,
      "jobs" => Map.new(WorldCoverage.required_jobs(), &{&1, []}),
      "failure_axes" => Map.new(WorldCoverage.required_failure_axes(), &{&1, []})
    }

    File.write!(coverage_path, Jason.encode!(incomplete))
    assert {:ok, %{complete?: false}} = WorldCoverage.report(fixture)

    assert {:error,
            {:world_coverage_incomplete,
             %{failure_axes: missing_failure_axes, jobs: missing_jobs}}} =
             WorldCoverage.complete(fixture)

    assert missing_jobs == Enum.sort(WorldCoverage.required_jobs())
    assert missing_failure_axes == Enum.sort(WorldCoverage.required_failure_axes())

    wrong_version = %{coverage_document(scenario_id) | "version" => 2}
    File.write!(coverage_path, Jason.encode!(wrong_version))
    assert {:error, {:invalid_world_coverage, :version}} = WorldCoverage.report(fixture)

    malformed_matrix = %{coverage_document(scenario_id) | "jobs" => []}
    File.write!(coverage_path, Jason.encode!(malformed_matrix))
    assert {:error, {:invalid_world_coverage, :jobs}} = WorldCoverage.report(fixture)

    malformed_ids = put_in(coverage_document(scenario_id), ["jobs", "artifacts"], scenario_id)
    File.write!(coverage_path, Jason.encode!(malformed_ids))
    assert {:error, {:invalid_world_coverage, :jobs}} = WorldCoverage.report(fixture)
  end

  defp coverage_document(scenario_id) do
    %{
      "version" => 1,
      "jobs" => Map.new(WorldCoverage.required_jobs(), &{&1, [scenario_id]}),
      "failure_axes" => Map.new(WorldCoverage.required_failure_axes(), &{&1, [scenario_id]})
    }
  end

  defp fixture_root! do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "ryker-world-coverage-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture)
    on_exit(fn -> File.rm_rf!(fixture) end)

    source = Path.join(@scenario_root, "universal-webhook-unknown-payload")
    File.cp_r!(source, Path.join(fixture, "universal-webhook-unknown-payload"))
    fixture
  end
end

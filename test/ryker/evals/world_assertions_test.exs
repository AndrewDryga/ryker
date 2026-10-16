defmodule Ryker.Evals.WorldAssertionsTest do
  @moduledoc """
  The host checks a model-world run must pass before a judge reads it, over a
  recorded report: no model, no worker and no database.
  """
  use ExUnit.Case, async: true
  alias Ryker.Evals.{WorldAssertions, WorldCase}

  # The VA1 health snapshot of 2026-10-15 saved a confirmed failure whose cause
  # nobody had found as explained, while its own reason said the root causes
  # had not been established. Any saved finding passed the check.
  test "a finding is checked by the status it was saved with, not only by being saved" do
    scenario =
      scenario([
        %{
          "kind" => "state_tool_recorded",
          "tool" => "record_finding",
          "payload" => %{"status" => "unexplained"}
        },
        %{
          "kind" => "state_tool_not_recorded",
          "tool" => "record_finding",
          "payload" => %{"status" => "explained"}
        }
      ])

    assert scenario |> failures(report(records: [finding("explained")])) |> kinds() ==
             ["state_tool_recorded", "state_tool_not_recorded"]

    assert failures(scenario, report(records: [finding("unexplained")])) == []
  end

  defp scenario(hard) do
    {:ok, scenario} = WorldCase.fetch("confirmed-failure-with-unknown-cause-stays-unexplained")
    %{scenario | expect: %{"hard" => hard, "trajectory" => [], "quality_rubric" => []}}
  end

  defp failures(scenario, report),
    do: WorldAssertions.failures(scenario, report, [], :model_world)

  defp report(options) do
    %{
      deliveries: [],
      record_history: Keyword.get(options, :records, []),
      runtime: %{state_calls: Keyword.get(options, :calls, [])},
      source_calls: []
    }
  end

  defp finding(status),
    do: %{"kind" => "finding", "payload" => %{"status" => status, "what" => "Arena fails."}}

  defp kinds(failures), do: Enum.map(failures, & &1["kind"])
end

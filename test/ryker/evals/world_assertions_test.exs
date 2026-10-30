defmodule Ryker.Evals.WorldAssertionsTest do
  @moduledoc """
  The host checks a model-world run must pass before a judge reads it, over a
  recorded report: no model, no worker and no database.
  """
  use ExUnit.Case, async: true
  alias Ryker.Evals.{WorldAssertions, WorldCase}

  test "an inert proposal cannot satisfy the model world's automatic-start expectation" do
    scenario = scenario([%{"kind" => "started_tasks", "count" => 1}])

    proposal = %{
      "kind" => "task_offer",
      "status" => "open",
      "ref" => "task:one",
      "confirmed_episode_id" => nil
    }

    assert kinds(failures(scenario, report(records: [proposal]))) == ["started_tasks"]
    task = %{proposal | "status" => "confirmed", "confirmed_episode_id" => "episode:task"}
    assert failures(scenario, report(records: [task])) == []

    assert kinds(failures(scenario, report(records: [task, Map.put(task, "ref", "task:two")]))) ==
             ["started_tasks"]

    assert failures(
             scenario([%{"kind" => "started_tasks", "count" => 0}]),
             report(records: [proposal])
           ) == []
  end

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

  # 2026-10-13: a finding over its ten-citation bound was refused twice with
  # the same error, and the summary sent in the same batch was refused for the
  # null standing where the finding's ref would have been.
  test "a refusal sent again unchanged, and a refused write that depended on it, fail the run" do
    scenario =
      scenario([
        %{"kind" => "refusal_repaired_before_retry"},
        %{"kind" => "state_tool_not_refused", "tool" => "update_conversation_summary"}
      ])

    bound = "invalid_arguments: 1 issue. /cause_evidence (max_items): takes at most 10 items."

    repeated =
      report(
        calls: [
          call("record_finding", "failed", bound),
          call("record_finding", "failed", bound),
          call(
            "update_conversation_summary",
            "failed",
            "invalid_arguments: 1 issue. /state/evidence_refs/11 (type): must be a string."
          )
        ]
      )

    assert scenario |> failures(repeated) |> kinds() ==
             ["refusal_repaired_before_retry", "state_tool_not_refused"]

    repaired =
      report(
        calls: [
          call("record_finding", "failed", bound),
          call("record_finding", "succeeded", nil),
          call("update_conversation_summary", "succeeded", nil)
        ]
      )

    assert failures(scenario, repaired) == []
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

  defp call(tool, outcome, error),
    do: %{"error_digest" => error && digest(error), "outcome" => outcome, "tool" => tool}

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp kinds(failures), do: Enum.map(failures, & &1["kind"])
end

defmodule Ryker.Evals.WorldJudgeCaseTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.{WorldCase, WorldJudgeCase}

  test "compiles a bounded judge case and requires one verdict per rubric criterion" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    assert judge.schema["title"] == "Ryker model-world quality judgment"
    assert Jason.decode!(judge.prompt)["scenario_id"] == scenario.id

    candidate = %{
      "criteria" => [
        %{"index" => 0, "passed" => true, "reason" => "The verdict and scope lead."},
        %{"index" => 1, "passed" => true, "reason" => "No missing-evidence overclaim."}
      ],
      "overall_pass" => true
    }

    assert {:accept, %{passed: true, document: ^candidate}} =
             WorldJudgeCase.validate(judge, Jason.encode!(candidate))

    duplicate = put_in(candidate, ["criteria", Access.at(1), "index"], 0)

    assert {:reject, [violation]} = WorldJudgeCase.validate(judge, Jason.encode!(duplicate))
    assert violation =~ "exactly once"
  end

  test "a well-formed failing judgment is accepted as evidence but does not pass" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    candidate = %{
      "criteria" => [
        %{"index" => 0, "passed" => true, "reason" => "Clear opening."},
        %{"index" => 1, "passed" => false, "reason" => "It overstates missing evidence."}
      ],
      "overall_pass" => false
    }

    assert {:accept, %{passed: false}} = WorldJudgeCase.validate(judge, Jason.encode!(candidate))
  end

  test "the judge sees trusted source revisions that justify lifecycle deliveries" do
    {:ok, scenario} = WorldCase.fetch("terraform-run-update-stays-in-one-session")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    prompt = Jason.decode!(judge.prompt)

    assert [planning, applied] = prompt["evidence"]["source_events"]
    assert planning["payload"]["state"] == "planning"
    assert applied["payload"]["state"] == "applied"
    assert applied["payload"]["run_id"] == "run-okjyXsDYXyMqqBYY"
  end

  test "malformed quality judgments are repaired through the same bounded contract" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    assert {:error, {:invalid_world_judge, :fields}} = WorldJudgeCase.new(%{}, report())
    assert {:reject, [message]} = WorldJudgeCase.validate(judge, "not-json")
    assert message =~ "valid bounded quality judgment"

    assert {:reject, [message]} =
             WorldJudgeCase.validate(
               judge,
               Jason.encode!(%{"criteria" => [], "overall_pass" => true})
             )

    assert message =~ "criterion index"

    invalid_criterion = %{
      "criteria" => [
        %{"index" => 0, "passed" => true, "reason" => "Clear."},
        %{"index" => 1, "passed" => true, "reason" => " "}
      ],
      "overall_pass" => true
    }

    assert {:reject, [message]} =
             WorldJudgeCase.validate(judge, Jason.encode!(invalid_criterion))

    assert message =~ "criteria"

    inconsistent = put_in(invalid_criterion, ["criteria", Access.at(1), "reason"], "Grounded.")
    inconsistent = Map.put(inconsistent, "overall_pass", false)

    assert {:reject, [message]} = WorldJudgeCase.validate(judge, Jason.encode!(inconsistent))
    assert message =~ "overall_pass"

    assert {:reject, [_message]} = WorldJudgeCase.validate(:invalid, :invalid)
  end

  defp report do
    %{
      deliveries: [
        %{
          document: %{"message" => "Healthy in the assessed scope."},
          kind: :message,
          target: %{conversation_ref: "eval:case", thread_ref: "eval:thread", transport: "eval"}
        }
      ],
      records: [
        %{
          "kind" => "evidence",
          "payload" => %{"observation" => "No firing alerts."},
          "ref" => "record:evidence:one",
          "status" => "open"
        }
      ],
      source_calls: [
        %{
          arguments: %{"environment" => "va1", "query" => "firing_alerts"},
          arguments_sha256: String.duplicate("a", 64),
          outcome: :result,
          tool: "monitoring.query"
        }
      ]
    }
  end
end

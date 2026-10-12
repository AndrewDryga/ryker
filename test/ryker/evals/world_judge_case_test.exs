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
    assert applied["payload"]["run_id"] == "run-5gvASLsVavas4TRg"
  end

  # 2026-10-04 review: va1's scenario records a host correction from the run it was harvested
  # from. The runner drives input events alone, yet the judge was shown every event as trusted
  # evidence, so it could credit the judged run with a correction that run never made.
  test "the judge is shown only the events the run was driven by" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    assert Enum.any?(scenario.events, &(&1["kind"] == "semantic_correction"))
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    events = Jason.decode!(judge.prompt)["evidence"]["source_events"]

    assert events != []
    assert Enum.all?(events, &(&1["kind"] == "input"))
  end

  test "the judge sees sanitized trusted state-tool outcomes" do
    {:ok, scenario} = WorldCase.fetch("missing-project-answer-is-remembered")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    prompt = Jason.decode!(judge.prompt)

    assert prompt["evidence"]["state_calls"] == [
             %{"outcome" => "succeeded", "tool" => "remember_answer"}
           ]

    assert Enum.any?(prompt["instructions"], &String.contains?(&1, "state calls"))
  end

  test "identical replies cannot hide different committed routing ownership from the judge" do
    # The review reproduced byte-identical judge prompts for separate episodes
    # and a wrongly merged episode. That blind spot could falsely qualify the
    # cross-environment rubric without changing a single delivered sentence.
    {:ok, scenario} = WorldCase.fetch("similar-alert-different-environment-stays-separate")

    first = routing_turn("episode:production", "session:production", "turn:one", "input:one")
    second = routing_turn("episode:staging", "session:staging", "turn:two", "input:two")
    separate_report = put_in(report(), [:runtime, :turns], [first, second])

    merged_second =
      second
      |> Map.put(:episode_id, first.episode_id)
      |> Map.put(:session_id, first.session_id)
      |> put_in([:routing, :action], "continue_episode")
      |> put_in([:routing, :relation], "same_work")

    merged_report = put_in(separate_report, [:runtime, :turns], [first, merged_second])
    {:ok, separate} = WorldJudgeCase.new(scenario, separate_report)
    {:ok, merged} = WorldJudgeCase.new(scenario, merged_report)

    refute separate.prompt == merged.prompt
    prompt = Jason.decode!(separate.prompt)
    assert [first_evidence, second_evidence] = prompt["evidence"]["routing"]
    assert first_evidence["episode_id"] == "episode:production"
    assert second_evidence["episode_id"] == "episode:staging"
    assert second_evidence["session_id"] == "session:staging"
    assert second_evidence["turn_id"] == "turn:two"
    assert second_evidence["input_provenance"]["source_item_ref"] == "input:two"
    assert second_evidence["input_clock"]["mode"] == "simulated"
    assert second_evidence["routing"]["mode"] == "model_admission"
    assert second_evidence["routing"]["action"] == "start_episode"
    refute Map.has_key?(second_evidence, "submission")

    assert Enum.any?(
             prompt["instructions"],
             &String.contains?(&1, "committed episode and session")
           )

    assert Enum.any?(prompt["instructions"], &String.contains?(&1, "forced_host_scenario"))
  end

  test "malformed quality judgments are repaired through the same bounded contract" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, judge} = WorldJudgeCase.new(scenario, report())

    assert WorldJudgeCase.new(%{}, report()) == {:error, {:invalid_world_judge, :fields}}
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

  defp routing_turn(episode_id, session_id, turn_id, input_ref) do
    %{
      episode_id: episode_id,
      session_id: session_id,
      turn_id: turn_id,
      input_clock: %{mode: "simulated", source_occurred_at: "2026-08-27T12:00:00Z"},
      input_provenance: %{source_item_ref: input_ref, source: %{kind: "slack"}},
      routing: %{action: "start_episode", mode: "model_admission", relation: "unrelated"},
      submission: "Not part of the judge evidence boundary."
    }
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
      ],
      runtime: %{
        state_calls: [%{outcome: :succeeded, tool: "remember_answer"}],
        turns: []
      }
    }
  end
end

defmodule Ryker.Evals.ImprovementReplayCaseTest do
  # The self-analysis prompt had no model eval. Its first run on live (2026-09-30, the task behind
  # PR #2 in AndrewDryga/test, once a task's rating could be analyzed) answered with this
  # diagnosis, harvested: the fault unclear, first at work, low confidence. A replay asks the same
  # evidence again under today's instructions and passes when the fault lands in the same place.
  use ExUnit.Case, async: true
  alias Ryker.Evals.{ImprovementReplay, ImprovementReplayCase}
  alias Ryker.Improvement.Prompt

  @recorded File.read!("test/ryker/evals/fixtures/improvement_analysis_pr2_task.json")
  @context %{
    "request" => %{"kind" => "work", "channel" => "slack", "state" => "complete"},
    "conversation" => [],
    "routing" => [],
    "work" => [],
    "feedback" => [],
    "omitted" => []
  }

  test "a recorded analysis is asked again with today's instructions over the same evidence" do
    recorded_prompt =
      Prompt.render(%{"instructions" => "Older instructions.", "context" => @context})

    assert {:ok, replay} =
             ImprovementReplayCase.new(%{
               "run_id" => "run-1",
               "prompt" => recorded_prompt,
               "result" => @recorded
             })

    assert replay.eval_id == "improvement-replay:run-1"
    assert replay.prompt =~ "diagnose what went wrong"
    refute replay.prompt =~ "Older instructions."
    assert Jason.decode!(replay.prompt)["context"] == @context
    assert replay.schema == Prompt.output_schema()
    assert replay.recorded == %{"category" => "unclear", "step" => "work"}

    assert {:accept, %{passed: true, document: document}} =
             ImprovementReplayCase.validate(replay, @recorded)

    assert document["confidence"] == "low"

    moved = @recorded |> Jason.decode!() |> Map.put("step", "routing") |> Jason.encode!()
    assert {:accept, %{passed: false}} = ImprovementReplayCase.validate(replay, moved)

    assert {:reject, [_repair]} =
             ImprovementReplayCase.validate(replay, ~s({"category":"unclear"}))
  end

  test "an export line that is not a recorded analysis is skipped with why" do
    path =
      Path.join(System.tmp_dir!(), "improvement-runs-#{System.unique_integer([:positive])}.jsonl")

    good = %{
      "run_id" => "run-2",
      "prompt" => Prompt.render(%{"instructions" => "x", "context" => @context}),
      "result" => @recorded
    }

    File.write!(
      path,
      Enum.join([Jason.encode!(good), "not json", Jason.encode!(%{"run_id" => "run-3"})], "\n")
    )

    try do
      assert {:ok, [case], skipped} = ImprovementReplay.cases(path)
      assert case.eval_id == "improvement-replay:run-2"
      assert Enum.map(skipped, & &1.line) == [2, 3]
    after
      File.rm(path)
    end

    assert {:error, {:improvement_runs_not_found, _path}} =
             ImprovementReplay.cases("/nonexistent/runs.jsonl")
  end
end

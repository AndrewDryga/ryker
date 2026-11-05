defmodule Ryker.Evals.ReactionConversationTest do
  use ExUnit.Case, async: true
  alias Ryker.Evals.{Evidence, Job, ReactionConversation}
  alias Ryker.TestSupport.FakeCoopAPI

  test "the next admission sees prior simulated choices and the judge sees the whole exchange" do
    # These are protocol doubles for the evaluator, not harvested model output.
    {:ok, subject} =
      FakeCoopAPI.start_link([
        decision(["eyes"]),
        decision(["plus"]),
        decision(["tada", "raised_hands"])
      ])

    {:ok, judge} = FakeCoopAPI.start_link([judgment(true)])
    {:ok, report} = ReactionConversation.run(options(subject, :routing), options(judge, :judge))

    assert report.passed
    assert report.hard_failures == []

    assert report.requested_targets == %{
             routing: "codex:fixture/low@eval",
             judge: "codex:fixture/low@eval"
           }

    assert {:ok, _generated_at, 0} = DateTime.from_iso8601(report.generated_at)
    assert length(report.choices) == 3
    prompt = subject |> FakeCoopAPI.state() |> Map.fetch!(:submitted_prompt) |> Jason.decode!()
    assert prompt["context"]["input"]["content"]["text"] == "Fixed"

    assert prompt["context"]["slack_addressing"] == %{
             "audience" => "ambient",
             "ryker_user_ref" => "URYKER"
           }

    assert prompt["instructions"] =~ "slack_addressing says how the message reached Ryker"
    assert [first, second] = prompt["context"]["conversation_context"]["messages"]
    assert Enum.map(first["ryker_reactions"], & &1["emoji"]) == ["eyes"]
    assert Enum.map(second["ryker_reactions"], & &1["emoji"]) == ["plus"]
    assert prompt["context"]["conversation_context"]["custom_emoji"]["names"] == ["plus"]

    evidence = judge |> FakeCoopAPI.state() |> Map.fetch!(:submitted_prompt) |> Jason.decode!()
    assert length(evidence["evidence"]["choices"]) == 3
    assert length(evidence["evidence"]["original_exchange"]) == 3
    assert FakeCoopAPI.state(subject).closed
    assert FakeCoopAPI.state(subject).discarded
    assert FakeCoopAPI.state(judge).discarded
  end

  test "a failing conversational judgment stays a failing evaluation" do
    {:ok, subject} = FakeCoopAPI.start_link(List.duplicate(decision(["thumbsup"]), 3))
    {:ok, judge} = FakeCoopAPI.start_link([judgment(false)])

    assert {:ok, %{passed: false, quality: %{status: :failed}}} =
             ReactionConversation.run(options(subject, :routing), options(judge, :judge))
  end

  # A failed worker turn carries tuple diagnostics. Writing the raw report
  # through Jason raised instead of preserving the failed evaluation.
  test "execution failures remain serializable with their diagnostic cause" do
    assert {:ok, report} = ReactionConversation.run([], [])
    refute report.passed
    printable = Evidence.json_value(report)
    decoded = printable |> Jason.encode!() |> Jason.decode!()
    assert [choice] = decoded["choices"]
    assert choice["result"]["reason"] =~ "invalid_eval_runner"
    assert decoded["quality"]["status"] == "unrun"
    refute decoded["passed"]
  end

  test "a missing or relative report path explains the required command before any model starts" do
    for args <- [[], ["--results", "relative.json"]] do
      assert_raise Mix.Error, ~r/absolute --results path/, fn ->
        Mix.Tasks.Ryker.Eval.run(["reactions" | args])
      end
    end
  end

  defp options(client, kind) do
    {:ok, job} = Job.new(kind, "codex:fixture/low@eval")

    [
      api: FakeCoopAPI,
      client: client,
      job: job,
      max_polls: 10,
      poll_interval_ms: 0,
      sleep: fn 0 -> :ok end
    ]
  end

  defp decision(reactions) do
    Jason.encode!(%{
      "action" => "react",
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => reactions,
      "relation" => "unrelated",
      "reason" => "A brief acknowledgement.",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => nil
    })
  end

  defp judgment(passed) do
    Jason.encode!(%{
      "overall_pass" => passed,
      "criteria" =>
        Enum.map(
          0..3,
          &%{"index" => &1, "passed" => passed, "reason" => "Evaluator protocol double."}
        )
    })
  end
end

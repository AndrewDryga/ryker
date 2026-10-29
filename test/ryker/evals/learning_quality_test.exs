defmodule Ryker.Evals.LearningQualityTest do
  use ExUnit.Case, async: true
  alias Ryker.Evals.{Job, LearningQuality, LearningRunner}
  alias Ryker.TestSupport.FakeCoopAPI, as: Fake

  test "an unrelated answer cannot pass because Work delivered it" do
    probe = LearningQuality.probe("relative-dates")

    result =
      LearningQuality.assess(probe, sources("relative-dates"), "The service is healthy.", nil)

    assert result.status == :failed
    assert result.reason == :required_fact_missing
    assert Enum.all?(result.checks, &(not &1.passed))
  end

  test "correct date tokens without a semantic assessment remain unassessed" do
    probe = LearningQuality.probe("relative-dates")
    result = LearningQuality.assess(probe, sources("relative-dates"), deadline_answer(), nil)
    assert result.status == :unassessed
    assert Enum.all?(result.checks, & &1.passed)
    assert result.judgment == nil
  end

  test "equivalent UTC timestamps and numeric formatting reach semantic assessment" do
    # Exactness concerns the value, not whether the model prints ISO or prose.
    for answer <- [
          "2026-09-10T10:30:00Z",
          "2026-09-10T10:30:00+00:00",
          "September 10, 2026 at 10:30:00 UTC"
        ] do
      assert LearningQuality.assess(LearningQuality.probe("relative-dates"), [], answer, nil).status ==
               :unassessed
    end

    assert LearningQuality.assess(
             LearningQuality.probe("exact-values"),
             [],
             "95.0 percent; 6:54:40, 7:13:40 and 7:52:40 UTC.",
             nil
           ).status == :unassessed
  end

  test "equivalent formatting does not admit a different time, offset or threshold" do
    for answer <- ["2026-09-10T10:30:01Z", "2026-09-10T10:30:00+01:00"] do
      assert LearningQuality.assess(LearningQuality.probe("relative-dates"), [], answer, nil).status ==
               :failed
    end

    for threshold <- ["195%", "95.01%"] do
      answer = threshold <> "; 06:54:40, 07:13:40 and 07:52:40 UTC."

      assert LearningQuality.assess(LearningQuality.probe("exact-values"), [], answer, nil).status ==
               :failed
    end
  end

  test "a source-grounded answer passes only after the judge finishes and cleans up" do
    probe = LearningQuality.probe("relative-dates")
    {:ok, fake} = Fake.start_link([verdict([true, true])])
    original = sources("relative-dates")
    result = LearningQuality.assess(probe, original, deadline_answer(), options(fake))
    assert result.status == :passed
    assert result.judgment.cleanup_error == nil
    assert Fake.state(fake).discarded

    prompt = Fake.state(fake).submitted_prompt |> Jason.decode!()
    assert prompt["evidence"]["original_inputs"] == original
    assert prompt["evidence"]["answer"] == deadline_answer()
    refute Map.has_key?(prompt["evidence"], "topics")
    assert Jason.decode!(result.request.prompt) == prompt
    assert result.request.job.name == "ryker-eval-judge"
    assert result.request.output_schema["properties"]["criteria"]["minItems"] == 2
  end

  test "a contradictory claim fails even when every required value is present" do
    probe = LearningQuality.probe("relative-dates")
    {:ok, fake} = Fake.start_link([verdict([true, false])])
    answer = deadline_answer() <> " The deployment and monitoring definitely completed."
    result = LearningQuality.assess(probe, sources("relative-dates"), answer, options(fake))
    assert Enum.all?(result.checks, & &1.passed)
    assert result.status == :failed
    refute result.judgment.decision["overall_pass"]
  end

  test "a judge outage leaves correctness unassessed, never passed or a model-quality failure" do
    probe = LearningQuality.probe("relative-dates")
    {:ok, fake} = Fake.start_link([], fail_create: true)

    result =
      LearningQuality.assess(probe, sources("relative-dates"), deadline_answer(), options(fake))

    assert result.status == :unassessed
    assert result.judgment.decision == nil
  end

  test "loss of an exact threshold or event time is caught before spending a judge call" do
    probe = LearningQuality.probe("exact-values")
    answer = "95%; 06:54:40, 07:13:40 and 07:52:40 UTC."

    assert LearningQuality.assess(probe, sources("exact-values"), answer, nil).status ==
             :unassessed

    for value <- ["95%", "06:54:40", "07:13:40", "07:52:40"] do
      result =
        LearningQuality.assess(
          probe,
          sources("exact-values"),
          String.replace(answer, value, "unknown"),
          nil
        )

      assert result.status == :failed
      assert Enum.count(result.checks, &(not &1.passed)) == 1
    end
  end

  test "both new cases reuse captured bytes and original source times" do
    [step] = LearningRunner.recorded_sequence("relative-dates")
    fixture = step.fixture |> File.read!() |> Jason.decode!()
    assert step.input["content"]["text"] == fixture["candidate"]["message"]
    assert step.input["occurred_at"] == fixture["source"]["accepted_at"]
    assert step.adapter == :retained_reply

    assert LearningRunner.recorded_sequence("exact-values") ==
             LearningRunner.recorded_sequence("auth-memory-recurrence")

    assert LearningQuality.valid?(LearningQuality.probe("relative-dates"))
    assert LearningQuality.valid?(LearningQuality.probe("exact-values"))
    refute LearningQuality.valid?(%{question: ""})
  end

  defp sources(scenario), do: Enum.map(LearningRunner.recorded_sequence(scenario), & &1.input)

  # Constructed answers test the evaluator, not model ability. The dates and
  # values above come from the preserved sources, never a fabricated harvest.
  defp deadline_answer,
    do: "The reply promised 10 September 2026 at 10:30 UTC; completion is unverified."

  defp verdict(values) do
    criteria =
      Enum.with_index(values, fn passed, index ->
        %{"index" => index, "passed" => passed, "reason" => "Constructed evaluator verdict."}
      end)

    Jason.encode!(%{"criteria" => criteria, "overall_pass" => Enum.all?(values)})
  end

  defp options(fake) do
    [
      api: Fake,
      client: fake,
      job: elem(Job.new(:judge, "codex:fixture/low@eval"), 1),
      id_generator: fn -> "learning-quality-test" end,
      max_polls: 2,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end

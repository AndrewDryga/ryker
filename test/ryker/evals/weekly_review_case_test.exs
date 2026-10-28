defmodule Ryker.Evals.WeeklyReviewCaseTest do
  use ExUnit.Case, async: true
  alias Ryker.Evals.{Job, WeeklyReviewCase}
  alias Ryker.WeeklyReport.ReviewPrompt

  # Published October 27 readiness finding from the observation-card report,
  # pseudonymized. The shared zone is evidence of risk, not of a live outage.
  @manifest %{
    "evidence" => [
      %{
        "id" => "e1",
        "answer" => "Both application endpoints pass readiness; both VMs are in us-central1-a."
      }
    ]
  }

  test "qualification uses the production prompt and filtered source-free worker policy" do
    assert {:ok, eval} = WeeklyReviewCase.new(@manifest)
    assert eval.prompt == ReviewPrompt.render(@manifest)
    assert eval.schema == ReviewPrompt.output_schema()
    assert {:ok, job} = Job.new(:weekly_review, "codex:gpt-6&sol@default")

    assert job.document["egress"] == %{
             "mode" => "filtered",
             "rules" => [],
             "export_destinations" => false
           }

    assert job.document["source"] == nil
    assert {:ok, _, _} = Job.bind(job, "weekly-qualification")
  end

  test "an invalid first answer fails without a repair call and evidence IDs remain exact" do
    {:ok, eval} = WeeklyReviewCase.new(@manifest)
    assert {:accept, %{passed: false}} = WeeklyReviewCase.validate(eval, "not JSON")

    assert {:accept, %{passed: true}} =
             WeeklyReviewCase.validate(eval, ~s({"recommendations":[]}))

    recommendation = %{
      "problem_key" => "shared-zone",
      "action" => "Review zone diversity.",
      "benefit" => "Reduce shared failure risk.",
      "evidence_ids" => ["absent"]
    }

    assert {:accept, %{passed: false}} =
             WeeklyReviewCase.validate(
               eval,
               Jason.encode!(%{"recommendations" => [recommendation]})
             )
  end
end

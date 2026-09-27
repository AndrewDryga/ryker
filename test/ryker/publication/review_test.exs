defmodule Ryker.Publication.ReviewTest do
  use ExUnit.Case, async: true

  alias Ryker.Publication.Review

  test "publication retains metadata even when Coop includes a large truncated display preview" do
    document =
      review_document()
      |> Map.merge(%{
        "patch" => Base.encode64(String.duplicate("x", 1_024 * 1_024)),
        "patch_truncated" => true,
        "source" => %{"repository" => "repo"}
      })

    assert {:ok, retained} =
             Review.prepare(document, %{revision: 7, session_id: "session-review"})

    refute Map.has_key?(retained, "patch")
    refute Map.has_key?(retained, "source")
    assert Review.draft_shareable?(retained)

    assert {:error, {:invalid_publication_review, :fields}} =
             Review.prepare(Map.put(document, "unknown", true), %{
               revision: 7,
               session_id: "session-review"
             })
  end

  test "malformed pull request identities fail closed without raising" do
    expected = %{revision: 7, session_id: "session-review"}

    for head <- [nil, %{}, 42, "not-a-commit"] do
      document = put_in(review_document(), ["pull_request", "head_commit"], head)

      assert Review.prepare(document, expected) ==
               {:error, {:invalid_publication_review, :pull_request}}
    end
  end

  # Andrew's 2026-09-09 recovery of the hosted-runner bump: the worker's gate
  # could not start because Docker was missing, so the change was never
  # publishable, yet its snapshot was exactly identified and safe to share.
  # "Do not just enable the current publish button" — a draft that a person can
  # read is a different question from a change that is ready to merge, and one
  # verdict answering both is how a missing tool, a failed assertion and a
  # policy finding end up equated.
  test "a shareable draft snapshot is a separate verdict from merge readiness" do
    unavailable =
      review_document()
      |> Map.merge(%{
        "gate" => "startup_error",
        "gate_error" => "docker: command not found",
        "not_publishable_reasons" => ["The gate could not start."],
        "publishable" => false
      })

    refute Review.publishable?(unavailable)
    assert Review.draft_shareable?(unavailable)

    verdict = Review.draft_verdict(unavailable)
    assert verdict["shareable"]
    assert verdict["gate"] == "startup_error"
    assert verdict["incomplete_checks"] == ["docker: command not found"]

    passed = review_document()
    assert Review.publishable?(passed)
    assert Review.draft_shareable?(passed)
    assert Review.draft_verdict(passed)["incomplete_checks"] == []
  end

  test "an unknown gate is shareable while a failed gate returns to correction" do
    for gate <- ~w(not_run none) do
      document = unpublishable(%{"gate" => gate})
      assert Review.draft_shareable?(document), "#{gate} is an unfinished check, not a verdict"
      assert Review.draft_verdict(document)["incomplete_checks"] != []
    end

    failed = unpublishable(%{"gate" => "failed", "gate_error" => "2 tests failed"})
    refute Review.draft_shareable?(failed)
    assert Review.draft_verdict(failed)["reasons"] == ["The trusted gate failed."]

    # A gate that ran and failed has a result, so it is never a missing check —
    # and the stage ledger that asked only for missing checks put a ✓ on the one
    # stage whose whole job is to say whether the change was checked.
    assert Review.draft_verdict(failed)["incomplete_checks"] == []
    assert Review.gate_failure(failed) == "2 tests failed"
    assert Review.gate_failure(Map.delete(failed, "gate_error")) == "The trusted gate failed."
    assert Review.gate_failure(%{failed | "gate_error" => "  "}) == "The trusted gate failed."

    for gate <- ~w(passed startup_error not_run none) do
      assert Review.gate_failure(unpublishable(%{"gate" => gate})) == nil
    end

    assert Review.gate_failure(nil) == nil
  end

  test "a finding, a conflict or an inexact snapshot can never be shared as a draft" do
    findings = unpublishable(%{"policy_findings" => ["A secret was written to lib/token.ex."]})
    refute Review.draft_shareable?(findings)

    assert Review.draft_verdict(findings)["reasons"] == [
             "The trusted policy review found 1 issue."
           ]

    conflict = unpublishable(%{"rebase" => "conflict"})
    refute Review.draft_shareable?(conflict)

    truncated = unpublishable(%{"patch_truncated" => true})
    assert Review.draft_shareable?(truncated)

    for missing <- ~w(candidate_retained candidate_head candidate_tree) do
      refute Review.draft_shareable?(unpublishable() |> Map.delete(missing)),
             "#{missing} is part of the exact snapshot identity"
    end

    refute Review.draft_shareable?(unpublishable(%{"candidate_retained" => false}))

    refute Review.draft_shareable?(
             unpublishable(%{"candidate_tree" => String.duplicate("5", 40)})
           )

    refute Review.draft_shareable?(%{})
    refute Review.draft_shareable?(nil)
  end

  # "Secret/path/identity/authorization failures cannot be bypassed to create any
  # PR." A refusal the typed fields do not account for is exactly that class: the
  # host cannot read the reason, so it cannot decide the snapshot is safe. Every
  # other clause here returns nil for a clean gate, so without this one a review
  # that refuses for an unnamed reason would have read as shareable.
  test "a refusal the typed verdict cannot explain is never shareable" do
    unexplained =
      review_document()
      |> Map.merge(%{
        "not_publishable_reasons" => ["The candidate identity could not be attributed."],
        "publishable" => false
      })

    refute Review.draft_shareable?(unexplained)

    assert Review.draft_verdict(unexplained)["reasons"] == [
             "The trusted review refused this candidate without a reason the host can read."
           ]

    # An unfinished check is a reason the host can read, so it stays shareable.
    assert Review.draft_shareable?(unpublishable())
  end

  defp unpublishable(overrides \\ %{}) do
    review_document()
    |> Map.merge(%{
      "gate" => "startup_error",
      "not_publishable_reasons" => ["The gate could not start."],
      "publishable" => false
    })
    |> Map.merge(overrides)
  end

  defp review_document do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "operation-review",
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "candidate_retained" => true,
      "patch_truncated" => false,
      "job_digest" => String.duplicate("a", 64),
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => %{
        "head_commit" => String.duplicate("9", 40),
        "number" => 42,
        "ref" => "refs/heads/ryker/fix"
      },
      "rebase" => "clean",
      "session_id" => "session-review",
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end
end

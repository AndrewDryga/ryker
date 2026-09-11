defmodule Responder.Publication.ReviewTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.Review

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
    refute Review.draft_shareable?(truncated)

    for missing <- ~w(patch_artifact_id patch_digest) do
      refute Review.draft_shareable?(unpublishable() |> Map.delete(missing)),
             "#{missing} is part of the exact snapshot identity"
    end

    refute Review.draft_shareable?(unpublishable(%{"patch_bytes" => 0}))
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
      "patch_artifact_id" => "patch-review",
      "patch_bytes" => 1,
      "patch_digest" => String.duplicate("8", 64),
      "patch_truncated" => false,
      "policy_digest" => String.duplicate("a", 64),
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => %{
        "head_commit" => String.duplicate("9", 40),
        "number" => 42,
        "ref" => "refs/heads/responder/fix"
      },
      "rebase" => "clean",
      "session_id" => "session-review",
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end
end

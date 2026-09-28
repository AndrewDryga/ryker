defmodule Ryker.Publication.ReviewTest do
  use ExUnit.Case, async: true

  alias Ryker.Fixtures.Publication, as: PublicationFixture
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

  # 2026-09-28, #test: Coop refused a committed change with
  # `not_publishable_reasons: ["gate_failed"]`. The review card printed
  # "Blocked by: gate_failed" and the task card said "no cause was recorded",
  # so the one person who could act had to know Coop's vocabulary to learn that
  # the repository's checks had failed. Every code Coop sends
  # (internal/sessionsvc/review.go) needs words, and a code this host has never
  # seen must still say the review refused the change without echoing it.
  test "every reason a review can refuse a change for reads as plain words" do
    codes =
      ~w(fork_owner_active gate_failed gate_modified_candidate gate_not_configured gate_startup_error no_changes parent_moved policy_findings rebase_conflict source_moved)

    for code <- codes do
      assert [clause] = Review.refusal(%{"not_publishable_reasons" => [code]}), code
      refute clause =~ "_", "#{code} read as #{inspect(clause)}"
      refute clause =~ "review refused the change", "#{code} has no words of its own"
    end

    assert Review.refusal(PublicationFixture.harvested_refusal()) == [
             "the repository's checks failed on the committed change"
           ]

    assert Review.refusal(%{"not_publishable_reasons" => ["lfs_object_missing"]}) == [
             "the review refused the change for a reason I don't recognize"
           ]

    # The gate never runs on a change that no longer applies; that is the
    # conflict, not a second thing to fix.
    assert Review.refusal(%{
             "gate" => "not_run",
             "not_publishable_reasons" => ["rebase_conflict"],
             "rebase" => "conflict"
           }) == ["the change conflicts with the latest base branch"]

    assert Review.refusal(%{"gate" => "not_run"}) == ["the repository's checks didn't run"]

    # The typed fields name a cause even where no code repeats it, and the
    # findings come last so the files they name can follow them.
    assert Review.refusal(%{
             "gate" => "failed",
             "policy_findings" => ["secret-like file: .env", "secret-like file: id_rsa"],
             "not_publishable_reasons" => ["policy_findings", "lfs_object_missing"]
           }) == [
             "the repository's checks failed on the committed change",
             "the review refused the change for a reason I don't recognize",
             "the safety scan flagged 2 issues in the change"
           ]

    assert Review.refusal(review_document()) == []
    assert Review.refusal(nil) == []
  end

  # Andrew's request, 2026-09-28: a refusal the task's own work can fix goes
  # back to it without a person, one that is only the moment it was checked is
  # checked again, and anything else waits for someone. The sorting is the
  # whole safety of the loop: a finding such as a possible credential looped
  # back to the agent would let the model decide what may leave the working
  # copy, and a reason this host cannot read is never guessed at.
  test "each refusal is fixed by its work, checked again, or left for a person" do
    refused = fn overrides ->
      review_document()
      |> Map.merge(%{"publishable" => false, "candidate_retained" => false})
      |> Map.merge(overrides)
    end

    finding = "possible secret in lib/token.ex — remove the credential before publication"

    assert Review.remedy(review_document()) == nil
    assert Review.remedy(PublicationFixture.harvested_refusal()) == :fix

    for {overrides, remedy} <- [
          {%{"gate" => "failed", "not_publishable_reasons" => ["gate_failed"]}, :fix},
          {%{
             "gate" => "not_run",
             "not_publishable_reasons" => ["rebase_conflict"],
             "rebase" => "conflict"
           }, :fix},
          {%{"not_publishable_reasons" => ["gate_modified_candidate"]}, :fix},
          {%{"gate" => "failed", "not_publishable_reasons" => ["gate_failed", "parent_moved"]},
           :fix},
          {%{"not_publishable_reasons" => ["parent_moved"]}, :recheck},
          {%{"not_publishable_reasons" => ["source_moved", "fork_owner_active"]}, :recheck},
          {%{"not_publishable_reasons" => ["policy_findings"], "policy_findings" => [finding]},
           :person},
          {%{
             "gate" => "failed",
             "not_publishable_reasons" => ["gate_failed"],
             "policy_findings" => [finding]
           }, :person},
          {%{"not_publishable_reasons" => ["no_changes"]}, :person},
          {%{"gate" => "none", "not_publishable_reasons" => ["gate_not_configured"]}, :person},
          {%{"gate" => "startup_error", "not_publishable_reasons" => ["gate_startup_error"]},
           :person},
          {%{"gate" => "not_run"}, :person},
          {%{"gate" => "failed", "not_publishable_reasons" => ["gate_failed", "lfs_missing"]},
           :person},
          {%{"not_publishable_reasons" => []}, :person},
          {%{"gate" => "failed", "policy_findings" => "unreadable"}, :person}
        ] do
      assert Review.remedy(refused.(overrides)) == remedy, inspect(overrides)
    end

    assert Review.remedy(nil) == :person

    assert Review.fixable(
             refused.(%{
               "gate" => "failed",
               "not_publishable_reasons" => ["gate_modified_candidate", "gate_failed"]
             })
           ) == ["gate_failed", "gate_modified_candidate"]
  end

  # Coop's proposed report of a failed gate (2026-09-28, not final) is the
  # agent's only view of what failed without running the gate again. Before
  # this the host refused any review carrying a field it did not know, so the
  # first job that asked for the report would have had every review refused;
  # it is evidence, never the verdict, so one of another shape is dropped
  # instead, and what is kept is bounded and holds nothing the store refuses.
  test "a failed gate's report is kept bounded and clean, and a malformed one is dropped" do
    expected = %{revision: 7, session_id: "session-review"}

    report = %{
      "command" => "./run gate review",
      "exit_code" => 1,
      "output_tail" => "1 test failed:\n  test/parser_test.exs:12\n",
      "output_truncated" => false
    }

    failed =
      review_document()
      |> Map.merge(%{
        "gate" => "failed",
        "not_publishable_reasons" => ["gate_failed"],
        "publishable" => false
      })

    assert {:ok, %{"gate_failure" => ^report}} =
             Review.prepare(Map.put(failed, "gate_failure", report), expected)

    long = String.duplicate("é", 40_000) <> "<nul>" <> <<0>> <> "last line"
    noisy = %{report | "output_tail" => long}

    assert {:ok, %{"gate_failure" => kept}} =
             Review.prepare(Map.put(failed, "gate_failure", noisy), expected)

    assert byte_size(kept["output_tail"]) <= 65_536
    assert String.valid?(kept["output_tail"])
    assert String.ends_with?(kept["output_tail"], "<nul>last line")
    assert kept["output_truncated"]

    for malformed <- [
          Map.delete(report, "exit_code"),
          Map.put(report, "stderr", "extra"),
          %{report | "exit_code" => "1"},
          %{report | "command" => " "},
          "gate failed"
        ] do
      assert {:ok, prepared} =
               Review.prepare(Map.put(failed, "gate_failure", malformed), expected)

      refute Map.has_key?(prepared, "gate_failure"), inspect(malformed)
    end

    assert {:ok, passed} =
             Review.prepare(Map.put(review_document(), "gate_failure", report), expected)

    refute Map.has_key?(passed, "gate_failure")
  end

  # Coop's policy scan words each finding as one of a few sentences around the
  # path it names (internal/sessionsvc/review_scan.go at the worker's Coop,
  # 126f5d07). A card that prints them whole reads Coop's phrasing as Ryker's,
  # and one Coop has not worded before would print unread.
  test "a policy finding names its file and says what is wrong in the host's words" do
    assert Review.findings([
             "secret-like file: config/prod.secret.exs",
             "possible secret in lib/token.ex — remove the credential before publication",
             "package.json adds a postinstall script — npm runs it automatically on install",
             "web/package.json cannot be inspected for automatic install scripts",
             ".envrc — Runs when you enter the folder with direnv.",
             ".github/workflows/deploy.yml — Runs on the project's CI runners.",
             "SECRET_DETECTED lib/token.ex"
           ]) == [
             {"config/prod.secret.exs", "looks like a file that holds secrets"},
             {"lib/token.ex", "may contain a credential"},
             {"package.json",
              "adds an npm postinstall script, which runs automatically on install"},
             {"web/package.json", "couldn't be checked for automatic install scripts"},
             {".envrc", "runs when you enter the folder with direnv"},
             {".github/workflows/deploy.yml", "runs on the project's CI runners"},
             :unrecognized
           ]

    assert Review.findings(nil) == []
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

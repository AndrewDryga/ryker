defmodule Responder.Emisar.ApprovalStatusTest do
  use ExUnit.Case, async: true

  alias Responder.Emisar.{ApprovalStatus, RunState}

  @fixture "test/responder/emisar/fixtures/wait_for_run_review_v1.json"

  test "accepts every exact remote status and assigns a bounded human label" do
    for status <- RunState.statuses() do
      assert {:ok, prepared} = ApprovalStatus.prepare(document(status))
      assert prepared["status"] == status
      assert is_binary(ApprovalStatus.label(status))
    end
  end

  # Four different things were all called "In progress", so the governed-action
  # card rendered byte-for-byte identically whether the action was still queued,
  # handed to the runner, executing, or being cancelled. An operator watching a
  # production restart could not tell that their cancellation was in flight.
  test "states an operator would act on differently do not share a label" do
    labels = Map.new(~w(pending sent running cancelling), &{&1, ApprovalStatus.label(&1)})

    assert map_size(Map.new(labels, fn {_status, label} -> {label, nil} end)) == 4,
           "expected four distinct labels, got #{inspect(labels)}"

    # Cancelling is the one that misleads: it must not read as forward progress.
    refute ApprovalStatus.label("cancelling") =~ "progress"
  end

  test "rejects crossed URLs, unknown status, and extra fields" do
    refute RunState.terminal?(:invalid)

    assert ApprovalStatus.prepare(%{document("success") | "run_url" => "http://example.test/run"}) ==
             {:error, {:invalid_emisar_approval_status, :document}}

    assert ApprovalStatus.prepare(%{document("success") | "status" => "invented"}) ==
             {:error, {:invalid_emisar_approval_status, :document}}

    assert ApprovalStatus.prepare(Map.put(document("success"), "approve", true)) ==
             {:error, {:invalid_emisar_approval_status, :document}}

    assert ApprovalStatus.prepare(:invalid) ==
             {:error, {:invalid_emisar_approval_status, :document}}
  end

  # Emisar's own published example is the contract between the two repositories.
  # A field it grows that this allowlist does not know fails closed here, in one
  # test, instead of silently dropping every governed-review card in production.
  test "Emisar's published review example survives this host's exact allowlist" do
    review = @fixture |> File.read!() |> Jason.decode!() |> get_in(["run", "review"])

    document =
      document("pending_approval")
      |> Map.merge(%{"request_id" => review["request_id"], "review" => review})

    assert {:ok, prepared} = ApprovalStatus.prepare(document)
    assert prepared["review"] == review

    # The receipt is evidence about ONE hold: a well-formed one for another
    # request is not this card's evidence.
    assert ApprovalStatus.prepare(%{document | "request_id" => "apr-other"}) ==
             {:error, {:invalid_emisar_approval_status, :document}}
  end

  test "a partial review stays held and reports the real distinct count once" do
    held =
      review(%{
        "status" => "pending",
        "approved_count" => 1,
        "decisions" => [approve("Jane Doe")]
      })

    assert {:ok, document} = ApprovalStatus.prepare(review_document(held))
    assert %{summary: summary, history: history} = ApprovalStatus.review_summary(document)
    assert summary == "◷ 1 of 2 reviews received."
    assert history == ["✓ Review granted by Jane Doe."]
    refute summary =~ "Waiting for"
  end

  test "two distinct reviewers release the action and the summary credits the quorum" do
    granted =
      review(%{
        "status" => "approved",
        "approved_count" => 2,
        "decisions" => [
          approve("Jane Doe"),
          approve("Sam Reviewer", "The runner and scope are correct.")
        ]
      })

    assert {:ok, document} = ApprovalStatus.prepare(review_document(granted))
    assert %{summary: summary, history: history} = ApprovalStatus.review_summary(document)
    assert summary == "✓ Review granted; 2 of 2 reviews received."

    assert history == [
             "✓ Review granted by Jane Doe.",
             "✓ Review granted by Sam Reviewer. Reason: The runner and scope are correct."
           ]
  end

  # The tally is Emisar's distinct-approver count. Recounting the history here
  # would turn a replayed or duplicated vote into a second reviewer and release
  # a quorum nobody reached.
  test "a duplicated vote in the history never raises the count" do
    replayed =
      review(%{
        "status" => "pending",
        "approved_count" => 1,
        "decisions" => [approve("Jane Doe"), approve("Jane Doe")]
      })

    assert {:ok, document} = ApprovalStatus.prepare(review_document(replayed))
    assert %{summary: "◷ 1 of 2 reviews received."} = ApprovalStatus.review_summary(document)
  end

  test "a denial after an approval is terminal and keeps both decisions" do
    denied =
      review(%{
        "status" => "denied",
        "approved_count" => 1,
        "decisions" => [approve("Jane Doe"), deny("Sam Reviewer", "Please narrow the query.")]
      })

    assert {:ok, document} = ApprovalStatus.prepare(review_document(denied))
    assert %{summary: summary, history: history} = ApprovalStatus.review_summary(document)

    assert summary == "✕ Review denied by Sam Reviewer."
    refute summary =~ "of 2"

    assert history == [
             "✓ Review granted by Jane Doe.",
             "✕ Review denied by Sam Reviewer. Reason: Please narrow the query."
           ]
  end

  test "expiry and cancellation after a partial review keep that review visible" do
    for {status, expected} <- [
          {"expired", "◷ Review window expired. 1 of 2 reviews received."},
          {"cancelled", "■ Review cancelled. 1 of 2 reviews received."}
        ] do
      lapsed =
        review(%{"status" => status, "approved_count" => 1, "decisions" => [approve("Jane Doe")]})

      assert {:ok, document} = ApprovalStatus.prepare(review_document(lapsed))
      assert %{summary: ^expected, history: history} = ApprovalStatus.review_summary(document)
      assert history == ["✓ Review granted by Jane Doe."]
    end
  end

  test "an override keeps the real count and mints no reviewer" do
    for {count, decisions, tally} <- [
          {0, [], "0 of 2 reviews received"},
          {1, [approve("Jane Doe")], "1 of 2 reviews received"}
        ] do
      overridden =
        review(%{
          "status" => "approved",
          "approved_count" => count,
          "decisions" => decisions,
          "override" => override("Alex Admin", "A second reviewer is unavailable.", count)
        })

      assert {:ok, document} = ApprovalStatus.prepare(review_document(overridden))
      assert %{summary: summary, history: history} = ApprovalStatus.review_summary(document)

      assert summary ==
               "✓ Review granted by Alex Admin; #{tally}; remaining reviews were overridden."

      # The reason belongs to the audit event, once, and the override is never a vote.
      refute summary =~ "unavailable"

      assert List.last(history) ==
               "⚠ Review granted by Alex Admin · admin override. Reason: A second reviewer is unavailable."

      assert length(history) == length(decisions) + 1
    end
  end

  test "an override with no reason fails closed rather than rendering an unexplained release" do
    for reason <- [nil, "", "   "] do
      unexplained =
        review(%{
          "status" => "approved",
          "approved_count" => 1,
          "decisions" => [approve("Jane Doe")],
          "override" => %{override("Alex Admin", "placeholder", 1) | "reason" => reason}
        })

      assert ApprovalStatus.prepare(review_document(unexplained)) ==
               {:error, {:invalid_emisar_approval_status, :document}}
    end
  end

  test "a failed poll reports an unavailable review and never a denial" do
    unavailable =
      document("pending_approval")
      |> Map.put("remote_error", "The approval read failed.")

    assert {:ok, prepared} = ApprovalStatus.prepare(unavailable)
    assert %{summary: summary, history: []} = ApprovalStatus.review_summary(prepared)

    assert summary == "⚠ Couldn't refresh review status. Check Emisar for the latest."
    refute summary =~ "denied"
  end

  test "rejects a review that invents a reviewer, a vote or a count it cannot hold" do
    invalid = [
      %{"status" => "invented"},
      %{"approved_count" => -1},
      # A tally above the requirement is not a receipt any decision could
      # produce; rendering it would state a quorum nobody reached.
      %{"approved_count" => 3},
      %{"required_approvals" => 0},
      %{"decisions" => [%{approve("Jane Doe") | "decision" => "maybe"}]},
      %{"decisions" => [Map.delete(approve("Jane Doe"), "decided_at")]},
      %{"decisions" => List.duplicate(approve("Jane Doe"), 21)},
      %{"command" => %{"kind" => "guessed", "text" => "rm -rf /", "truncated" => false}},
      %{"request_id" => "other-request"}
    ]

    for override_fields <- invalid do
      assert ApprovalStatus.prepare(review_document(review(override_fields))) ==
               {:error, {:invalid_emisar_approval_status, :document}},
             "accepted #{inspect(override_fields)}"
    end

    assert ApprovalStatus.prepare(review_document(Map.put(review(%{}), "invented", true))) ==
             {:error, {:invalid_emisar_approval_status, :document}}
  end

  defp review_document(review), do: Map.put(document("pending_approval"), "review", review)

  defp review(fields) do
    Map.merge(
      %{
        "request_id" => "apr-1",
        "status" => "pending",
        "required_approvals" => 2,
        "approved_count" => 0,
        "argument_count" => 2,
        "reason" => "Check whether the reload churn has settled.",
        "evidence" => "43 reloads in ten minutes across five allocations.",
        "expected" => "A time series showing whether reloads returned below the threshold.",
        "command" => %{
          "kind" => "preview",
          "text" => "vmctl query-range --query 'sum(...)' --step 60s",
          "truncated" => false
        },
        "decisions" => []
      },
      fields
    )
  end

  defp approve(actor, reason \\ nil), do: decision(actor, "approve", reason)
  defp deny(actor, reason), do: decision(actor, "deny", reason)

  defp decision(actor, decision, reason) do
    %{"actor" => actor, "decision" => decision, "decided_at" => "2026-09-11T08:07:23.379141Z"}
    |> then(&if reason, do: Map.put(&1, "reason", reason), else: &1)
  end

  defp override(actor, reason, approved_count) do
    %{
      "actor" => actor,
      "reason" => reason,
      "approved_count" => approved_count,
      "required_approvals" => 2,
      "waived_approvals" => 2 - approved_count,
      "decided_at" => "2026-09-11T08:07:23.488276Z"
    }
  end

  defp document(status) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => nil,
      "request_id" => "apr-1",
      "review" => nil,
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end
end

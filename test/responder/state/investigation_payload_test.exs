defmodule Responder.State.InvestigationPayloadTest do
  use ExUnit.Case, async: true

  alias Responder.State.InvestigationPayload

  test "a fully sized Unicode finding leaves room for every advertised evidence reference" do
    payload = %{
      "what" => String.duplicate("🟢", 4_000),
      "reason" => String.duplicate("🟢", 2_000),
      "scope" => String.duplicate("🟢", 2_000),
      "status" => "expected",
      "cause_evidence" =>
        Enum.map(
          1..10,
          &(String.duplicate("a", 253) <> String.pad_leading(to_string(&1), 3, "0"))
        )
    }

    assert {:ok, ^payload} = InvestigationPayload.prepare("finding", payload)
  end

  test "accepts the conditional finding, authority, and assessment shapes" do
    assert {:ok, _finding} =
             InvestigationPayload.prepare("finding", %{
               "cause_evidence" => ["record:evidence:cause"],
               "status" => "explained",
               "what" => "The service failed."
             })

    assert {:ok, _finding} =
             InvestigationPayload.prepare("finding", %{
               "reason" => "The scheduled restart occurred at its documented time.",
               "status" => "expected",
               "what" => "The service restarted."
             })

    assert {:ok, _goal} =
             InvestigationPayload.prepare("goal", %{
               "authority" => "repository_write",
               "completion_contract" => "The focused gate passes.",
               "id" => "fix-parser",
               "kind" => "engineering",
               "requested_outcome" => "Fix the parser",
               "required" => true,
               "writable_repository" => "responder"
             })

    assert {:ok, _assessment} =
             InvestigationPayload.prepare("alert_assessment", %{
               "impact" => "The alert reflects a scheduled restart.",
               "scope" => %{
                 "checked_targets" => ["service.production"],
                 "evidence_refs" => ["record:evidence:universe"],
                 "status" => "exhaustive",
                 "universe_evidence_ref" => "record:evidence:universe",
                 "unverified_targets" => []
               },
               "verdict" => "not_issue"
             })
  end

  test "rejects malformed investigation payloads at their actionable field" do
    non_maps = ~w(evidence coverage finding progress goal goal_state alert_assessment)

    Enum.each(non_maps, fn kind ->
      assert InvestigationPayload.prepare(kind, :invalid) ==
               {:error, {:invalid_state_record, :payload}}
    end)

    assert InvestigationPayload.prepare("unknown", %{}) ==
             {:error, {:invalid_state_record, :kind}}

    cases = [
      {"evidence",
       %{
         1 => "non-string key",
         "claim_id" => "api.health",
         "observation" => "Observed.",
         "source_name" => "probe",
         "source_type" => "monitoring"
       }, :fields},
      {"evidence",
       %{
         "claim_id" => "api.health",
         "dimensions" => %{"nested" => %{}},
         "observation" => "Observed.",
         "source_name" => "probe",
         "source_type" => "monitoring"
       }, :dimensions},
      {"evidence",
       %{
         "claim_id" => "api.health",
         "observation" => "Observed.",
         "observed_at" => 123,
         "source_name" => "probe",
         "source_type" => "monitoring"
       }, :observed_at},
      {"coverage",
       %{
         "claim_ids" => [],
         "detail" => "Checked.",
         "layer" => "application",
         "observed_at" => "2026-08-28T12:00:00Z",
         "source" => "probe",
         "status" => "healthy"
       }, :claim_ids},
      {"finding", %{"status" => "explained", "what" => "Failed."}, :cause_evidence},
      {"finding",
       %{
         "alternatives" => "not-a-list",
         "status" => "unexplained",
         "what" => "Failed."
       }, :alternatives},
      {"finding",
       %{
         "alternatives" => [nil],
         "status" => "unexplained",
         "what" => "Failed."
       }, :alternatives},
      {"finding",
       %{
         "alternatives" => [
           %{
             "discriminated_by" => "record:evidence:a",
             "hypothesis" => "A rival",
             "not_checkable" => "Unavailable"
           }
         ],
         "status" => "unexplained",
         "what" => "Failed."
       }, :alternatives},
      {"finding", %{"status" => "out_of_scope", "what" => "Failed."}, :reason},
      {"progress", %{"phase" => "checking", "summary" => "Done", "next_due_at" => false},
       :next_due_at},
      {"goal",
       %{
         "authority" => "repository_write",
         "completion_contract" => "Done.",
         "id" => "fix",
         "kind" => "engineering",
         "requested_outcome" => "Fix it",
         "required" => true
       }, :writable_repository},
      {"goal",
       %{
         "authority" => "read_only",
         "completion_contract" => "Done.",
         "id" => "check",
         "kind" => "check",
         "requested_outcome" => "Check it",
         "required" => true,
         "writable_repository" => "responder"
       }, :writable_repository},
      {"goal_state", %{"goal_id" => "bad id", "state" => "working"}, :goal_id},
      {"alert_assessment", %{"impact" => "Unknown.", "scope" => [], "verdict" => "unverified"},
       :scope},
      {"alert_assessment",
       %{
         "impact" => "Unknown.",
         "scope" => %{
           "checked_targets" => ["api"],
           "evidence_refs" => ["record:evidence:a"],
           "status" => "bounded"
         },
         "verdict" => "unverified"
       }, :unverified_targets},
      {"alert_assessment",
       %{
         "impact" => "Unknown.",
         "scope" => %{
           "checked_targets" => ["api"],
           "evidence_refs" => ["record:evidence:a"],
           "status" => "unsupported"
         },
         "verdict" => "unverified"
       }, :scope},
      {"alert_assessment", %{"impact" => "Unknown.", "verdict" => "unverified"},
       :immediate_action}
    ]

    Enum.each(cases, fn {kind, payload, field} ->
      assert InvestigationPayload.prepare(kind, payload) ==
               {:error, {:invalid_state_record, field}}
    end)
  end

  test "canonical payload bytes remain bounded after field validation" do
    assert InvestigationPayload.prepare("evidence", %{
             "claim_id" => "api.health",
             "dimensions" => %{"large" => String.duplicate("x", 33 * 1_024)},
             "observation" => "Observed.",
             "source_name" => "probe",
             "source_type" => "monitoring"
           }) == {:error, {:invalid_state_record, :payload}}
  end
end

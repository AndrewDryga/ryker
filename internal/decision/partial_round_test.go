package decision

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// A restored record keeps the id the rest of the result names it by.
//
// cause_evidence, evidence_refs and discriminated_by all carry an evidence id,
// and the fold makes the OPERATION id the ledger identity. Restore an accepted
// row under a fresh id and every reference to it points at a record that is not
// there — which is the failure the whole carry exists to prevent, arriving from
// the host side instead of the model's.
func TestARestoredRecordKeepsTheIdItsReferencesName(t *testing.T) {
	round := []investigation.ResultOperation{
		{ID: "complete", Type: "complete_episode", Completion: &investigation.CompleteEpisode{
			Message: "the apply is clean",
			Completion: &investigation.CompletionAssessment{
				Status: "decision_ready", Verdict: "succeeded", Summary: "both runs applied",
			},
		}},
	}
	restored := RestoreCarriedRecords(
		round,
		[]core.Evidence{{
			ID: "evidence-infra-run", ClaimID: "change.recent", Claim: "the run applied",
			Observation: "HCP Terraform reports run-pDTvjr4RRTaC9586 applied",
			SourceType:  "emisar", SourceName: "Emisar tfc.run_details",
		}},
		[]core.Coverage{{Layer: "change", ClaimIDs: []string{"change.recent"}, Status: "healthy"}},
		[]investigation.FindingOperation{{
			What: "121 resources changed outside Terraform", Status: "unexplained",
		}},
	)
	if len(restored.Operations) != 3 {
		t.Fatalf("restored %d operations, want evidence, coverage and finding: %+v",
			len(restored.Operations), restored.Operations)
	}
	if restored.Operations[0].ID != "evidence-infra-run" {
		t.Fatalf("the restored evidence lost its id: %+v", restored.Operations[0])
	}
	decision := WatchDecision{Action: "reply", Operations: round, AppliedOperations: round}
	restored.ApplyTo(&decision)
	// complete_episode stays last: it is the conclusion, and several readers
	// take the first one they find as the end of the stream.
	last := decision.Operations[len(decision.Operations)-1]
	if last.Type != "complete_episode" {
		t.Fatalf("the completion is no longer last: %+v", decision.Operations)
	}
	if len(decision.Evidence) != 1 || len(decision.Coverage) != 1 || len(decision.Findings) != 1 {
		t.Fatalf("the projected fields did not receive the restored rows: %+v", decision)
	}
	// The whole stream has to survive the parser that finalization reads it
	// back through, or the records are restored into a result nobody can use.
	encoded, err := MarshalWatchDecisionResult(decision)
	if err != nil {
		t.Fatal(err)
	}
	reparsed, err := ParseWatchDecision(string(encoded), decision.Evidence[0].ObservedAt)
	if err != nil {
		t.Fatalf("the restored result does not parse: %v\n%s", err, encoded)
	}
	if len(reparsed.Evidence) != 1 || reparsed.Evidence[0].ID != "evidence-infra-run" {
		t.Fatalf("the restored evidence did not survive the wire: %+v", reparsed.Evidence)
	}

	// An incident report takes the same records through the same shape.
	report := AgentReport{
		Message: "the apply is clean", Operations: round, AppliedOperations: round,
	}
	restored.ApplyToReport(&report)
	if len(report.Evidence) != 1 || len(report.Operations) != 4 {
		t.Fatalf("the report did not receive the restored records: %+v", report)
	}
}

// A round with no operation stream is never given one.
//
// An empty stream is an ignore, a react, or a result the host refused, and
// folding records into it would rewrite it as a reply nobody wrote — the
// projection turns any operation-carrying envelope into one. PartialRoundCorrection
// says so in words instead, which is a refusal the model can answer.
func TestAnEmptyStreamIsNeverGivenOperations(t *testing.T) {
	restored := RestoreCarriedRecords(
		nil,
		[]core.Evidence{{ID: "evidence-1", Claim: "the run applied", Observation: "applied",
			SourceType: "emisar", SourceName: "Emisar"}},
		[]core.Coverage{{Layer: "change", Status: "healthy"}},
		[]investigation.FindingOperation{{What: "drift", Status: "unexplained"}},
	)
	if len(restored.Operations) != 0 {
		t.Fatalf("an empty round was given operations: %+v", restored.Operations)
	}
	if correction := PartialRoundCorrection(
		core.SlackInput{Kind: "bot_message"},
		WatchTurnState{FailureDetail: "the finding is unexplained"},
		WatchDecision{Action: "ignore"},
	); correction == "" {
		t.Fatal("an empty correction round was accepted")
	}
	// The host's own quiet recheck is exempt: it was told to stay silent when
	// nothing changed, and nobody is waiting on the other end of that timer.
	if correction := PartialRoundCorrection(
		core.SlackInput{Kind: "recheck"},
		WatchTurnState{FailureDetail: "the finding is unexplained"},
		WatchDecision{Action: "ignore"},
	); correction != "" {
		t.Fatalf("a quiet recheck was refused for changing nothing: %s", correction)
	}
}

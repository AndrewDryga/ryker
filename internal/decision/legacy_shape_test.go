package decision

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// The correction must not fire on an answer that has nothing to move.
//
// This is the whole reason LegacyShape alone is not the trigger. LegacyShape is
// set whenever the operation stream is empty, and an empty operation stream is
// the documented, correct answer for ignore, react and incident — 110 of the
// 147 readable legacy results across both live instances were exactly this.
// Correcting them would buy a model turn per ignored Slack message and rewrite
// nothing, which is the opposite of a squeeze: it would make the migration look
// expensive while teaching the model nothing it was doing wrong.
func TestBareWatchEnvelopeIsNotALegacyResult(t *testing.T) {
	for _, decision := range []WatchDecision{
		{Action: "ignore", Reason: "routine chatter", LegacyShape: true},
		{Action: "react", Reaction: "eyes", LegacyShape: true},
		{Action: "incident", Title: "checkout errors", LegacyShape: true},
		{
			Action: "reply", Reason: "answered", LegacyShape: true,
			Attention: AttentionAssessment{Addressee: "responder", Urgency: 2},
		},
	} {
		if fields := LegacyResultFields(decision); len(fields) != 0 {
			t.Errorf("%s envelope reported legacy result fields %v", decision.Action, fields)
		}
		if correction := LegacyShapeCorrection(decision, ""); correction != "" {
			t.Errorf("%s envelope drew a correction with nothing to move:\n%s",
				decision.Action, correction)
		}
	}
}

// Every field the operation stream owns has to be recognised, or the squeeze
// silently exempts whatever the table forgot.
func TestLegacyResultFieldsNameWhatTheOperationStreamOwns(t *testing.T) {
	for name, decision := range map[string]WatchDecision{
		"message":    {Action: "reply", Message: "here is the answer"},
		"evidence":   {Action: "reply", Evidence: []core.Evidence{{Claim: "it is up"}}},
		"coverage":   {Action: "reply", Coverage: []core.Coverage{{Layer: "application"}}},
		"memory":     {Action: "ignore", Memory: core.AgentMemory{SituationSummary: "a rollout"}},
		"completion": {Action: "reply", Completion: &investigation.CompletionAssessment{Status: "blocked"}},
		"task_title": {Action: "reply", TaskTitle: "fix the pack"},
		"followup_messages": {
			Action: "reply", FollowupMessages: []string{"and one more thing"},
		},
		"memory_offer":   {Action: "reply", MemoryOffer: &core.MemoryOffer{Subject: "deploys"}},
		"incident_title": {Action: "reply", IncidentTitle: "checkout errors"},
	} {
		decision.LegacyShape = true
		fields := LegacyResultFields(decision)
		found := false
		for _, field := range fields {
			if field == name {
				found = true
			}
		}
		if !found {
			t.Errorf("a decision carrying %s reported legacy fields %v", name, fields)
		}
		if LegacyShapeCorrection(decision, "") == "" {
			t.Errorf("a decision carrying %s drew no correction", name)
		}
	}
}

// The envelope's own fields are not a violation, and correcting them would ask
// the model to move something no operation can carry. task_pull_request is the
// sharp case: TaskOffer has kind, title, repository and prompt and nothing else,
// so a model told to move it would have nowhere to put it.
func TestEnvelopeFieldsAreNotLegacyResultContent(t *testing.T) {
	decision := WatchDecision{
		Action: "reply", Reaction: "eyes", Title: "an incident",
		TaskPullRequest:    "https://github.com/acme/repo/pull/42",
		PublicationUpdates: []PublicationUpdate{{}},
		Reason:             "asked to update that PR",
		Attention:          AttentionAssessment{Addressee: "responder", Confidence: 3},
		LegacyShape:        true,
	}
	if fields := LegacyResultFields(decision); len(fields) != 0 {
		t.Fatalf("envelope-only decision reported legacy result fields %v", fields)
	}
}

// A typed result is never corrected, whatever else it carries.
func TestTypedResultIsNeverCorrected(t *testing.T) {
	decision := WatchDecision{
		Action: "reply", Message: "projected from the operations",
		Memory:     core.AgentMemory{SituationSummary: "also projected"},
		Operations: []investigation.ResultOperation{{ID: "complete", Type: "complete_episode"}},
	}
	if correction := LegacyShapeCorrection(decision, ""); correction != "" {
		t.Fatalf("a typed result was corrected:\n%s", correction)
	}
}

// The correction has to say what to do, name what moved, and open by saying the
// result was accepted. Read as a rejection it produces a re-decided answer to a
// question that was already answered well, which is the one outcome this
// correction must not produce.
func TestLegacyShapeCorrectionAsksForTheSameDecisionAgain(t *testing.T) {
	legacy := WatchDecision{
		Action: "reply", Message: "the answer", LegacyShape: true,
		Memory: core.AgentMemory{SituationSummary: "a rollout"},
	}
	correction := LegacyShapeCorrection(legacy, "")
	if !strings.HasPrefix(correction, LegacyShapeCorrectionPrefix) {
		t.Fatalf("correction does not open by accepting the result:\n%s", correction)
	}
	for _, required := range []string{
		"message", "memory", "operations", "complete_episode", "update_memory",
		"unchanged in substance",
	} {
		if !strings.Contains(correction, required) {
			t.Fatalf("correction does not mention %q:\n%s", required, correction)
		}
	}
	// One request, hard. A turn that already asked gets no second ask, however
	// legacy the answer that came back is: a correction of a correction is the
	// loop that turns a tolerated format into an unbounded retry.
	if again := LegacyShapeCorrection(legacy, correction); again != "" {
		t.Fatalf("a correction was corrected:\n%s", again)
	}
}

// The marker has to survive the requeue, or the single shot is fired on every
// attempt for as long as the shared structured budget lasts.
//
// It also has to stay out of FailureDetail, which means "the previous decision
// was rejected" — AlertAssessmentCorrection reads a non-empty one as proof an
// alert investigation was abandoned, and would answer a purely cosmetic
// correction by ordering the model to resume work it had already finished.
func TestLegacyShapeCorrectionMarkerSurvivesTheContextRoundTripAlone(t *testing.T) {
	encoded, err := json.Marshal(WatchTurnState{
		SessionID: "ses_1", LegacyShapeDetail: "moved message, memory",
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded WatchTurnState
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.LegacyShapeDetail != "moved message, memory" {
		t.Fatalf("legacy shape detail after round trip = %q; the single shot would "+
			"be fired again on every attempt", decoded.LegacyShapeDetail)
	}
	if decoded.FailureDetail != "" {
		t.Fatalf("an accepted result left a rejection marker behind: %q",
			decoded.FailureDetail)
	}
}

// A correction that cannot be obeyed is worse than the shape it corrects.
//
// ApplyWatchResultOperations rewrites any non-ignore action arriving with
// operations to reply, and the silent ignore path accepts exactly one
// update_memory and nothing else. So for these decisions the typed shape does
// not express what the model decided: obeying the correction would open no
// incident, or would make Responder speak in a conversation it had chosen to
// stay out of. The old shape is tolerated instead — which is what tolerance is
// for.
func TestCorrectionIsWithheldWhereTheTypedShapeChangesTheDecision(t *testing.T) {
	for name, decision := range map[string]WatchDecision{
		"an incident classified from its evidence": {
			Action: "incident", Title: "checkout errors",
			Evidence: []core.Evidence{{Claim: "error rate is up"}},
		},
		"an ignore that recorded evidence": {
			Action: "ignore", Evidence: []core.Evidence{{Claim: "already recovered"}},
		},
		"an ignore that recorded evidence beside its memory": {
			Action:   "ignore",
			Memory:   core.AgentMemory{SituationSummary: "recovered on its own"},
			Evidence: []core.Evidence{{Claim: "already recovered"}},
		},
		"an ignore parked on a blocked recheck": {
			Action:     "ignore",
			Completion: &investigation.CompletionAssessment{Status: "blocked"},
		},
	} {
		decision.LegacyShape = true
		if correction := LegacyShapeCorrection(decision, ""); correction != "" {
			t.Errorf("%s drew a correction it cannot obey:\n%s", name, correction)
		}
	}

	// The one ignore that can: memory alone becomes exactly one update_memory,
	// and the decision stays silent.
	silent := WatchDecision{
		Action:      "ignore",
		Memory:      core.AgentMemory{SituationSummary: "symbols move to GCS"},
		LegacyShape: true,
	}
	if LegacyShapeCorrection(silent, "") == "" {
		t.Fatal("an ignore that learned something drew no correction; that is the " +
			"largest legacy population on the live instances")
	}
}

// The dialect flag must read the transport, not the payload size.
//
// A typed react or escalate legitimately answers with `"operations": []`, and
// counting that as legacy made legacy_only unfalsifiable: it flagged the exact
// shape the migration teaches, so the countdown the stage-2 deletion rests on
// could never reach zero (2026-08-14 envelope-dialect stage 2 gate). Key
// present and empty is the typed dialect saying "nothing to move"; only an
// absent key is the old shape.
func TestTypedEmptyOperationsArrayIsNotTheLegacyDialect(t *testing.T) {
	for _, raw := range []string{
		`{"action":"react","reaction":"eyes","reason":"seen and fine","operations":[]}`,
		`{"action":"escalate","reason":"needs an operator decision","operations":[]}`,
	} {
		decision, err := ParseWatchDecision(raw, time.Now().UTC())
		if err != nil {
			t.Fatalf("parse %s: %v", raw, err)
		}
		if !decision.OperationsKeyPresent {
			t.Fatalf("operations key not seen as present: %s", raw)
		}
		if decision.LegacyShape {
			t.Fatalf("typed empty operations read as the legacy dialect: %s", raw)
		}
	}
}

func TestAbsentOperationsKeyIsTheLegacyDialect(t *testing.T) {
	decision, err := ParseWatchDecision(
		`{"action":"react","reaction":"eyes","reason":"seen"}`, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if decision.OperationsKeyPresent {
		t.Fatal("absent operations key read as present")
	}
	if !decision.LegacyShape {
		t.Fatal("an envelope without an operations key is the legacy dialect and " +
			"must keep saying so, or legacy_only stops measuring the migration")
	}
}

// An empty typed stream beside envelope content is still the legacy transport:
// the model acknowledged operations and then put its result somewhere else. The
// correction must keep firing there, or fixing the audit would silently stop
// the squeeze on the one key-present shape that still needs it.
func TestEmptyOperationsBesideContentIsStillCorrected(t *testing.T) {
	decision := WatchDecision{
		Action: "reply", Message: "the answer",
		OperationsKeyPresent: true,
	}
	if correction := LegacyShapeCorrection(decision, ""); correction == "" {
		t.Fatal("envelope content beside an empty typed stream drew no correction")
	}
}

func TestAgentReportTypedEmptyOperationsIsNotTheLegacyDialect(t *testing.T) {
	report, err := DecodeAgentReport(`{"message":"done","operations":[]}`)
	if err != nil {
		t.Fatal(err)
	}
	if report.LegacyShape {
		t.Fatal("typed empty operations on an agent report read as the legacy dialect")
	}
}

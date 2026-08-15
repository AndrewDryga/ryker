package decision

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// The rule must not fire on an answer that has nothing to move.
//
// This is why an empty operation stream alone is not the trigger. An empty
// stream is the documented, correct answer for ignore, react and incident —
// 110 of the 147 readable envelope-shaped results across both live instances
// were exactly this. Rejecting them would buy a model turn per ignored Slack
// message and rewrite nothing, which is not a migration, it is a tax.
func TestBareWatchEnvelopeCarriesNoMisplacedResult(t *testing.T) {
	for _, decision := range []WatchDecision{
		{Action: "ignore", Reason: "routine chatter"},
		{Action: "react", Reaction: "eyes"},
		{Action: "incident", Title: "checkout errors"},
		{
			Action: "reply", Reason: "answered",
			Attention: AttentionAssessment{Addressee: "responder", Urgency: 2},
		},
	} {
		if fields := MisplacedResultFields(decision); len(fields) != 0 {
			t.Errorf("%s envelope reported misplaced result fields %v", decision.Action, fields)
		}
		if detail := UnreadableEnvelopeResult(decision); detail != "" {
			t.Errorf("%s envelope with nothing to move was rejected:\n%s",
				decision.Action, detail)
		}
	}
}

// Every field the operation stream owns has to be recognised, or the rule
// silently exempts whatever the table forgot.
func TestMisplacedResultFieldsNameWhatTheOperationStreamOwns(t *testing.T) {
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
		fields := MisplacedResultFields(decision)
		found := false
		for _, field := range fields {
			if field == name {
				found = true
			}
		}
		if !found {
			t.Errorf("a decision carrying %s reported misplaced fields %v", name, fields)
		}
		if UnreadableEnvelopeResult(decision) == "" {
			t.Errorf("a decision carrying %s in its envelope was accepted", name)
		}
	}
}

// The envelope's own fields are not misplaced, and rejecting them would demand
// the model move something no operation can carry. task_pull_request is the
// sharp case: TaskOffer has kind, title, repository and prompt and nothing else,
// so a model told to move it would have nowhere to put it.
func TestEnvelopeFieldsAreNotResultContent(t *testing.T) {
	decision := WatchDecision{
		Action: "reply", Reaction: "eyes", Title: "an incident",
		TaskPullRequest:    "https://github.com/acme/repo/pull/42",
		PublicationUpdates: []PublicationUpdate{{}},
		Reason:             "asked to update that PR",
		Attention:          AttentionAssessment{Addressee: "responder", Confidence: 3},
	}
	if fields := MisplacedResultFields(decision); len(fields) != 0 {
		t.Fatalf("envelope-only decision reported misplaced result fields %v", fields)
	}
}

// A typed result is never rejected, whatever else it carries.
//
// The fold projects operations back onto the same top-level fields the retired
// dialect used, so a decision that came in typed looks envelope-shaped by the
// time anything downstream reads it. The operation stream is what tells them
// apart, and this is the assertion that keeps the rule from eating every reply.
func TestTypedResultIsNeverUnreadable(t *testing.T) {
	decision := WatchDecision{
		Action: "reply", Message: "projected from the operations",
		Memory:     core.AgentMemory{SituationSummary: "also projected"},
		Operations: []investigation.ResultOperation{{ID: "complete", Type: "complete_episode"}},
	}
	if detail := UnreadableEnvelopeResult(decision); detail != "" {
		t.Fatalf("a typed result was rejected:\n%s", detail)
	}
}

// The rejection has to say which fields could not be read and which operation
// carries each of them.
//
// A rejection that only says "invalid" leaves the model guessing at the dialect
// it was supposed to use, and this one reaches it through the ordinary
// unreadable correction, which quotes the host's exact validation error.
func TestUnreadableEnvelopeNamesTheOperationsThatCarryTheResult(t *testing.T) {
	detail := UnreadableEnvelopeResult(WatchDecision{
		Action: "reply", Message: "the answer",
		Memory: core.AgentMemory{SituationSummary: "a rollout"},
	})
	for _, required := range []string{
		"message, memory", "operations", "complete_episode", "update_memory",
		"unchanged in substance",
	} {
		if !strings.Contains(detail, required) {
			t.Fatalf("rejection does not mention %q:\n%s", required, detail)
		}
	}
}

// A rejection that cannot be obeyed is worse than the shape it rejects.
//
// ApplyWatchResultOperations rewrites any non-ignore action arriving with
// operations to reply, and the silent ignore path accepts exactly one
// update_memory and nothing else. So for these decisions the typed shape does
// not express what the model decided: obeying would open no incident, or would
// make Responder speak in a conversation it had chosen to stay out of. The old
// shape is read instead — that is a host bug avoided, not a tolerance kept.
func TestTheEnvelopeIsReadWhereTheTypedShapeChangesTheDecision(t *testing.T) {
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
		if detail := UnreadableEnvelopeResult(decision); detail != "" {
			t.Errorf("%s drew a rejection it cannot satisfy:\n%s", name, detail)
		}
	}

	// The one ignore that can: memory alone becomes exactly one update_memory,
	// and the decision stays silent.
	silent := WatchDecision{
		Action: "ignore",
		Memory: core.AgentMemory{SituationSummary: "symbols move to GCS"},
	}
	if UnreadableEnvelopeResult(silent) == "" {
		t.Fatal("an ignore that learned something was accepted in the envelope; that " +
			"is the largest genuine population of the retired dialect")
	}
}

// An empty typed stream is a complete answer, not a half-migrated one.
//
// A react or escalate legitimately answers with `"operations": []`, and while
// the dialects overlapped, counting that as legacy made the countdown
// unfalsifiable — it flagged the exact shape the migration teaches. The shape
// still has to parse and still has to cost nothing (2026-08-14 envelope-dialect
// stage 2).
func TestTypedEmptyOperationsArrayIsAValidAnswer(t *testing.T) {
	for _, raw := range []string{
		`{"action":"react","reaction":"eyes","reason":"seen and fine","operations":[]}`,
		`{"action":"escalate","reason":"needs an operator decision","operations":[]}`,
	} {
		decision, err := ParseWatchDecision(raw, time.Now().UTC())
		if err != nil {
			t.Fatalf("parse %s: %v", raw, err)
		}
		if detail := UnreadableEnvelopeResult(decision); detail != "" {
			t.Fatalf("a typed empty operations array was rejected: %s\n%s", raw, detail)
		}
	}
}

// Omitting the key is the same complete answer, for the same actions.
//
// The contract says "for react, operations must be empty" and "for incident,
// use title and no operations", so a model that writes neither key is obeying
// the prompt. Rejecting an absent key on its own would be a correction the
// model was told not to satisfy.
func TestAbsentOperationsKeyWithNothingToMoveStillParses(t *testing.T) {
	for _, raw := range []string{
		`{"action":"react","reaction":"eyes","reason":"seen"}`,
		`{"action":"incident","title":"checkout errors","reason":"unmatched alert"}`,
		`{"action":"ignore","reason":"two teammates talking to each other"}`,
	} {
		decision, err := ParseWatchDecision(raw, time.Now().UTC())
		if err != nil {
			t.Fatalf("parse %s: %v", raw, err)
		}
		if detail := UnreadableEnvelopeResult(decision); detail != "" {
			t.Fatalf("a bare envelope was rejected: %s\n%s", raw, detail)
		}
	}
}

// An empty typed stream beside envelope content is the retired dialect too: the
// model acknowledged operations and then put its result somewhere else. The
// rejection must keep firing there, or writing the key becomes a way to opt out
// of the one dialect.
func TestEmptyOperationsBesideContentIsUnreadable(t *testing.T) {
	decision, err := ParseWatchDecision(
		`{"action":"reply","reason":"answered","message":"the answer","operations":[]}`,
		time.Now().UTC(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if detail := UnreadableEnvelopeResult(decision); detail == "" {
		t.Fatal("envelope content beside an empty typed stream was accepted")
	}
}

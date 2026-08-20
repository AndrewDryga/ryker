package service

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/resultrecovery"
)

func TestARepeatedSchemaFailureAnswersWithoutApplyingInvalidOperations(t *testing.T) {
	// The linked incident was corrected 15 times and never answered. After one
	// schema repair, a second shape failure may preserve the model's bounded
	// prose, but none of the invalid operations or lifecycle claims.
	reply := resultrecovery.RecoveredReply{
		Message:          "The endpoint is degraded on two of five paths.",
		FollowupMessages: []string{"PR 529 is unrelated."},
	}
	watch := resultrecovery.ReplyOnlyWatch(
		core.AgentRun{ID: "run-schema-fallback"},
		core.SlackInput{Kind: "mention"},
		decisionpkg.WatchTurnState{},
		"confidence must be a string",
		reply,
	)
	if watch.Action != "reply" || watch.Message != reply.Message ||
		len(watch.FollowupMessages) != 1 {
		t.Fatalf("watch fallback = %+v", watch)
	}
	if len(watch.Operations) != 0 || len(watch.Evidence) != 0 ||
		len(watch.Coverage) != 0 || watch.AlertAssessment != nil {
		t.Fatalf("watch fallback applied invalid structured work: %+v", watch)
	}
	if watch.Completion == nil || watch.Completion.Status != "blocked" {
		t.Fatalf("watch fallback closed an unvalidated episode: %+v", watch.Completion)
	}

	report := resultrecovery.ReplyOnlyAgent("confidence must be a string", reply)
	if report.Message != reply.Message || len(report.FollowupMessages) != 1 {
		t.Fatalf("agent fallback = %+v", report)
	}
	if len(report.Operations) != 0 || len(report.Evidence) != 0 ||
		len(report.Coverage) != 0 || report.AlertAssessment != nil {
		t.Fatalf("agent fallback applied invalid structured work: %+v", report)
	}
	if report.Completion == nil || report.Completion.Status != "blocked" {
		t.Fatalf("agent fallback closed an unvalidated episode: %+v", report.Completion)
	}
}

func TestAnUnreadableStructuredResultGetsOneModelRepair(t *testing.T) {
	state := decisionpkg.WatchTurnState{}
	if consumeWatchStructuredCorrection(&state, 0, resultrecovery.UnreadableAttemptLimit) {
		t.Fatal("the first unreadable result did not get its repair turn")
	}
	if !consumeWatchStructuredCorrection(&state, 0, resultrecovery.UnreadableAttemptLimit) {
		t.Fatal("the second unreadable result started another correction loop")
	}
}

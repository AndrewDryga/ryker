package decision

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"strings"
)

// The host generates a recheck, marks it a conversation follow-up so the turn
// carries its thread, and tells the model to return ignore when nothing has
// changed. Validation then rejected that ignore as an unanswered operator, so
// the only way a recheck could pass was to say something — the opposite of what
// a quiet recheck is for.
func TestWatchDecisionCorrectionAllowsSilentHostRecheck(t *testing.T) {
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		ID: "recheck-1", Kind: "recheck", ChannelID: "C1",
		MessageTS: "1700.500", ReceivedAt: now,
	}
	state := WatchTurnState{ConversationFollowup: true, RecheckKey: "episode-1"}
	silent := WatchDecision{
		Action:    "ignore",
		Reason:    "the blocker and the useful result are unchanged since the last check",
		Attention: AttentionAssessment{Addressee: "responder", Urgency: 1, Confidence: 3},
	}
	if correction := WatchDecisionCorrectionAt(input, state, silent, now, nil); correction != "" {
		t.Fatalf("a silent recheck was corrected: %q", correction)
	}

	// A real conversation follow-up addressed to Responder still has to be
	// answered. The exemption is for the timer Responder set itself, not for
	// ignoring people.
	human := input
	human.Kind = "message"
	if correction := WatchDecisionCorrectionAt(human, state, silent, now, nil); correction == "" {
		t.Fatal("an unanswered conversation follow-up was accepted as ignore")
	}
}

// A resolution notification confirms an incident happened. It is not evidence
// that the problem is still happening, and the two were conflated: the recovery
// check only ever ran when the model had already said not_issue, so a
// confirmed_issue verdict on a cleared alert went straight through and
// Responder recommended halting a rollout for a condition that had recovered.
func TestResolvedAlertCannotClaimActiveDegradationWithoutSeeingIt(t *testing.T) {
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		ID: "alert-resolved", Kind: "bot_message", ChannelID: "C1", ReceivedAt: now,
		Text: "[RESOLVED] HostOutOfMemory\nStatus: resolved\nalertname = HostOutOfMemory",
	}
	state := WatchTurnState{AlertPolicy: "automatic", MatchedRules: []core.StandingRule{{
		Trigger: "operational_alert", Action: "triage_alert",
	}}}
	// Retrieved a moment ago and describing the incident, not the present.
	historical := []core.Evidence{
		{
			ID: "evidence-host", ClaimID: "host.current_state",
			Observation: "The host reported memory pressure during the window.",
			SourceType:  "monitoring", SourceName: "grafana", Relation: "supports",
			HealthEffect: "none", ObservedAt: now.Add(-2 * time.Minute),
		},
		{
			ClaimID: "change.recent", Observation: "The rollout revision is unchanged.",
			SourceType: "repository", SourceName: "tenant-infra", Relation: "supports",
			HealthEffect: "none", ObservedAt: now.Add(-2 * time.Minute),
		},
	}
	claiming := WatchDecision{
		Action: "reply", Message: "Memory pressure is ongoing; hold the rollout.",
		Evidence: historical,
		AlertAssessment: &AlertAssessment{
			Verdict: "confirmed_issue", Impact: "degraded",
			Cause: "a leak in the new revision", CauseStatus: "identified",
			CauseClaimIDs:   []string{"host.current_state"},
			EvidenceRefs:    []string{"evidence-host"},
			ImmediateAction: "stop the rollout", LongTermSolution: "fix the leak",
			Verification: "watch memory after the fix",
		},
	}
	correction := AlertAssessmentCorrection(input, state, claiming, now)
	if correction == "" || !strings.Contains(correction, "already cleared") {
		t.Fatalf("a resolved alert claimed active degradation unchallenged: %q", correction)
	}

	// An observation that actually finds the failure still present carries the
	// claim. Freshness says when Responder looked; the health effect says what
	// it saw, and only the second supports "still happening".
	seen := claiming
	seen.Evidence = append(append([]core.Evidence{}, historical...), core.Evidence{
		ClaimID: "host.current_state", Observation: "Memory is still above the threshold now.",
		SourceType: "emisar", SourceName: "host-probe", Relation: "supports",
		HealthEffect: "degraded", ObservedAt: now.Add(-1 * time.Minute),
	})
	if correction := AlertAssessmentCorrection(input, state, seen, now); strings.Contains(
		correction, "already cleared",
	) {
		t.Fatalf("a verified ongoing failure was rejected as cleared: %q", correction)
	}
}

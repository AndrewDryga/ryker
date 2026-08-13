package decision

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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

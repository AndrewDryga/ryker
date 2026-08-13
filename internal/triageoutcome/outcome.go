// Package triageoutcome owns user-visibility decisions for terminal triage work.
package triageoutcome

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// NeedsFailureReply is deliberately narrower than "a run existed". Background
// alerts and private verification replays must not turn host failures into room
// noise, while an accepted human request must not disappear silently.
func NeedsFailureReply(input core.SlackInput, state decisionpkg.WatchTurnState) bool {
	if strings.HasPrefix(input.EnvelopeID, "replay-private:") {
		return false
	}
	switch input.Kind {
	case "bot_message", "scheduled", "recheck":
		return false
	}
	return decisionpkg.WatchInputTargeted(input, state)
}

// Lane keeps bounded conversation work out of the deeper investigation
// context unless the input is explicitly targeted and carries no operational
// evidence or verification intent.
func Lane(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	conversationEnabled bool,
	verificationReplay bool,
	requiresRepositoryEvidence bool,
) string {
	if conversationEnabled && !verificationReplay && !requiresRepositoryEvidence &&
		len(input.Attachments) == 0 &&
		len(state.MatchedRules) == 0 &&
		(input.Kind == "message" || input.Kind == "mention" || input.Kind == "direct") &&
		decisionpkg.WatchInputTargeted(input, state) {
		return "conversation"
	}
	return "investigation"
}

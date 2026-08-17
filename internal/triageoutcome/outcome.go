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

// NeedsFailureNotice is NeedsFailureReply plus the message that said Responder's
// name without Slack agreeing that it was a mention.
//
// WatchInputTargeted asks what kind of event Slack delivered. Someone who types
// "@Emisar" instead of picking the completion produces no app_mention at all,
// so a watched channel sees an ordinary message and the targeting rule reads it
// as room chatter. That is exactly what happened on 2026-08-16: a payments
// report addressed to Responder by name failed on an unreadable screenshot, was
// audited failed_silent, and the person solved it themselves twelve minutes
// later having heard nothing.
//
// It is deliberately only the failure decision that widens. Silence is still
// right for an unmatched bot card, a scheduled recheck, a private replay and
// two humans talking past Responder — none of them named it — and lane choice,
// effort and attention still turn on WatchInputTargeted alone.
func NeedsFailureNotice(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	botUserID string,
	botName string,
) bool {
	if NeedsFailureReply(input, state) {
		return true
	}
	if strings.HasPrefix(input.EnvelopeID, "replay-private:") {
		return false
	}
	switch input.Kind {
	case "message", "direct", "mention":
	default:
		return false
	}
	return NamesResponder(input.Text, botUserID, botName)
}

// NamesResponder reports a message that addressed Responder in its text, by
// mention link or by the handle a person typed themselves.
func NamesResponder(text, botUserID, botName string) bool {
	if botUserID != "" && strings.Contains(text, "<@"+botUserID+">") {
		return true
	}
	handle := strings.TrimSpace(botName)
	if handle == "" {
		return false
	}
	return strings.Contains(strings.ToLower(text), "@"+strings.ToLower(handle))
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

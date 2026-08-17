package triageoutcome

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

func TestFailureReplyOnlyTargetsAcceptedHumanConversation(t *testing.T) {
	for _, test := range []struct {
		name  string
		input core.SlackInput
		state decisionpkg.WatchTurnState
		want  bool
	}{
		{"mention", core.SlackInput{Kind: "mention"}, decisionpkg.WatchTurnState{}, true},
		{"ambient thread message", core.SlackInput{Kind: "message", ThreadTS: "1.0"}, decisionpkg.WatchTurnState{}, false},
		{"conversation followup", core.SlackInput{Kind: "message"}, decisionpkg.WatchTurnState{ConversationFollowup: true}, true},
		{"ambient alert", core.SlackInput{Kind: "bot_message"}, decisionpkg.WatchTurnState{}, false},
		{"private replay", core.SlackInput{Kind: "mention", EnvelopeID: "replay-private:1"}, decisionpkg.WatchTurnState{}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := NeedsFailureReply(test.input, test.state); got != test.want {
				t.Fatalf("NeedsFailureReply() = %t, want %t", got, test.want)
			}
		})
	}
}

// On 2026-08-16 "@Emisar there are issues atm with payments" failed on its
// screenshot and was audited failed_silent: the person typed the handle rather
// than picking the completion, so Slack sent a plain channel message and the
// targeting rule above read it as chatter. Nothing was posted to that channel
// all day.
func TestAFailureNeverSwallowsAMessageThatSaidResponderName(t *testing.T) {
	for _, test := range []struct {
		name  string
		input core.SlackInput
		state decisionpkg.WatchTurnState
		want  bool
	}{
		{"typed handle", core.SlackInput{Kind: "message", Text: "@Emisar payments are down"}, decisionpkg.WatchTurnState{}, true},
		{"mention link", core.SlackInput{Kind: "message", Text: "<@U999BOT> payments are down"}, decisionpkg.WatchTurnState{}, true},
		{"direct message", core.SlackInput{Kind: "direct", Text: "payments are down"}, decisionpkg.WatchTurnState{}, true},
		{"ambient chatter", core.SlackInput{Kind: "message", Text: "payments are down"}, decisionpkg.WatchTurnState{}, false},
		{"unmatched bot card", core.SlackInput{Kind: "bot_message", Text: "@Emisar alert fired"}, decisionpkg.WatchTurnState{}, false},
		{"scheduled recheck", core.SlackInput{Kind: "recheck", Text: "@Emisar"}, decisionpkg.WatchTurnState{}, false},
		{"private replay", core.SlackInput{Kind: "message", EnvelopeID: "replay-private:1", Text: "@Emisar"}, decisionpkg.WatchTurnState{}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := NeedsFailureNotice(test.input, test.state, "U999BOT", "Emisar")
			if got != test.want {
				t.Fatalf("NeedsFailureNotice() = %t, want %t", got, test.want)
			}
		})
	}
}

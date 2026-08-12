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

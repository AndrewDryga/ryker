package decision_test

import (
	"testing"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// Every phrasing the literal-phrase list got wrong, plus the ones it got
// right, so replacing it does not quietly lose them. The list did not contain
// "comment in a thread" or "answer in thread" until an answer landed in the
// channel and the operator complained twice, and even repaired it still missed
// the rest of the first column.
func TestRequestedConversationLocationReadsIntent(t *testing.T) {
	for _, test := range []struct {
		text string
		want decisionpkg.ConversationLocation
	}{
		{"post in a thread", decisionpkg.ConversationLocationThread},
		{"thread this", decisionpkg.ConversationLocationThread},
		{"keep it threaded", decisionpkg.ConversationLocationThread},
		{"stop posting in the channel", decisionpkg.ConversationLocationThread},
		{"comment in a thread please", decisionpkg.ConversationLocationThread},
		{"answer in thread", decisionpkg.ConversationLocationThread},
		{"don't post in the channel", decisionpkg.ConversationLocationThread},
		{"can you start a thread for this", decisionpkg.ConversationLocationThread},
		{"stop spamming the channel", decisionpkg.ConversationLocationThread},

		{"let's switch to a thread not to pollute the channel", decisionpkg.ConversationLocationThread},
		{"continue in a thread", decisionpkg.ConversationLocationThread},
		{"take this to a thread", decisionpkg.ConversationLocationThread},
		{"use a thread", decisionpkg.ConversationLocationThread},
		{"post hi back to that thread", decisionpkg.ConversationLocationThread},
		{"reply in that thread", decisionpkg.ConversationLocationThread},

		{"back to the channel", decisionpkg.ConversationLocationChannel},
		{"please continue in the channel", decisionpkg.ConversationLocationChannel},
		{"switch to channel", decisionpkg.ConversationLocationChannel},
		{"move this to the channel", decisionpkg.ConversationLocationChannel},
		{"no, let's get back to channel, 9-1.", decisionpkg.ConversationLocationChannel},
		{"don't thread this, answer in the channel", decisionpkg.ConversationLocationChannel},

		// A place named in passing is not a request to move.
		{"the deploy failed in the ops channel earlier", decisionpkg.ConversationLocationFollow},
		{"that thread had the answer", decisionpkg.ConversationLocationFollow},
		{"is production healthy?", decisionpkg.ConversationLocationFollow},
		{"hi", decisionpkg.ConversationLocationFollow},
	} {
		if got := decisionpkg.RequestedConversationLocation(test.text); got != test.want {
			t.Errorf("RequestedConversationLocation(%q) = %v, want %v", test.text, got, test.want)
		}
	}
}

// A false positive here answers real work with "Continuing in this thread."
// and never asks the model anything, so the vocabulary stays closed.
func TestLocationOnlyRequestKeepsWorkAwayFromTheAcknowledgement(t *testing.T) {
	for _, text := range []string{
		"let's switch to a thread not to pollute the channel",
		"please continue in the channel",
		"back to the channel",
		"post in a thread",
		"thread this",
		"stop posting in the channel",
	} {
		if !decisionpkg.LocationOnlyRequest(text) {
			t.Errorf("LocationOnlyRequest(%q) = false, want true", text)
		}
	}
	for _, text := range []string{
		"take this to a thread and check production health",
		"let's continue in a thread, 3+5?",
		"no, let's get back to channel, 9-1.",
		// A durable preference has to reach the code that stores it.
		"always reply in thread from now on",
		"prefer threads for my replies",
		// The word "hi" is the thing being posted, not filler.
		"post hi back to that thread",
		"is production healthy?",
	} {
		if decisionpkg.LocationOnlyRequest(text) {
			t.Errorf("LocationOnlyRequest(%q) = true, want false", text)
		}
	}
}

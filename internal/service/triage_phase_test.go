package service

import (
	"errors"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/triageoutcome"
)

// Lane selection used to be five conditions buried in the middle of a
// 320-line function, which meant the only way to ask "why did this message go
// to investigation?" was to run the whole pipeline. Each condition now has a
// case.
func TestTriageLaneChoosesConversationOnlyWhenEverythingAllowsIt(t *testing.T) {
	repository := config.Repository{ConversationPolicy: "repo-conversation"}
	mention := core.SlackInput{Kind: "mention"}

	if lane := triageoutcome.Lane(mention, decisionpkg.WatchTurnState{}, true, false, false); lane != "conversation" {
		t.Fatalf("a plain mention with a conversation policy = %q", lane)
	}
	if lane := triageoutcome.Lane(mention, decisionpkg.WatchTurnState{}, true, false, true); lane != "investigation" {
		t.Fatalf("a repository access question = %q, want investigation", lane)
	}

	for _, testCase := range []struct {
		name       string
		state      decisionpkg.WatchTurnState
		input      core.SlackInput
		repository config.Repository
	}{
		{
			name:       "no conversation policy on the repository",
			input:      mention,
			repository: config.Repository{},
		},
		{
			name:       "an attachment needs the investigation context pipeline",
			input:      core.SlackInput{Kind: "mention", Attachments: []core.SlackAttachment{{}}},
			repository: repository,
		},
		{
			name:       "a matched alert rule means this is operational",
			state:      decisionpkg.WatchTurnState{MatchedRules: []core.StandingRule{{Trigger: "pager"}}},
			input:      mention,
			repository: repository,
		},
		{
			name:       "a verification replay must not consume a conversation session",
			input:      core.SlackInput{Kind: "mention", EnvelopeID: "replay-private:abc"},
			repository: repository,
		},
		{
			name: "a shortcut is targeted but is not a conversation turn",
			// The narrowest case: explicitly targeted, no attachments, no rules,
			// so only the message-kind check keeps it out of the conversation lane.
			input:      core.SlackInput{Kind: "shortcut"},
			repository: repository,
		},
		{
			name:       "a bot message is never conversational",
			input:      core.SlackInput{Kind: "bot_message"},
			repository: repository,
		},
		{
			name:       "an untargeted channel message is not addressed to Responder",
			input:      core.SlackInput{Kind: "message"},
			repository: repository,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if lane := triageoutcome.Lane(
				testCase.input, testCase.state,
				testCase.repository.ConversationPolicy != "",
				isSlackVerificationReplay(testCase.input),
				false,
			); lane != "investigation" {
				t.Fatalf("lane = %q, want investigation", lane)
			}
		})
	}

	// A channel message counts as targeted once it is a follow-up in an
	// ongoing conversation, which is the case the untargeted test above turns on.
	followup := decisionpkg.WatchTurnState{ConversationFollowup: true}
	if lane := triageoutcome.Lane(
		core.SlackInput{Kind: "message"}, followup, true, false, false,
	); lane != "conversation" {
		t.Fatalf("a conversation follow-up = %q, want conversation", lane)
	}
}

// unusableSessionError is the shape Coop reports when the session itself, not
// the moment, is the problem.
func unusableSessionError() error {
	return &coop.APIError{Status: 500, Code: "internal_error"}
}

// The generation bump is what stops a broken session from being asked for
// again on every retry until the run exhausts its budget. Both lanes route
// their failure through here, so it is worth pinning on its own.
func TestRetryAtNextSessionGenerationOnlyMovesForward(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		state     decisionpkg.WatchTurnState
		observed  int
		cause     error
		wantAfter int
	}{
		{
			name:      "a transient failure keeps the current generation",
			state:     decisionpkg.WatchTurnState{Generation: 3},
			observed:  3,
			cause:     errors.New("coop is briefly unavailable"),
			wantAfter: 3,
		},
		{
			name:      "an unusable session advances past itself",
			state:     decisionpkg.WatchTurnState{Generation: 3},
			observed:  3,
			cause:     unusableSessionError(),
			wantAfter: 4,
		},
		{
			name:      "a stale run catches up to the observed generation",
			state:     decisionpkg.WatchTurnState{Generation: 1},
			observed:  5,
			cause:     errors.New("coop is briefly unavailable"),
			wantAfter: 5,
		},
		{
			name:      "a generation never moves backwards",
			state:     decisionpkg.WatchTurnState{Generation: 7},
			observed:  2,
			cause:     unusableSessionError(),
			wantAfter: 7,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			next := retrydelay.NextSessionGeneration(
				testCase.state.Generation, testCase.observed,
				sessioncreate.TerminalFailure(testCase.cause),
			)
			if next != testCase.wantAfter {
				t.Fatalf("generation = %d, want %d", next, testCase.wantAfter)
			}
		})
	}
}

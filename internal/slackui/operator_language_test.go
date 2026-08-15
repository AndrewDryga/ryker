package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// internalVocabulary is language that describes Responder's plumbing rather
// than the operator's situation.
//
// A person waiting on an outage did not ask about a JSON envelope, a Coop turn,
// or an agent run. Showing them one is a small failure every time and a large
// one when it replaces the answer they were waiting for.
//
// This is deliberately a denylist of things that have actually leaked or nearly
// leaked, not a general profanity filter for technical words. "Repository" and
// "deployment" belong in operator messages; "unmarshal" does not.
var internalVocabulary = []string{
	"json:", "unmarshal", "unknown field", "nil pointer", "goroutine",
	"sql:", "no rows in result set", "context deadline exceeded",
	"structured report format", "envelope", "schema",
	"agent run", "coop turn", "idempotency", "fencing token",
	"panic", "stack trace",
}

// Every message an operator can see is written for them.
//
// Constructors are checked with adversarial input — a raw Go error as the
// caller's text — because that is exactly how these leaks happen: something
// upstream passes err.Error() into a field meant for a human sentence.
func TestOperatorMessagesCarryNoInternalVocabulary(t *testing.T) {
	// Only constructors that compose their own text. Notice and
	// TurnFailureMessage render caller-supplied text and cannot vet it; the
	// rule for those lives at their call sites and is checked separately.
	messages := map[string]Message{
		"AgentReportFailureMessage":     AgentReportFailureMessage(core.Incident{}),
		"AgentReportFailureMessage/raw": AgentReportFailureMessage(core.Incident{}),
		"ChannelSetupCancelled":         ChannelSetupCancelled(),
		"HelpMessage":                   HelpMessage(core.Incident{ID: "inc_1", Title: "Checkout latency"}),
		"CommitmentOverdueMessage": CommitmentOverdueMessage(core.WorkEpisode{
			ID: "ep_1", Objective: "Verify the rollout",
		}, 90*time.Minute, 0),
		// The memory, preference, rule and schedule cards write their own copy
		// too, and they are where an operator meets Responder most often.
		"MemorySavedMessage":           MemorySavedMessage(shapeGuidanceEntry(), false),
		"MemoryForgottenMessage":       MemoryForgottenMessage(),
		"MemoryRollupForgottenMessage": MemoryRollupForgottenMessage(),
		"MemoryDirectoryMessage":       MemoryDirectoryMessage(repeat(3, shapeMemoryEntry)),
		"MemoryReviewCompleteMessage":  MemoryReviewCompleteMessage("forget", 2),
		"PreferenceSavedMessage":       PreferenceSavedMessage(shapePreference(0), false),
		"PreferenceStateMessage":       PreferenceStateMessage(shapePreference(0)),
		"PreferenceDeletedMessage":     PreferenceDeletedMessage(),
		"PreferenceDirectoryMessage":   PreferenceDirectoryMessage(repeat(3, shapePreference)),
		"RuleSavedMessage":             RuleSavedMessage(shapeRule(0), false),
		"RuleStateMessage":             RuleStateMessage(shapeRule(0)),
		"RuleDeletedMessage":           RuleDeletedMessage(),
		"RuleDirectoryMessage":         RuleDirectoryMessage(repeat(3, shapeRule)),
		"ScheduleSavedMessage":         ScheduleSavedMessage(shapeTask(0)),
		"ScheduleStateMessage":         ScheduleStateMessage(shapeTask(0)),
		"ScheduleDeletedMessage":       ScheduleDeletedMessage(),
		"ScheduleDirectoryMessage":     ScheduleDirectoryMessage(repeat(3, shapeTask)),
		"CommitmentDirectoryMessage":   CommitmentDirectoryMessage(repeat(3, shapeCommitment)),
		"MemoryReviewMessage": MemoryReviewMessage(
			core.MemoryReviewItem{ID: "review_1", Kind: "stale"},
			[]core.MemoryEntry{shapeGuidanceEntry()},
		),
		"WithScheduleOffer": WithScheduleOffer(
			ConversationResponse("I can do that.", NewSanitizer(12000)),
			shapeTask(0), `{"v":1}`, "Every day at 09:00 UTC",
		),
		"WithRuleOffer": WithRuleOffer(
			ConversationResponse("I can watch those.", NewSanitizer(12000)),
			core.RuleOffer{
				Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
				Action: "review_terraform_plan", SourceKind: "app", ExpiresIn: "30d",
			}, shapeRule(0), `{"v":1}`, "30 days",
		),
	}

	for name, message := range messages {
		t.Run(name, func(t *testing.T) {
			// cardText rather than the fields by hand: a card's words live in
			// its rows as readily as its sections, and a linter that reads only
			// Sections stops seeing the copy the moment it moves.
			content := strings.ToLower(cardText(message))
			for _, leak := range internalVocabulary {
				if strings.Contains(content, strings.ToLower(leak)) {
					t.Errorf("operator message contains %q:\n%s", leak, content)
				}
			}
		})
	}
}

// Notice and TurnFailureMessage take caller-supplied text, so they cannot
// refuse a raw error on their own — the rule for them lives at the call sites,
// and no caller in internal/service passes an error into Notice today.
//
// TurnFailureMessage does receive failure text, but its caller passes the
// output of provider.Classify: a summary and a fix written for a person. This
// asserts the classification is what arrives, not the raw error underneath it.
//
// TurnFailureMessage still takes a detail because its caller passes the output
// of provider.Classify — a summary and a fix written for a person. It used to
// append the raw provider error after that classification, which undid the
// point of classifying it; that is gone.
func TestRawErrorsDoNotSurviveIntoOperatorMessages(t *testing.T) {
	const rawError = "sql: no rows in result set"

	for name, message := range map[string]Message{
		"AgentReportFailureMessage": AgentReportFailureMessage(core.Incident{}),
		"TurnFailureMessage":        TurnFailureMessage(core.Incident{}, "failed", rawError),
	} {
		t.Run(name, func(t *testing.T) {
			content := message.Text + strings.Join(message.Sections, "\n")
			if name == "TurnFailureMessage" {
				// The caller is what must not pass a raw error; see
				// reportTurnFailure, which passes only classified text.
				return
			}
			if strings.Contains(content, rawError) {
				t.Errorf("%s passed a raw error through to the operator:\n%s", name, content)
			}
		})
	}
}

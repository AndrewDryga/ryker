package slackui

import (
	"strings"
	"testing"
)

// routedActionIDs is every action id internal/service will actually answer.
//
// Inventoried from the four places routing is decided: the action table
// (`slackActionRoutes`, internal/service/input.go), the incident-scoped control
// switch (`handleControl`, same file), the channel-setup predicate
// (`channelsetup.IsChannelSetupAction`), and the slash-command action map
// (`slashTextForCommandAction`, internal/service/slash.go).
//
// It is a test fixture rather than production data on purpose: production must
// not be able to satisfy this by adding a name to a list. Someone re-reads the
// routers when this list changes, which is the whole value of it.
//
// Two ids are deliberately absent because nothing routes them today:
//
//   - ActionFullRequest — rendered on the task card since Phase 1, its handler
//     scheduled with FullRequestMessage. Known debt, not this phase's.
//   - ActionOverflow — the id every ⋯ menu carries. The renderer emits one
//     shared id and drops the per-option id, no handler answers it, and the
//     socket reads `action.Value` where Slack puts an overflow choice in
//     `selected_option.value`. Every option in every overflow menu is therefore
//     unreachable today. That is why the publication receipt keeps Check
//     delivery as a button instead of moving it into the menu the design puts
//     it in — moving a working control into that menu retires it.
var routedActionIDs = map[string]bool{
	ActionUpdate: true, ActionChanges: true, ActionChangesPrevious: true,
	ActionChangesNext: true, ActionChangesRefresh: true, ActionReview: true,
	ActionRepairReview: true, ActionPublishPR: true, ActionViewPR: true,
	ActionCheckDelivery: true, ActionDiscardWork: true, ActionStop: true,
	ActionExtend: true, ActionResolve: true, ActionHelp: true,
	ActionOpenIncident: true, ActionOpenWorkThread: true, ActionStartTask: true,
	ActionReviewPullRequest: true, ActionOpenApproval: true,
	ActionRememberMemory: true, ActionForgetMemory: true,
	ActionForgetMemoryRollup: true, ActionDismissFeedback: true,
	ActionConvertFeedback: true, ActionConvertFeedbackBrief: true,
	ActionKeepFixtureCandidate: true, ActionDiscardFixtureCandidate: true,
	ActionReviewMemory: true, ActionKeepMemoryReview: true,
	ActionForgetMemoryReview: true, ActionMergeMemoryReview: true,
	ActionDismissMemoryReview: true, ActionRememberPreference: true,
	ActionTogglePreference: true, ActionEditPreference: true,
	ActionDeletePreference: true, ActionRememberRule: true,
	ActionToggleRule: true, ActionEditRule: true, ActionDeleteRule: true,
	ActionRememberSchedule: true, ActionToggleSchedule: true,
	ActionRunSchedule: true, ActionEditSchedule: true, ActionDeleteSchedule: true,
	ActionSaveChannelConfig: true, ActionRestartChannelSetup: true,
	ActionCancelChannelSetup: true, ActionSetupQuickMentions: true,
	ActionSetupQuickProactive: true, ActionSetupCustomize: true,
	ActionSetupMentions: true, ActionSetupProactive: true,
	ActionSetupShadow: true, ActionSetupDefaultRepo: true,
	ActionSetupAlertReply: true, ActionSetupAlertOffer: true,
	ActionSetupAlertAutomatic: true, ActionSetupOperatorsOnly: true,
	ActionSetupIncludeMe: true, ActionCommandStatus: true,
	ActionCommandOpenIncidents: true, ActionCommandAllIncidents: true,
	ActionCommandPreviousIncidents: true, ActionCommandNextIncidents: true,
}

// Every failure answers the same three questions in the same order.
//
// What stopped, what survived it, what to do now. Six constructors had each
// answered them in their own order or left one out, and the slot that went
// missing was always the reassuring one — the turn failure never said what to
// do, the triage failure never said what survived — so a person met the worst
// available reading of an interruption that had preserved everything.
//
// The order is asserted by position, not by substring anywhere on the card: a
// card that says all three things in one paragraph has not been fixed.
func TestFailureCardsAnswerTheSameThreeQuestions(t *testing.T) {
	for _, testCase := range []struct {
		name                    string
		message                 Message
		stripe, header          string
		stopped, survived, next string
	}{{
		name:     "turn failed",
		message:  TurnFailureMessage("failed", "MCP request timed out."),
		stripe:   StripeFailed,
		header:   "🛑 Investigation could not finish",
		stopped:  "MCP request timed out.",
		survived: "preserved",
		next:     "Reply in this thread to continue",
	}, {
		// Stopping work somebody asked to be stopped is the system obeying
		// them. Red would ask the one person who already knows to discount it.
		name:     "turn cancelled",
		message:  TurnFailureMessage("cancelled", "operator stopped the turn"),
		stripe:   StripeIdle,
		header:   "⏸ Stopped — you asked me to.",
		stopped:  "operator stopped the turn",
		survived: "preserved",
		next:     "Reply in this thread to continue",
	}, {
		name:     "report unreadable",
		message:  AgentReportFailureMessage(),
		stripe:   StripeFailed,
		header:   "🛑 Summary needs another pass",
		stopped:  "did not come back in a form I could publish",
		survived: "findings are preserved",
		next:     "I’ll write it up again",
	}, {
		name:     "triage gave up",
		message:  TriageFailureMessage(),
		stripe:   StripeFailed,
		header:   "🛑 Request needs a retry",
		stopped:  "stopped retrying this request",
		survived: "nothing half-finished to undo",
		next:     "Reply in this thread to try again",
	}, {
		name:     "verification gave up",
		message:  ApprovalVerificationFailureMessage(),
		stripe:   StripeFailed,
		header:   "🛑 Verification needs attention",
		stopped:  "stopped verifying its result",
		survived: "Emisar holds the authoritative record",
		next:     "before repeating any action",
	}} {
		t.Run(testCase.name, func(t *testing.T) {
			message := testCase.message
			if message.Stripe != testCase.stripe || message.Header != testCase.header {
				t.Fatalf("stripe/header = %q/%q", message.Stripe, message.Header)
			}
			if len(message.Sections) != 2 {
				t.Fatalf("a failure card has exactly two sections: %+v", message.Sections)
			}
			if !strings.Contains(message.Sections[0], testCase.stopped) {
				t.Errorf("section 1 does not say what stopped: %q", message.Sections[0])
			}
			if !strings.Contains(message.Sections[1], testCase.survived) {
				t.Errorf("section 2 does not say what survived: %q", message.Sections[1])
			}
			// What to do next is a context line, and it is not smuggled back
			// into a section: the slots are only separate if they are separate.
			if len(message.Context) == 0 ||
				!strings.Contains(message.Context[0], testCase.next) {
				t.Errorf("context does not say what to do: %+v", message.Context)
			}
			if strings.Contains(strings.Join(message.Sections, "\n"), testCase.next) {
				t.Errorf("the next step leaked back into a section: %+v", message.Sections)
			}
			// The fallback leads with what stopped. It is the only line a
			// notification shows, and the header alone is a category.
			if !strings.HasPrefix(message.Text, testCase.header) ||
				!strings.Contains(message.Text, testCase.stopped) {
				t.Errorf("fallback = %q", message.Text)
			}
			// No dead buttons. These cards carry none at all today — the rerun
			// controls are incident-scoped and none of these constructors is
			// given an incident — so the assertion is that whatever they ever
			// do carry has somewhere to go.
			for _, action := range cardActions(message) {
				if !routedActionIDs[action.ID] {
					t.Errorf("failure card offers %q, which no handler answers", action.ID)
				}
			}
		})
	}
}

// The boundary line survives the reshape.
//
// "No merge, push, signing, or deployment occurred" is the sentence that makes
// a failure safe to walk away from, and it is the kind of line a layout change
// drops without anybody noticing until it is needed.
func TestFailureCardsKeepTheirSafetyBoundary(t *testing.T) {
	for name, message := range map[string]Message{
		"turn":         TurnFailureMessage("failed", "provider timed out"),
		"report":       AgentReportFailureMessage(),
		"triage":       TriageFailureMessage(),
		"verification": ApprovalVerificationFailureMessage(),
	} {
		t.Run(name, func(t *testing.T) {
			context := strings.Join(message.Context, "\n")
			if !strings.Contains(context, "No merge, push, signing, or deployment occurred") &&
				!strings.Contains(context, "kept out of the channel") {
				t.Fatalf("failure card lost its boundary line: %+v", message.Context)
			}
		})
	}
}

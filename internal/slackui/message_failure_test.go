package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
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
// ActionOverflow is routed at admission rather than by a handler:
// slackControlSelection reads the chosen option out of `selected_option.value`,
// splits the encoded action back off it, and hands the ordinary control path an
// input indistinguishable from the equivalent button click. It is listed here
// because a menu that reaches nothing is the same failure as a button that
// does — and it did reach nothing, for every option on every card, until the
// option value started carrying its own action id.
var routedActionIDs = map[string]bool{
	ActionOverflow: true, ActionFullRequest: true, ActionTurnReceipt: true,
	ActionDismissMessage: true,
	// A URL button still reports its click, and Slack shows the operator a
	// failure on an interaction nobody answered. acknowledgeLinkAction is the
	// answer: the link already did the work.
	ActionOpenCanvas: true,
	ActionUpdate:     true, ActionChanges: true, ActionChangesPrevious: true,
	ActionChangesNext: true, ActionChangesRefresh: true, ActionCloseDiff: true,
	ActionReview:       true,
	ActionRepairReview: true, ActionPublishPR: true, ActionViewPR: true,
	ActionCheckDelivery: true, ActionDiscardWork: true, ActionStop: true,
	ActionExtend: true, ActionResolve: true, ActionHelp: true,
	ActionOpenIncident: true, ActionOpenWorkThread: true, ActionStartTask: true,
	ActionReviewPullRequest: true, ActionOpenApproval: true,
	// The model's own question, answered by pressing one of the choices it
	// supplied. Routed like any other control, because a press that reached
	// nothing would leave the work parked on a question the operator believes
	// they have already answered.
	ActionOperatorChoice: true,
	// The one click that grants Ryker authority to offer an action. Routed
	// like any other control, and refused by the handler unless the presser is a
	// configured operator with active full workspace membership.
	ActionConfirmGrantPromotion: true,
	ActionRememberMemory:        true, ActionForgetMemory: true,
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
	ActionRecordTimeline: true, ActionRecordEvidence: true,
	ActionRecordHandoff: true, ActionRecordPostmortem: true,
	ActionRecordDirectory: true, ActionRecordBack: true,
}

// Every option in every ⋯ menu production can render reaches a handler.
//
// The allowlist above is checked against Action structs, which is one step
// short of the truth: the struct's ID is not what Slack sends back. Slack sends
// the shared menu action_id and the option's value, so an option is only
// reachable if the value it actually shipped decodes to a routed id. That gap
// is precisely where seven live controls went missing — the renderer built the
// options from Action.Value alone and discarded each option's own ID, and the
// audit could not see it because the audit read the struct.
//
// So this reads the rendered payload: every menu every production constructor
// emits, decoded the way the socket decodes it.
func TestEveryOverflowOptionDecodesToARoutedAction(t *testing.T) {
	// An alert-routed incident, not an engineering task: a different constructor
	// with a different menu, and the ⋯ the publication receipt was kept off.
	incident := taskFixture()
	incident.WorkKind = ""
	incident.WorkScope = ""
	incident.Route = "grafana"
	incident.SourceIncidentID = "alert-1"
	if incident.IsEngineeringTask() {
		t.Fatal("the incident fixture still renders as an engineering task")
	}
	closedIncident := incident
	closedIncident.Status = core.IncidentClosed
	closedIncident.Workflow = core.WorkflowClosed
	published := openPublication()

	schedule := core.ScheduledTask{
		ID: "schedule_" + strings.Repeat("a", 32), ChannelID: "COPS", ThreadTS: "100.1",
		Repository: "repo", Title: "Morning health report",
		Prompt:     "Check production health and summarize material changes.",
		Recurrence: "daily", LocalTime: "09:00", Timezone: "UTC",
		NextRunAt: time.Now().UTC().Add(time.Hour), Enabled: true,
	}
	paused := schedule
	paused.Enabled = false
	firedOneShot := schedule
	firedOneShot.NextRunAt = time.Time{}

	cards := append([]namedCard{}, everyTaskCardState(t)...)
	for _, incidentCase := range []struct {
		name        string
		incident    core.Incident
		publication core.Publication
	}{
		{"incident published", incident, published},
		{"incident closed with PR", closedIncident, published},
		{"incident plain", incident, core.Publication{}},
	} {
		cards = append(cards, namedCard{
			name: incidentCase.name,
			message: IncidentCardWithPublication(
				incidentCase.incident, "Blitz Infrastructure", nil, false, true,
				incidentCase.publication, core.PublicationFollowup{},
				core.PublicationLifecycleEvent{},
			),
		})
	}
	cards = append(cards,
		namedCard{
			name:    "schedule directory",
			message: ScheduleDirectoryMessage([]core.ScheduledTask{schedule, paused, firedOneShot}),
		},
	)

	routed := map[string]bool{}
	for _, card := range cards {
		options := renderedOverflowOptions(t, card.message)
		// Every entry the constructor put in a menu has to have shipped. A
		// guard that silently swallowed the whole menu would otherwise read as
		// a pass here, which is the failure this test exists to catch.
		// Render order, not declaration order: every row menu is emitted while
		// the sections are walked, and the card's own menu joins its buttons,
		// which come after them either way — ActionsEarly moves the button
		// block ahead of the ledger and the footer, not ahead of the rows.
		// Pairing an option with the wrong entry is what this comparison is
		// for, so the order it compares in has to be the wire's.
		var wanted []Action
		for _, row := range card.message.Rows {
			wanted = append(wanted, row.Overflow...)
		}
		wanted = append(wanted, card.message.Overflow...)
		if len(options) != len(wanted) {
			t.Fatalf("%s: rendered %d overflow options for %d menu entries",
				card.name, len(options), len(wanted))
		}
		for index, value := range options {
			actionID, target, ok := DecodeOverflowOptionValue(value)
			if !ok {
				t.Fatalf("%s: overflow option %q does not decode", card.name, value)
			}
			if !routedActionIDs[actionID] {
				t.Errorf("%s: ⋯ offers %q, which no handler answers", card.name, actionID)
			}
			// The decoded halves are what a button carrying the same action
			// would have sent, or the re-entry into the button path routes a
			// real action at the wrong thing.
			if actionID != wanted[index].ID || target != wanted[index].Value {
				t.Errorf("%s: option %q decodes to %q/%q, want %q/%q",
					card.name, value, actionID, target,
					wanted[index].ID, wanted[index].Value)
			}
			if len(value) > overflowOptionValueLimit {
				t.Errorf("%s: option value is %d characters, over Slack's %d",
					card.name, len(value), overflowOptionValueLimit)
			}
			routed[actionID] = true
		}
	}

	// The controls Phases 1 and 4 moved into menus, named rather than counted:
	// a refactor that empties a menu should fail here rather than pass quietly.
	// ActionFullRequest is deliberately absent: the card renders the whole
	// request in its tail, so the control that used to reveal it is retired
	// from every menu. It stays routed for the cards that still carry it.
	for _, want := range []string{
		ActionUpdate, ActionReview, ActionCheckDelivery, ActionHelp,
		ActionToggleSchedule, ActionEditSchedule,
	} {
		if !routed[want] {
			t.Errorf("no production ⋯ menu offers %q; the audit covers nothing", want)
		}
	}
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
		message:  TurnFailureMessage(core.Incident{}, "failed", "MCP request timed out."),
		stripe:   StripeFailed,
		header:   "🛑 Investigation could not finish",
		stopped:  "MCP request timed out.",
		survived: "preserved",
		next:     "Reply in this thread to continue",
	}, {
		// Stopping work somebody asked to be stopped is the system obeying
		// them. Red would ask the one person who already knows to discount it.
		name:     "turn cancelled",
		message:  TurnFailureMessage(core.Incident{}, "cancelled", "operator stopped the turn"),
		stripe:   StripeIdle,
		header:   "⏸ Stopped — you asked me to.",
		stopped:  "operator stopped the turn",
		survived: "preserved",
		next:     "Reply in this thread to continue",
	}, {
		name:     "report unreadable",
		message:  AgentReportFailureMessage(core.Incident{}),
		stripe:   StripeFailed,
		header:   "🛑 Summary needs another pass",
		stopped:  "did not come back in a form I could publish",
		survived: "workspace are preserved",
		next:     "I’ll write it up again",
	}, {
		name:     "triage gave up",
		message:  TriageFailureMessage(false),
		stripe:   StripeFailed,
		header:   "🛑 Request needs a retry",
		stopped:  "stopped retrying this request",
		survived: "before a model turn started",
		next:     "Reply in this thread to try again",
	}, {
		name:     "verification gave up",
		message:  ApprovalVerificationFailureMessage(),
		stripe:   StripeFailed,
		header:   "🛑 Verification needs attention",
		stopped:  "stopped verifying its result",
		survived: "Emisar run record shows what happened",
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

// Failure cards say what survived and what to do next without appending the
// same merge/deploy disclaimer to every unrelated failure.
func TestFailureCardsKeepRecoveryWithoutBoilerplate(t *testing.T) {
	for name, message := range map[string]Message{
		"turn":         TurnFailureMessage(core.Incident{}, "failed", "provider timed out"),
		"report":       AgentReportFailureMessage(core.Incident{}),
		"triage":       TriageFailureMessage(false),
		"verification": ApprovalVerificationFailureMessage(),
	} {
		t.Run(name, func(t *testing.T) {
			content := cardText(message)
			if len(message.Context) == 0 {
				t.Fatalf("failure card lost its next step: %+v", message)
			}
			for _, boilerplate := range []string{"No merge, push", "kept out of the channel"} {
				if strings.Contains(content, boilerplate) {
					t.Fatalf("failure card still carries %q: %s", boilerplate, content)
				}
			}
		})
	}
}

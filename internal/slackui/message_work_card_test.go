package slackui

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func taskFixture() core.Incident {
	return core.Incident{
		ID: "inc_01ce33abd2000000", Route: "manual", SourceIncidentID: "task:VA1",
		WorkKind: core.WorkKindEngineeringTask, WorkScope: core.WorkScopeThread,
		OriginChannelID: "COPS", OriginThreadTS: "1700.0",
		Title:  "VA1: prevent reload-driven Traefik OOM recurrence",
		Status: core.IncidentActive, Workflow: core.WorkflowParked,
		RootTS: "1700.1", CoopSessionID: "ses_1", CoopForkName: "remote-44f3f67",
		CreatedAt: time.Now().Add(-46 * time.Minute), UpdatedAt: time.Now(),
	}
}

func openPublication() core.Publication {
	return core.Publication{
		State: core.PublicationPublished, PRNumber: 482,
		PRURL: "https://github.example/owner/repository/pull/482",
	}
}

// One state, one answer. The card that this replaced derived its colour, its
// heading, its controls and its closing sentence from four separate conditions
// that could disagree; the resolver is the single place they are decided, so
// every combination the lifecycle can reach is pinned to the three things a
// reader gets — the colour, the glyph, and the word that survives both.
func TestTaskCardStateResolverCoversEveryLifecycleCombination(t *testing.T) {
	stale := core.Publication{
		State: core.PublicationStale, PRNumber: 482,
		PRURL: "https://github.example/owner/repository/pull/482",
	}
	failed := core.Publication{
		State: core.PublicationFailed, LastError: "GitHub rejected the branch update",
	}
	sessionBinding := core.Publication{
		State: core.PublicationFailed, FailureCode: core.PublicationFailureSessionBinding,
		LastError: "This task's session no longer exists.",
	}
	tests := []struct {
		name        string
		workflow    core.WorkflowState
		status      core.IncidentStatus
		activeTurn  string
		lastError   string
		publication core.Publication
		followup    core.PublicationFollowup
		hasChanges  bool
		known       bool
		stripe      string
		glyph       string
		word        string
	}{
		// The real VA1 state, read off the tenant state DB on 2026-08-13:
		// investigating, a turn running, no code changes yet. It is the state
		// the card is open in most of the time and the one the design starts
		// from, so it is pinned by name.
		{
			name: "VA1 investigating with a running turn", workflow: core.WorkflowInvestigating,
			status: core.IncidentActive, activeTurn: "turn_1", known: true,
			stripe: StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "investigating between turns", workflow: core.WorkflowInvestigating,
			status: core.IncidentActive, known: true,
			stripe: StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "creating the working room", workflow: core.WorkflowProvisioningChannel,
			status: core.IncidentActive,
			stripe: StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "preparing the workspace", workflow: core.WorkflowProvisioningSession,
			status: core.IncidentActive,
			stripe: StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "queued for capacity", workflow: core.WorkflowHolding,
			status: core.IncidentActive, known: true,
			stripe: StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "closing", workflow: core.WorkflowClosing, status: core.IncidentActive,
			known:  true,
			stripe: StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "blocked on a teammate", workflow: core.WorkflowBlocked,
			status: core.IncidentActive, known: true,
			stripe: StripeNeedsYou, glyph: "✋", word: "Needs you",
		},
		{
			name: "parked with an error to clear", workflow: core.WorkflowParked,
			status: core.IncidentActive, lastError: "Turn budget exhausted.", known: true,
			stripe: StripeNeedsYou, glyph: "✋", word: "Needs you",
		},
		{
			name: "parked with nothing to publish", workflow: core.WorkflowParked,
			status: core.IncidentActive, known: true,
			stripe: StripeIdle, glyph: "⏸", word: "Parked",
		},
		{
			name: "changes waiting on a draft PR", workflow: core.WorkflowParked,
			status: core.IncidentActive, hasChanges: true, known: true,
			stripe: StripeNeedsYou, glyph: "📦", word: "Ready to publish",
		},
		{
			name: "readiness review running", workflow: core.WorkflowParked,
			status: core.IncidentActive, hasChanges: true, known: true,
			publication: core.Publication{State: core.PublicationReviewing},
			stripe:      StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "publishing", workflow: core.WorkflowParked, status: core.IncidentActive,
			hasChanges: true, known: true,
			publication: core.Publication{State: core.PublicationPublishing},
			stripe:      StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "retry scheduled", workflow: core.WorkflowParked, status: core.IncidentActive,
			hasChanges: true, known: true,
			publication: core.Publication{State: core.PublicationRetrying},
			stripe:      StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "tree changed after the PR", workflow: core.WorkflowParked,
			status: core.IncidentActive, hasChanges: true, known: true, publication: stale,
			stripe: StripeNeedsYou, glyph: "📦", word: "Ready to publish",
		},
		{
			name: "PR open while checks run", workflow: core.WorkflowParked,
			status: core.IncidentActive, known: true, publication: openPublication(),
			followup: core.PublicationFollowup{ChecksState: "pending"},
			stripe:   StripeWorking, glyph: "🔀", word: "PR open",
		},
		{
			name: "PR open with checks green", workflow: core.WorkflowParked,
			status: core.IncidentActive, known: true, publication: openPublication(),
			followup: core.PublicationFollowup{ChecksState: "passing"},
			stripe:   StripeNeedsYou, glyph: "🔀", word: "PR open",
		},
		{
			name: "PR open with checks red", workflow: core.WorkflowParked,
			status: core.IncidentActive, known: true, publication: openPublication(),
			followup: core.PublicationFollowup{ChecksState: "failing"},
			stripe:   StripeNeedsYou, glyph: "🔀", word: "PR open",
		},
		// A failure with a retry button on the card is an ask, not a stop.
		// Red is for where the run actually ended.
		{
			name: "publication failed but retryable", workflow: core.WorkflowParked,
			status: core.IncidentActive, hasChanges: true, known: true, publication: failed,
			stripe: StripeNeedsYou, glyph: "✋", word: "Needs you",
		},
		{
			name: "publication failed with no changes to publish", workflow: core.WorkflowParked,
			status: core.IncidentActive, known: true, publication: failed,
			stripe: StripeFailed, glyph: "🛑", word: "Failed",
		},
		{
			name: "publication failed on a lost session", workflow: core.WorkflowParked,
			status: core.IncidentActive, hasChanges: true, known: true,
			publication: sessionBinding,
			stripe:      StripeFailed, glyph: "🛑", word: "Failed",
		},
		{
			name: "merged", workflow: core.WorkflowParked, status: core.IncidentActive,
			hasChanges: true, known: true, publication: openPublication(),
			followup: core.PublicationFollowup{PRState: "merged", MergeSHA: "b3b6bb4e50119ba6"},
			stripe:   StripeDone, glyph: "✅", word: "Merged",
		},
		{
			name: "PR closed without merging", workflow: core.WorkflowParked,
			status: core.IncidentActive, hasChanges: true, known: true,
			publication: openPublication(),
			followup:    core.PublicationFollowup{PRState: "closed"},
			stripe:      StripeIdle, glyph: "⏸", word: "PR closed",
		},
		{
			name: "task closed", workflow: core.WorkflowClosed, status: core.IncidentClosed,
			hasChanges: true, known: true,
			stripe: StripeIdle, glyph: "⏸", word: "Closed",
		},
		// Precedence: a turn that is running outranks a publication that is
		// waiting on it, and an outcome that already happened outranks both.
		{
			name:     "running turn outranks a publication in flight",
			workflow: core.WorkflowInvestigating, status: core.IncidentActive,
			activeTurn: "turn_1", hasChanges: true, known: true,
			publication: core.Publication{State: core.PublicationReviewing},
			stripe:      StripeWorking, glyph: "⚙️", word: "Working",
		},
		{
			name: "merge outranks a running turn", workflow: core.WorkflowInvestigating,
			status: core.IncidentActive, activeTurn: "turn_1", hasChanges: true, known: true,
			publication: openPublication(),
			followup:    core.PublicationFollowup{PRState: "merged"},
			stripe:      StripeDone, glyph: "✅", word: "Merged",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			task := taskFixture()
			task.Workflow = test.workflow
			task.Status = test.status
			task.ActiveTurnID = test.activeTurn
			task.LastError = test.lastError
			state := taskCardState(
				task, test.hasChanges, test.known, test.publication, test.followup,
			)
			if state.Stripe != test.stripe || state.Glyph != test.glyph || state.Word != test.word {
				t.Fatalf(
					"state = {%q %q %q}, want {%q %q %q}",
					state.Stripe, state.Glyph, state.Word, test.stripe, test.glyph, test.word,
				)
			}
			// Rule 3: colour never travels alone. A notification carries the
			// word, the sidebar carries neither the colour nor the glyph, and
			// a card that set one without the others would be unreadable in
			// exactly the surfaces people see first.
			card := IncidentCardWithPublication(
				task, "Tenant Infrastructure", nil, test.hasChanges, test.known,
				test.publication, test.followup, core.PublicationLifecycleEvent{},
			)
			if card.Stripe != test.stripe ||
				!strings.HasPrefix(card.Header, test.glyph+" ") ||
				!strings.HasPrefix(card.Text, test.word+" — ") {
				t.Fatalf("card does not state its state three ways: %+v", card)
			}
			// Rule 1: the state line always ends with the ask or its absence.
			if !strings.Contains(card.Sections[0], "*"+test.word+"*") ||
				!strings.HasSuffix(strings.TrimSpace(card.Sections[0]), "*") {
				t.Fatalf("state line does not close on the ask: %q", card.Sections[0])
			}
		})
	}
}

// Green is earned, not decorative, and red is for destruction only.
//
// The card being replaced put a primary "Ask agent for update" on a task that
// was waiting on nothing, and a red "Stop current run" on one whose work was
// fully preserved. Both taught the operator that the colours mean nothing.
func TestTaskCardControlsFollowCustody(t *testing.T) {
	running := taskFixture()
	running.Workflow = core.WorkflowInvestigating
	running.ActiveTurnID = "turn_1"
	working := IncidentCardWithPublication(
		running, "Tenant Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	for _, action := range working.Actions {
		if action.Style != "" {
			t.Fatalf("Emisar's turn carries a styled button: %+v", action)
		}
	}
	stop, found := findAction(working.Actions, ActionStop)
	if !found || stop.Style != "" || stop.Confirm == "" {
		t.Fatalf("Stop is not a neutral control with its guard intact: %+v", working.Actions)
	}

	ready := taskFixture()
	primaries := 0
	readyCard := IncidentCardWithPublication(
		ready, "Tenant Infrastructure", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	for _, action := range readyCard.Actions {
		if action.Style == "primary" {
			primaries++
		}
		if action.Style == "danger" && action.ID != ActionResolve {
			t.Fatalf("red on something that destroys nothing: %+v", action)
		}
	}
	if primaries != 1 {
		t.Fatalf("ready-to-publish card has %d primaries, want exactly one: %+v",
			primaries, readyCard.Actions)
	}
	publish, found := findAction(readyCard.Actions, ActionPublishPR)
	if !found || !strings.Contains(publish.Confirm, "cannot merge or deploy") {
		t.Fatalf("the primary lost the boundary its confirmation carries: %+v", publish)
	}

	// Discard is the one irreversible control on any task card, and it stays a
	// red button exactly where the old card offered it.
	closed := taskFixture()
	closed.Status = core.IncidentClosed
	closed.Workflow = core.WorkflowClosed
	closedCard := IncidentCardWithPublication(
		closed, "Tenant Infrastructure", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	discard, found := findAction(closedCard.Actions, ActionDiscardWork)
	if !found || discard.Style != "danger" || discard.Confirm == "" {
		t.Fatalf("closed task with retained work lost its discard control: %+v", closedCard.Actions)
	}
}

// Block Kit gives an overflow element one confirmation dialog for all of its
// options, not one per option. A confirmable action moved into the menu would
// therefore either guard every harmless item beside it — teaching the operator
// to dismiss the dialog unread — or ship with no guard at all.
func TestConfirmableActionsNeverReachTheOverflowMenu(t *testing.T) {
	for _, card := range everyTaskCardState(t) {
		for _, action := range card.message.Overflow {
			if action.Confirm != "" {
				t.Fatalf("%s: overflow holds a confirmable action: %+v", card.name, action)
			}
		}
		// What was asserted on the struct has to be what shipped, so the
		// rendered payload is read back rather than trusted.
		options := renderedOverflowOptions(t, card.message)
		if len(options) > 5 {
			t.Fatalf("%s: overflow renders %d options, over Slack's limit of 5",
				card.name, len(options))
		}
		for _, value := range options {
			if !slices.ContainsFunc(card.message.Overflow, func(action Action) bool {
				return OverflowOptionValue(action) == value
			}) {
				t.Fatalf("%s: rendered an overflow option no Overflow entry owns: %q",
					card.name, value)
			}
		}
		// Rule 6: the bottom row is a few controls worth pressing, not the
		// whole state machine. Four is the renderer's own chunk width.
		if len(card.message.Actions) > 4 {
			t.Fatalf("%s: %d buttons in the bottom row: %+v",
				card.name, len(card.message.Actions), card.message.Actions)
		}
	}
}

// Position, not adjective: the run states where it has got to rather than
// naming its phase and leaving the reader to place it in a sequence they
// cannot see. A finished run states nothing at all — it is a receipt.
func TestTaskLedgerStatesPositionAndTerminalCardsShrinkToAReceipt(t *testing.T) {
	task := taskFixture()
	task.Workflow = core.WorkflowInvestigating
	task.ActiveTurnID = "turn_1"
	card := IncidentCardWithPublication(
		task, "Tenant Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if len(card.Ledger) != 5 {
		t.Fatalf("mid-investigation ledger = %+v", card.Ledger)
	}
	position, steps := ledgerMarker(card.Ledger)
	if position != 2 || steps != 5 ||
		card.Ledger[1].Label != "Investigate" ||
		card.Ledger[0].Glyph != "✓" || card.Ledger[4].Owner != "yours" {
		t.Fatalf("ledger does not state the run's position: %+v", card.Ledger)
	}
	// The fallback carries the position too, because a notification gets the
	// string and never the strip.
	if !strings.Contains(card.Text, "step 2 of 5") {
		t.Fatalf("fallback lost the run's position: %q", card.Text)
	}

	// Once a change exists the middle step is named for the change, not for
	// the investigation that produced it.
	changed := IncidentCardWithPublication(
		taskFixture(), "Tenant Infrastructure", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if changed.Ledger[1].Label != "Make the change" || changed.Ledger[1].Glyph != "✓" {
		t.Fatalf("ledger did not follow the phase: %+v", changed.Ledger)
	}
	if position, _ := ledgerMarker(changed.Ledger); position != 3 {
		t.Fatalf("ready-to-publish run is at step %d, want the readiness review", position)
	}

	merged := IncidentCardWithPublication(
		taskFixture(), "Tenant Infrastructure", nil, true, true, openPublication(),
		core.PublicationFollowup{PRState: "merged", MergeSHA: "b3b6bb4e50119ba6"},
		core.PublicationLifecycleEvent{},
	)
	if len(merged.Ledger) != 0 {
		t.Fatalf("a finished run still renders a ledger: %+v", merged.Ledger)
	}
	receipt := strings.Join(merged.Sections, "\n")
	if !strings.Contains(receipt, "PR merged") || !strings.Contains(receipt, "b3b6bb4e501") {
		t.Fatalf("merged receipt lost its outcome or its identifiers: %q", receipt)
	}
}

// The middle ledger step names the phase, and never an object.
//
// It read "Investigate the trigger" in every state, carried over from a mock
// whose task happened to be an OOM investigation. On "Bump the pinned admin
// runner release" there is no trigger, so the card was putting a question to
// the operator about a thing that did not exist. The renderer knows the phase
// and knows nothing about the subject; the label may only say the part it
// knows.
func TestTheChangeStepNamesThePhaseAndNeverAnObject(t *testing.T) {
	for _, testCase := range []struct {
		name           string
		workflow       core.WorkflowState
		hasCodeChanges bool
		publication    core.Publication
		label          string
	}{
		{
			name:     "nothing has run, so the step ahead is working out what to do",
			workflow: core.WorkflowProvisioningChannel,
			label:    "Plan the work",
		},
		{
			name:     "the workspace is still coming up",
			workflow: core.WorkflowProvisioningSession,
			label:    "Plan the work",
		},
		{
			name:     "a turn is running and has produced no change",
			workflow: core.WorkflowInvestigating,
			label:    "Investigate",
		},
		{
			name:     "a turn has run and produced no change",
			workflow: core.WorkflowParked,
			label:    "Investigate",
		},
		{
			name:           "the fork holds a change",
			workflow:       core.WorkflowInvestigating,
			hasCodeChanges: true,
			label:          "Make the change",
		},
		{
			// Nobody probes the fork while a publication runs, so the caller
			// reports no changes and the step is marked done anyway. A step
			// with a ✓ on it under the word "Investigate" would be the label
			// and the glyph contradicting each other.
			name:        "a PR exists, so a change exists whatever the fork probe says",
			workflow:    core.WorkflowParked,
			publication: openPublication(),
			label:       "Make the change",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			task := taskFixture()
			task.Workflow = testCase.workflow
			if testCase.workflow == core.WorkflowProvisioningChannel ||
				testCase.workflow == core.WorkflowProvisioningSession {
				// Nothing is provisioned yet, so there is no session to name.
				task.CoopSessionID = ""
			}
			state := taskCardState(
				task, testCase.hasCodeChanges, true,
				testCase.publication, core.PublicationFollowup{},
			)
			ledger := taskLedger(
				task, state, testCase.hasCodeChanges, testCase.publication,
				LiveTurn{}, time.Now(),
			)
			if len(ledger) != 5 {
				t.Fatalf("ledger = %+v", ledger)
			}
			if ledger[1].Label != testCase.label {
				t.Fatalf("change step = %q, want %q", ledger[1].Label, testCase.label)
			}
			for _, step := range ledger {
				if strings.Contains(step.Label, "trigger") {
					t.Fatalf("a step named an object the card cannot know: %+v", ledger)
				}
			}
		})
	}

	// The receipt hangs off the position, not off the wording. A finished
	// turn's totals move onto the middle step whatever that step is called, so
	// renaming it for the phase cannot cost a reader the only record of what
	// the turn actually did.
	task := taskFixture()
	task.Workflow = core.WorkflowParked
	ledger := taskLedger(
		task,
		taskCardState(task, true, true, core.Publication{}, core.PublicationFollowup{}),
		true, core.Publication{},
		LiveTurn{ToolCalls: 119, Evidence: 2}, time.Now(),
	)
	if ledger[1].Label != "Make the change" ||
		ledger[1].Detail != "119 calls · 2 evidence" {
		t.Fatalf("the completed step lost its receipt: %+v", ledger)
	}
}

// The state line may not point at a section the card did not render.
//
// Same rule as the ledger label, one section down: name only what is there.
// "Needs you" is reached from a blocked workflow as well as from a failed
// publication, and *Action needed* is rendered only when something recorded a
// reason — so a task blocked without one was sending the operator to read a
// block that is not on the card.
func TestTheStateLineNeverPointsAtASectionTheCardDidNotRender(t *testing.T) {
	blocked := taskFixture()
	blocked.Workflow = core.WorkflowBlocked
	card := IncidentCardWithPublication(
		blocked, "Tenant Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	body := strings.Join(card.Sections, "\n")
	if strings.Contains(body, "*Action needed*") {
		t.Fatalf("a blocker with no recorded reason rendered a section: %q", body)
	}
	if !strings.Contains(body, "reply with how to continue") {
		t.Fatalf("the state line lost its ask: %q", body)
	}

	// With a reason the section exists, and then the pointer is honest.
	blocked.LastError = "The gate needs a repository validation command."
	withReason := IncidentCardWithPublication(
		blocked, "Tenant Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	reason := strings.Join(withReason.Sections, "\n")
	if !strings.Contains(reason, "*Action needed*") ||
		!strings.Contains(reason, "read *Action needed*") {
		t.Fatalf("a recorded blocker lost its section or its pointer: %q", reason)
	}
}

// Firing first, because a recovered signal is history and a firing one is the
// incident. A strip ordered by arrival buries the live signals under the ones
// that already cleared, which is the opposite of what it is for.
func TestIncidentSignalStripOrdersFiringFirstAndCaps(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "Checkout is failing", Severity: "sev1",
		Status: core.IncidentActive, Workflow: core.WorkflowInvestigating,
		FiringCount: 3, SignalCount: 5, RootTS: "1700.1",
		CreatedAt: time.Now().Add(-12 * time.Minute), UpdatedAt: time.Now(),
	}
	signals := []core.Signal{
		{Status: core.SignalResolved, Title: "DiskPressure", EndsAt: time.Now().Add(-9 * time.Minute)},
		{
			Status: core.SignalFiring, Labels: map[string]string{
				"alertname": "TraefikOOMKilled", "service": "traefik",
			},
			StartsAt: time.Now().Add(-12 * time.Minute),
		},
		{Status: core.SignalResolved, Title: "NodeNotReady", EndsAt: time.Now().Add(-4 * time.Minute)},
		{Status: core.SignalFiring, Title: "CheckoutLatencyHigh", StartsAt: time.Now().Add(-8 * time.Minute)},
		{Status: core.SignalFiring, Title: "FiveHundredsElevated", StartsAt: time.Now().Add(-6 * time.Minute)},
	}
	card := IncidentCardWithPublication(
		incident, "Infrastructure", signals, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if len(card.Ledger) != 5 {
		t.Fatalf("signal strip = %+v", card.Ledger)
	}
	for index, step := range card.Ledger {
		want := "●"
		if index >= 3 {
			want = "○"
		}
		if step.Glyph != want {
			t.Fatalf("strip is not ordered firing first: %+v", card.Ledger)
		}
	}
	// The name comes from the alertname label where the source supplies one,
	// and the topology label qualifies it.
	if card.Ledger[0].Label != "TraefikOOMKilled" || card.Ledger[0].Detail != "traefik" ||
		card.Ledger[0].When == "" {
		t.Fatalf("firing signal lost its name, its site, or its age: %+v", card.Ledger[0])
	}

	many := make([]core.Signal, 0, 9)
	for range 9 {
		many = append(many, core.Signal{
			Status: core.SignalFiring, Title: "Alert", StartsAt: time.Now().Add(-time.Minute),
		})
	}
	capped := IncidentCardWithPublication(
		incident, "Infrastructure", many, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	// Seven and a count, because thirty alertnames is not more informative
	// than seven and a number, and the card is an instrument, not a log.
	if len(capped.Ledger) != 8 || capped.Ledger[7].Label != "… and 2 more" {
		t.Fatalf("capped strip = %+v", capped.Ledger)
	}
}

// The card is a fixed-height instrument that is rewritten, never extended.
// This is the guard on that: the busiest state a task can legally reach still
// fits in a screen, and a new conditional section cannot quietly turn the card
// back into the log it was.
func TestBusiestTaskCardStaysAnInstrument(t *testing.T) {
	task := taskFixture()
	task.LastError = "The readiness gate needs a repository validation command."
	task.LatestUpdate = "Raised the allocation memory and added the two alert rules."
	card := IncidentCardWithPublication(
		task, "Tenant Infrastructure",
		[]core.Signal{{
			Status: core.SignalFiring,
			Summary: "Raise Traefik memory 4096 to 8192 MiB, keep five replicas, add RSS " +
				"and swap and reload-rate alerts, keep the failed-reload alert, and " +
				"document the rollout checks.",
		}},
		true, true,
		core.Publication{
			State: core.PublicationFailed, PRNumber: 482,
			PRURL:     "https://github.example/owner/repository/pull/482",
			LastError: "GitHub rejected the branch update.",
		},
		core.PublicationFollowup{ChecksState: "failing"},
		core.PublicationLifecycleEvent{
			ID: "delivery-1", Kind: "terraform", State: "failed",
			Summary: "Terraform apply failed for the next staged hostname.",
		},
	)
	if blocks := len(card.Blocks()); blocks > 14 {
		t.Fatalf("the busiest task card renders %d blocks; it is becoming a log", blocks)
	}
	// Every part the design says must be there is still there at that height.
	if len(card.Fields) != 0 || len(card.Context) != 1 || len(card.Ledger) != 5 ||
		len(card.Rows) != 1 {
		t.Fatalf("the busiest card lost a required part: %+v", card)
	}
	if !strings.Contains(card.Context[0], "Isolated fork — cannot merge or deploy") ||
		!strings.Contains(card.Context[0], "`01ce33abd2`") {
		t.Fatalf("footer does not carry the boundary and the identifiers: %q", card.Context[0])
	}
}

// slackDate was added with no caller, so nothing noticed that the sanitizer
// neutered every token it produced: `<!date^…>` matches the broadcast-mention
// pattern that exists to stop `<!channel>` reaching a room. The first card to
// render a local time would have shipped a backticked string instead.
func TestSanitizerKeepsDateTokensAndStillNeutersBroadcasts(t *testing.T) {
	sanitizer := NewSanitizer(12000)
	token := slackDate(time.Unix(1786648800, 0), "2006-01-02 15:04 UTC")
	if got := sanitizer.Text("started " + token); !strings.Contains(got, token) {
		t.Fatalf("a date token did not survive sanitization: %q", got)
	}
	for _, broadcast := range []string{"<!channel>", "<!here>", "<!subteam^S123>", "<@U123ABC>"} {
		got := sanitizer.Text("please look " + broadcast)
		if strings.Contains(got, broadcast) {
			t.Fatalf("a broadcast mention survived sanitization: %q", got)
		}
	}
	// A hostile string cannot smuggle a broadcast through by opening with the
	// shape of a date token.
	smuggled := sanitizer.Text("<!date^0^x|<!channel>>")
	if strings.Contains(smuggled, "<!channel>") {
		t.Fatalf("a broadcast rode in on a date token: %q", smuggled)
	}
}

// The row, the overflow menu and the ledger were renderer primitives with no
// caller until the work cards used them, so redaction had never had to reach
// them. A row now carries the requester's own words and a ledger line carries
// alert labels — both arrive from outside this process.
func TestSanitizerRedactsTheCardPartsTheWorkCardsIntroduced(t *testing.T) {
	const secret = "xoxb-1234567890-abcdefghijklmnop"
	message := Message{
		Text: "card",
		Rows: []Row{{
			Text:     "> deploy with " + secret,
			Actions:  []Action{{ID: ActionHelp, Label: "Full " + secret}},
			Overflow: []Action{{ID: ActionHelp, Label: "Replace " + secret}},
		}},
		Overflow: []Action{{ID: ActionHelp, Label: "How " + secret, Confirm: "really " + secret}},
		Ledger:   []LedgerStep{{Label: "Alert " + secret, Children: []LedgerStep{{Label: "check " + secret}}}},
	}
	cleaned := NewSanitizer(12000).Message(message)
	rendered := cleaned.Rows[0].Text + cleaned.Rows[0].Actions[0].Label +
		cleaned.Rows[0].Overflow[0].Label +
		cleaned.Overflow[0].Label + cleaned.Overflow[0].Confirm +
		cleaned.Ledger[0].Label + cleaned.Ledger[0].Children[0].Label
	if strings.Contains(rendered, secret) {
		t.Fatalf("a credential survived into a card: %q", rendered)
	}
	// The caller's own value is never rewritten in place.
	if !strings.Contains(message.Rows[0].Text, secret) {
		t.Fatalf("sanitizing rewrote the caller's message: %+v", message)
	}
}

type namedCard struct {
	name    string
	message Message
}

// everyTaskCardState renders one card per state the resolver can produce, so a
// rule about controls is checked against all of them rather than the one the
// author had in mind.
func everyTaskCardState(t *testing.T) []namedCard {
	t.Helper()
	running := taskFixture()
	running.Workflow = core.WorkflowInvestigating
	running.ActiveTurnID = "turn_1"
	blocked := taskFixture()
	blocked.Workflow = core.WorkflowBlocked
	blocked.LastError = "The gate needs a repository validation command."
	closed := taskFixture()
	closed.Status = core.IncidentClosed
	closed.Workflow = core.WorkflowClosed
	failed := core.Publication{
		State: core.PublicationFailed, PRNumber: 482,
		PRURL:     "https://github.example/owner/repository/pull/482",
		LastError: "GitHub rejected the branch update.",
	}
	cases := []struct {
		name        string
		task        core.Incident
		hasChanges  bool
		known       bool
		publication core.Publication
		followup    core.PublicationFollowup
	}{
		{name: "working", task: running, known: true},
		{name: "parked", task: taskFixture(), known: true},
		{name: "ready to publish", task: taskFixture(), hasChanges: true, known: true},
		{
			name: "needs you", task: blocked, hasChanges: true, known: true,
			publication: failed,
		},
		{
			name: "failed", task: taskFixture(), known: true,
			publication: core.Publication{
				State: core.PublicationFailed, LastError: "Nothing to publish.",
			},
		},
		{
			name: "PR open", task: taskFixture(), known: true, publication: openPublication(),
			followup: core.PublicationFollowup{ChecksState: "passing"},
		},
		{
			name: "merged", task: taskFixture(), hasChanges: true, known: true,
			publication: openPublication(),
			followup:    core.PublicationFollowup{PRState: "merged"},
		},
		{
			name: "PR closed", task: taskFixture(), hasChanges: true, known: true,
			publication: openPublication(),
			followup:    core.PublicationFollowup{PRState: "closed"},
		},
		{name: "closed", task: closed, hasChanges: true, known: true},
	}
	cards := make([]namedCard, 0, len(cases))
	for _, test := range cases {
		cards = append(cards, namedCard{name: test.name, message: IncidentCardWithPublication(
			test.task, "Tenant Infrastructure",
			[]core.Signal{{Status: core.SignalFiring, Summary: "Raise Traefik memory."}},
			test.hasChanges, test.known, test.publication, test.followup,
			core.PublicationLifecycleEvent{},
		)})
	}
	return cards
}

func findAction(actions []Action, id string) (Action, bool) {
	for _, action := range actions {
		if action.ID == id {
			return action, true
		}
	}
	return Action{}, false
}

// renderedOverflowOptions reads the option values back out of the payload
// Slack would actually receive.
func renderedOverflowOptions(t *testing.T, message Message) []string {
	t.Helper()
	var values []string
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Elements []struct {
				Type    string `json:"type"`
				Options []struct {
					Value string `json:"value"`
				} `json:"options"`
			} `json:"elements"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		for _, element := range probe.Elements {
			if element.Type != "overflow" {
				continue
			}
			for _, option := range element.Options {
				values = append(values, option.Value)
			}
		}
	}
	return values
}

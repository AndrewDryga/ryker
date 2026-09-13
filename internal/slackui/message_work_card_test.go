package slackui

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/slack-go/slack"
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

// The old task card led with a generated state sentence, put the controls at
// the top, and left the request below the fold after the progress instrument.
// That made the thing being changed the hardest part of the card to find. The
// card is one durable work surface: request first, then progress with the live
// window inside it, then the controls.
func TestEngineeringTaskCardReadsRequestProgressAndActionsInWorkOrder(t *testing.T) {
	task := taskFixture()
	task.Workflow = core.WorkflowInvestigating
	task.ActiveTurnID = "turn_1"
	task.ChangesStat = "2 files · +121 −3"
	now := time.Now()
	card := IncidentCardWithPublication(
		task, "Blitz Rivals Scraper", []core.Signal{{
			Status:  core.SignalFiring,
			Summary: "In src/scraper_app.py, add bounded Gate request context.",
		}}, true, true, core.Publication{State: core.PublicationReviewing},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{}, LiveTurn{
			Active: true, ToolCalls: 18, LastActivity: now.Add(-time.Second),
			Lines: []ActivityLine{{Kind: ActivityTool, Title: "pytest -q", Target: "tests/unit"}},
		},
	)

	if len(card.Sections) == 0 || !strings.HasPrefix(card.Sections[0], "*The request*") {
		t.Fatalf("request is not first: sections=%v tail=%v", card.Sections, card.Tail)
	}
	if len(card.Tail) != 0 {
		t.Fatalf("request still renders after the card: %v", card.Tail)
	}
	if card.ActionsEarly {
		t.Fatal("task controls still render above progress")
	}
	wantSteps := []string{
		"Isolated fork of Blitz Rivals Scraper ready", "Plan the changes", "Implement changes",
		"Readiness review", "Draft PR", "Review and merge",
	}
	if len(card.Ledger) != len(wantSteps) {
		t.Fatalf("progress = %+v, want %d steps", card.Ledger, len(wantSteps))
	}
	for index, want := range wantSteps {
		if card.Ledger[index].Label != want {
			t.Errorf("step %d = %q, want %q", index, card.Ledger[index].Label, want)
		}
	}
	if got := card.Ledger[2].Detail; got != "2 files · +121 −3" {
		t.Errorf("change summary = %q, want compact git-style counts", got)
	}
	workspace := card.Ledger[0]
	if workspace.Subtext != "" || strings.Contains(ledgerText(card.Ledger), "remote-44f3f67") {
		t.Fatalf("workspace step still exposes internal fork plumbing: %+v", workspace)
	}
	current := card.Ledger[3]
	for _, want := range []string{"working", "last activity", "18 tool calls"} {
		if !strings.Contains(current.Detail, want) {
			t.Errorf("current step detail %q lacks %q", current.Detail, want)
		}
	}
	if len(card.Chips) != 0 || len(card.Context) != 0 {
		t.Fatalf("progress facts still float below the workflow: chips=%+v context=%+v",
			card.Chips, card.Context)
	}
	for _, action := range card.Overflow {
		if action.ID == ActionTurnReceipt {
			t.Fatalf("per-turn receipt still appears in the task menu: %+v", card.Overflow)
		}
	}

	blocks := card.Blocks()
	requestAt, progressAt, activityAt, actionsAt := -1, -1, -1, -1
	for index, block := range blocks {
		switch typed := block.(type) {
		case *slack.SectionBlock:
			if typed.Text == nil {
				continue
			}
			if strings.HasPrefix(typed.Text.Text, "*The request*") {
				requestAt = index
			}
			if strings.Contains(typed.Text.Text, "*Progress*") {
				progressAt = index
			}
		case *slack.RichTextBlock:
			activityAt = index
		case *slack.ActionBlock:
			actionsAt = index
		}
	}
	if !(requestAt >= 0 && requestAt < progressAt && progressAt < activityAt && activityAt < actionsAt) {
		t.Fatalf("block order request=%d progress=%d activity=%d actions=%d", requestAt, progressAt, activityAt, actionsAt)
	}
	for index, block := range blocks {
		section, ok := block.(*slack.SectionBlock)
		if !ok || section.Text == nil {
			continue
		}
		if strings.Contains(section.Text.Text, "*Progress*") && !section.Expand {
			t.Errorf("progress block %d can still collapse behind Show more", index)
		}
		if strings.HasPrefix(section.Text.Text, "*The request*") && section.Expand {
			t.Errorf("long request block %d cannot use Slack's own Show more", index)
		}
	}
}

func TestPRDeliveryAndFeedbackLiveUnderReviewAndMerge(t *testing.T) {
	task := taskFixture()
	task.Workflow = core.WorkflowInvestigating
	task.ActiveTurnID = "turn_feedback"
	publication := openPublication()
	publication.State = core.PublicationPublished
	publication.PRNumber = 20
	publication.PRURL = "https://github.example/pull/20"
	card := IncidentCardWithPublication(
		task, "Blitz Rivals Scraper", nil, true, true, publication,
		core.PublicationFollowup{
			PRState: "open", ChecksState: "passing",
			ChecksTotal: 2, ChecksPassed: 2,
			ChecksURL: "https://github.example/actions/runs/991",
		},
		core.PublicationLifecycleEvent{
			ID: "github-checks-20", Kind: "checks", State: "success",
			Summary: "GitHub checks passed for PR #20 (2 of 2). It is ready for review or merge.",
		},
		LiveTurn{Active: true, LastActivity: time.Now().Add(-time.Second), ToolCalls: 4},
	)
	review := card.Ledger[len(card.Ledger)-1]
	if !review.Current || !strings.Contains(review.Detail, "Working on feedback received") ||
		review.Owner != "" {
		t.Fatalf("feedback did not return Review and merge to working: %+v", review)
	}
	if review.Subtext != "" {
		t.Fatalf("review step still repeats PR prose: %q", review.Subtext)
	}
	if len(card.Ledger) != 7 || card.Ledger[4].Label != "Draft PR" ||
		card.Ledger[5].Glyph != "✓" || card.Ledger[5].Label != "GitHub checks" ||
		card.Ledger[5].Detail != "passed (2/2)" ||
		card.Ledger[6].Label != "Review and merge" {
		t.Fatalf("compact delivery progress = %+v", card.Ledger)
	}
	var progress strings.Builder
	for _, block := range card.Blocks() {
		section, ok := block.(*slack.SectionBlock)
		if ok && section.Text != nil {
			progress.WriteString(section.Text.Text)
		}
	}
	for _, want := range []string{
		"<https://github.example/pull/20|#20>",
		"<https://github.example/actions/runs/991|passed (2/2)>",
	} {
		if !strings.Contains(progress.String(), want) {
			t.Errorf("progress lost link %q:\n%s", want, progress.String())
		}
	}
	if strings.Contains(strings.Join(card.Sections, "\n"), "Delivery update") {
		t.Fatalf("delivery still renders as a detached section: %+v", card.Sections)
	}
	for _, stale := range []string{"exact tree", "It is ready for review or merge"} {
		if strings.Contains(cardText(card), stale) {
			t.Errorf("card still repeats delivery prose %q", stale)
		}
	}
	task.ActiveTurnID = ""
	queued := IncidentCardWithPublication(
		task, "Blitz Rivals Scraper", nil, true, true, publication,
		core.PublicationFollowup{
			PRState: "open", ChecksState: "passing", ChecksTotal: 2, ChecksPassed: 2,
		},
		core.PublicationLifecycleEvent{},
	)
	queuedReview := queued.Ledger[len(queued.Ledger)-1]
	if !queuedReview.Current || queuedReview.Detail != "Working on feedback received" ||
		queuedReview.Owner != "" {
		t.Fatalf("accepted feedback still looks like the operator's turn: %+v", queuedReview)
	}
	var queuedProgress strings.Builder
	for _, block := range queued.Blocks() {
		section, ok := block.(*slack.SectionBlock)
		if ok && section.Text != nil {
			queuedProgress.WriteString(section.Text.Text)
		}
	}
	if want := "<https://github.example/pull/20|passed (2/2)>"; !strings.Contains(queuedProgress.String(), want) {
		t.Errorf("checks without a workflow URL lost the PR fallback %q:\n%s", want, queuedProgress.String())
	}
}

func TestEngineeringTaskHelpExplainsTheForkAndHowToSteerIt(t *testing.T) {
	help := cardText(HelpMessage(taskFixture()))
	for _, want := range []string{
		"Emisar is working on code changes in an isolated fork.",
		"It cannot merge or deploy them.",
		"reply in this thread", "no `@mention` needed",
		"continues the same isolated session",
		"Use the work card above for actions and its record.",
		"Ask for anything else in plain language.",
	} {
		if !strings.Contains(help, want) {
			t.Errorf("help lacks %q:\n%s", want, help)
		}
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
		// The real VA1 state, read off the blitz state DB on 2026-08-13:
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
			stripe: StripeWorking, glyph: "⚙️", word: "Updating PR",
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
				task, "Blitz Infrastructure", nil, test.hasChanges, test.known,
				test.publication, test.followup, core.PublicationLifecycleEvent{},
			)
			if card.Stripe != test.stripe ||
				!strings.HasPrefix(card.Header, test.glyph+" ") ||
				!strings.HasPrefix(card.Text, test.word+" — ") {
				t.Fatalf("card does not state its state three ways: %+v", card)
			}
			// The request, when present, leads; state is carried by fallback,
			// header glyph and stripe instead of a repeated prose line.
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
		running, "Blitz Infrastructure", nil, false, true, core.Publication{},
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
		ready, "Blitz Infrastructure", nil, true, true, core.Publication{},
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
	if !found || !strings.Contains(publish.Confirm, "create a draft PR") {
		t.Fatalf("the primary does not name its result: %+v", publish)
	}

	// Discard is the one irreversible control on any task card, and it stays a
	// red button exactly where the old card offered it.
	closed := taskFixture()
	closed.Status = core.IncidentClosed
	closed.Workflow = core.WorkflowClosed
	closedCard := IncidentCardWithPublication(
		closed, "Blitz Infrastructure", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	discard, found := findAction(closedCard.Actions, ActionDiscardWork)
	if !found || discard.Style != "danger" || discard.Confirm == "" {
		t.Fatalf("closed task with retained work lost its discard control: %+v", closedCard.Actions)
	}
}

func TestClosingChangedTaskNamesManualRecoveryBoundary(t *testing.T) {
	task := taskFixture()
	card := IncidentCardWithPublication(
		task, "Blitz Infrastructure", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	close, found := findAction(card.Actions, ActionResolve)
	if !found || !strings.Contains(close.Confirm, "manual inspection and recovery outside the task") {
		t.Fatalf("changed-task close confirmation hides the recovery boundary: %+v", close)
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
		for _, row := range card.message.Rows {
			for _, action := range row.Overflow {
				if action.Confirm != "" {
					t.Fatalf("%s: a row menu holds a confirmable action: %+v", card.name, action)
				}
			}
		}
		// What was asserted on the struct has to be what shipped, so the
		// rendered payload is read back rather than trusted.
		owned := append([]Action{}, card.message.Overflow...)
		for _, row := range card.message.Rows {
			owned = append(owned, row.Overflow...)
		}
		for _, menu := range renderedOverflowMenus(t, card.message) {
			if len(menu) > 5 {
				t.Fatalf("%s: one menu renders %d options, over Slack's limit of 5",
					card.name, len(menu))
			}
			for _, value := range menu {
				if !slices.ContainsFunc(owned, func(action Action) bool {
					return OverflowOptionValue(action) == value
				}) {
					t.Fatalf("%s: rendered an overflow option no menu entry owns: %q",
						card.name, value)
				}
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

// The card names each durable part of the engineering workflow. A finished
// run states nothing at all — it is a receipt.
func TestTaskLedgerStatesPositionAndTerminalCardsShrinkToAReceipt(t *testing.T) {
	task := taskFixture()
	task.Workflow = core.WorkflowInvestigating
	task.ActiveTurnID = "turn_1"
	card := IncidentCardWithPublication(
		task, "Blitz Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if len(card.Ledger) != 6 {
		t.Fatalf("mid-investigation ledger = %+v", card.Ledger)
	}
	position, steps := ledgerMarker(card.Ledger)
	if position != 2 || steps != 6 ||
		card.Ledger[1].Label != "Plan the changes" ||
		card.Ledger[0].Glyph != "✓" || card.Ledger[5].Owner != "your turn" {
		t.Fatalf("ledger does not state the run's position: %+v", card.Ledger)
	}
	// The fallback carries the position too, because a notification gets the
	// string and never the strip.
	if !strings.Contains(card.Text, "step 2 of 6") {
		t.Fatalf("fallback lost the run's position: %q", card.Text)
	}

	// Once a change exists planning and implementation are complete, and the
	// current marker advances to the readiness review.
	changed := IncidentCardWithPublication(
		taskFixture(), "Blitz Infrastructure", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if changed.Ledger[2].Label != "Implement changes" || changed.Ledger[2].Glyph != "✓" {
		t.Fatalf("ledger did not follow the phase: %+v", changed.Ledger)
	}
	if position, _ := ledgerMarker(changed.Ledger); position != 4 {
		t.Fatalf("ready-to-publish run is at step %d, want the readiness review", position)
	}

	merged := IncidentCardWithPublication(
		taskFixture(), "Blitz Infrastructure", nil, true, true, openPublication(),
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

// Workflow labels are stable host language and never guessed from the task.
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
	}{
		{
			name:     "nothing has run, so the step ahead is working out what to do",
			workflow: core.WorkflowProvisioningChannel,
		},
		{
			name:     "the workspace is still coming up",
			workflow: core.WorkflowProvisioningSession,
		},
		{
			name:     "a turn is running and has produced no change",
			workflow: core.WorkflowInvestigating,
		},
		{
			name:     "a turn has run and produced no change",
			workflow: core.WorkflowParked,
		},
		{
			name:           "the fork holds a change",
			workflow:       core.WorkflowInvestigating,
			hasCodeChanges: true,
		},
		{
			// Nobody probes the fork while a publication runs, so the caller
			// reports no changes and the step is marked done anyway. A step
			// with a ✓ on it under the word "Investigate" would be the label
			// and the glyph contradicting each other.
			name:        "a PR exists, so a change exists whatever the fork probe says",
			workflow:    core.WorkflowParked,
			publication: openPublication(),
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
				core.PublicationFollowup{}, core.PublicationLifecycleEvent{}, LiveTurn{}, time.Now(),
			)
			if len(ledger) != 6 {
				t.Fatalf("ledger = %+v", ledger)
			}
			want := []string{
				"Workspace ready", "Plan the changes", "Implement changes",
				"Readiness review", "Draft PR", "Review and merge",
			}
			for index, label := range want {
				if ledger[index].Label != label {
					t.Fatalf("step %d = %q, want %q", index+1, ledger[index].Label, label)
				}
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
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
		LiveTurn{ToolCalls: 119, Evidence: 2}, time.Now(),
	)
	if ledger[2].Label != "Implement changes" ||
		ledger[2].Detail != "119 calls · 2 evidence" {
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
		blocked, "Blitz Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	body := card.Text + "\n" + strings.Join(card.Sections, "\n")
	if strings.Contains(body, "*Action needed*") {
		t.Fatalf("a blocker with no recorded reason rendered a section: %q", body)
	}
	if !strings.Contains(body, "reply with how to continue") {
		t.Fatalf("the state line lost its ask: %q", body)
	}

	// With a reason the section exists, and then the pointer is honest.
	blocked.LastError = "The gate needs a repository validation command."
	withReason := IncidentCardWithPublication(
		blocked, "Blitz Infrastructure", nil, false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	sections := strings.Join(withReason.Sections, "\n")
	if !strings.Contains(sections, "*Action needed*") ||
		!strings.Contains(withReason.Text, "read Action needed") {
		t.Fatalf("a recorded blocker lost its section or its pointer: %q / %q",
			withReason.Text, sections)
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
		task, "Blitz Infrastructure",
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
	if len(card.Fields) != 0 || len(card.Context) != 0 || len(card.Ledger) != 7 ||
		len(card.Tail) != 0 {
		t.Fatalf("the busiest card lost a required part: %+v", card)
	}
	if card.Ledger[0].Label != "Isolated fork of Blitz Infrastructure ready" ||
		card.Ledger[0].Subtext != "" {
		t.Fatalf("workspace step = %+v", card.Ledger[0])
	}
}

// Every surface that offers the diff offers the same two labels.
//
// The button is a toggle now, and which way it points is decided by one column
// on the incident. Three constructors render it — the task card, the incident
// card, and the delivery footer on a finished turn — and a "View diff" that
// deletes the diff in front of you is worse than no button at all.
func TestEverySurfaceLabelsTheDiffControlByWhetherOneIsOpen(t *testing.T) {
	signals := []core.Signal{{Status: core.SignalFiring, Summary: "Raise Traefik memory."}}
	task := taskFixture()
	task.LatestUpdate = "Raised the allocation memory."
	incident := taskFixture()
	incident.WorkKind, incident.WorkScope, incident.Route = "", "", "grafana"
	incident.SourceIncidentID = "alert-1"

	for name, open := range map[string]bool{"no diff open": false, "a diff open": true} {
		t.Run(name, func(t *testing.T) {
			want := "View diff"
			ts := ""
			if open {
				want, ts = "Hide diff", "1700.900"
			}
			task.ChangesMessageTS, incident.ChangesMessageTS = ts, ts
			surfaces := map[string]Message{
				"task card": IncidentCardWithPublication(
					task, "Blitz Infrastructure", signals, true, true,
					core.Publication{}, core.PublicationFollowup{},
					core.PublicationLifecycleEvent{},
				),
				"incident card": IncidentCardWithPublication(
					incident, "Blitz Infrastructure", signals, true, true,
					core.Publication{}, core.PublicationFollowup{},
					core.PublicationLifecycleEvent{},
				),
				"delivery footer": WithEngineeringTaskDelivery(
					Message{Text: "Done."}, task, true,
					core.Publication{}, core.PublicationFollowup{},
				),
			}
			for surface, message := range surfaces {
				action, found := findAction(message.Actions, ActionChanges)
				if !found {
					t.Fatalf("%s offers no diff control: %+v", surface, message.Actions)
				}
				if action.Label != want {
					t.Errorf("%s offers %q, want %q", surface, action.Label, want)
				}
			}
		})
	}
}

// Cards and confirmations name the requested action without stacking boilerplate.
//
// The card used to state one in its footer while the publication receipt beside
// it stated another and the confirmation on the button stated a third, all
// saying that Ryker could not merge or deploy. The card now states the
// concrete result: create or update a draft PR from the approved tree.
//
// Run over every state, including the receipts a finished task shrinks to.
// Merged and closed are where a stacked disclaimer would hide longest, because
// nobody re-reads a card about work that is over.
func TestTheTaskCardStacksNoDisclaimers(t *testing.T) {
	boilerplate := []string{
		"cannot merge or deploy", "did not merge, deploy, sign",
		"Lease-protected", "lease-protected", "No merge, signing, push",
	}
	for _, card := range everyTaskCardState(t) {
		t.Run(card.name, func(t *testing.T) {
			for _, line := range card.message.Context {
				for _, phrase := range boilerplate {
					if strings.Contains(line, phrase) {
						t.Errorf("a context line restates the boundary: %q", line)
					}
				}
			}
			// Publication confirmations name their concrete result.
			for _, action := range card.message.Actions {
				if action.ID == ActionPublishPR && !strings.Contains(action.Confirm, "PR") {
					t.Errorf("the publish confirmation does not name its result: %q", action.Confirm)
				}
			}
		})
	}
	// And the receipt that lands beside the card in the same flow states none
	// either: the publish control confirmed with it and the PR body carries it.
	receipt := PublicationMessage(openPublication(), false)
	for _, line := range receipt.Context {
		for _, phrase := range boilerplate {
			if strings.Contains(line, phrase) {
				t.Errorf("the publication receipt restates the boundary: %q", line)
			}
		}
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
			test.task, "Blitz Infrastructure",
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
// renderedOverflowMenus is renderedOverflowOptions without the flattening.
// Slack's five-option limit is per menu, so a card with a card-level menu and a
// row menu is inside the limit at four options each and outside it if the two
// are counted together.
func renderedOverflowMenus(t *testing.T, message Message) [][]string {
	t.Helper()
	var menus [][]string
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
			menu := make([]string, 0, len(element.Options))
			for _, option := range element.Options {
				menu = append(menu, option.Value)
			}
			menus = append(menus, menu)
		}
	}
	return menus
}

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

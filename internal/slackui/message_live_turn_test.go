package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func runningTask() core.Incident {
	return core.Incident{
		ID: "inc_live", WorkKind: core.WorkKindEngineeringTask, Title: "Prevent the OOM",
		Repository: "repo", ChannelID: "COPS", RootTS: "1700.101",
		CoopSessionID: "ses_1", ActiveTurnID: "turn_1",
		Workflow: core.WorkflowInvestigating, CreatedAt: time.Now().Add(-40 * time.Minute),
	}
}

func liveTaskCard(task core.Incident, hasChanges, changesKnown bool, live LiveTurn) Message {
	return IncidentCardWithPublication(
		task, "Tenant Infrastructure", nil, hasChanges, changesKnown,
		core.Publication{}, core.PublicationFollowup{},
		core.PublicationLifecycleEvent{}, live,
	)
}

func chipText(message Message) string {
	parts := make([]string, 0, len(message.Chips))
	for _, chip := range message.Chips {
		parts = append(parts, chip.Label+"="+chip.Value)
	}
	return strings.Join(parts, " ")
}

// The window is the present tense, and only the present tense.
//
// A card carrying a turn's last three lines after that turn stopped would be
// the most reassuring thing on the screen and the least true: the same three
// lines that meant "working" a second ago would now mean "stopped here". So
// Active, not the presence of data, is what puts the window up.
func TestTheWindowRendersOnlyWhileTheTurnIsRunning(t *testing.T) {
	live := LiveTurn{
		Active:       true,
		Lines:        []ActivityLine{{Kind: ActivityTool, Title: "Emisar vm.query_range"}},
		ToolCalls:    119,
		Evidence:     2,
		Claim:        "Reloads correlate with the RSS step",
		LastActivity: time.Now().Add(-6 * time.Second),
	}
	running := liveTaskCard(runningTask(), false, true, live)
	if len(running.Activity) != 1 {
		t.Fatalf("a running turn rendered no window: %+v", running.Activity)
	}
	if !strings.Contains(chipText(running), "119 tool calls") {
		t.Fatalf("the counters do not describe the whole turn: %s", chipText(running))
	}

	stopped := runningTask()
	stopped.ActiveTurnID = ""
	stopped.Workflow = core.WorkflowParked
	live.Active = false
	parked := liveTaskCard(stopped, false, true, live)
	if len(parked.Activity) != 0 {
		t.Fatalf("a stopped turn kept its window: %+v", parked.Activity)
	}
	// The totals survive as a receipt on the step that earned them. This is
	// the only place a reader later learns that "Investigate" was 119 tool
	// calls rather than two.
	receipt := ""
	for _, step := range parked.Ledger {
		if strings.Contains(step.Detail, "calls") {
			receipt = step.Detail
		}
	}
	if !strings.Contains(receipt, "119 calls") || !strings.Contains(receipt, "2 evidence") {
		t.Fatalf("the ledger did not absorb the totals: %+v", parked.Ledger)
	}
}

// Unknown is a real third state, and it is not "none".
//
// While a publication runs nobody has inspected the fork, so the count is not
// zero, it is unasked. Rendering that as "none yet" tells an operator their
// work is gone — the one thing a card must never say by accident.
func TestTheChangesChipRefusesToGuessWhatTheForkHolds(t *testing.T) {
	live := LiveTurn{
		Active: true, ToolCalls: 4,
		Lines: []ActivityLine{{Kind: ActivityEdit, Title: "Edit traefik.nomad.hcl"}},
	}
	known := chipText(liveTaskCard(runningTask(), true, true, live))
	if !strings.Contains(known, "changes=present") {
		t.Fatalf("a fork with changes did not say so: %s", known)
	}
	empty := chipText(liveTaskCard(runningTask(), false, true, live))
	if !strings.Contains(empty, "changes=none yet") {
		t.Fatalf("an empty fork did not say so: %s", empty)
	}
	unknown := chipText(liveTaskCard(runningTask(), false, false, live))
	if strings.Contains(unknown, "changes=") {
		t.Fatalf("an uninspected fork was reported as a count: %s", unknown)
	}
}

// Rule 9 holds against the window: three lines, never four.
//
// The card is a fixed-height instrument that is rewritten rather than
// extended. A fourth line is not more information, it is a card that grows
// every turn until it is the tallest thing in the channel.
func TestTheWindowKeepsThreeLinesHoweverManyItIsGiven(t *testing.T) {
	lines := make([]ActivityLine, 0, 8)
	for index := range 8 {
		lines = append(lines, ActivityLine{
			Kind: ActivityTool, Title: "call " + string(rune('a'+index)),
		})
	}
	card := liveTaskCard(runningTask(), false, true, LiveTurn{
		Active: true, Lines: lines, ToolCalls: 8,
	})
	rendered := activityLines(card.Activity)
	if len(rendered) != 3 {
		t.Fatalf("the window rendered %d lines: %+v", len(rendered), rendered)
	}
	for _, line := range rendered {
		if runes := len([]rune(line)); runes > monospaceLineRunes {
			t.Fatalf("a window line ran to %d runes: %q", runes, line)
		}
	}
}

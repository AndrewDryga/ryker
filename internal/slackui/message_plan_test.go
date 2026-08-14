package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Every state the store can hold gets a glyph, and only one of them is a tick.
//
// The vocabulary is the CHECK constraint on episode_goals.state, which allows
// exactly these eight. A state added there and not here renders as pending
// rather than as a blank column, which is why the default arm is tested beside
// the named ones: an unknown state is "not yet", never "gone".
//
// The tick is guarded because it is the mark an operator scans a card for. A
// goal that was excluded or cancelled is terminal and is not done, and ticking
// it would be the card claiming work that never happened.
func TestPlanGlyphsUseTheStatesTheStoreActuallyAllows(t *testing.T) {
	cases := map[string]string{
		"planned":   "·",
		"ready":     "·",
		"working":   "▸",
		"waiting":   "·",
		"completed": "✓",
		"blocked":   "!",
		"excluded":  "✕",
		"cancelled": "✕",
		// Not a state the constraint allows; it renders rather than vanishing.
		"":            "·",
		"some_future": "·",
	}
	for state, want := range cases {
		if got := planGlyph(state); got != want {
			t.Fatalf("state %q rendered %q, want %q", state, got, want)
		}
	}
	ticked := 0
	for state := range cases {
		if planGlyph(state) == "✓" {
			ticked++
		}
	}
	if ticked != 1 {
		t.Fatalf("%d states render as done; the tick must mean one thing", ticked)
	}
}

func TestPlanChildrenRenderTheChecklistAndItsOverflow(t *testing.T) {
	if children := planChildren(nil); children != nil {
		t.Fatalf("an unplanned episode grew a checklist: %+v", children)
	}
	plan := []PlanStep{
		{Label: "Reproduce the timeout", State: "completed"},
		{Label: "Bound the blast radius", State: "completed"},
		{Label: "Find the cause", State: "working"},
		{Label: "Confirm the fix", State: "planned"},
		{Label: "Wait for the deploy", State: "blocked"},
	}
	children := planChildren(plan)
	if len(children) != 5 {
		t.Fatalf("children = %d, want 5: %+v", len(children), children)
	}
	for index, want := range []string{"✓", "✓", "▸", "·", "!"} {
		if children[index].Glyph != want {
			t.Fatalf("child %d glyph = %q, want %q", index, children[index].Glyph, want)
		}
		if children[index].Label != plan[index].Label {
			t.Fatalf("child %d label = %q", index, children[index].Label)
		}
	}

	// Past the cap the count is what the reader loses, not the names.
	long := make([]PlanStep, 0, 9)
	for index := range 9 {
		long = append(long, PlanStep{Label: string(rune('a' + index)), State: "planned"})
	}
	capped := planChildren(long)
	if len(capped) != planStripLimit+1 {
		t.Fatalf("capped = %d, want %d: %+v", len(capped), planStripLimit+1, capped)
	}
	overflow := capped[len(capped)-1]
	if overflow.Label != "… and 3 more" {
		t.Fatalf("overflow line = %q", overflow.Label)
	}
	// A blank glyph, because the line is a count and any mark would claim a
	// state for it.
	if strings.TrimSpace(overflow.Glyph) != "" {
		t.Fatalf("the overflow line claimed a state: %q", overflow.Glyph)
	}
	// Exactly at the cap there is nothing to count, and a "… and 0 more" line
	// would be the card reporting its own arithmetic.
	exact := planChildren(long[:planStripLimit])
	if len(exact) != planStripLimit {
		t.Fatalf("a plan exactly at the cap grew an overflow line: %+v", exact)
	}
}

// A goal with no outcome still says what state it is in.
func TestPlanChildKeepsARowForAGoalWithNoOutcome(t *testing.T) {
	children := planChildren([]PlanStep{{State: "blocked"}})
	if len(children) != 1 || children[0].Glyph != "!" {
		t.Fatalf("children = %+v", children)
	}
	if children[0].Label == "" {
		t.Fatal("a nameless goal rendered a blank line")
	}
}

// An incident card has no current step for a plan to nest under.
//
// Its ledger is a list of what is firing, not a run's phases, so the plan gets
// a position of its own at the top with the goals as its children — the same
// nesting the task card does inline, given the parent it was missing. Above the
// signals because the plan is the present tense and the signals are what
// started it.
func TestIncidentLedgerGivesThePlanTheParentItIsMissing(t *testing.T) {
	now := time.Now()
	signals := []core.Signal{{
		Route: "grafana", SourceID: "a", Status: core.SignalFiring,
		Title: "HighErrorRate", StartsAt: now.Add(-12 * time.Minute),
	}}
	plan := []PlanStep{
		{Label: "Confirm the alert scope", State: "completed"},
		{Label: "Find the cause", State: "working"},
	}

	// No plan: the strip is the signals and nothing else, exactly as before.
	bare := incidentLedger(signals, LiveTurn{}, now)
	if len(bare) != 1 || bare[0].Label != "HighErrorRate" {
		t.Fatalf("an unplanned incident grew a heading: %+v", bare)
	}

	planned := incidentLedger(signals, LiveTurn{Plan: plan}, now)
	if len(planned) != 2 {
		t.Fatalf("ledger = %d rows, want the plan and the signal: %+v", len(planned), planned)
	}
	if planned[0].Label != "Plan" || len(planned[0].Children) != 2 {
		t.Fatalf("the plan did not lead the strip: %+v", planned[0])
	}
	if planned[0].Children[0].Glyph != "✓" || planned[0].Children[1].Glyph != "▸" {
		t.Fatalf("plan children lost their states: %+v", planned[0].Children)
	}
	if planned[1].Label != "HighErrorRate" {
		t.Fatalf("the signals were displaced rather than followed: %+v", planned[1])
	}
	// A card with a plan and no signals at all is still a checklist, not an
	// empty heading over nothing.
	only := incidentLedger(nil, LiveTurn{Plan: plan}, now)
	if len(only) != 1 || len(only[0].Children) != 2 {
		t.Fatalf("a planned incident with no signals = %+v", only)
	}
}

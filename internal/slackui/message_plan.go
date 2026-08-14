package slackui

import "fmt"

// planStripLimit bounds the checklist at what a card can show without becoming
// the log rule 9 forbids.
//
// The contract asks for two to five goals, so six is one more than a
// well-behaved plan and the overflow line exists for the plans that are not.
// Past it the count is what the reader loses, not the names — the same trade
// signalStripLimit makes, at the size this list is asked to be.
const planStripLimit = 6

// planChildren renders a plan as the checks under the step doing them.
//
// Children rather than steps of their own, because that is what they are: the
// ledger's own positions are the run's phases, which exist whether or not a
// model planned anything, and a plan that replaced them would lose "step 4 of
// 5" to gain a checklist. Nested, the card says both — where the run is, and
// what the model undertook to do inside that.
//
// Absent goals return nothing at all, which is today's card exactly: this whole
// strip is additive, and an episode whose model never planned renders as it did
// before the plan existed.
func planChildren(plan []PlanStep) []LedgerStep {
	if len(plan) == 0 {
		return nil
	}
	steps := make([]LedgerStep, 0, min(len(plan), planStripLimit)+1)
	for _, goal := range plan[:min(len(plan), planStripLimit)] {
		label := goal.Label
		if label == "" {
			// A goal with no outcome is a row that says a goal exists and
			// nothing else. The state is still worth a line — a blocked
			// something is news — and the id is not, so the kind of row it is
			// stands in for the name it never had.
			label = "(unnamed goal)"
		}
		steps = append(steps, LedgerStep{Glyph: planGlyph(goal.State), Label: label})
	}
	if extra := len(plan) - planStripLimit; extra > 0 {
		// A blank glyph rather than a mark: the line is a count, not another
		// goal, and any of the glyphs below would claim a state for it.
		steps = append(steps, LedgerStep{
			Glyph: " ", Label: fmt.Sprintf("… and %d more", extra),
		})
	}
	return steps
}

// planGlyph is what a goal's state looks like in one column.
//
// The vocabulary is the store's, not this package's — the CHECK constraint on
// episode_goals.state allows exactly these eight — and each maps to what the
// reader needs to know about it rather than to its own name:
//
//   - completed is the tick, and the only one. It is the mark the operator is
//     scanning for and it must mean one thing.
//   - working is the run's own current mark, so a reader already fluent in the
//     ledger reads it without being told.
//   - blocked gets the one glyph that interrupts a scan, because it is the one
//     state that needs somebody.
//   - excluded and cancelled are struck rather than ticked. Both are terminal
//     and neither is done, and a tick on a goal that was dropped would be the
//     card claiming work that never happened.
//   - planned, ready and waiting are all the same fact to a reader — not yet —
//     and so is anything this package does not recognise.
func planGlyph(state string) string {
	switch state {
	case "completed":
		return "✓"
	case "working":
		return "▸"
	case "blocked":
		return "!"
	case "excluded", "cancelled":
		return "✕"
	default:
		return "·"
	}
}

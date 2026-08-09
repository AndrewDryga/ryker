package core

import (
	"slices"
	"strings"
	"testing"
)

// Every run mode a correction can arrive from must produce a capability the
// promoter is allowed to claim.
//
// The recording site set no capability at all, so every promoted fixture was
// tagged "capability:" with nothing after it, and the coverage ratchet would
// have rejected all four the moment they were moved anywhere it looks. A mode
// added later that falls through to nothing would put that back.
func TestEveryRunModeNamesAPromotableCapability(t *testing.T) {
	promotable := PromotableCapabilities()
	for _, mode := range []AgentRunMode{
		AgentRunTriage,
		AgentRunIncident,
		AgentRunEngineeringTask,
	} {
		capability := FixtureCapability(AgentRun{Mode: mode})
		if strings.TrimSpace(capability) == "" {
			t.Errorf("mode %q produces an empty capability tag", mode)
			continue
		}
		if !slices.Contains(promotable, capability) {
			t.Errorf(
				"mode %q produces capability %q, which PromotableCapabilities does not list, "+
					"so nothing checks it against the matrix",
				mode, capability,
			)
		}
	}
	// An unset mode is the case that actually shipped: a candidate row written
	// before anything filled the field in. It must still land on a real
	// capability rather than the empty string.
	if got := FixtureCapability(AgentRun{}); got != DefaultFixtureCapability() {
		t.Errorf("unset mode capability = %q, want %q", got, DefaultFixtureCapability())
	}
	if !slices.Contains(promotable, DefaultFixtureCapability()) {
		t.Errorf(
			"the default capability %q is not listed as promotable, so nothing checks it",
			DefaultFixtureCapability(),
		)
	}
}

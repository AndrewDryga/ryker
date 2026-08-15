package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The tally sentence has to say when a shadow period has proved nothing.
//
// A count on its own cannot: forty evaluations reads as a busy assignment
// whether it would have opened forty pull requests or none. Standing rules
// learned this the expensive way — a rule that had fired 64 times looked
// productive and had ignored every one — and this is the same question in a
// different shape, so it gets the same sentence.
func TestTheWorthSentenceSaysWhenNothingWasProved(t *testing.T) {
	silent := AssignmentWorth(core.StandingAssignmentTally{})
	if !strings.Contains(silent, "nothing to judge it on") {
		t.Fatalf("an assignment nobody has offered a signal to reads as %q", silent)
	}

	busy := AssignmentWorth(core.StandingAssignmentTally{
		Evaluated: 40, Eligible: 0, Declined: 40,
		TopDecline:      "this has not happened often enough to be a pattern yet",
		TopDeclineCount: 31,
	})
	for _, required := range []string{
		"Evaluated 40",
		"would have opened 0",
		"not happened often enough",
		"31 times",
		"granting it would change nothing yet",
	} {
		if !strings.Contains(busy, required) {
			t.Errorf("worth sentence is missing %q:\n%s", required, busy)
		}
	}

	proved := AssignmentWorth(core.StandingAssignmentTally{
		Evaluated: 12, Eligible: 5, Declined: 7,
		LastEligible: time.Date(2026, 8, 14, 9, 30, 0, 0, time.UTC),
	})
	if strings.Contains(proved, "change nothing yet") {
		t.Errorf("an assignment that reached the bar five times reads as idle:\n%s", proved)
	}
	if !strings.Contains(proved, "2026-08-14 09:30 UTC") {
		t.Errorf("worth sentence does not say when it last would have acted:\n%s", proved)
	}
}

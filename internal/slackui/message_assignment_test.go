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

// The offer card carries one control, and the dialog on it names what is being
// agreed to rather than asking "are you sure".
//
// This is the moment an operator hands Responder the authority to open pull
// requests without being asked again, and it is the only moment they see the
// bounds. So the button is a confirmation with a dialog, the dialog states the
// class and the repository in the same sentence as the word "without asking
// again", and the card says both that nothing is granted yet and that what the
// click grants is still shadowed. A neutral button here would be the one
// control in this product where a mis-click costs the most.
func TestTheAssignmentOfferCardConfirmsWhatIsBeingGranted(t *testing.T) {
	message := WithAssignmentOffer(Message{}, core.StandingAssignment{
		Repository: "AndrewDryga/responder", ChangeClass: "dependency_upgrade",
		SignalPattern: "renovate failure", DailyBudget: 2,
		PathGlobs: []string{"go.mod"}, ExpiresAt: time.Now().Add(720 * time.Hour),
	}, 30, `{"version":1}`, "")

	actions := allActions(message)
	if len(actions) != 1 {
		t.Fatalf("the offer card carries %d controls, want exactly one", len(actions))
	}
	if actions[0].ID != ActionConfirmAssignmentOffer {
		t.Fatalf("control is %q, want %q", actions[0].ID, ActionConfirmAssignmentOffer)
	}
	if actions[0].Confirm == "" {
		t.Fatal("the widest grant in the product is one unconfirmed click away")
	}
	for _, required := range []string{"dependency upgrade", "standing assignment"} {
		if !strings.Contains(actions[0].Confirm, required) {
			t.Errorf("the dialog does not say %q:\n%s", required, actions[0].Confirm)
		}
	}
	rendered := strings.Join(append(message.Sections, message.Context...), "\n")
	for _, row := range message.Rows {
		rendered += "\n" + row.Text
	}
	for _, required := range []string{
		"New assignments start in shadow mode", "starts in shadow mode",
		// The expiry is a span rather than a date on this card alone: it is
		// read before the grant exists, and a date would be the one it would
		// have expired on had the button been pressed the instant it was posted.
		"expires 30 days after confirmation",
	} {
		if !strings.Contains(rendered, required) {
			t.Errorf("the offer card does not say %q:\n%s", required, rendered)
		}
	}
}

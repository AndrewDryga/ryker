package remediation

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func liveConfirmation(now time.Time) Confirmation {
	return NewConfirmation(liveGrant(RungPropose), now)
}

// TestAPromotionConfirmationExpiresAfterADay is the staleness bound the memory
// offers learned to want and never got their own test for.
//
// A promotion card names a count the host recomputed when it composed the card.
// The handler recomputes again on the click, so a stale click cannot grant
// against stale evidence — but it CAN show an operator one sentence and act on
// another, and a day is the point past which "3 verified successes" is a claim
// about a week that has since had other weeks in it.
func TestAPromotionConfirmationExpiresAfterADay(t *testing.T) {
	issued := at(2)
	payload := liveConfirmation(issued)
	if _, _, _, err := payload.Resolve(apiAlert.ChannelID, issued.Add(23*time.Hour)); err != nil {
		t.Fatalf("a card 23 hours old was refused: %v", err)
	}
	_, _, _, err := payload.Resolve(apiAlert.ChannelID, issued.Add(25*time.Hour))
	if !errors.Is(err, ErrStaleConfirmation) {
		t.Fatalf("err=%v, want ErrStaleConfirmation", err)
	}
	if !strings.Contains(err.Error(), "older than") {
		t.Fatalf("rejection %q does not say why", err)
	}
}

// TestAPromotionConfirmationIsBoundToTheChannelItWasPostedIn stops a card being
// replayed somewhere the operator was not looking.
//
// The grant's scope INCLUDES the channel, so a payload accepted from another
// room would grant authority in a room where nobody read the offer. The click's
// own channel is the authority on where the click happened; the payload's is a
// claim.
func TestAPromotionConfirmationIsBoundToTheChannelItWasPostedIn(t *testing.T) {
	payload := liveConfirmation(at(2))
	if _, _, _, err := payload.Resolve("C0SOMEWHERE_ELSE", at(3)); !errors.Is(err, ErrStaleConfirmation) {
		t.Fatalf("a card replayed into another channel resolved: %v", err)
	}
	if _, _, _, err := payload.Resolve("", at(3)); !errors.Is(err, ErrStaleConfirmation) {
		t.Fatal("a card with no click channel resolved")
	}
}

// TestAPromotionConfirmationCarriesNoNumbers is the design rule, asserted so it
// cannot be helpfully "fixed" by adding the count to the payload.
//
// Everything a promotion rests on — the verified count, the expiry, the
// operator — is recomputed or supplied at confirm time. A button value is a
// round trip through a Slack client, and the moment one of those numbers is
// carried on it, a tampered value is a granted rung.
func TestAPromotionConfirmationCarriesNoNumbers(t *testing.T) {
	granted := liveGrant(RungOneClick)
	granted.SuccessCount, granted.GrantedBy = 9, "U0OPERATOR"
	payload := NewConfirmation(granted, at(2))
	class, action, rung, err := payload.Resolve(apiAlert.ChannelID, at(3))
	if err != nil {
		t.Fatal(err)
	}
	if !class.Equal(granted.Trigger) || !action.Equal(granted.Action) || rung != RungOneClick {
		t.Fatalf("payload resolved to %v / %v / %q", class, action, rung)
	}
	// Resolve returns an identity and a rung. There is nowhere for a count, an
	// expiry or an operator to travel, which is the point.
	if payload.ChannelID != granted.Trigger.ChannelID {
		t.Fatal("the payload lost the channel it scopes to")
	}
}

func TestAMalformedPromotionConfirmationIsRefused(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*Confirmation)
	}{
		{"another version", func(c *Confirmation) { c.Version = 2 }},
		{"no issue time", func(c *Confirmation) { c.IssuedAt = time.Time{} }},
		{"issued tomorrow", func(c *Confirmation) { c.IssuedAt = at(30) }},
		{"no pack ref", func(c *Confirmation) { c.PackRef = "" }},
		{"no alert group", func(c *Confirmation) { c.AlertGroupKey = "" }},
		{"a rung off the ladder", func(c *Confirmation) { c.Rung = "supervisor" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := liveConfirmation(at(2))
			tc.mutate(&payload)
			if _, _, _, err := payload.Resolve(apiAlert.ChannelID, at(3)); !errors.Is(err, ErrStaleConfirmation) {
				t.Fatalf("err=%v, want ErrStaleConfirmation", err)
			}
		})
	}
}

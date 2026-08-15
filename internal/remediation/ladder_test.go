package remediation

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func at(hour int) time.Time {
	return time.Date(2026, 8, 15, hour, 0, 0, 0, time.UTC)
}

// restartAPI is the action every test below grants, refuses, or counts. Named
// once so a test that means to change the action ref has to say so.
var restartAPI = ActionRef{
	ActionID:  "nomad.job.restart",
	PackRef:   "nomad@1.4.0+sha256:1111",
	RunnerRef: "runner:prod-us-east",
}

var apiAlert = TriggerClass{
	AlertGroupKey: "grafana:api-5xx:production",
	ChannelID:     "C0INCIDENT",
	Repository:    "api",
}

func liveGrant(rung Rung) Grant {
	return Grant{
		ID:        "grant-1",
		Trigger:   apiAlert,
		Action:    restartAPI,
		Rung:      rung,
		GrantedBy: "U0OPERATOR",
		GrantedAt: at(1),
		ExpiresAt: at(9),
	}
}

// TestAGrantMatchesOnlyTheExactActionItWasGrantedFor is the invariant the whole
// ladder rests on: authority is granted to one immutable Emisar identity, not
// to a name that looks like it.
//
// Emisar's own client discipline forbids invented or substituted identifiers,
// and a matcher that compared only the action id would hand a grant earned on
// one runner to the same action pointed at another — which is how a
// single-target grant silently becomes a fleet-wide one.
func TestAGrantMatchesOnlyTheExactActionItWasGrantedFor(t *testing.T) {
	granted := []Grant{liveGrant(RungPropose)}
	for _, tc := range []struct {
		name  string
		ref   ActionRef
		match bool
	}{
		{"the exact ref", restartAPI, true},
		{"another action in the same pack", ActionRef{
			ActionID: "nomad.job.stop", PackRef: restartAPI.PackRef, RunnerRef: restartAPI.RunnerRef,
		}, false},
		{"the same action from another pack version", ActionRef{
			ActionID: restartAPI.ActionID, PackRef: "nomad@1.5.0+sha256:2222", RunnerRef: restartAPI.RunnerRef,
		}, false},
		{"the same action on another runner", ActionRef{
			ActionID: restartAPI.ActionID, PackRef: restartAPI.PackRef, RunnerRef: "runner:prod-eu-west",
		}, false},
		{"the action id in a different case", ActionRef{
			ActionID: "NOMAD.JOB.RESTART", PackRef: restartAPI.PackRef, RunnerRef: restartAPI.RunnerRef,
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			decision := Decide(granted, Trigger{Class: apiAlert, Action: tc.ref}, at(2))
			if decision.Matched != tc.match {
				t.Fatalf("matched=%v, want %v (reason %q)", decision.Matched, tc.match, decision.Reason)
			}
		})
	}
}

// TestAGrantMatchesOnlyItsOwnTriggerClass keeps a grant earned on one alert
// from firing on another. The trigger class is the other half of the grant's
// identity; without this the first promotion would authorize the action for
// every alert in the channel.
func TestAGrantMatchesOnlyItsOwnTriggerClass(t *testing.T) {
	granted := []Grant{liveGrant(RungPropose)}
	for _, tc := range []struct {
		name  string
		class TriggerClass
		match bool
	}{
		{"the exact class", apiAlert, true},
		{"another alert group", TriggerClass{
			AlertGroupKey: "grafana:api-latency:production",
			ChannelID:     apiAlert.ChannelID, Repository: apiAlert.Repository,
		}, false},
		{"the same alert in another channel", TriggerClass{
			AlertGroupKey: apiAlert.AlertGroupKey, ChannelID: "C0OTHER", Repository: apiAlert.Repository,
		}, false},
		{"the same alert against another repository", TriggerClass{
			AlertGroupKey: apiAlert.AlertGroupKey, ChannelID: apiAlert.ChannelID, Repository: "worker",
		}, false},
		{"an empty class matches nothing", TriggerClass{}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			decision := Decide(granted, Trigger{Class: tc.class, Action: restartAPI}, at(2))
			if decision.Matched != tc.match {
				t.Fatalf("matched=%v, want %v (reason %q)", decision.Matched, tc.match, decision.Reason)
			}
		})
	}
}

// TestNormalizationNeverWidensAGrant fixes the direction trimming is allowed to
// move in. Surrounding whitespace is transport noise and folding it changes
// nothing about which action runs; case folding an opaque identifier is a
// different claim entirely, and the pair is easy to implement together by
// accident.
func TestNormalizationNeverWidensAGrant(t *testing.T) {
	granted := []Grant{liveGrant(RungPropose)}
	padded := Trigger{
		Class: TriggerClass{
			AlertGroupKey: "  " + apiAlert.AlertGroupKey + "  ",
			ChannelID:     apiAlert.ChannelID + "\t",
			Repository:    " " + apiAlert.Repository,
		},
		Action: ActionRef{
			ActionID:  " " + restartAPI.ActionID,
			PackRef:   restartAPI.PackRef + " ",
			RunnerRef: "  " + restartAPI.RunnerRef,
		},
	}
	if decision := Decide(granted, padded, at(2)); !decision.Matched {
		t.Fatalf("padded trigger did not match its own grant: %s", decision.Reason)
	}
	upper := Trigger{
		Class:  TriggerClass{AlertGroupKey: strings.ToUpper(apiAlert.AlertGroupKey), ChannelID: apiAlert.ChannelID, Repository: apiAlert.Repository},
		Action: restartAPI,
	}
	if decision := Decide(granted, upper, at(2)); decision.Matched {
		t.Fatal("an upper-cased alert group key matched a grant earned on the exact key")
	}
}

// TestAnExpiredGrantAuthorizesNothing is why expiry is a column and not a
// policy note. Authority that outlives the operator's attention is the failure
// mode this ladder exists to avoid, so a lapsed grant has to read as absent
// rather than as merely old.
func TestAnExpiredGrantAuthorizesNothing(t *testing.T) {
	granted := []Grant{liveGrant(RungOneClick)}
	if decision := Decide(granted, Trigger{Class: apiAlert, Action: restartAPI}, at(8)); !decision.Matched {
		t.Fatalf("a grant one hour before expiry did not match: %s", decision.Reason)
	}
	decision := Decide(granted, Trigger{Class: apiAlert, Action: restartAPI}, at(10))
	if decision.Matched {
		t.Fatal("an expired grant matched")
	}
	if decision.Rung != RungObserve {
		t.Fatalf("expired grant fell back to %q, want %q", decision.Rung, RungObserve)
	}
	if !strings.Contains(decision.Reason, "expired") {
		t.Fatalf("reason %q does not say the grant expired", decision.Reason)
	}
}

// TestAGrantWithoutAnExpiryIsRefused holds the "nothing is permanent by
// default" rule shut at the only place it can be enforced for every writer: a
// grant with a zero expiry is not a long-lived grant, it is an invalid one.
func TestAGrantWithoutAnExpiryIsRefused(t *testing.T) {
	forever := liveGrant(RungPropose)
	forever.ExpiresAt = time.Time{}
	if err := forever.Validate(); err == nil {
		t.Fatal("a grant with no expiry validated")
	}
	if decision := Decide([]Grant{forever}, Trigger{Class: apiAlert, Action: restartAPI}, at(2)); decision.Matched {
		t.Fatal("a grant with no expiry matched")
	}
}

// TestAnObserveGrantOffersNoAction keeps rung one honest. Observe is today's
// behaviour — the remediation appears as prose and nothing is clickable — and
// it is also where every demotion lands, so a bug here quietly re-arms a grant
// that was just taken away.
func TestAnObserveGrantOffersNoAction(t *testing.T) {
	decision := Decide([]Grant{liveGrant(RungObserve)}, Trigger{Class: apiAlert, Action: restartAPI}, at(2))
	if decision.MayOffer {
		t.Fatal("an observe grant offered an action control")
	}
	if decision.Rung != RungObserve {
		t.Fatalf("rung=%q, want %q", decision.Rung, RungObserve)
	}
}

// TestNoGrantExecutesUnattendedInThisBuild is the seam guard for the auto rung.
//
// The auto rung is specified but deliberately unimplemented: it needs a
// decision only the operator can make (a host-side Emisar run_action against a
// minimal Coop turn). Until that decision is taken, a row that says "auto" —
// written by a future migration, a fixture, or a hand-edited database — must
// behave as the highest rung this build actually supervises, and must say so.
// The alternative is a grant that reads as unattended authority and is executed
// by nothing, which is the worst of both readings.
func TestNoGrantExecutesUnattendedInThisBuild(t *testing.T) {
	decision := Decide([]Grant{liveGrant(RungAuto)}, Trigger{Class: apiAlert, Action: restartAPI}, at(2))
	if decision.MaySubmitUnattended {
		t.Fatal("a grant authorized unattended submission; the auto rung is not implemented")
	}
	if decision.Rung != Ceiling {
		t.Fatalf("an auto grant acted at %q, want it clamped to %q", decision.Rung, Ceiling)
	}
	if !strings.Contains(decision.Reason, "auto") {
		t.Fatalf("reason %q does not name the clamped rung", decision.Reason)
	}
}

// TestTheNewestLiveGrantWinsWhenSeveralMatch makes the matcher a function
// rather than a race. Two rows can legitimately match after a promotion writes
// a new grant beside an old one, and "whichever the store returned first" is
// not a rule anybody can reason about.
func TestTheNewestLiveGrantWinsWhenSeveralMatch(t *testing.T) {
	older := liveGrant(RungPropose)
	older.ID, older.GrantedAt = "grant-old", at(1)
	newer := liveGrant(RungOneClick)
	newer.ID, newer.GrantedAt = "grant-new", at(3)
	for _, order := range [][]Grant{{older, newer}, {newer, older}} {
		decision := Decide(order, Trigger{Class: apiAlert, Action: restartAPI}, at(4))
		if decision.Grant.ID != "grant-new" {
			t.Fatalf("matched %q, want the newest grant", decision.Grant.ID)
		}
	}
}

// --- promotion -----------------------------------------------------------

// TestAPromotionOfferThatOverstatesItsSuccessesIsRejected is the reason the
// host recomputes at all.
//
// The model proposes and the host decides. An offer carries a count because the
// operator reads it on the card, not because the host trusts it: a result that
// claims six verified successes where the outcomes table records two is either
// a miscount or an argument for authority nobody earned, and both are refused
// the same way.
func TestAPromotionOfferThatOverstatesItsSuccessesIsRejected(t *testing.T) {
	policy := DefaultPolicy()
	offer := Offer{Trigger: apiAlert, Action: restartAPI, Rung: RungPropose, ClaimedSuccesses: 6}
	_, err := EvaluateOffer(offer, Grant{}, 2, policy, at(2))
	if err == nil {
		t.Fatal("an offer claiming six verified successes against two recorded was accepted")
	}
	if !errors.Is(err, ErrOfferUnverifiable) {
		t.Fatalf("err=%v, want ErrOfferUnverifiable", err)
	}
	if !strings.Contains(err.Error(), "6") || !strings.Contains(err.Error(), "2") {
		t.Fatalf("rejection %q names neither the claim nor the recomputed count", err)
	}
}

// TestAPromotionOfferIsAcceptedOnlyOnTheHostsOwnCount pins the other side of
// the same rule: understating is not a way to sneak past the threshold either,
// and an accurate offer is graded against the host's number.
func TestAPromotionOfferIsAcceptedOnlyOnTheHostsOwnCount(t *testing.T) {
	policy := DefaultPolicy()
	offer := Offer{Trigger: apiAlert, Action: restartAPI, Rung: RungPropose, ClaimedSuccesses: 1}
	if _, err := EvaluateOffer(offer, Grant{}, 1, policy, at(2)); err == nil {
		t.Fatal("one verified success cleared a threshold of three")
	}
	offer.ClaimedSuccesses = 3
	granted, err := EvaluateOffer(offer, Grant{}, 3, policy, at(2))
	if err != nil {
		t.Fatalf("an accurate offer at the threshold was refused: %v", err)
	}
	if granted.Rung != RungPropose {
		t.Fatalf("granted rung %q, want %q", granted.Rung, RungPropose)
	}
	if granted.SuccessCount != 3 {
		t.Fatalf("granted success count %d, want the host's 3", granted.SuccessCount)
	}
	if !granted.ExpiresAt.Equal(at(2).Add(policy.GrantTTL)) {
		t.Fatalf("granted expiry %v, want now+TTL", granted.ExpiresAt)
	}
}

// TestAPromotionOfferCannotSkipARung stops the ladder being a lever. Each rung
// is a separate operator decision, and an offer that proposes one-click for a
// trigger class that has never been past observe asks for two decisions with
// one click.
func TestAPromotionOfferCannotSkipARung(t *testing.T) {
	policy := DefaultPolicy()
	offer := Offer{Trigger: apiAlert, Action: restartAPI, Rung: RungOneClick, ClaimedSuccesses: 3}
	if _, err := EvaluateOffer(offer, Grant{}, 3, policy, at(2)); !errors.Is(err, ErrOfferSkipsRung) {
		t.Fatalf("err=%v, want ErrOfferSkipsRung", err)
	}
	current := liveGrant(RungPropose)
	if _, err := EvaluateOffer(offer, current, 3, policy, at(2)); err != nil {
		t.Fatalf("the next rung up from propose was refused: %v", err)
	}
}

// TestAPromotionOfferCannotReachTheAutoRung is the second half of the seam
// guard. Nothing may hand out authority this build cannot supervise, and the
// refusal names the missing decision rather than reading as a validation slip.
func TestAPromotionOfferCannotReachTheAutoRung(t *testing.T) {
	policy := DefaultPolicy()
	current := liveGrant(RungOneClick)
	offer := Offer{Trigger: apiAlert, Action: restartAPI, Rung: RungAuto, ClaimedSuccesses: 9}
	_, err := EvaluateOffer(offer, current, 9, policy, at(2))
	if !errors.Is(err, ErrRungNotImplemented) {
		t.Fatalf("err=%v, want ErrRungNotImplemented", err)
	}
}

// TestAPromotionOfferCannotMoveToAnotherAction is the "a model proposal can
// never widen a grant" rule at its sharpest: the counts belong to the exact
// action they were earned by, and an offer that carries one action's successes
// under another action's identity is laundering them.
func TestAPromotionOfferCannotMoveToAnotherAction(t *testing.T) {
	policy := DefaultPolicy()
	current := liveGrant(RungPropose)
	offer := Offer{
		Trigger: apiAlert,
		Action:  ActionRef{ActionID: "nomad.job.stop", PackRef: restartAPI.PackRef, RunnerRef: restartAPI.RunnerRef},
		Rung:    RungOneClick, ClaimedSuccesses: 3,
	}
	if _, err := EvaluateOffer(offer, current, 3, policy, at(2)); !errors.Is(err, ErrOfferWidensGrant) {
		t.Fatalf("err=%v, want ErrOfferWidensGrant", err)
	}
	wider := Offer{
		Trigger: TriggerClass{AlertGroupKey: apiAlert.AlertGroupKey, ChannelID: apiAlert.ChannelID},
		Action:  restartAPI, Rung: RungOneClick, ClaimedSuccesses: 3,
	}
	if _, err := EvaluateOffer(wider, current, 3, policy, at(2)); !errors.Is(err, ErrOfferWidensGrant) {
		t.Fatalf("dropping the repository scope: err=%v, want ErrOfferWidensGrant", err)
	}
}

// TestAPromotionOfferIsRefusedOnAnIncompleteIdentity keeps a half-filled offer
// from being stored as a grant that matches whatever is also half-filled.
func TestAPromotionOfferIsRefusedOnAnIncompleteIdentity(t *testing.T) {
	policy := DefaultPolicy()
	for _, tc := range []struct {
		name  string
		offer Offer
	}{
		{"no action id", Offer{Trigger: apiAlert, Action: ActionRef{PackRef: "p", RunnerRef: "r"}, Rung: RungPropose, ClaimedSuccesses: 3}},
		{"no pack ref", Offer{Trigger: apiAlert, Action: ActionRef{ActionID: "a", RunnerRef: "r"}, Rung: RungPropose, ClaimedSuccesses: 3}},
		{"no runner ref", Offer{Trigger: apiAlert, Action: ActionRef{ActionID: "a", PackRef: "p"}, Rung: RungPropose, ClaimedSuccesses: 3}},
		{"no alert group key", Offer{Trigger: TriggerClass{ChannelID: "C0", Repository: "api"}, Action: restartAPI, Rung: RungPropose, ClaimedSuccesses: 3}},
		{"no channel", Offer{Trigger: TriggerClass{AlertGroupKey: "g", Repository: "api"}, Action: restartAPI, Rung: RungPropose, ClaimedSuccesses: 3}},
		{"an unknown rung", Offer{Trigger: apiAlert, Action: restartAPI, Rung: Rung("supervisor"), ClaimedSuccesses: 3}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := EvaluateOffer(tc.offer, Grant{}, 9, policy, at(2)); err == nil {
				t.Fatal("an incomplete offer was accepted")
			}
		})
	}
}

// TestAPromotionCarriesTheOperatorWhoConfirmedIt records who took the decision,
// because "promotion requires a human" is only auditable if the row names one.
func TestAPromotionCarriesTheOperatorWhoConfirmedIt(t *testing.T) {
	offer := Offer{Trigger: apiAlert, Action: restartAPI, Rung: RungPropose, ClaimedSuccesses: 3}
	granted, err := EvaluateOffer(offer, Grant{}, 3, DefaultPolicy(), at(2))
	if err != nil {
		t.Fatal(err)
	}
	if err := granted.Validate(); err == nil {
		t.Fatal("a grant with no confirming operator validated")
	}
	granted.GrantedBy = "U0OPERATOR"
	if err := granted.Validate(); err != nil {
		t.Fatalf("a confirmed grant did not validate: %v", err)
	}
}

// --- demotion ------------------------------------------------------------

// TestAFailedVerificationDemotesImmediately is the rule that makes the rest of
// the ladder safe to climb. Promotion is slow, human and reversible; demotion
// is none of those things, and it must not wait for a turn, a poll, or an
// operator to notice.
func TestAFailedVerificationDemotesImmediately(t *testing.T) {
	current := liveGrant(RungOneClick)
	current.SuccessCount, current.LastVerifiedAt = 5, at(1)
	demoted := Demote(current, VerificationFailed, at(4))
	if demoted.Rung != RungPropose {
		t.Fatalf("rung=%q, want one rung down at %q", demoted.Rung, RungPropose)
	}
	if demoted.DemotedReason != string(VerificationFailed) {
		t.Fatalf("reason=%q, want %q", demoted.DemotedReason, VerificationFailed)
	}
	if !demoted.DemotedAt.Equal(at(4)) {
		t.Fatalf("demoted at %v, want the moment it was decided", demoted.DemotedAt)
	}
	// The earned count goes with the rung. Leaving it would let a single
	// verified run re-promote a grant that had just failed one.
	if demoted.SuccessCount != 0 {
		t.Fatalf("success count survived demotion at %d", demoted.SuccessCount)
	}
}

// TestEveryDemotionTriggerDropsExactlyOneRung enumerates the four triggers the
// spec names, so adding a fifth without deciding its effect fails here.
func TestEveryDemotionTriggerDropsExactlyOneRung(t *testing.T) {
	for _, reason := range []DemotionReason{
		VerificationFailed, Expired, ContractChanged, OperatorCommand,
	} {
		t.Run(string(reason), func(t *testing.T) {
			demoted := Demote(liveGrant(RungOneClick), reason, at(4))
			if demoted.Rung != RungPropose {
				t.Fatalf("rung=%q, want %q", demoted.Rung, RungPropose)
			}
			if demoted.DemotedReason != string(reason) {
				t.Fatalf("reason=%q, want %q", demoted.DemotedReason, reason)
			}
		})
	}
}

// TestDemotionNeverFallsBelowObserve keeps the floor a floor. Observe is
// read-only and is what the system did before any of this existed, so there is
// nothing below it to fall to and no reason to invent one.
func TestDemotionNeverFallsBelowObserve(t *testing.T) {
	demoted := Demote(liveGrant(RungObserve), VerificationFailed, at(4))
	if demoted.Rung != RungObserve {
		t.Fatalf("rung=%q, want %q", demoted.Rung, RungObserve)
	}
	again := Demote(demoted, OperatorCommand, at(5))
	if again.Rung != RungObserve {
		t.Fatalf("rung=%q after a second demotion, want %q", again.Rung, RungObserve)
	}
}

// TestAnAutoGrantDemotesToTheRungBelowIt covers the row this build refuses to
// create but may still have to take away.
func TestAnAutoGrantDemotesToTheRungBelowIt(t *testing.T) {
	demoted := Demote(liveGrant(RungAuto), ContractChanged, at(4))
	if demoted.Rung != RungOneClick {
		t.Fatalf("rung=%q, want %q", demoted.Rung, RungOneClick)
	}
}

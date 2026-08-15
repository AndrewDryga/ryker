// Package remediation is the trust ladder: which exact Emisar action Responder
// may offer for which exact trigger, how a rung is earned, and how it is taken
// away.
//
// Everything here is a pure function over values. That is deliberate and it is
// the whole point of the package existing: authority decisions are the ones
// that most need to be readable, reproducible and cheap to test exhaustively,
// and a decision that needs a database, a Slack client and a model turn to
// exercise is a decision nobody tests exhaustively. The store persists what
// these functions decide; the service renders it; neither re-decides it.
//
// Three rules run through all of it.
//
//   - A grant names ONE immutable Emisar identity — action id, pack ref and
//     runner ref together — and one trigger class. Anything that is not exactly
//     that pair is a different grant, and matching is exact.
//   - Promotion is human. The model may propose one, the host recomputes the
//     evidence for it from its own records, and an operator confirms it. None of
//     those three may be skipped, and the model's number is never the one used.
//   - Demotion is automatic, immediate and needs no one's permission.
package remediation

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Rung is one step on the ladder. The order below is the ladder.
type Rung string

const (
	// RungObserve is today's behaviour and the floor: read-only, with any
	// remediation appearing as prose in a reply. Every demotion lands here
	// eventually and nothing is below it.
	RungObserve Rung = "observe"
	// RungPropose renders the action as a typed card whose control submits a
	// REQUEST to Emisar. Emisar still decides; the card never approves.
	RungPropose Rung = "propose"
	// RungOneClick is the same card with the request pre-validated, so the
	// single click submits without a round trip. It is a latency rung, not an
	// authority rung — the authority is identical to propose.
	RungOneClick Rung = "one_click"
	// RungAuto is specified and NOT implemented. See Ceiling.
	RungAuto Rung = "auto"
)

// Ceiling is the highest rung this build can actually supervise.
//
// The auto rung — the host submitting a granted action with no human in the
// loop — needs a decision only the operator can make: a host-side run_action
// through internal/emisar, or a minimal Coop turn carrying the frozen request.
// The design recommends the first and neither is built. Until one is, a stored
// rung of "auto" is clamped here and Decision.Reason says so, because a grant
// that reads as unattended authority and is executed by nothing is worse than
// either honest answer.
const Ceiling = RungOneClick

var ladder = []Rung{RungObserve, RungPropose, RungOneClick, RungAuto}

// Valid reports whether the rung is one this package knows.
func (r Rung) Valid() bool {
	for _, known := range ladder {
		if r == known {
			return true
		}
	}
	return false
}

// rank is the rung's position on the ladder, or -1 if it is not on it.
func (r Rung) rank() int {
	for index, known := range ladder {
		if r == known {
			return index
		}
	}
	return -1
}

// atMost clamps the rung to the ceiling, reporting whether it had to.
func (r Rung) atMost(limit Rung) (Rung, bool) {
	if r.rank() > limit.rank() {
		return limit, true
	}
	return r, false
}

// ActionRef is Emisar's immutable identity for one action.
//
// All three parts are the identity. The pack ref pins the version and digest
// the action's behaviour came from, and the runner ref pins where it runs — a
// grant earned restarting one job on one runner says nothing about the same
// action id pointed at a different fleet, which is exactly the widening the
// blast-radius rule exists to prevent.
type ActionRef struct {
	ActionID  string
	PackRef   string
	RunnerRef string
}

func (a ActionRef) normalized() ActionRef {
	return ActionRef{
		ActionID:  strings.TrimSpace(a.ActionID),
		PackRef:   strings.TrimSpace(a.PackRef),
		RunnerRef: strings.TrimSpace(a.RunnerRef),
	}
}

// Complete reports whether every part of the identity is present. A partial ref
// is never stored: it would match whatever else is partial.
func (a ActionRef) Complete() bool {
	normalized := a.normalized()
	return normalized.ActionID != "" && normalized.PackRef != "" && normalized.RunnerRef != ""
}

// Equal compares two refs exactly, after trimming transport whitespace.
//
// Trimming is safe because it cannot change which action runs. Case folding is
// not, and is deliberately absent: these are opaque identifiers Emisar assigned,
// and treating two spellings as one is a decision about authority dressed up as
// a string comparison.
func (a ActionRef) Equal(other ActionRef) bool {
	return a.normalized() == other.normalized()
}

func (a ActionRef) String() string {
	normalized := a.normalized()
	return normalized.ActionID + " @ " + normalized.PackRef + " on " + normalized.RunnerRef
}

// TriggerClass is the other half of a grant's identity: which situation it was
// earned on, and how far its scope reaches.
type TriggerClass struct {
	// AlertGroupKey is the provider's stable identity for the alert group —
	// Grafana's groupKey — which is the strongest "this is the same thing
	// happening again" signal available.
	AlertGroupKey string
	// ChannelID scopes the grant to where the operator confirmed it.
	ChannelID string
	// Repository narrows it further when the trigger belongs to one. Empty is a
	// real value and a WIDER one, which is why an offer may never drop it from
	// a grant that has it.
	Repository string
}

func (t TriggerClass) normalized() TriggerClass {
	return TriggerClass{
		AlertGroupKey: strings.TrimSpace(t.AlertGroupKey),
		ChannelID:     strings.TrimSpace(t.ChannelID),
		Repository:    strings.TrimSpace(t.Repository),
	}
}

// Complete reports whether the class identifies a situation at all. The
// repository is optional; the alert group and the channel are not.
func (t TriggerClass) Complete() bool {
	normalized := t.normalized()
	return normalized.AlertGroupKey != "" && normalized.ChannelID != ""
}

func (t TriggerClass) Equal(other TriggerClass) bool {
	return t.normalized() == other.normalized()
}

func (t TriggerClass) String() string {
	normalized := t.normalized()
	if normalized.Repository == "" {
		return normalized.AlertGroupKey + " in " + normalized.ChannelID
	}
	return normalized.AlertGroupKey + " in " + normalized.ChannelID + "/" + normalized.Repository
}

// Grant is one row of earned authority.
type Grant struct {
	ID      string
	Trigger TriggerClass
	Action  ActionRef
	Rung    Rung
	// GrantedBy is the operator who confirmed the promotion. It is required:
	// "promotion requires a human" is only auditable if the row names one, and
	// EvaluateOffer deliberately cannot fill it in.
	GrantedBy string
	GrantedAt time.Time
	// ExpiresAt is mandatory. Authority that outlives the operator's attention
	// is the failure this ladder exists to avoid; renewal is one click.
	ExpiresAt time.Time
	// SuccessCount is the host's own count of verified successes at the moment
	// the grant was confirmed, kept so the card and the audit trail can say what
	// the promotion rested on.
	SuccessCount   int
	LastVerifiedAt time.Time
	DemotedReason  string
	DemotedAt      time.Time
}

// Validate reports why a grant may not be stored or acted on.
func (g Grant) Validate() error {
	switch {
	case !g.Trigger.Complete():
		return fmt.Errorf("remediation grant requires an alert group key and a channel")
	case !g.Action.Complete():
		return fmt.Errorf("remediation grant requires an action id, pack ref and runner ref")
	case !g.Rung.Valid():
		return fmt.Errorf("remediation grant has unsupported rung %q", g.Rung)
	case g.ExpiresAt.IsZero():
		return fmt.Errorf(
			"remediation grant for %s has no expiry; authority is never granted permanently",
			g.Action,
		)
	case strings.TrimSpace(g.GrantedBy) == "":
		return fmt.Errorf("remediation grant for %s names no confirming operator", g.Action)
	}
	return nil
}

// Live reports whether the grant is currently in force.
func (g Grant) Live(now time.Time) bool {
	return g.ExpiresAt.After(now)
}

// Trigger is one live occurrence being matched against the grants on file.
type Trigger struct {
	Class  TriggerClass
	Action ActionRef
}

// Decision is what the host may do about one trigger, and why.
type Decision struct {
	// Rung is the authority actually in force, after clamping and expiry.
	Rung Rung
	// Grant is the row this decision came from, when one matched.
	Grant   Grant
	Matched bool
	// MayOffer is whether the host may render a control that submits the action
	// as a REQUEST to Emisar. Emisar's own policy still decides what happens to
	// that request; this only says whether the card gets a button.
	MayOffer bool
	// MaySubmitUnattended is whether the host may submit with no human click.
	// It is false in every branch of this build — see Ceiling.
	MaySubmitUnattended bool
	// Reason is the host's own words for the decision, for the card and the
	// audit trail.
	Reason string
}

// Decide is the deterministic matcher: the whole of what one trigger is allowed
// to become.
//
// It is total. Every input produces a decision with a reason, because "no grant
// matched" and "a grant matched and authorizes nothing" are different facts and
// an operator reading a card is entitled to know which one they are looking at.
func Decide(grants []Grant, trigger Trigger, now time.Time) Decision {
	observe := func(reason string) Decision {
		return Decision{Rung: RungObserve, Reason: reason}
	}
	if !trigger.Class.Complete() || !trigger.Action.Complete() {
		return observe("the trigger does not name a complete alert class and action identity")
	}
	var best Grant
	var found, lapsed bool
	for _, grant := range grants {
		if grant.Validate() != nil && !grant.ExpiresAt.IsZero() {
			continue
		}
		if grant.ExpiresAt.IsZero() {
			// A grant with no expiry is not a long-lived grant, it is an
			// invalid one. Skipped rather than honoured, and never silently
			// treated as live.
			continue
		}
		if !grant.Trigger.Equal(trigger.Class) || !grant.Action.Equal(trigger.Action) {
			continue
		}
		if !grant.Live(now) {
			lapsed = true
			continue
		}
		// Newest wins. Two rows legitimately match after a promotion writes a
		// grant beside the one it replaces, and "whichever the store returned
		// first" is not a rule anyone can reason about.
		if !found || grant.GrantedAt.After(best.GrantedAt) {
			best, found = grant, true
		}
	}
	if !found {
		if lapsed {
			return observe("the grant for " + trigger.Action.String() + " has expired")
		}
		return observe("no grant covers " + trigger.Action.String() + " for " + trigger.Class.String())
	}
	rung, clamped := best.Rung.atMost(Ceiling)
	decision := Decision{
		Rung: rung, Grant: best, Matched: true,
		MayOffer: rung.rank() >= RungPropose.rank(),
		Reason: fmt.Sprintf(
			"grant %s allows %s for %s until %s",
			best.ID, rung, trigger.Class, best.ExpiresAt.UTC().Format(time.RFC3339),
		),
	}
	if clamped {
		decision.Reason += "; the auto rung is not implemented in this build, so it acts at " +
			string(Ceiling)
	}
	return decision
}

// NextRung is the rung one above whatever a grant currently holds, and the only
// rung an offer for it may name.
//
// The zero Grant — no row on file — is at observe, so the first promotion any
// action can be offered is propose. Nothing above the ceiling is ever returned,
// so a grant already at the top is offered no further promotion rather than an
// unreachable one.
func NextRung(current Grant) Rung {
	rank := current.Rung.rank()
	if rank < 0 {
		rank = RungObserve.rank()
	}
	if next := rank + 1; next <= Ceiling.rank() {
		return ladder[next]
	}
	return Ceiling
}

// --- promotion -----------------------------------------------------------

// Policy is what promotion costs.
type Policy struct {
	// RequiredSuccesses is how many verified successes of the SAME exact action
	// for the SAME trigger class a rung costs.
	RequiredSuccesses int
	// GrantTTL is how long a confirmed grant lasts before it must be renewed.
	GrantTTL time.Duration
}

// DefaultPolicy is three verified successes and thirty days.
//
// Three because it is the smallest number that is not a coincidence, and thirty
// days because it is long enough that renewal is not noise and short enough
// that a grant nobody remembers granting cannot still be live next quarter.
func DefaultPolicy() Policy {
	return Policy{RequiredSuccesses: 3, GrantTTL: 30 * 24 * time.Hour}
}

// Offer is a promotion a model proposed. Every field is a claim, including the
// count — see EvaluateOffer.
type Offer struct {
	Trigger          TriggerClass
	Action           ActionRef
	Rung             Rung
	ClaimedSuccesses int
}

var (
	// ErrOfferUnverifiable is an offer whose evidence the host cannot reproduce.
	ErrOfferUnverifiable = errors.New("promotion offer overstates its verified successes")
	// ErrOfferNotEarned is an accurate offer that has not reached the threshold.
	ErrOfferNotEarned = errors.New("promotion offer has not earned the rung")
	// ErrOfferSkipsRung is an offer that is not exactly one rung up.
	ErrOfferSkipsRung = errors.New("promotion offer does not climb exactly one rung")
	// ErrOfferWidensGrant is an offer that changes the action or the scope it
	// counted its successes under.
	ErrOfferWidensGrant = errors.New("promotion offer widens the grant it counted")
	// ErrOfferIncomplete is an offer that does not identify one action and one
	// trigger class.
	ErrOfferIncomplete = errors.New("promotion offer does not name a complete grant identity")
	// ErrRungNotImplemented is the auto rung's seam.
	ErrRungNotImplemented = errors.New("promotion offer asks for a rung this build cannot supervise")
)

// EvaluateOffer decides a model's promotion offer against the host's own count.
//
// `verified` is recomputed by the caller from the outcomes table and is the only
// number that decides anything; `offer.ClaimedSuccesses` is checked against it
// and then discarded. That asymmetry is the design: the model is an input, and
// an offer claiming six successes where the record holds two is either a
// miscount or an argument for authority nobody earned. Both are refused, and
// the refusal names both numbers so the disagreement is legible.
//
// `current` is the grant already on file for this exact pair, or the zero Grant
// when there is none. The returned grant is unconfirmed: it has no GrantedBy,
// so it cannot pass Validate until an operator's click supplies one.
func EvaluateOffer(
	offer Offer,
	current Grant,
	verified int,
	policy Policy,
	now time.Time,
) (Grant, error) {
	if !offer.Trigger.Complete() || !offer.Action.Complete() || !offer.Rung.Valid() {
		return Grant{}, fmt.Errorf(
			"%w: action %q, trigger %q, rung %q",
			ErrOfferIncomplete, offer.Action, offer.Trigger, offer.Rung,
		)
	}
	if offer.Rung == RungAuto {
		return Grant{}, fmt.Errorf(
			"%w: the auto rung needs a host-side execution path that has not been decided; "+
				"the highest grantable rung is %q",
			ErrRungNotImplemented, Ceiling,
		)
	}
	// An existing grant fixes the identity the successes were earned under.
	// Without this an offer could carry one action's record under another
	// action's name, which is the "a model proposal can never widen a grant"
	// rule at its sharpest.
	if current.Rung != "" || current.ID != "" {
		if !current.Action.Equal(offer.Action) || !current.Trigger.Equal(offer.Trigger) {
			return Grant{}, fmt.Errorf(
				"%w: grant %s covers %s for %s, and the offer names %s for %s",
				ErrOfferWidensGrant, current.ID, current.Action, current.Trigger,
				offer.Action, offer.Trigger,
			)
		}
	}
	from := current.Rung
	if from == "" {
		from = RungObserve
	}
	if offer.Rung.rank() != from.rank()+1 {
		return Grant{}, fmt.Errorf(
			"%w: %s is at %q and the offer asks for %q; each rung is a separate decision",
			ErrOfferSkipsRung, offer.Action, from, offer.Rung,
		)
	}
	if offer.ClaimedSuccesses > verified {
		return Grant{}, fmt.Errorf(
			"%w: the offer claims %d verified successes of %s for %s and the host recomputes %d",
			ErrOfferUnverifiable, offer.ClaimedSuccesses, offer.Action, offer.Trigger, verified,
		)
	}
	if verified < policy.RequiredSuccesses {
		return Grant{}, fmt.Errorf(
			"%w: %q costs %d verified successes of %s and the host recomputes %d",
			ErrOfferNotEarned, offer.Rung, policy.RequiredSuccesses, offer.Action, verified,
		)
	}
	return Grant{
		ID:      current.ID,
		Trigger: offer.Trigger.normalized(),
		Action:  offer.Action.normalized(),
		Rung:    offer.Rung,
		// GrantedBy is deliberately empty. This function decides that a
		// promotion is EARNED; only an operator's click decides that it happens.
		GrantedAt:    now.UTC(),
		ExpiresAt:    now.UTC().Add(policy.GrantTTL),
		SuccessCount: verified,
	}, nil
}

// --- demotion ------------------------------------------------------------

// DemotionReason is why a grant lost a rung. Promotion needs a human; every one
// of these happens without asking.
type DemotionReason string

const (
	// VerificationFailed is the verification episode after a granted execution
	// reporting that the fix did not hold.
	VerificationFailed DemotionReason = "verification_failed"
	// Expired is the grant reaching its expiry without renewal.
	Expired DemotionReason = "expired"
	// ContractChanged is Emisar's target_contract_changed: the action is no
	// longer the action the successes were earned on.
	ContractChanged DemotionReason = "target_contract_changed"
	// OperatorCommand is a person taking it back.
	OperatorCommand DemotionReason = "operator_command"
)

// Demote drops a grant one rung and records why.
//
// One rung rather than straight to observe, because the ladder's steps are the
// unit of trust everywhere else and a demotion that skipped them would make the
// next promotion offer un-gradeable. The earned count goes with the rung: leaving
// it would let one verified run re-promote a grant that had just failed one.
func Demote(grant Grant, reason DemotionReason, now time.Time) Grant {
	if rank := grant.Rung.rank(); rank > 0 {
		grant.Rung = ladder[rank-1]
	} else {
		grant.Rung = RungObserve
	}
	grant.DemotedReason = string(reason)
	grant.DemotedAt = now.UTC()
	grant.SuccessCount = 0
	return grant
}

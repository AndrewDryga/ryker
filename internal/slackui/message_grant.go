package slackui

import (
	"strconv"
	"time"

	"github.com/AndrewDryga/responder/internal/remediation"
)

// GrantConfirmationStale tells an operator how to get a fresh offer.
const GrantConfirmationStale = "*This promotion expired; ask Responder for a new one.*"

// GrantRefusedNotice is the refusal an operator reads when the host can no
// longer reproduce the evidence the card was composed on.
const GrantRefusedNotice = "*Current verified successes no longer support this promotion.*"

// GrantExpiryLabel renders a grant's remaining life the way the offer cards
// render every other expiry.
func GrantExpiryLabel(expires, now time.Time) string {
	if days := int(expires.Sub(now).Hours() / 24); days > 1 {
		return strconv.Itoa(days) + " days"
	}
	return "1 day"
}

// GrantConfirmedNotice is the receipt for a granted rung.
//
// It restates the boundary in the same breath as the grant, because this is the
// message an operator remembers having read: Emisar still approves every run,
// and the grant undoes itself if one fails.
func GrantConfirmedNotice(grant remediation.Grant, verified int) string {
	return "*Granted.* I may now offer `" + safeInlineCode(grant.Action.ActionID) +
		"` for this alert at `" + safeInlineCode(string(grant.Rung)) + "`, on " +
		strconv.Itoa(verified) + " verified successes, until " +
		grant.ExpiresAt.Format("2006-01-02") + "; Emisar decides whether each run can execute and a failure lowers the grant automatically."
}

// grantOfferContext keeps the execution decision boundary explicit.
const grantOfferContext = "Emisar decides whether each run can execute."

// rungPhrase says what a rung actually permits, in the reader's terms.
//
// The stored words — propose, one_click — are the ladder's vocabulary and mean
// nothing to somebody being asked to authorize something. An operator confirming
// a rung is entitled to a sentence about what changes, not a term of art.
func rungPhrase(rung remediation.Rung) string {
	switch rung {
	case remediation.RungPropose:
		return "show this action on the card with a button that asks Emisar to run it"
	case remediation.RungOneClick:
		return "pre-validate the request so one press sends it straight to Emisar"
	default:
		return "keep this action read-only and mention it only in prose"
	}
}

// WithGrantPromotionOffer asks an operator to move one grant up one rung.
//
// The card states the host's OWN recomputed count rather than whatever the
// model said, because the number is the entire argument for the promotion and
// showing a claimed one would make the operator's decision rest on the thing
// this design refuses to trust. The action identity is rendered in full — id,
// pack and runner — for the same reason the approval card renders it: a person
// granting authority over an action should be reading the identity it is
// granted over, not a friendly name for it.
//
// There is exactly one control and it is a confirmation. There is deliberately
// no decline button: declining an offer is not pressing it, and a second button
// would imply the offer is a decision that has to be resolved.
func WithGrantPromotionOffer(
	message Message,
	grant remediation.Grant,
	verifiedSuccesses int,
	actionValue string,
	expiresLabel string,
	rationale string,
) Message {
	quote := "Let me " + rungPhrase(grant.Rung) + "."
	if text := externalText(rationale); text != "" {
		quote = text
	}
	return offerCard(message, grantOfferContext, offerProposal{
		Quote: quote,
		Facts: joinFacts([]string{
			"Action `" + safeInlineCode(grant.Action.ActionID) + "`",
			"Runner `" + safeInlineCode(grant.Action.RunnerRef) + "`",
			"Pack `" + safeInlineCode(grant.Action.PackRef) + "`",
			"Alert `" + safeInlineCode(grant.Trigger.AlertGroupKey) + "`",
			strconv.Itoa(verifiedSuccesses) + " verified successes, counted by Responder",
			expiryTerm(expiresLabel),
		}),
		Actions: []Action{{
			ID:    ActionConfirmGrantPromotion,
			Label: "Allow this action here",
			Value: actionValue,
			Style: "primary",
			Confirm: "Let Responder offer " + grant.Action.ActionID + " for this alert " +
				rememberPhrase(expiresLabel) + " while Emisar decides whether each run can execute?",
		}},
	})
}

// GrantDemotedMessage says a grant lost a rung and why.
//
// Demotion is automatic and immediate, which is exactly why it has to be
// announced. An operator who confirmed a promotion is entitled to learn that it
// was taken back without them, and the reason is the useful part: a grant that
// lapsed, one whose action stopped resolving, and one whose fix did not hold
// are three different things to do next.
func GrantDemotedMessage(grant remediation.Grant, reason remediation.DemotionReason) Message {
	explanation := "The remediation did not hold, so this grant dropped a rung."
	switch reason {
	case remediation.ContractChanged:
		explanation = "Emisar no longer resolves this action to what the grant was earned on, " +
			"so the grant dropped a rung."
	case remediation.Expired:
		explanation = "This grant reached its expiry and dropped a rung."
	case remediation.OperatorCommand:
		explanation = "An operator took this grant back a rung."
	}
	return Message{
		Text: truncateUTF8(
			"Remediation grant lowered — "+grant.Action.ActionID+" is now "+string(grant.Rung)+".",
			4000,
		),
		Header: "Remediation grant lowered",
		Stripe: StripeIdle,
		Sections: []string{
			explanation,
			"`" + safeInlineCode(grant.Action.ActionID) + "` is now at `" +
				safeInlineCode(string(grant.Rung)) + "` for `" +
				safeInlineCode(grant.Trigger.AlertGroupKey) + "`.",
		},
		Temporary: true,
	}
}

package slackui

import (
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// approvalBlastRadius is what a paused action would touch, as a label/value
// strip.
//
// Every row is a typed field of the stored request and nothing else. The design
// asked for target, change and policy rows beside these three; `core.EmisarApproval`
// records none of them — it holds the action, the pack it came from, the runner
// it would run on, the run id, and the URL where the arguments, the diff and
// the policy decision actually live. The rows that could only have been
// inferred from the action's name, or read out of model prose, are absent: a
// blast-radius strip that guesses the blast radius is worse than one that stops
// at what was recorded, because it is the strip an operator is meant to approve
// from.
//
// The glyph is left empty, so the strip renders as an aligned list of facts
// rather than as a run with steps — nothing here has a position or a state.
func approvalBlastRadius(approval core.EmisarApproval) []LedgerStep {
	rows := make([]LedgerStep, 0, 3)
	for _, row := range []struct{ label, value string }{
		{"action", approval.ActionID},
		{"runner", approval.RunnerRef},
		// externalText strips the 64-character sha256 the pack ref drags
		// behind it. The version in front of the digest is what names the pack
		// to a person, and the digest alone is 71 of the 46 columns a strip
		// line has.
		{"pack", approval.PackRef},
	} {
		if value := externalText(row.value); value != "" {
			rows = append(rows, LedgerStep{Label: row.label, Detail: value})
		}
	}
	return rows
}

// approvalExpiry states when the request lapses, in the reader's own timezone.
//
// The design asked for a countdown — "expires in 1h 59m". This card is composed
// once and posted; nothing refreshes it. A countdown would be right for one
// second and then quietly wrong for the whole hour that mattered, and wrong by
// the largest margin exactly when the deadline was closest. Slack resolves the
// date token client-side on every read, so the wall time is correct whenever it
// is looked at, and it is correct in the reader's zone rather than in UTC.
func approvalExpiry(expires time.Time) string {
	if when := slackDate(expires, "2006-01-02 15:04 UTC"); when != "" {
		return "expires " + when
	}
	return ""
}

// approvalHeader names the action waiting for a decision.
//
// The action id is a typed identifier Emisar assigned, not model prose, which
// is what makes it safe in a header — the one line of a card that cannot be
// escaped, cannot hold a link, and is read before anything else.
func approvalHeader(actionID string) string {
	if action := externalText(actionID); action != "" {
		return truncateUTF8("✋ Approval needed: "+action, maxSlackHeaderBytes)
	}
	return "✋ Approval needed"
}

// WithEmisarApproval marks a reply as waiting on a person.
//
// It decorates the model's reply rather than replacing it: the reply is the
// agent's account of why it wants this, and this function has no better version
// of that sentence. What it adds is everything the reply cannot be trusted to
// state — which action, on which runner, from which pack, until when — and it
// adds it as typed fields in a fixed shape, so an operator approving from this
// card is reading the record rather than a summary of it.
func WithEmisarApproval(message Message, approval core.EmisarApproval) Message {
	message.Header = approvalHeader(approval.ActionID)
	// Salmon: the ball is with a person, and this is the one card in the
	// approval family where that is true.
	message.Stripe = StripeNeedsYou
	// The fallback leads with the state word, because a notification and the
	// sidebar strip the colour and the glyph and leave only this line.
	message.Text = truncateUTF8(
		"Needs you — Emisar paused "+approval.ActionID+
			" for approval. Nothing has executed. Review it in Emisar: "+approval.ApprovalURL,
		4000,
	)
	// One section, not three. It used to say that Emisar paused the action,
	// then restate the action id the header now carries, then promise to watch
	// the request — three blocks between the reply and the button, two of which
	// were about Responder rather than about the decision.
	message.Sections = append(message.Sections,
		"Emisar paused this before anything ran. Review the exact target, arguments, "+
			"evidence, blast radius, and policy decision in Emisar.",
	)
	message.Ledger = append(message.Ledger, approvalBlastRadius(approval)...)
	message.Context = append(message.Context, joinFacts([]string{
		"Run `" + safeInlineCode(approval.RunID) + "`",
		approvalExpiry(approval.ExpiresAt),
		"Approval happens only in Emisar; opening the link does not execute it.",
	}))
	message.Context = append(
		message.Context,
		"I’ll watch this request and update this card automatically.",
	)
	// The proposal approve and reject buttons used to be filtered out here so an
	// Emisar approval card could not also offer a Slack approval for the same
	// work. Nothing composes those buttons any more, so there is nothing to
	// filter and the card simply appends its own control.
	message.Actions = append(message.Actions, Action{
		ID:    ActionOpenApproval,
		Label: "Review approval in Emisar",
		Value: approval.RequestID,
		Style: "primary",
		URL:   approval.ApprovalURL,
	})
	return message
}

// emisarApprovalState resolves colour, glyph and word together for one status.
//
// The statuses are Emisar's, and there are eleven of them; custody has three
// answers. Waiting is the only one where a person owes something, everything
// mid-flight belongs to Emisar, and every terminal status differs only in
// whether it stopped cleanly. Denied is deliberately grey rather than red: an
// operator declining a change is the control working, not a failure, and
// colouring it as one editorialises a decision this card does not get a vote in.
func emisarApprovalState(status string) cardState {
	switch status {
	case "pending", "sent", "running", "cancelling":
		return cardState{
			Stripe: StripeWorking, Glyph: "⚙️", Word: "Working", Custody: custodyEmisar,
		}
	case "success":
		return cardState{
			Stripe: StripeDone, Glyph: "✅", Word: "Done", Custody: custodyNobody,
		}
	case "denied":
		return cardState{
			Stripe: StripeIdle, Glyph: "⏸", Word: "Not approved", Custody: custodyNobody,
		}
	case "cancelled":
		return cardState{
			Stripe: StripeIdle, Glyph: "⏸", Word: "Cancelled", Custody: custodyNobody,
		}
	case "failed", "error", "validation_failed", "unknown_action", "timed_out", "refused":
		return cardState{
			Stripe: StripeFailed, Glyph: "🛑", Word: "Failed", Custody: custodyNobody,
		}
	default:
		return cardState{
			Stripe: StripeNeedsYou, Glyph: "✋", Word: "Needs you", Custody: custodyOperator,
		}
	}
}

// EmisarApprovalStateMessage is where a governed run stands, in one shape.
//
// The running state carries no progress ledger. The design asked for one
// ("rolling restart 2 of 5 allocs") and the record cannot supply it:
// `core.EmisarApproval` stores a status word and the timestamps around it, and
// nothing that counts steps. A ledger composed from those fields would be a
// drawing of a run rather than a reading of one, so the running card says the
// status and where it is running, which is all that was recorded.
func EmisarApprovalStateMessage(
	approval core.EmisarApproval,
	continuing bool,
) Message {
	status := safeInlineCode(approval.Status)
	action := safeInlineCode(approval.ActionID)
	runner := safeInlineCode(approval.RunnerRef)
	state := emisarApprovalState(approval.Status)
	header := "Emisar is waiting for approval"
	summary := "`" + action + "` is still waiting for an operator decision in Emisar."
	next := "I’ll keep watching this request and update this card automatically."
	switch approval.Status {
	case "pending", "sent", "running", "cancelling":
		header = "Emisar is running the approved action"
		summary = "`" + action + "` is now `" + status + "` on `" + runner + "`."
		next = "I’ll post the result here when Emisar finishes. You can keep using Slack meanwhile."
	case "success":
		header = "Emisar action completed"
		summary = "Emisar reports that `" + action + "` completed successfully on `" + runner + "`."
		next = "The final result is recorded in Emisar."
	case "denied":
		header = "Emisar action was not approved"
		summary = "Emisar reports that `" + action + "` was denied and did not run."
		next = "No operational change was made by this request. I’ll carry on without it."
	case "cancelled":
		header = "Emisar action was cancelled"
		summary = "Emisar reports that `" + action + "` was cancelled."
		next = "The run is terminal; check Emisar for its authoritative audit trail."
	case "failed", "error", "validation_failed", "unknown_action", "timed_out", "refused":
		header = "Emisar action did not complete"
		summary = "Emisar reports that `" + action + "` ended as `" + status + "` on `" + runner + "`."
		next = "The run is terminal; check Emisar for its authoritative error and audit trail."
	}
	if continuing {
		next += " I’m checking the terminal result and will post a concise follow-up here."
	}
	sections := []string{summary, next}
	if strings.TrimSpace(approval.LastError) != "" {
		sections = append(sections, "*Reported by Emisar:* "+truncateUTF8(approval.LastError, 800))
	}
	url := approval.RunURL
	label := "Open run in Emisar"
	if url == "" {
		url = approval.ApprovalURL
		label = "Open request in Emisar"
	}
	message := Message{
		Text: truncateUTF8(
			state.Word+" — "+approval.ActionID+" is "+approval.Status+". "+url,
			4000,
		),
		Header:   state.Header(header),
		Stripe:   state.Stripe,
		Sections: sections,
		Context: []string{
			"Run `" + safeInlineCode(approval.RunID) + "` · Emisar remains authoritative for execution, policy, and audit.",
		},
	}
	if url != "" {
		control := Action{
			ID: ActionOpenApproval, Label: label, Value: approval.RequestID, URL: url,
		}
		// One primary, earned. A link to a run that has already succeeded or
		// failed is a place to read the record, not a decision anyone is
		// waiting on, and a green button on every terminal card is how "the
		// ball is with you" stops meaning anything.
		if state.Custody == custodyOperator {
			control.Style = "primary"
		}
		message.Actions = []Action{control}
	}
	return message
}

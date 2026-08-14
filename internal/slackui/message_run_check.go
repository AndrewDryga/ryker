package slackui

import "strings"

// Run-check outcomes. Five, because that is what the host can tell apart from
// an external lifecycle notification without asking a model: it finished
// cleanly, it is waiting for a person, it failed, it is still going, or
// somebody stopped it.
const (
	RunCheckClean   = "clean"
	RunCheckReview  = "review"
	RunCheckFailed  = "failed"
	RunCheckRunning = "running"
	RunCheckStopped = "stopped"
)

// RunCheckVerdict is one answer about one external run.
//
// Every field is host-derived or host-typed. Nothing here is model prose, and
// that is the entire point of the card: the most frequent operator-visible
// message Responder sends is a Terraform run check — six of the last twelve
// episodes on the live instance — and it ships today as a paragraph the model
// wrote about a notification it read. A paragraph can be right, and it can also
// be confident and wrong, and neither reads differently.
type RunCheckVerdict struct {
	// Subject is what was checked, as a typed label the host chose:
	// "Terraform plan", "Deployment". Not a title the model composed.
	Subject string
	Outcome string
	// RunRef is the run's own identifier, as the notification carried it.
	RunRef string
	RunURL string
	// Basis is what the answer was read from — the tools consulted, and the
	// fact that all of them were read-only. A verdict that cannot say what it
	// checked is an opinion.
	Basis []string
}

// runCheckState resolves colour, glyph and word together.
//
// Clean is green and has no button: a check that found nothing wanted is the
// one card on the surface that has earned the right to be two lines and no
// controls. Review is salmon because a plan that touches something needs a
// person before it proceeds, and that person is the reader.
func runCheckState(outcome string) cardState {
	switch outcome {
	case RunCheckClean:
		return cardState{Stripe: StripeDone, Glyph: "✅", Word: "Clean", Custody: custodyNobody}
	case RunCheckReview:
		return cardState{
			Stripe: StripeNeedsYou, Glyph: "✋", Word: "Needs you", Custody: custodyOperator,
		}
	case RunCheckFailed:
		return cardState{Stripe: StripeFailed, Glyph: "🛑", Word: "Failed", Custody: custodyNobody}
	case RunCheckRunning:
		return cardState{
			Stripe: StripeWorking, Glyph: "⚙️", Word: "Running", Custody: custodyEmisar,
		}
	default:
		return cardState{Stripe: StripeIdle, Glyph: "⏸", Word: "Stopped", Custody: custodyNobody}
	}
}

// runCheckStatement is what the host is willing to claim, per outcome.
//
// Each sentence states the observation and its boundary in the same breath —
// "nothing entered apply" is the half of "the plan was clean" that an operator
// actually needs, and it is the half a summary drops first.
func runCheckStatement(outcome, subject string) string {
	switch outcome {
	case RunCheckClean:
		return "*" + subject + " finished with no material changes.* Nothing entered apply."
	case RunCheckReview:
		return "*" + subject + " is waiting for a decision.* It will not proceed until somebody approves it."
	case RunCheckFailed:
		return "*" + subject + " did not finish.* Open the run for the exact failure."
	case RunCheckRunning:
		return "*" + subject + " is still running.* I’ll report the result when it finishes."
	default:
		return "*" + subject + " was stopped before it finished.* Nothing further will happen on it."
	}
}

// RunCheckVerdictMessage states what a run check found, from typed fields only.
//
// SEAM — not yet wired. The intended call site is `watchReplyMessage` in
// internal/service/watch.go, which is where a standing rule's reply to an
// external run notification is composed and which currently returns
// `slackui.EvidenceResponse(text, nil, nil, …)` — the model's paragraph, with
// the evidence deliberately dropped.
//
// The typed inputs this needs already exist beside that call and are already
// trusted for policy: `lifecycle.Classify(input.Text)` returns a host-parsed
// phase (Succeeded, Reviewable, Failed, Applying, Planning, Created, Stopped)
// from the notification's own status lines, and `lifecycle.CorrelationKey`
// returns the run id or link. internal/service/external_message_reconcile.go
// already composes host-written `core.Evidence` from exactly those two, so the
// host demonstrably knows the answer at that point and throws it away when it
// builds the message.
//
// It is left unwired here on purpose. Turning the most frequent operator-facing
// reply from the agent's own words into a host card is a behaviour change that
// wants its own decision and its own live acceptance, not a quiet ride on a
// card-shapes commit — and the resource counts the design's "no material
// changes" wording leans on (`N to add, N to change, N to destroy`) are parsed
// nowhere in this repository, so the clean case would be claiming more than the
// host can currently see. Wire it when those counts are parsed, or when the
// weaker claim above is agreed to be enough.
func RunCheckVerdictMessage(verdict RunCheckVerdict) Message {
	state := runCheckState(verdict.Outcome)
	subject := externalText(verdict.Subject)
	if strings.TrimSpace(subject) == "" {
		subject = "The run"
	}
	facts := make([]string, 0, 3)
	if ref := externalText(verdict.RunRef); ref != "" {
		facts = append(facts, "run `"+safeInlineCode(ref)+"`")
	}
	if basis := joinFacts(verdict.Basis); basis != "" {
		facts = append(facts, "verified via "+externalText(basis))
	}
	// Said on every one of these cards, because the check is the thing being
	// trusted and "it only looked" is what makes it safe to trust.
	facts = append(facts, "read-only")
	message := Message{
		Text:     truncateUTF8(state.Word+" — "+subject+". "+verdict.RunURL, 4000),
		Header:   state.Header("Checked " + subject),
		Stripe:   state.Stripe,
		Sections: []string{runCheckStatement(verdict.Outcome, subject)},
		Context:  []string{joinFacts(facts)},
	}
	// A link out is the only control this card offers. It carries
	// ActionOpenWorkThread because Slack still posts an interaction when a URL
	// button is pressed, and that id routes to acknowledgeLinkAction — the
	// handler for a button that has already done its job by being a link.
	// ActionOpenApproval would look the value up as a stored Emisar approval
	// and tell the operator their control was invalid. Anything that acted on
	// the run would be Emisar's to authorize, not a Slack button's to fire.
	if url := verdict.RunURL; url != "" {
		control := Action{
			ID: ActionOpenWorkThread, Label: "Open the run", Value: verdict.RunRef, URL: url,
		}
		if verdict.Outcome == RunCheckReview {
			control.Label = "Review the plan"
			control.Style = "primary"
		}
		message.Actions = []Action{control}
	}
	return message
}

package investigation

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// A runbook offer missing any part of the Emisar identity is rejected where the
// model reads the rejection, naming the part that is missing.
//
// The deeper refusal — "this episode never ran that action" — needs the record
// and happens later. Separating them is the point: a shape complaint is
// something the next turn can act on, and an evidence complaint is not, so a
// partial identity must never reach the evidence check and come back as
// "unrecorded action" when the real answer is "you left out the runner".
func TestAKnowledgeOfferWithoutACompleteActionIdentityIsRejected(t *testing.T) {
	complete := func() *core.RunbookDraftOffer {
		return &core.RunbookDraftOffer{
			Title: "Restart a job that lost its registration", Slug: "nomad-lost-registration",
			Summary:  "Run when allocations are healthy but the service is not routable.",
			ActionID: "nomad.job.restart", PackRef: "nomad@1.4.0+sha256:1111",
			RunnerRef: "prod~7f3c",
		}
	}
	if err := (ResultOperation{
		ID: "rb-1", Type: "offer_runbook_draft", RunbookOffer: complete(),
	}).Validate(); err != nil {
		t.Fatalf("a complete runbook offer was rejected: %v", err)
	}
	for _, missing := range []struct {
		field string
		blank func(*core.RunbookDraftOffer)
	}{
		{"action_id", func(o *core.RunbookDraftOffer) { o.ActionID = " " }},
		{"pack_ref", func(o *core.RunbookDraftOffer) { o.PackRef = "" }},
		{"runner_ref", func(o *core.RunbookDraftOffer) { o.RunnerRef = "" }},
	} {
		offer := complete()
		missing.blank(offer)
		err := (ResultOperation{
			ID: "rb-1", Type: "offer_runbook_draft", RunbookOffer: offer,
		}).Validate()
		if err == nil {
			t.Fatalf("an offer with no %s was accepted", missing.field)
		}
		if !strings.Contains(err.Error(), missing.field) {
			t.Fatalf("rejection for a missing %s does not name it: %v", missing.field, err)
		}
	}
}

// Both offers are real operation types with real payload slots, and each holds
// exactly one payload like every other operation.
//
// The second half is what this pins: an operation carrying both a runbook and a
// card is refused rather than silently resolved to whichever the fold checks
// first. Two artefacts are two decisions and get two operations.
func TestAKnowledgeOperationCarriesExactlyOnePayload(t *testing.T) {
	card := &core.KnowledgeCardOffer{
		Slug: "pool-exhaustion", Title: "Pool exhaustion", Body: "The export job overlaps.",
	}
	if err := (ResultOperation{
		ID: "kb-1", Type: "offer_kb_card", CardOffer: card,
	}).Validate(); err != nil {
		t.Fatalf("a complete card offer was rejected: %v", err)
	}
	err := (ResultOperation{
		ID: "kb-1", Type: "offer_kb_card", CardOffer: card,
		RunbookOffer: &core.RunbookDraftOffer{Title: "t", Slug: "s"},
	}).Validate()
	if err == nil || !strings.Contains(err.Error(), "exactly one typed payload") {
		t.Fatalf("an operation carrying both artefacts was accepted: %v", err)
	}
}

// The operations prompt has to name both offers, or the contract allows
// something no model has been told about. The allowlist in
// internal/investigationcontract and this list are read together by every
// non-conversational turn, and a type in one and not the other is a validator
// nothing ever reaches.
func TestTheOperationsPromptTeachesBothKnowledgeOffers(t *testing.T) {
	prompt := ResultOperationsPrompt()
	for _, want := range []string{
		"offer_runbook_draft", "runbook_draft", "offer_kb_card", "kb_card",
		"an operator confirms",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("the operations prompt omits %q", want)
		}
	}
	for _, kind := range []string{"offer_runbook_draft", "offer_kb_card"} {
		if _, ok := resultOperationValidators[kind]; !ok {
			t.Fatalf("%s is in the prompt with no validator behind it", kind)
		}
	}
}

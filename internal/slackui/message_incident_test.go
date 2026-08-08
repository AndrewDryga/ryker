package slackui

import "testing"

// An incident offer drops the context footer, which the function has always
// said it would.
//
// The composer adds the footer upstream — ConciseEvidenceResponse appends
// "Details saved: N findings…" — so every evidence-backed reply that also
// offered an incident shipped a footer the code's own comment called
// redundant, in production as well as in the eval. Caught by the tenant
// episode-replay corpus refusing to reach its gate on 2026-08-08.
func TestWithIncidentOfferDropsTheRedundantContextFooter(t *testing.T) {
	message := Message{
		Text:    "here is what I found",
		Context: []string{"Details saved: 3 findings and 2 system areas checked."},
	}
	offered := WithIncidentOffer(message, "slack_input_1")
	if len(offered.Context) != 0 {
		t.Fatalf("incident offer kept a context footer: %q", offered.Context)
	}
	if len(offered.Actions) != 1 || offered.Actions[0].ID != ActionOpenIncident {
		t.Fatalf("incident action missing: %+v", offered.Actions)
	}
	// The boundary the footer was not carrying still has to be stated, or
	// dropping it would be removing a safety notice rather than a duplicate.
	if offered.Actions[0].Confirm == "" {
		t.Fatal("incident action lost its confirmation boundary")
	}
	// The answer itself is untouched: only the duplicated summary goes.
	if offered.Text != "here is what I found" {
		t.Fatalf("incident offer altered the reply: %q", offered.Text)
	}
}

package core

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMemoryOfferAcceptsTopicAsSubject(t *testing.T) {
	var offer MemoryOffer
	if err := json.Unmarshal([]byte(`{
		"topic":"Whole-platform health review baseline",
		"predicate":"prefers",
		"value":"the published v5 runbook",
		"scope":"workspace",
		"visibility":"operator"
	}`), &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Subject != "Whole-platform health review baseline" {
		t.Fatalf("subject = %q", offer.Subject)
	}
	encoded, err := json.Marshal(offer)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "topic") {
		t.Fatalf("alias leaked into canonical output: %s", encoded)
	}
}

// The canonical spelling has to win, or an alias could overwrite a field the
// model actually filled in.
func TestMemoryOfferPrefersSubjectOverTopic(t *testing.T) {
	var offer MemoryOffer
	if err := json.Unmarshal([]byte(`{
		"subject":"canonical","topic":"alias",
		"predicate":"prefers","value":"v5","scope":"workspace","visibility":"operator"
	}`), &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Subject != "canonical" {
		t.Fatalf("subject = %q", offer.Subject)
	}
}

func TestMemoryOfferStillRejectsUnknownFields(t *testing.T) {
	var offer MemoryOffer
	err := json.Unmarshal([]byte(`{"subject":"a","invented":"b"}`), &offer)
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unexpected error = %v", err)
	}
}

// The channel a standing rule binds to is read from the Slack input, never from
// the offer, so a model that names it is echoing a decision it does not get to
// make. Dropping the echo is safe; refusing the response over it was not.
func TestRuleOfferDropsHostOwnedChannel(t *testing.T) {
	var offer RuleOffer
	if err := json.Unmarshal([]byte(`{
		"trigger":"terraform_plan","action":"review_terraform_plan",
		"source_kind":"any","scope":"channel","channel_id":"CEVALUATION",
		"repository":"emisar"
	}`), &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Trigger != "terraform_plan" || offer.Scope != "channel" ||
		offer.Repository != "emisar" {
		t.Fatalf("rule offer = %+v", offer)
	}
	encoded, err := json.Marshal(offer)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "channel_id") {
		t.Fatalf("host-owned channel survived decoding: %s", encoded)
	}
}

func TestRuleOfferStillRejectsUnknownFields(t *testing.T) {
	var offer RuleOffer
	err := json.Unmarshal([]byte(`{"trigger":"a","action":"b","invented":"c"}`), &offer)
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unexpected error = %v", err)
	}
}

func TestDecodeModelObjectLeavesNonObjectsToTheStrictDecoder(t *testing.T) {
	var offer MemoryOffer
	err := DecodeModelObject([]byte(`["not an object"]`), map[string]string{"topic": "subject"}, &offer)
	if err == nil {
		t.Fatal("a JSON array decoded as a memory offer")
	}
}

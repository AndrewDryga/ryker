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

// A memory offer's value is the thing being remembered, and "guidance" is what
// a model called it when the remembered thing was guidance.
func TestMemoryOfferAcceptsGuidanceAsValue(t *testing.T) {
	var offer MemoryOffer
	if err := json.Unmarshal([]byte(`{
		"topic":"Whole-platform health review method",
		"predicate":"When conducting a whole-platform health assessment",
		"guidance":"Prefer the published v5 runbook as a baseline, not the whole assessment.",
		"scope":"workspace","visibility":"operator"
	}`), &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Subject == "" || offer.Value == "" {
		t.Fatalf("memory offer = %+v", offer)
	}
	var canonical MemoryOffer
	if err := json.Unmarshal([]byte(`{
		"subject":"s","predicate":"p","value":"canonical","guidance":"alias",
		"scope":"workspace","visibility":"operator"
	}`), &canonical); err != nil {
		t.Fatal(err)
	}
	if canonical.Value != "canonical" {
		t.Fatalf("value = %q", canonical.Value)
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

// "event" is what a rule fires on, which is the only thing Trigger holds.
func TestRuleOfferAcceptsEventAsTrigger(t *testing.T) {
	var offer RuleOffer
	if err := json.Unmarshal([]byte(`{
		"event":"terraform_plan","action":"review_terraform_plan",
		"source_kind":"any","scope":"channel","repository":"emisar"
	}`), &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Trigger != "terraform_plan" {
		t.Fatalf("trigger = %q", offer.Trigger)
	}
	var canonical RuleOffer
	if err := json.Unmarshal([]byte(`{
		"trigger":"canonical","event":"alias","action":"a","scope":"channel","repository":"r"
	}`), &canonical); err != nil {
		t.Fatal(err)
	}
	if canonical.Trigger != "canonical" {
		t.Fatalf("trigger = %q", canonical.Trigger)
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

package investigation

import (
	"encoding/json"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// resultOperationJSONKeys is the set of payload names a result operation really
// has, read from the struct rather than restated.
func resultOperationJSONKeys() map[string]bool {
	keys := map[string]bool{}
	value := reflect.TypeOf(ResultOperation{})
	for index := 0; index < value.NumField(); index++ {
		tag, _, _ := strings.Cut(value.Field(index).Tag.Get("json"), ",")
		if tag != "" && tag != "-" {
			keys[tag] = true
		}
	}
	return keys
}

// The prompt used to describe these payload names instead of stating them, and
// the description did not match the struct. A model followed the description
// and its whole response was rejected. Anything the prompt now writes as
// operation{key} must be a field that exists.
func TestPromptBracedPayloadKeysExist(t *testing.T) {
	keys := resultOperationJSONKeys()
	pattern := regexp.MustCompile(`([a-z_]+)\{([a-z_]+)\}`)
	matches := pattern.FindAllStringSubmatch(ResultOperationsPrompt(), -1)
	if len(matches) < 7 {
		t.Fatalf("prompt names only %d braced payload keys", len(matches))
	}
	for _, match := range matches {
		if !keys[match[2]] {
			t.Fatalf(
				"prompt tells the model %s carries %q, which is not a result operation field",
				match[1], match[2],
			)
		}
	}
}

// Every alias must name exactly one real field. An alias for a field that does
// not exist would silently discard the payload instead of reporting it.
func TestResultOperationAliasesNameRealFields(t *testing.T) {
	keys := resultOperationJSONKeys()
	for alias, canonical := range resultOperationPayloadAliases {
		if !keys[canonical] {
			t.Fatalf("alias %q maps to %q, which is not a result operation field", alias, canonical)
		}
		if keys[alias] {
			t.Fatalf("alias %q is itself a real field and must not be remapped", alias)
		}
	}
}

func TestResultOperationAcceptsOperationNamedPayloads(t *testing.T) {
	var operation ResultOperation
	if err := json.Unmarshal([]byte(`{
		"id":"preference-1","type":"offer_preference",
		"preference":{"name":"response_location","value":"prefer_thread","scope":"channel"}
	}`), &operation); err != nil {
		t.Fatal(err)
	}
	if operation.PreferenceOffer == nil || operation.PreferenceOffer.Name != "response_location" {
		t.Fatalf("preference offer = %+v", operation.PreferenceOffer)
	}
	if err := operation.Validate(); err != nil {
		t.Fatalf("aliased preference offer rejected: %v", err)
	}

	var rule ResultOperation
	if err := json.Unmarshal([]byte(`{
		"id":"rule-1","type":"offer_rule",
		"rule":{"trigger":"terraform_plan","action":"review_terraform_plan","scope":"channel","repository":"emisar"}
	}`), &rule); err != nil {
		t.Fatal(err)
	}
	if rule.RuleOffer == nil || rule.RuleOffer.Trigger != "terraform_plan" {
		t.Fatalf("rule offer = %+v", rule.RuleOffer)
	}

	var schedule ResultOperation
	if err := json.Unmarshal([]byte(`{
		"id":"schedule-1","type":"offer_schedule",
		"schedule":{"title":"Daily review","prompt":"run it","repository":"emisar","recurrence":"daily","start_at":"2026-08-10T09:00:00Z"}
	}`), &schedule); err != nil {
		t.Fatal(err)
	}
	if schedule.ScheduleOffer == nil || schedule.ScheduleOffer.Title != "Daily review" {
		t.Fatalf("schedule offer = %+v", schedule.ScheduleOffer)
	}
}

func TestResultOperationPrefersCanonicalPayloadName(t *testing.T) {
	var operation ResultOperation
	if err := json.Unmarshal([]byte(`{
		"id":"preference-1","type":"offer_preference",
		"preference_offer":{"name":"canonical","value":"v","scope":"channel"},
		"preference":{"name":"alias","value":"v","scope":"channel"}
	}`), &operation); err != nil {
		t.Fatal(err)
	}
	if operation.PreferenceOffer == nil || operation.PreferenceOffer.Name != "canonical" {
		t.Fatalf("preference offer = %+v", operation.PreferenceOffer)
	}
}

// Tolerance is for names, not for invented claims.
func TestResultOperationStillRejectsUnknownPayloads(t *testing.T) {
	var operation ResultOperation
	err := json.Unmarshal([]byte(`{
		"id":"x-1","type":"offer_preference","invented":{"name":"n"}
	}`), &operation)
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unexpected error = %v", err)
	}
}

// "memory" is the one payload name the prompt's old wording implied that the
// host cannot accept: update_memory already uses it for conversation memory.
// Aliasing it would make offer_memory and update_memory indistinguishable.
func TestMemoryIsNotAliasedToMemoryOffer(t *testing.T) {
	if _, aliased := resultOperationPayloadAliases["memory"]; aliased {
		t.Fatal("memory is aliased despite belonging to update_memory")
	}
	if !strings.Contains(ResultOperationsPrompt(), "offer_memory{memory_offer}") {
		t.Fatal("the prompt no longer tells the model offer_memory carries memory_offer")
	}
}

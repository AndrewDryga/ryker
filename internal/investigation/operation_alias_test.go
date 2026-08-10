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

// bracedPayloadPattern reads the prompt's own "operation{key}" and
// "operation{key: field,field}" notation back out of it.
var bracedPayloadPattern = regexp.MustCompile(`([a-z_]+)\{([a-z_]+)(?:: ([a-z_,]+))?\}`)

// The prompt used to describe these payload names instead of stating them, and
// the description did not match the struct. A model followed the description
// and its whole response was rejected. Anything the prompt now writes as
// operation{key} must be a field that exists.
func TestPromptBracedPayloadKeysExist(t *testing.T) {
	keys := resultOperationJSONKeys()
	matches := bracedPayloadPattern.FindAllStringSubmatch(ResultOperationsPrompt(), -1)
	// Six since propose_action{proposal} left the list. The floor only proves
	// the pattern still matches the prompt's notation at all; if it stops
	// matching, every check below passes over an empty set.
	if len(matches) < 6 {
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

// The four offer payloads are the ones the prompt now spells out field by
// field, because they were the ones it never spelled out at all — and three
// consecutive real runs each invented a different name for one of their fields
// (topic, event, guidance). A field list that drifts from the struct would
// teach the drift instead of curing it, so every name the prompt lists is
// checked against the payload's own tags.
func TestPromptOfferFieldListsMatchTheirStructs(t *testing.T) {
	operation := reflect.TypeOf(ResultOperation{})
	payloadFields := func(key string) map[string]bool {
		for index := 0; index < operation.NumField(); index++ {
			field := operation.Field(index)
			tag, _, _ := strings.Cut(field.Tag.Get("json"), ",")
			if tag != key {
				continue
			}
			payload := field.Type
			for payload.Kind() == reflect.Pointer {
				payload = payload.Elem()
			}
			names := map[string]bool{}
			for inner := 0; inner < payload.NumField(); inner++ {
				name, _, _ := strings.Cut(payload.Field(inner).Tag.Get("json"), ",")
				if name != "" && name != "-" {
					names[name] = true
				}
			}
			return names
		}
		return nil
	}
	listed := 0
	for _, match := range bracedPayloadPattern.FindAllStringSubmatch(ResultOperationsPrompt(), -1) {
		if match[3] == "" {
			continue
		}
		listed++
		fields := payloadFields(match[2])
		if fields == nil {
			t.Fatalf("prompt lists fields for %q, which is not a result operation payload", match[2])
		}
		for _, name := range strings.Split(match[3], ",") {
			if !fields[name] {
				t.Errorf("prompt tells the model %s carries %q, which %s does not have",
					match[1], name, match[2])
			}
		}
	}
	if listed != 4 {
		t.Fatalf("expected the four offer payloads to list their fields, found %d", listed)
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
	if !strings.Contains(ResultOperationsPrompt(), "offer_memory{memory_offer:") {
		t.Fatal("the prompt no longer tells the model offer_memory carries memory_offer")
	}
}

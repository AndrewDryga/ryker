package investigation

import (
	"strings"
	"testing"
)

// A format correction shows the schema for the field that failed, and only
// that field.
//
// The whole operation schema is already in every briefing — resending it
// teaches nothing and costs the same ~146KB the loop was already spending per
// round. What the recorded `unreadable` corrections carry is a validator
// sentence with no shape beside it: "result operation requires a bounded id",
// "typed result operations require exactly one complete_episode",
// "confirmed or likely alert assessment requires cause_status identified or
// bounded". Forty of these in two days.
//
// The classes are the boundary. unreadable and legacy_shape are about format,
// so a shape helps. incomplete never was — its problem is the answer, and a
// schema fragment under it is noise pointing at the wrong thing.
//
// Covers: TestFormatCorrectionsCarryTheFailingFieldSchema
func TestOnlyFormatCorrectionsCarryASchemaFragment(t *testing.T) {
	// Harvested from tenant audit_events, kind result.correction.
	recorded := []struct {
		class  string
		detail string
		wants  []string
	}{
		{
			class: "unreadable",
			detail: "the structured Slack response is invalid: invalid typed operation " +
				"stream: result operation 1: result operation requires a bounded id",
			wants: []string{`"id"`, `"type"`},
		},
		{
			class: "unreadable",
			detail: "the structured Slack response is invalid: invalid typed operation " +
				"stream: typed result operations require exactly one complete_episode",
			wants: []string{"complete_episode", `"status":"decision_ready"`},
		},
		{
			class: "unreadable",
			detail: "the structured Slack response is invalid: invalid typed operation " +
				"stream: result operation 3: result operation " +
				`"complete-website-mig-recheck-427ddd25" requires a completion message`,
			wants: []string{"complete_episode", `"message"`},
		},
		{
			class: "unreadable",
			detail: "the structured Slack response is invalid: confirmed or likely alert " +
				"assessment requires cause_status identified or bounded",
			wants: []string{"record_alert_assessment", "cause_status"},
		},
		{
			class:  "legacy_shape",
			detail: "carried its result in the legacy top-level field(s) message, memory",
			wants:  []string{`"operations"`, "complete_episode", "update_memory"},
		},
	}
	for _, testCase := range recorded {
		fragment := SchemaFragmentForCorrection(testCase.class, testCase.detail)
		if fragment == "" {
			t.Errorf("%s correction got no schema fragment: %s", testCase.class, testCase.detail)
			continue
		}
		for _, want := range testCase.wants {
			if !strings.Contains(fragment, want) {
				t.Errorf(
					"%s fragment does not carry %q:\n%s\nfor: %s",
					testCase.class, want, fragment, testCase.detail,
				)
			}
		}
	}
}

// `incomplete` gets no schema, whatever its text happens to mention. Its
// problem was never format: the answer parsed, and the host refused what it
// said. 257 of these were recorded in two days and a schema under any one of
// them would have been an answer to a question nobody asked.
func TestAnIncompleteCorrectionNeverCarriesASchemaFragment(t *testing.T) {
	recorded := []string{
		"required claims still contain unresolved contradictions: change.recent",
		"required claims do not have fresh supporting evidence: host.current_state (stale)",
		"the active issue cites absent or unrelated cause evidence; use exact evidence " +
			"ids whose claim_id is named in cause_claim_ids",
		// Deliberately names an operation and a field: the class decides, not
		// the words in the text.
		"the completed episode has no typed evidence bound to a required claim; emit " +
			"record_evidence with claim_id change.recent before completing",
	}
	for _, detail := range recorded {
		if got := SchemaFragmentForCorrection("incomplete", detail); got != "" {
			t.Errorf("an incomplete correction was given a schema fragment:\n%s\nfor: %s", got, detail)
		}
	}
	for _, class := range []string{"rejected", "shape", ""} {
		if got := SchemaFragmentForCorrection(class, "result operation requires a bounded id"); got != "" {
			t.Errorf("class %q was given a schema fragment:\n%s", class, got)
		}
	}
}

// The fragment is the failing field, not the schema. A correction that
// re-sent the whole operation list would be the briefing again, which is the
// cost this is supposed to remove.
func TestASchemaFragmentIsTheFailingFieldNotTheWholeSchema(t *testing.T) {
	fragment := SchemaFragmentForCorrection(
		"unreadable",
		"the structured Slack response is invalid: confirmed or likely alert assessment "+
			"requires cause_status identified or bounded",
	)
	if fragment == "" {
		t.Fatal("no fragment for a recorded alert-assessment rejection")
	}
	for _, unwanted := range []string{"record_repository_contents", "wait_external", "plan_goal"} {
		if strings.Contains(fragment, unwanted) {
			t.Errorf("the fragment carries unrelated operation %q:\n%s", unwanted, fragment)
		}
	}
	if size := len(fragment); size > 1200 {
		t.Errorf("fragment is %d bytes; a fragment that large is the schema again", size)
	}
}

// A parse error with no identifiable field gets no fragment rather than a
// guessed one. `unexpected EOF` and `invalid character '{' looking for
// beginning of object key string` are both recorded, and neither names a field
// that could be shown.
func TestAParseErrorNamingNoFieldGetsNoFragment(t *testing.T) {
	for _, detail := range []string{
		"the structured Slack response is invalid: unexpected EOF",
		"the structured Slack response is invalid: invalid character '{' looking for " +
			"beginning of object key string",
	} {
		if got := SchemaFragmentForCorrection("unreadable", detail); got != "" {
			t.Errorf("a fragment was guessed for an unlocatable failure:\n%s\nfor: %s", got, detail)
		}
	}
}

// An invented field name is answered with the operation that carries what it
// was reaching for, in one round.
//
// tenant run_a162e8457a76089aa94ea5264cc1e61c spent five correction rounds
// inside two minutes guessing the name of a recurrence: `frequency` at
// 07:26:13, `schedule_type` at 07:26:36, `cadence` at 07:26:58, `schedule` at
// 07:27:15, `daily` at 07:28:13. Each round threw the whole envelope away and
// handed back `json: unknown field "<the guess>"`, which is an invitation to
// guess again and nothing else; the run finished with failure_count 9 on an
// answer whose substance never changed. The operation it wanted the entire time
// was offer_schedule.
//
// 79445e8 excluded these deliberately, on the reasoning that "an unknown field
// has no schema by definition". True of the field, and false of the answer: an
// unknown-field error is the one parse failure that does name something, and
// the name is enough to point at the operation that carries it.
func TestAnInventedFieldIsAnsweredWithTheOperationThatCarriesIt(t *testing.T) {
	// Harvested from tenant audit_events, kind result.correction, one run.
	for _, field := range []string{"frequency", "schedule_type", "cadence", "schedule", "daily"} {
		detail := `the structured Slack response is invalid: json: unknown field "` + field + `"`
		fragment := SchemaFragmentForCorrection("unreadable", detail)
		if fragment == "" {
			t.Errorf("%q got no fragment, so the next round is another guess", field)
			continue
		}
		for _, want := range []string{field, "offer_schedule", "schedule_offer", "recurrence"} {
			if !strings.Contains(fragment, want) {
				t.Errorf("the %q fragment does not carry %q:\n%s", field, want, fragment)
			}
		}
	}

	// The completion's own fields, named one level too high, and the evidence
	// fields reached for outside record_evidence. All recorded the same way.
	for _, testCase := range []struct {
		field string
		wants []string
	}{
		{field: "material_gaps", wants: []string{"material_gaps", "blocker_kind"}},
		{field: "next_action", wants: []string{"next_action"}},
		{field: "message", wants: []string{"complete_episode", `"message"`}},
		{field: "claim_id", wants: []string{"claim_id", "record_evidence"}},
	} {
		fragment := SchemaFragmentForCorrection(
			"unreadable",
			`the structured Slack response is invalid: json: unknown field "`+testCase.field+`"`,
		)
		if fragment == "" {
			t.Errorf("%q got no fragment", testCase.field)
			continue
		}
		for _, want := range testCase.wants {
			if !strings.Contains(fragment, want) {
				t.Errorf("the %q fragment does not carry %q:\n%s", testCase.field, want, fragment)
			}
		}
	}
}

// A field that maps to no operation is told it exists nowhere, and pointed at
// the list, rather than given a fragment for whatever it happened to resemble.
//
// A fragment for the wrong field is worse than none, because it reads as the
// host having identified the problem. `id_note` is recorded and names nothing
// at all; the answer to it is that no operation carries that key, not a schema
// picked because "id" appears in both.
func TestAFieldNoOperationCarriesIsNamedRatherThanGuessedAt(t *testing.T) {
	for _, field := range []string{"id_note", "claim_placeholder", "conclusion_kind"} {
		fragment := SchemaFragmentForCorrection(
			"unreadable",
			`the structured Slack response is invalid: json: unknown field "`+field+`"`,
		)
		if fragment == "" {
			t.Errorf("%q was answered with silence", field)
			continue
		}
		if !strings.Contains(fragment, field) {
			t.Errorf("the answer for %q does not name it:\n%s", field, fragment)
		}
		if !strings.Contains(fragment, "no result operation") {
			t.Errorf("the answer for %q does not say the field exists nowhere:\n%s", field, fragment)
		}
		if strings.Contains(fragment, "Minimal valid example") {
			t.Errorf("an unmapped field was given a schema for something else:\n%s", fragment)
		}
	}

	// The class still decides. An incomplete correction that happens to quote a
	// decoder error gets nothing, as it always did.
	if got := SchemaFragmentForCorrection(
		"incomplete", `json: unknown field "schedule"`,
	); got != "" {
		t.Errorf("an incomplete correction was given an unknown-field answer:\n%s", got)
	}
}

package investigation

import (
	"regexp"
	"strings"
)

// Schema fragments for the correction classes that are about format.
//
// The whole operation schema is already in every briefing. Resending it in a
// correction teaches nothing and costs the round the same ~146KB it was
// already spending, so what goes back is the shape of exactly the field that
// failed, plus one minimal valid example of it.
//
// Two classes qualify and no others. `unreadable` (40 in two days) and
// `legacy_shape` (3) are both statements about the envelope: the answer could
// not be read, or it arrived in the transport the typed stream replaced. A
// shape is the useful reply to both. `incomplete` (257 in two days) is a
// statement about the answer — it parsed, and the host refused what it said —
// and a schema underneath it points at the wrong thing entirely. First-try
// rates say the same from the other direction: format is mostly learned on the
// first attempt already, so more schema is not what the loop was short of.

// formatCorrectionClasses are the classes whose problem is the envelope.
var formatCorrectionClasses = map[string]bool{
	"unreadable":   true,
	"legacy_shape": true,
}

// schemaFragment pairs a recorded validator phrase with the shape of the field
// it names. Ordered most specific first: the first match wins, so a
// complete_episode failure that also mentions an operation id shows the
// completion shape rather than the id shape.
type schemaFragment struct {
	// matches are lowercase substrings of the recorded correction text. Any
	// one of them selects this fragment.
	matches []string
	// field names what failed, in the words the model can search the briefing
	// for.
	field string
	// shape is the schema fragment for that field.
	shape string
	// example is one minimal valid instance of it.
	example string
}

var schemaFragments = []schemaFragment{
	{
		matches: []string{"complete_episode", "completion message"},
		field:   "complete_episode",
		shape: `{"id":<string>,"type":"complete_episode","completion":{"message":<string>,` +
			`"completion":{"status":"decision_ready"|"blocked","summary":<string>}}}`,
		example: `{"id":"complete-1","type":"complete_episode","completion":` +
			`{"message":"The alert condition cleared at 03:18 UTC.","completion":` +
			`{"status":"decision_ready","summary":"Recovered; no action needed."}}}`,
	},
	{
		matches: []string{"cause_status", "alert assessment", "cause_claim_ids"},
		field:   "record_alert_assessment",
		shape: `{"id":<string>,"type":"record_alert_assessment","alert_assessment":` +
			`{"verdict":"confirmed_issue"|"likely_issue"|"not_issue"|"unverified",` +
			`"cause_status":"identified"|"bounded"|"unverified","cause":<string>,` +
			`"cause_claim_ids":[<claim_id>],"evidence_refs":[<record_evidence id>]}}`,
		example: `{"id":"alert-1","type":"record_alert_assessment","alert_assessment":` +
			`{"verdict":"not_issue","cause_status":"bounded","cause":"transient disk latency",` +
			`"cause_claim_ids":["host.current_state"],"evidence_refs":["evidence-1"]}}`,
	},
	{
		matches: []string{"confidence"},
		field:   "evidence.confidence",
		shape:   `"confidence":"high"|"medium"|"low"`,
		example: `{"id":"evidence-1","type":"record_evidence","evidence":{"claim_id":` +
			`"host.current_state","observation":"nomad-hst02 responsive","relation":"supports",` +
			`"source_type":"emisar","source_name":"Emisar Nomad snapshot","confidence":"high"}}`,
	},
	{
		matches: []string{"claim_id"},
		field:   "evidence.claim_id",
		shape:   `"claim_id":<exact required_claims id from the host contract>`,
		example: `{"id":"evidence-1","type":"record_evidence","evidence":{"claim_id":` +
			`"host.current_state","observation":"nomad-hst02 responsive","relation":"supports",` +
			`"source_type":"emisar","source_name":"Emisar Nomad snapshot","confidence":"high"}}`,
	},
	{
		matches: []string{"coverage", "layer"},
		field:   "record_coverage",
		shape: `{"id":<string>,"type":"record_coverage","coverage":{"layer":<contract layer>,` +
			`"claim_ids":[<claim_id>],"status":"healthy"|"degraded"|"unhealthy"|"unknown"|` +
			`"not_applicable","detail":<string>}}`,
		example: `{"id":"coverage-host","type":"record_coverage","coverage":{"layer":"host",` +
			`"claim_ids":["host.current_state"],"status":"healthy","detail":"all five nodes responsive"}}`,
	},
	{
		matches: []string{"blocker_kind", "blocked completion"},
		field:   "completion blocked fields",
		shape: `"completion":{"status":"blocked","summary":<string>,"material_gaps":[<string>],` +
			`"blocker_kind":"source_unavailable"|"access_denied"|"operator_input_required"|` +
			`"authority_boundary"|"tool_failure"|"capability_unavailable","attempts":[<string>],` +
			`"next_action":<string>}`,
		example: `{"status":"blocked","summary":"The rollout state cannot be read.",` +
			`"material_gaps":["Nomad allocation status"],"blocker_kind":"source_unavailable",` +
			`"attempts":["Emisar nomad snapshot"],"next_action":"Restore the Nomad API route."}`,
	},
	{
		matches: []string{"schedule_offer"},
		field:   "offer_schedule",
		shape: `{"id":<string>,"type":"offer_schedule","schedule_offer":{"title":<string>,` +
			`"prompt":<string>,"repository":<string>,"recurrence":"once"|"interval"|"daily"|` +
			`"weekly"|"monthly","start_at":<RFC3339>,"local_time":"HH:MM","timezone":<IANA name>}}`,
		example: `{"id":"schedule-1","type":"offer_schedule","schedule_offer":{"title":` +
			`"Daily platform health report","prompt":"Run the published whole-platform health ` +
			`review and report the verdict here.","repository":"tenant-infra","recurrence":"daily",` +
			`"local_time":"09:00","timezone":"America/Merida"}}`,
	},
	{
		matches: []string{"update_memory", "memory"},
		field:   "update_memory",
		shape:   `{"id":<string>,"type":"update_memory","memory":{...}}`,
		example: `{"id":"memory-1","type":"update_memory","memory":{"scope":"channel",` +
			`"subject":"va1","predicate":"disk latency alert","value":"cleared 03:18 UTC"}}`,
	},
	{
		// Last of the operation-shaped matches: a bounded id is the field every
		// operation carries, so anything more specific above wins first.
		matches: []string{"bounded id", "operation id", "unique stable id"},
		field:   "operation id",
		shape:   `{"id":<unique stable string within this operations array>,"type":<operation type>,...}`,
		example: `{"id":"evidence-1","type":"record_evidence","evidence":{...}}`,
	},
}

// legacyOperationsFragment is the envelope shape a legacy_shape correction is
// asking for. The prose already names which operation each legacy field maps
// to; this is the array those operations go in.
const legacyOperationsFragment = `"operations":[<operation>,...] — each operation is ` +
	`{"id":<unique stable string>,"type":<operation type>,<payload key>:{...}}`

const legacyOperationsExample = `{"operations":[{"id":"complete-1","type":"complete_episode",` +
	`"completion":{"message":"Slack Markdown answer","completion":{"status":"decision_ready",` +
	`"summary":"concise decision"}}},{"id":"memory-1","type":"update_memory","memory":{...}}]}`

// unknownFieldPattern pulls the field name out of a strict-decoder rejection.
// It is the one parse failure that names something.
var unknownFieldPattern = regexp.MustCompile(`unknown field "([^"]+)"`)

// unknownFieldOperations maps a name no schema carries onto the fragment that
// answers what it was reaching for.
//
// tenant run_a162e8457a76089aa94ea5264cc1e61c spent five correction rounds
// inside two minutes on the first six entries: `frequency`, `schedule_type`,
// `cadence`, `schedule`, then `daily`, each one throwing the whole envelope
// away and handing back the name of the guess. Every one of them wanted
// offer_schedule, and the run finished with failure_count 9 on an answer whose
// substance never changed between rounds.
//
// Entries are only for names that can mean one operation. `summary` is
// deliberately absent — progress and completion both carry one — and so is
// every real payload key, which fails for being in the wrong place rather than
// for existing. claim_id and confidence are here to keep by intent what the
// substring table below was doing by accident.
var unknownFieldOperations = map[string]string{
	"schedule": "offer_schedule", "schedule_type": "offer_schedule",
	"recurrence": "offer_schedule", "cadence": "offer_schedule",
	"frequency": "offer_schedule", "daily": "offer_schedule",
	"material_gaps": "completion blocked fields", "next_action": "completion blocked fields",
	"blocker_kind": "completion blocked fields", "attempts": "completion blocked fields",
	"message": "complete_episode", "answer": "complete_episode",
	"claim_id": "evidence.claim_id", "confidence": "evidence.confidence",
}

// unknownFieldAnswer names the invented field and, where it can only have meant
// one operation, shows that operation's shape.
//
// 79445e8 excluded these on the reasoning that "an unknown field has no schema
// by definition". True of the field and false of the answer: the model is
// reaching for a real capability under the wrong name, and the host knows both
// the name it used and the operation that carries it. An unmapped field still
// gets no schema — a fragment for the wrong field reads as the host having
// identified the problem — but it is told the field exists nowhere, which is
// the fact that stops the next round being another guess.
func unknownFieldAnswer(detail string) string {
	match := unknownFieldPattern.FindStringSubmatch(detail)
	if match == nil {
		return ""
	}
	field := match[1]
	preface := `no result operation carries a field named "` + field + `"`
	target, mapped := unknownFieldOperations[field]
	if !mapped {
		return "\n\n<host-unknown-field name=\"" + field + "\">\n" + preface +
			". Use the operation from the contract's result_operations list that carries what " +
			"you meant, under that operation's own payload key.\n</host-unknown-field>"
	}
	for _, fragment := range schemaFragments {
		if fragment.field == target {
			return renderSchemaFragment(
				target, preface+"; "+target+" does.\n"+fragment.shape, fragment.example,
			)
		}
	}
	return ""
}

// SchemaFragmentForCorrection returns the schema for exactly the field a
// format correction names, with one minimal valid example, or "" when the
// class is not about format or no field can be located.
//
// Guessing is refused on purpose. `unexpected EOF` and `invalid character '{'
// looking for beginning of object key string` are both recorded, and neither
// names a field that could be shown. A fragment for the wrong field is worse
// than none, because it reads as the host having identified the problem.
func SchemaFragmentForCorrection(correctionClass, detail string) string {
	if !formatCorrectionClasses[correctionClass] || strings.TrimSpace(detail) == "" {
		return ""
	}
	lower := strings.ToLower(detail)
	if correctionClass == "legacy_shape" {
		return renderSchemaFragment(
			"operations", legacyOperationsFragment, legacyOperationsExample,
		)
	}
	// Before the substring table, so a named field is answered by the name the
	// decoder printed rather than by whatever phrase it happens to contain.
	if answer := unknownFieldAnswer(detail); answer != "" {
		return answer
	}
	for _, fragment := range schemaFragments {
		for _, match := range fragment.matches {
			if strings.Contains(lower, match) {
				return renderSchemaFragment(fragment.field, fragment.shape, fragment.example)
			}
		}
	}
	return ""
}

func renderSchemaFragment(field, shape, example string) string {
	return "\n\n<host-schema-fragment field=\"" + field + "\">\n" +
		shape + "\nMinimal valid example: " + example +
		"\n</host-schema-fragment>"
}

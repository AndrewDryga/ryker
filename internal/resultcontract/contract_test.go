package resultcontract

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
)

func TestPublishedSchemaHasNoDuplicateObjectProperties(t *testing.T) {
	decoder := json.NewDecoder(bytes.NewReader(Schema()))
	if err := rejectDuplicateObjectProperties(decoder, "$schema"); err != nil {
		t.Fatal(err)
	}
	if _, err := decoder.Token(); !isEOF(err) {
		t.Fatalf("schema has trailing JSON: %v", err)
	}
}

func rejectDuplicateObjectProperties(decoder *json.Decoder, path string) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, composite := token.(json.Delim)
	if !composite {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]struct{}{}
		for decoder.More() {
			nameToken, nameErr := decoder.Token()
			if nameErr != nil {
				return nameErr
			}
			name, ok := nameToken.(string)
			if !ok {
				return fmt.Errorf("%s has a non-string property name", path)
			}
			if _, duplicate := seen[name]; duplicate {
				return fmt.Errorf("%s repeats property %q", path, name)
			}
			seen[name] = struct{}{}
			if err := rejectDuplicateObjectProperties(decoder, path+"/"+name); err != nil {
				return err
			}
		}
	case '[':
		for index := 0; decoder.More(); index++ {
			if err := rejectDuplicateObjectProperties(decoder, fmt.Sprintf("%s/%d", path, index)); err != nil {
				return err
			}
		}
	default:
		return fmt.Errorf("%s starts with unexpected delimiter %q", path, delimiter)
	}
	_, err = decoder.Token()
	return err
}

func isEOF(err error) bool { return err == io.EOF }

func TestRecordedResultFromTheCorrectionLoopMatchesThePublishedSchema(t *testing.T) {
	// This is the first real reply from episode_run_6f5409ee1bc67c42adf6ed2c08040dda,
	// not a synthetic example. The host rejected it because prompt and validator
	// read different evidence ledgers; its JSON contract itself must stay valid.
	raw, err := os.ReadFile("../service/testdata/live_ads_continuity_first_turn.txt")
	if err != nil {
		t.Fatal(err)
	}
	if err := Validate(raw); err != nil {
		t.Fatalf("the recorded production result does not match the published schema: %v", err)
	}
}

func TestSchemaRejectsTheResultMistakesThatConsumedCorrectionTurns(t *testing.T) {
	valid := `{"operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"Done.","completion":{"status":"decision_ready","summary":"Done."}}}]}`
	if err := Validate([]byte(valid)); err != nil {
		t.Fatalf("minimal canonical result was rejected: %v", err)
	}
	for _, test := range []struct {
		name string
		raw  string
		path string
	}{
		{
			name: "integer evidence confidence",
			raw: `{"operations":[
				{"id":"e1","type":"record_evidence","evidence":{"claim_id":"task.result","claim":"c","observation":"o","relation":"supports","source_type":"repository","source_name":"repo","freshness":"current","confidence":3,"dimensions":{}}},
				{"id":"complete-1","type":"complete_episode","completion":{"message":"Done.","completion":{"status":"decision_ready","summary":"Done."}}}
			]}`,
			path: "/operations/0/evidence/confidence",
		},
		{
			name: "bare operation noun",
			raw:  `{"operations":[{"id":"a1","type":"alert_assessment","alert_assessment":{"verdict":"unverified","impact":"unknown","immediate_action_kind":"investigation","immediate_action":"inspect"}},{"id":"complete-1","type":"complete_episode","completion":{"message":"Blocked.","completion":{"status":"decision_ready","summary":"Blocked."}}}]}`,
			path: "/operations/0/type",
		},
		{
			name: "payload does not match type",
			raw:  `{"operations":[{"id":"e1","type":"record_evidence","coverage":{"layer":"task","claim_ids":["task.result"],"status":"healthy","source":"test","detail":"ok"}},{"id":"complete-1","type":"complete_episode","completion":{"message":"Done.","completion":{"status":"decision_ready","summary":"Done."}}}]}`,
			path: "/operations/0",
		},
		{
			name: "host owned evidence id",
			raw: `{"operations":[
				{"id":"e1","type":"record_evidence","evidence":{"id":"host-row","claim_id":"task.result","claim":"c","observation":"o","relation":"supports","source_type":"repository","source_name":"repo","freshness":"current","confidence":"high","dimensions":{}}},
				{"id":"complete-1","type":"complete_episode","completion":{"message":"Done.","completion":{"status":"decision_ready","summary":"Done."}}}
			]}`,
			path: "/operations/0/evidence",
		},
		{
			name: "partial blocked completion",
			raw:  `{"operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"Blocked.","completion":{"status":"blocked","summary":"Cannot decide."}}}]}`,
			path: "/operations/0/completion/completion",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := Validate([]byte(test.raw))
			if err == nil {
				t.Fatal("invalid result matched the schema")
			}
			if !strings.Contains(err.Error(), test.path) {
				t.Fatalf("validation error does not identify %s: %v", test.path, err)
			}
		})
	}
}

func TestSchemaReportsEveryIndependentRepairInOnePass(t *testing.T) {
	raw := `{"operations":[
		{"id":"e1","type":"record_evidence","evidence":{"claim_id":"task.result","claim":"c","observation":"o","relation":"supports","source_type":"repository","source_name":"repo","freshness":"current","confidence":3,"dimensions":{}}},
		{"id":"coverage-1","type":"record_coverage","coverage":{"layer":"configuration","claim_ids":[],"status":"fine","source":"test","detail":"ok"}},
		{"id":"complete-1","type":"complete_episode","completion":{"message":"Done.","completion":{"status":"decision_ready","summary":"Done."}}}
	]}`
	err := Validate([]byte(raw))
	if err == nil {
		t.Fatal("invalid result matched the schema")
	}
	for _, path := range []string{
		"/operations/0/evidence/confidence",
		"/operations/1/coverage/layer",
		"/operations/1/coverage/claim_ids",
		"/operations/1/coverage/status",
	} {
		if !strings.Contains(err.Error(), path) {
			t.Fatalf("one-pass validation omitted %s: %v", path, err)
		}
	}
}

func TestSchemaMatchesHostStaticResultRules(t *testing.T) {
	complete := `{"id":"complete-1","type":"complete_episode","completion":{"message":"Done.","completion":{"status":"decision_ready","summary":"Done."}}}`
	agent := func(operation string) string {
		return `{"operations":[` + operation + `,` + complete + `]}`
	}
	for _, test := range []struct {
		name  string
		raw   string
		valid bool
	}{
		{
			name:  "daily schedule defaults start time",
			raw:   agent(`{"id":"schedule-1","type":"offer_schedule","schedule_offer":{"title":"Daily check","prompt":"Check the service.","repository":"repo","recurrence":"daily","local_time":"09:00","timezone":"UTC"}}`),
			valid: true,
		},
		{
			name: "one-time schedule requires start time",
			raw:  agent(`{"id":"schedule-1","type":"offer_schedule","schedule_offer":{"title":"One check","prompt":"Check the service.","repository":"repo","recurrence":"once"}}`),
		},
		{
			name: "interval has the host minimum",
			raw:  agent(`{"id":"schedule-1","type":"offer_schedule","schedule_offer":{"title":"Fast check","prompt":"Check the service.","repository":"repo","recurrence":"interval","interval_seconds":60}}`),
		},
		{
			name: "calendar time has a real hour",
			raw:  agent(`{"id":"schedule-1","type":"offer_schedule","schedule_offer":{"title":"Daily check","prompt":"Check the service.","repository":"repo","recurrence":"daily","local_time":"24:00","timezone":"UTC"}}`),
		},
		{
			name: "operation id follows host 80-byte limit",
			raw:  agent(`{"id":"` + strings.Repeat("x", 81) + `","type":"record_feedback","feedback":{"category":"reliability","sentiment":"negative","summary":"looped"}}`),
		},
		{
			name: "metadata values match string map decoder",
			raw:  agent(`{"id":"evidence-1","type":"record_evidence","evidence":{"claim_id":"task.result","observation":"observed","source_type":"monitoring","source_name":"probe","metadata":{"attempt":2}}}`),
		},
		{
			name:  "dimension values keep scalar compatibility",
			raw:   agent(`{"id":"evidence-1","type":"record_evidence","evidence":{"claim_id":"task.result","observation":"observed","source_type":"monitoring","source_name":"probe","dimensions":{"attempt":2,"ready":true}}}`),
			valid: true,
		},
		{
			name: "completion assessment is mandatory",
			raw:  `{"operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"Done."}}]}`,
		},
		{
			name: "blocked completion cannot claim a verdict",
			raw:  `{"operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"Blocked.","completion":{"status":"blocked","verdict":"failed","summary":"Cannot inspect.","material_gaps":["live state"],"blocker_kind":"source_unavailable","attempts":["queried source"],"next_action":"restore source"}}}]}`,
		},
		{
			name: "recheck uses host bounds",
			raw:  `{"operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"Blocked.","completion":{"status":"blocked","summary":"Cannot inspect.","material_gaps":["live state"],"blocker_kind":"source_unavailable","attempts":["queried source"],"next_action":"restore source","recheck":{"key":"provider:source","reason":"temporary outage","after_seconds":5,"additional_attempts":8}}}}]}`,
		},
		{
			name: "Slack reaction follows the host name grammar",
			raw:  `{"action":"react","reaction":"bad reaction!","operations":[]}`,
		},
		{
			name: "reply cannot also carry a reaction",
			raw:  `{"action":"reply","reaction":"eyes","operations":[` + complete + `]}`,
		},
		{
			name: "escalation requires a reason",
			raw:  `{"action":"escalate","operations":[]}`,
		},
		{
			name: "material attention needs an addressee and contribution",
			raw:  `{"action":"ignore","attention":{"material":true,"contribution":"none"},"operations":[]}`,
		},
		{
			name: "publication updates use the host cardinality",
			raw: `{"action":"ignore","publication_updates":[
				{"incident_id":"i","kind":"deployment","state":"pending","reference":"r1","summary":"s"},
				{"incident_id":"i","kind":"deployment","state":"pending","reference":"r2","summary":"s"},
				{"incident_id":"i","kind":"terraform","state":"succeeded","reference":"r3","summary":"s"},
				{"incident_id":"i","kind":"terraform","state":"failed","reference":"r4","summary":"s"},
				{"incident_id":"i","kind":"deployment","state":"pending","reference":"r5","summary":"s"}
			],"operations":[]}`,
		},
		{
			name: "publication update kind follows the host enum",
			raw:  `{"action":"ignore","publication_updates":[{"incident_id":"i","kind":"release","state":"done","reference":"r","summary":"s"}],"operations":[]}`,
		},
		{
			name: "pull request reference uses the host bound",
			raw:  `{"action":"reply","task_pull_request":"` + strings.Repeat("x", 501) + `","operations":[` + complete + `]}`,
		},
		{
			name: "pull request reference requires a task offer",
			raw:  `{"action":"reply","task_pull_request":"https://github.com/acme/repo/pull/1","operations":[` + complete + `]}`,
		},
		{
			name: "singleton operations cannot pass preflight twice",
			raw: agent(`{"id":"memory-1","type":"update_memory","memory":{"goal":"first"}},` +
				`{"id":"memory-2","type":"update_memory","memory":{"goal":"second"}}`),
		},
		{
			name: "task offer fields use the reply projection bounds",
			raw: agent(`{"id":"task-1","type":"offer_task","task":{"kind":"engineering","title":"` +
				strings.Repeat("x", 201) + `","repository":"repo","prompt":"fix it"}}`),
		},
		{
			name:  "silent wait is a valid ignore",
			raw:   `{"action":"ignore","operations":[{"id":"wait-1","type":"wait_external","external_wait":{"id":"deploy-1","kind":"deployment","poll_after":"2026-08-20T18:00:00Z"}}]}`,
			valid: true,
		},
		{
			name: "ignore cannot hide arbitrary operations",
			raw:  `{"action":"ignore","operations":[{"id":"feedback-1","type":"record_feedback","feedback":{"category":"reliability","sentiment":"negative","summary":"looped"}}]}`,
		},
		{
			name: "escalate cannot carry an operation stream",
			raw:  `{"action":"escalate","reason":"operator needed","operations":[{"id":"feedback-1","type":"record_feedback","feedback":{"category":"reliability","sentiment":"negative","summary":"looped"}}]}`,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := Validate([]byte(test.raw))
			if test.valid && err != nil {
				t.Fatalf("valid result rejected: %v", err)
			}
			if !test.valid && err == nil {
				t.Fatal("invalid result matched the schema")
			}
		})
	}
}

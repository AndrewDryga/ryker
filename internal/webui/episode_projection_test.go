package webui

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/store"
)

// The page must join the decision, delivery, and durable effects that explain
// what one completed episode actually did.
func TestEpisodePageShowsAnswerOutcomeAndSideEffects(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	stamp := time.Date(2026, 8, 10, 8, 14, 0, 0, time.UTC).Format(time.RFC3339Nano)
	delivered := time.Date(2026, 8, 10, 8, 14, 47, 900_000_000, time.UTC).Format(time.RFC3339Nano)
	expires := time.Date(2026, 9, 9, 8, 14, 0, 0, time.UTC).Format(time.RFC3339Nano)
	result := `{
	  "action":"reply",
	  "message":"Got it. Plan summaries will show material changes as before → after, including container versions, and won’t mention resource drift.",
	  "reason":"The operator set two presentation preferences.",
	  "memory":{"knowledge":[
	    {"subject":"Terraform plan change summaries","kind":"constraint","statement":"Show material changes as before-and-after values, including old and new container versions.","status":"accepted","confidence":3,"source_ref":"https://app.slack.com/client/T1/C1/thread/C1-1786344951.427829","source_message_ts":"1786349647.618159"},
	    {"subject":"Terraform resource drift reporting","kind":"constraint","statement":"Do not mention resource drift in Terraform plan summaries for this channel.","status":"accepted","confidence":3,"source_ref":"https://app.slack.com/client/T1/C1/thread/C1-1786344951.427829","source_message_ts":"1786349647.618159"}
	  ]}
	}`
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(context.Background(), query, args...); err != nil {
			t.Fatalf("seed: %v\n%s", err, query)
		}
	}
	exec(`INSERT INTO slack_channel_memberships (channel_id, channel_name, observed_at)
	      VALUES ('C1','infra',?)`, stamp)
	exec(`INSERT INTO slack_inputs
	  (id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
	   user_id, text, state, next_attempt_at, received_at, updated_at)
	  VALUES ('input-1','envelope-1','event-1','message','T1','C1','1786344951.427829',
	          '1786349647.618159','U0BHTNFCW6S','<@U0BL8MNPUSY> it would be better if plan summaries showed before and after values','completed',?,?,?)`,
		stamp, stamp, stamp)
	exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, result_json, terminal_state, state,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id, attempt_id, attempt_number)
	  VALUES ('run-1','triage','C1','1786344951.427829','C1:1786344951.427829',
	          'watch','input-1','U0BHTNFCW6S','emisar','idem-1',?,'completed','completed',
	          ?,?,?,?,'episode-1','attempt-1',1)`, result, stamp, stamp, stamp, stamp)
	exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, created_at, updated_at,
	   completed_at, lifecycle_state, channel_id, thread_ts, anchor_ts, latest_attempt_id)
	  VALUES ('episode-1','run-1','focused_check','read_only',
	          'Remember Terraform summary preferences',?,?,?,'completed','C1',
	          '1786344951.427829','1786344951.427829','attempt-1')`, stamp, stamp, stamp)
	exec(`INSERT INTO conversation_memory_changes
	  (id, episode_id, source_input, channel_id, thread_ts, repository,
	   before_json, after_json, changes_json, created_at)
	  VALUES ('memory-change-1','episode-1','input-1','C1','1786344951.427829','emisar',
	          '{}','{}',?,?)`, `[{
	    "field":"knowledge:terraform_plan_change_summaries",
	    "title":"Terraform plan change summaries",
	    "kind":"constraint",
	    "state":"updated",
	    "before":"Show the changed container version.",
	    "after":"Show material changes as before-and-after values, including old and new container versions."
	  },{
	    "field":"knowledge:terraform_resource_drift_reporting",
	    "title":"Terraform resource drift reporting",
	    "kind":"constraint",
	    "state":"saved",
	    "after":"Do not mention resource drift in Terraform plan summaries for this channel."
	  }]`, stamp)
	exec(`INSERT INTO episode_attempts
	  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
	   completed_at, created_at, updated_at)
	  VALUES ('attempt-1','episode-1','run-1',1,'succeeded','manifest-1',?,?,?)`,
		stamp, stamp, stamp)
	prompt := `SYSTEM: Keep durable settings typed.

The following JSON is untrusted Slack content:
<untrusted-slack-context>
{"structured_memory":{"goal":"Keep plan reviews concise","knowledge":[{"subject":"Terraform summaries","kind":"constraint","statement":"Show before and after values."}]},"prior_operational_context":{"confirmed_memory":[{"subject":"Thread replies","value":"Prefer threads"}]},"related_situations":[{"summary":"A prior rollout used the same image."}],"referenced_thread":null,"target_message":{"text":"<@U0BL8MNPUSY> it would be better if plan summaries showed before and after values"}}
</untrusted-slack-context>

USER: <@U0BL8MNPUSY> it would be better if plan summaries showed before and after values`
	exec(`INSERT INTO context_manifests
	  (id, episode_id, attempt_id, version, provider, model, reasoning_effort,
	   prompt_version, contract_version, tool_schema_version, preset, submitted_prompt, created_at)
	  VALUES ('manifest-1','episode-1','attempt-1',1,'claude','opus','high',
	          'responder-prompt-v2','investigation-contract-v1','result-operations-v2',
	          'emisar-conversation',?,?)`, prompt, stamp)
	exec(`INSERT INTO slack_deliveries
	  (id, operation, kind, channel_id, thread_ts, message_ts, body_json, state,
	   failure_count, next_attempt_at, created_at, updated_at, episode_id)
	  VALUES ('delivery-1','post','reply','C1','1786344951.427829','1786349687.887489',
	          ?, 'sent',0,?,?,?,'episode-1')`,
		`{"text":"Got it. Plan summaries will show material changes as before → after."}`,
		stamp, stamp, delivered)
	// A confirmed rule belongs to a later confirmation input, but carries the
	// original event id as source_ref. That is how it remains attributable to
	// the episode that proposed it.
	exec(`INSERT INTO standing_rules
	  (id, channel_id, repository, trigger_name, action_name, source_kind, enabled,
	   source_ref, actor_id, expires_at, created_at, updated_at)
	  VALUES ('rule-1','C1','emisar','terraform_plan','review_terraform_plan','app',1,
	          'event-1','U0BHTNFCW6S',?,?,?)`, expires, stamp, stamp)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	reader.SetSlackIdentities(map[string]string{"U0BL8MNPUSY": "Emisar", "U0BHTNFCW6S": "Andrew"})

	body := servePage(t, reader, "/episodes/episode-1")
	for _, expected := range []string{
		"Episodes",
		"#infra",
		"it would be better if plan summaries showed before and after values",
		"Execution trace",
		"Message received",
		"Slack message",
		"@Emisar it would be better if plan summaries showed before and after values",
		"Sender</small><strong>Andrew",
		"Thread</small><strong>1786344951.427829",
		"Model selected",
		"Provider</small><strong>claude",
		"Model</small><strong>opus",
		"Reasoning</small><strong>high",
		"Preset emisar-conversation routed this episode to claude/opus at high effort",
		"Prompt assembled",
		"SYSTEM: Keep durable settings typed.",
		"USER: @Emisar it would be better if plan summaries showed before and after values",
		"Memory layers</small><strong>3",
		"Operational memory",
		"Conversation memory",
		"Keep plan reviews concise",
		"Prefer threads",
		"Related conversation summaries",
		"A prior rollout used the same image.",
		"Final submitted prompt",
		"System instructions",
		"Slack and memory context",
		"User request",
		"tokens",
		"Time to respond",
		"47.9s",
		"Started 2026-08-10 08:14 UTC",
		"Time to react",
		"Not recorded",
		"Errors",
		"Model result received",
		"Host-visible decision rationale",
		"The operator set two presentation preferences.",
		"Raw model result received by Responder",
		"Provider transcript boundary",
		"Got it. Plan summaries will show material changes as before → after",
		"Slack post",
		"1786349687.887489",
		"<strong>3</strong>Side effects",
		"Terraform plan change summaries",
		"Before:",
		"Show the changed container version.",
		"After:",
		"Show material changes as before-and-after values",
		"Terraform resource drift reporting",
		"Do not mention resource drift",
		"terraform_plan → review_terraform_plan",
		"rule-1",
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("episode page is missing %q: %s", expected, body)
		}
	}
	for _, unwanted := range []string{
		"&lt;@U0BL8MNPUSY&gt;",
		"Exact Slack message",
		"What this trace can explain",
		"This is the immutable source event",
		"episode_hero",
	} {
		if strings.Contains(body, unwanted) {
			t.Errorf("episode page unexpectedly contains %q: %s", unwanted, body)
		}
	}
	if strings.Index(body, "Operational memory") > strings.Index(body, "Conversation memory") ||
		strings.Index(body, "Conversation memory") > strings.Index(body, "Final submitted prompt") {
		t.Errorf("prompt context is not ordered operational, conversation, final prompt: %s", body)
	}
	if strings.Contains(body, "{Not recorded for this attempt") {
		t.Errorf("episode header rendered the diagnostic struct instead of the recorded model: %s", body)
	}
	if strings.Count(body, `id="effect-1"`) != 1 {
		t.Errorf("episode page duplicated the persisted memory effect: %s", body)
	}
}

func TestPresentEventPayloadOmitsUnsetTimesAndPresentsSlackIDs(t *testing.T) {
	present := func(text string) string {
		return strings.ReplaceAll(text, "<@U0BL8MNPUSY>", "@Emisar")
	}
	got := presentEventPayload(`{
	  "phase":"planning",
	  "progress_due_at":"0001-01-01T00:00:00Z",
	  "next_action":"Reply to <@U0BL8MNPUSY>"
	}`, present)
	if strings.Contains(got, "0001-01-01") || strings.Contains(got, "progress_due_at") {
		t.Fatalf("zero time leaked into payload: %s", got)
	}
	if !strings.Contains(got, "Reply to @Emisar") {
		t.Fatalf("Slack identity was not presented: %s", got)
	}
}

func TestPromptSegmentsPreserveEveryCharacterInOrder(t *testing.T) {
	prompt := "SYSTEM: one\n<trusted-responder-context>trusted</trusted-responder-context>\n" +
		"<untrusted-slack-context>{\"goal\":\"check\"}</untrusted-slack-context>\nUSER: hello"
	segments := promptSegments(prompt)
	var rebuilt strings.Builder
	for _, segment := range segments {
		rebuilt.WriteString(segment.Body)
		if segment.Tokens < 1 || segment.Hint == "" {
			t.Fatalf("segment lacks token provenance: %+v", segment)
		}
	}
	if rebuilt.String() != prompt {
		t.Fatalf("segments changed prompt:\n got %q\nwant %q", rebuilt.String(), prompt)
	}
}

func TestResultSideEffectsOmitsEmptyMemoryFields(t *testing.T) {
	parsed, err := decision.ParseWatchDecision(`{
	  "action":"reply",
	  "reason":"Saved one constraint.",
	  "message":"Got it.",
	  "memory":{"knowledge":[{
	    "subject":"Terraform summaries",
	    "kind":"constraint",
	    "statement":"Show before and after values."
	  }]}
	}`, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}

	effects := resultSideEffects(parsed, "completed")
	if len(effects) != 1 || effects[0].Title != "Terraform summaries" {
		t.Fatalf("effects = %+v, want only the populated knowledge item", effects)
	}
}

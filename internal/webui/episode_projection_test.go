package webui

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	          '1786349647.618159','U1','remember these settings','completed',?,?,?)`,
		stamp, stamp, stamp)
	exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, result_json, terminal_state, state,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id, attempt_id, attempt_number)
	  VALUES ('run-1','triage','C1','1786344951.427829','C1:1786344951.427829',
	          'watch','input-1','U1','emisar','idem-1',?,'completed','completed',
	          ?,?,?,?,'episode-1','attempt-1',1)`, result, stamp, stamp, stamp, stamp)
	exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, created_at, updated_at,
	   completed_at, lifecycle_state, channel_id, thread_ts, anchor_ts, latest_attempt_id)
	  VALUES ('episode-1','run-1','focused_check','read_only',
	          'Remember Terraform summary preferences',?,?,?,'completed','C1',
	          '1786344951.427829','1786344951.427829','attempt-1')`, stamp, stamp, stamp)
	exec(`INSERT INTO episode_attempts
	  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
	   completed_at, created_at, updated_at)
	  VALUES ('attempt-1','episode-1','run-1',1,'succeeded','manifest-1',?,?,?)`,
		stamp, stamp, stamp)
	exec(`INSERT INTO context_manifests
	  (id, episode_id, attempt_id, version, provider, model, reasoning_effort,
	   prompt_version, contract_version, tool_schema_version, preset, created_at)
	  VALUES ('manifest-1','episode-1','attempt-1',1,'claude','opus','high',
	          'responder-prompt-v2','investigation-contract-v1','result-operations-v2',
	          'emisar-conversation',?)`, stamp)
	exec(`INSERT INTO slack_deliveries
	  (id, operation, kind, channel_id, thread_ts, message_ts, body_json, state,
	   failure_count, next_attempt_at, created_at, updated_at, episode_id)
	  VALUES ('delivery-1','post','reply','C1','1786344951.427829','1786349687.887489',
	          ?, 'sent',0,?,?,?,'episode-1')`,
		`{"text":"Got it. Plan summaries will show material changes as before → after."}`,
		stamp, stamp, stamp)
	// A confirmed rule belongs to a later confirmation input, but carries the
	// original event id as source_ref. That is how it remains attributable to
	// the episode that proposed it.
	exec(`INSERT INTO standing_rules
	  (id, channel_id, repository, trigger_name, action_name, source_kind, enabled,
	   source_ref, actor_id, expires_at, created_at, updated_at)
	  VALUES ('rule-1','C1','emisar','terraform_plan','review_terraform_plan','app',1,
	          'event-1','U1',?,?,?)`, expires, stamp, stamp)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	body := servePage(t, reader, "/episodes/episode-1")
	for _, expected := range []string{
		`answered by <span class="who">opus/high</span>`,
		"Response outcome",
		"Got it. Plan summaries will show material changes as before → after",
		"Slack post",
		"message 1786349687.887489",
		"Side effects",
		"Terraform plan change summaries",
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
	if strings.Contains(body, "{Not recorded for this attempt") {
		t.Errorf("episode header rendered the diagnostic struct instead of the recorded model: %s", body)
	}
}

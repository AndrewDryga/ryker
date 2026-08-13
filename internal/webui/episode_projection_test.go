package webui

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
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
	reacted := time.Date(2026, 8, 10, 8, 14, 1, 400_000_000, time.UTC).Format(time.RFC3339Nano)
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
	exec(`INSERT INTO slack_deliveries
	  (id, operation, kind, channel_id, thread_ts, body_json, state,
	   failure_count, next_attempt_at, created_at, updated_at, episode_id)
	  VALUES ('status-1','status','status','C1','1786344951.427829','{}','sent',
	          0,?,?,?, 'episode-1')`, stamp, stamp, reacted)
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
	reader.SetSlackIdentities(map[string]string{"U0BL8MNPUSY": "Emisar", "U0BHTNFCW6S": "Andrew Dryga"})

	body := servePage(t, reader, "/episodes/episode-1")
	for _, expected := range []string{
		"Episodes",
		"#infra",
		"it would be better if plan summaries showed before and after values",
		"Execution trace",
		"Message received",
		"Slack message",
		"@Emisar it would be better if plan summaries showed before and after values",
		"Sender</small><strong>@Andrew Dryga",
		"Thread</small><strong>1786344951.427829",
		"Model selected",
		"Provider</small><strong>claude",
		"Model</small><strong>opus",
		"Reasoning</small><strong>high",
		"Routing is set statically in the configuration.",
		"Coop policy emisar-conversation",
		"Model briefed",
		"Slack conversation",
		"Sent to model",
		"SYSTEM: Keep durable settings typed.",
		"USER: @Emisar it would be better if plan summaries showed before and after values",
		"tokens went to the model, kept exactly as sent.",
		"Not sent",
		"No additional nearby Slack messages were admitted into this prompt.",
		"This request did not resolve to a separate referenced thread.",
		"Operational memory",
		"Operational memory · Confirmed memory (1)",
		"Conversation memory",
		"Conversation memory · Goal (1)",
		"Conversation memory · Knowledge (1)",
		"Keep plan reviews concise",
		"Prefer threads",
		"Related conversation summaries (1)",
		"A prior rollout used the same image.",
		"Final submitted prompt",
		"Exact model input",
		"System instructions",
		"Operational memory",
		"Conversation memory",
		"Related conversation summaries",
		"Source Slack message",
		"User request",
		"tokens",
		"Outcome",
		"Replied",
		"Time to respond",
		"Model spend",
		"47.9s",
		"From the message to the reply in #infra.",
		"Acknowledged in 1.4s.",
		"Errors",
		"What came in",
		"The work",
		"The answer",
		"What came of it",
		"Model result received",
		"Why the model chose this",
		"The operator set two presentation preferences.",
		"Raw model result",
		"Got it. Plan summaries will show material changes as before → after",
		"Replied in the thread",
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
		"Provider transcript boundary",
		"Time to react",
		"Not recorded",
		"terraformplan",
	} {
		if strings.Contains(body, unwanted) {
			t.Errorf("episode page unexpectedly contains %q: %s", unwanted, body)
		}
	}
	if strings.Index(body, "Slack conversation") > strings.Index(body, "Operational memory") ||
		strings.Index(body, "Operational memory") > strings.Index(body, "Conversation memory") ||
		strings.Index(body, "Conversation memory") > strings.Index(body, "Final submitted prompt") {
		t.Errorf("prompt context is not ordered conversation, memory, final prompt: %s", body)
	}
	if strings.Contains(body, "{Not recorded for this attempt") {
		t.Errorf("episode header rendered the diagnostic struct instead of the recorded model: %s", body)
	}
	if strings.Count(body, `id="effect-1"`) != 1 {
		t.Errorf("episode page duplicated the persisted memory effect: %s", body)
	}
}

func TestFollowUpEpisodeStartsWithSlackOriginThenAutomaticTrigger(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 8, 10, 20, 13, 50, 0, time.UTC)
	t1 := t0.Add(5 * time.Minute)
	t2 := t1.Add(5 * time.Minute)
	stamp := func(value time.Time) string { return value.Format(time.RFC3339Nano) }
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(context.Background(), query, args...); err != nil {
			t.Fatalf("seed: %v\n%s", err, query)
		}
	}
	exec(`INSERT INTO slack_channel_memberships (channel_id, channel_name, observed_at)
	      VALUES ('C1','infra',?)`, stamp(t0))
	exec(`INSERT INTO slack_inputs
	  (id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
	   user_id, text, state, next_attempt_at, received_at, updated_at)
	  VALUES ('root-input','root-envelope','root-event','bot_message','T1','C1','',
	          '1786392830.431989','UTERRAFORM','Terraform run failed','completed',?,?,?)`,
		stamp(t0), stamp(t0), stamp(t0))
	for _, input := range []struct {
		id, envelope, text string
		at                 time.Time
	}{
		{"episode_wakeup_terraform-terminal", "primary-envelope", "Resume after the Terraform run reached a terminal state", t1},
		{"later-recheck", "later-envelope", "Retry the same Terraform follow-up", t2},
	} {
		exec(`INSERT INTO slack_inputs
		  (id, envelope_id, kind, team_id, channel_id, thread_ts, message_ts,
		   user_id, text, state, next_attempt_at, received_at, updated_at)
		  VALUES (?,?,'recheck','T1','C1','1786392830.431989','',
		          '','', 'completed',?,?,?)`, input.id, input.envelope,
			stamp(input.at), stamp(input.at), stamp(input.at))
		// Keep the exact synthetic instruction distinct so the assertion proves
		// which trigger the reader selected.
		exec(`UPDATE slack_inputs SET text = ? WHERE id = ?`, input.text, input.id)
	}
	exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, terminal_state, state, attempt_number,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id)
	  VALUES ('primary-run','triage','C1','1786392830.431989','C1:1786392830.431989',
	          'recheck','episode_wakeup_terraform-terminal','','emisar','primary-idem','completed','completed',2,
	          ?,?,?,?,'follow-up-episode')`, stamp(t1), stamp(t1), stamp(t1), stamp(t1))
	exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, terminal_state, state, attempt_number,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id)
	  VALUES ('later-run','triage','C1','1786392830.431989','C1:1786392830.431989',
	          'recheck','later-recheck','','emisar','later-idem','completed','completed',1,
	          ?,?,?,?,'follow-up-episode')`, stamp(t2), stamp(t2), stamp(t2), stamp(t2))
	exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, created_at, updated_at,
	   completed_at, lifecycle_state, channel_id, thread_ts, anchor_ts)
	  VALUES ('follow-up-episode','primary-run','focused_check','read_only',
	          'Resume Terraform follow-up',?,?,?,'completed','C1',
	          '1786392830.431989','episode_wakeup_terraform-terminal')`,
		stamp(t1), stamp(t1), stamp(t1))
	exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, terminal_state, state, attempt_number,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id)
	  VALUES ('original-run','triage','C1','1786392830.431989','C1:1786392830.431989',
	          'watch','root-input','','emisar','original-idem','completed','completed',1,
	          ?,?,?,?,'original-episode')`, stamp(t0), stamp(t0), stamp(t0), stamp(t0))
	exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, created_at, updated_at,
	   completed_at, lifecycle_state, channel_id, thread_ts, anchor_ts)
	  VALUES ('original-episode','original-run','focused_check','read_only',
	          'Watch Terraform until it finishes',?,?,?,'completed','C1',
	          '1786392830.431989','1786392830.431989')`,
		stamp(t0), stamp(t1), stamp(t1))
	exec(`INSERT INTO episode_wakeups
	  (id, episode_id, kind, event_matcher_json, state, last_observation_json,
	   created_at, updated_at, resolved_at)
	  VALUES ('terraform-terminal','original-episode','terraform_run',?,'resolved',?,?,?,?)`,
		`{"provider":"hcp_terraform","run_id":"run-CRHCeYKxfPSNpEUw"}`,
		`{"provider":"hcp_terraform","run_id":"run-CRHCeYKxfPSNpEUw","state":"applied"}`,
		stamp(t1.Add(-time.Minute)), stamp(t1), stamp(t1))
	// Recovery rebound the already-started run to the follow-up episode. Its
	// immutable attempt and prompt manifest correctly retain the original
	// episode identity. The trace must follow the run and show this call before
	// displaying the correction that it produced.
	exec(`INSERT INTO episode_attempts
	  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
	   started_at, completed_at, created_at, updated_at)
	  VALUES ('primary-attempt','original-episode','primary-run',1,'succeeded','primary-manifest',?,?,?,?)`,
		stamp(t1.Add(100*time.Millisecond)), stamp(t1.Add(2*time.Second)),
		stamp(t1.Add(100*time.Millisecond)), stamp(t1.Add(2*time.Second)))
	exec(`INSERT INTO context_manifests
	  (id, episode_id, attempt_id, version, provider, model, reasoning_effort,
	   prompt_version, contract_version, tool_schema_version, preset,
	   submitted_prompt, created_at)
	  VALUES ('primary-manifest','original-episode','primary-attempt',1,
	          'codex','gpt-5.6-terra','low','prompt-v1','contract-v1','tools-v1',
	          'emisar-conversation','SYSTEM: Continue the Terraform follow-up.',?)`,
		stamp(t1.Add(100*time.Millisecond)))
	exec(`INSERT INTO audit_events
	  (id, kind, actor_id, object_id, outcome, detail, created_at)
	  VALUES ('correction-1','result.correction','responder','primary-run',
	          'invalid result','return a corrected result',?)`, stamp(t1.Add(time.Second)))
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	source, err := reader.SourceInput(context.Background(), "follow-up-episode")
	if err != nil {
		t.Fatal(err)
	}
	trigger, err := reader.TriggerInput(context.Background(), "follow-up-episode")
	if err != nil {
		t.Fatal(err)
	}
	if source.ID != "root-input" || source.Text != "Terraform run failed" {
		t.Fatalf("source = %+v, want original Slack message", source)
	}
	if trigger.ID != "episode_wakeup_terraform-terminal" || !strings.Contains(trigger.Text, "terminal state") {
		t.Fatalf("trigger = %+v, want primary episode wake-up", trigger)
	}
	wakeup, err := reader.WakeupForTrigger(context.Background(), trigger.ID)
	if err != nil {
		t.Fatal(err)
	}
	if wakeup.ID != "terraform-terminal" || !strings.Contains(wakeup.Matcher, "run-CRHCeYKxfPSNpEUw") {
		t.Fatalf("wakeup = %+v, want exact persisted Terraform subscription", wakeup)
	}
	wakeups, err := reader.Wakeups(context.Background(), "follow-up-episode", trigger.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(wakeups) != 1 || wakeups[0].ID != "terraform-terminal" {
		t.Fatalf("wakeups = %+v, want linked Terraform subscription", wakeups)
	}
	manifests, err := reader.Manifests(context.Background(), "follow-up-episode")
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) != 1 || manifests[0].RunID != "primary-run" {
		t.Fatalf("manifests = %+v, want rebound primary run manifest", manifests)
	}
	attempts, err := reader.Attempts(context.Background(), "follow-up-episode")
	if err != nil {
		t.Fatal(err)
	}
	rejections, err := reader.Rejections(context.Background(), "follow-up-episode")
	if err != nil {
		t.Fatal(err)
	}

	page := episodePage{
		Item: Item{Created: t1}, Source: source, Trigger: trigger, Wakeup: wakeup,
		Wakeups:  wakeups,
		Manifest: manifests[0], Manifests: manifests, Attempts: attempts, Rejections: rejections,
	}
	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	if len(trace.Steps) < 7 {
		t.Fatalf("trace steps = %+v", trace.Steps)
	}
	positions := map[string]int{}
	for index, step := range trace.Steps {
		positions[step.ID] = index
	}
	for _, want := range []string{
		"source", "wakeup-scheduled", "wakeup-resolved", "trigger", "model", "prompt", "rejection-1", "attempt-1",
	} {
		if _, ok := positions[want]; !ok {
			t.Fatalf("trace is missing %q: %+v", want, trace.Steps)
		}
	}
	for before, after := range map[string]string{
		"source":           "wakeup-scheduled",
		"wakeup-scheduled": "wakeup-resolved",
		"wakeup-resolved":  "trigger",
		"trigger":          "model",
		"model":            "prompt",
		"prompt":           "rejection-1",
		"rejection-1":      "attempt-1",
	} {
		if positions[before] >= positions[after] {
			t.Fatalf("%s must precede %s; trace = %+v", before, after, trace.Steps)
		}
	}
	if trace.Steps[1].Title != "Wake-up scheduled" ||
		trace.Steps[2].Title != "Wake-up resolved" ||
		trace.Steps[3].Title != "Wake-up delivered" {
		t.Fatalf("wake-up lifecycle is not explicit: %+v", trace.Steps[:4])
	}
}

// The briefing bar answers "what filled the model's attention" — families
// must group every segment tone, keep real slivers visible, and lay out to
// exactly the whole strip.
func TestPromptCompositionBarGroupsFamiliesAcrossTheWholeStrip(t *testing.T) {
	segments := []PromptSegment{
		{Tone: "system", Tokens: 700},
		{Tone: "structure", Tokens: 20},
		{Tone: "operational", Tokens: 90},
		{Tone: "conversation", Tokens: 90},
		{Tone: "slack", Tokens: 80},
		{Tone: "user", Tokens: 3},
	}
	bar, total := promptCompositionBar(segments, coop.MaxPromptBytes/2, false)
	if bar == nil || len(bar.Slices) != 5 {
		t.Fatalf("composition = %+v, want four families plus headroom", bar)
	}
	if total != 983 {
		t.Fatalf("composition total = %d, want 983", total)
	}
	if bar.Slices[0].Label != "Instructions" || bar.Slices[1].Label != "Memory" ||
		bar.Slices[2].Label != "Slack" || bar.Slices[3].Label != "Request" {
		t.Fatalf("family order = %+v", bar.Slices)
	}
	covered := 0
	for _, slice := range bar.Slices {
		if slice.X != covered {
			t.Fatalf("slice %q starts at %d, want %d", slice.Label, slice.X, covered)
		}
		if slice.W < 8 {
			t.Fatalf("slice %q rounded away to %d units", slice.Label, slice.W)
		}
		covered += slice.W
	}
	if covered != 1000 {
		t.Fatalf("bar covers %d of 1000 units", covered)
	}
	free := bar.Slices[4]
	if free.Class != "free" || free.X != 500 || free.W != 500 {
		t.Fatalf("half-used budget headroom = %+v, want the second half of the strip", free)
	}
	if !strings.Contains(bar.Note, "50% of the 256 KiB turn budget") {
		t.Fatalf("note does not state budget use: %q", bar.Note)
	}

	// A trimmed turn fills the strip by definition: its budget was the
	// ceiling it hit, and the note says so instead of inventing headroom.
	full, _ := promptCompositionBar(segments, 62<<10, true)
	last := full.Slices[len(full.Slices)-1]
	if last.Class == "free" || last.X+last.W != 1000 {
		t.Fatalf("trimmed turn bar = %+v, want families across the whole strip", full.Slices)
	}
	if !strings.Contains(full.Note, "budget was full at 62.0 KiB") {
		t.Fatalf("trimmed note = %q", full.Note)
	}
}

// The kernel writes a context_extended receipt in the same transaction that
// creates a manifest; when that manifest renders as a "Model briefed" card,
// the receipt is the same fact twice and must not become its own step.
func TestContextReceiptFoldsIntoItsBriefedCard(t *testing.T) {
	at := time.Date(2026, 8, 12, 23, 53, 0, 0, time.UTC)
	page := episodePage{
		Manifests: []ManifestRow{{ID: "context_1", Version: 1, Created: at,
			SubmittedPrompt: "SYSTEM: x"}},
		Manifest: ManifestRow{ID: "context_1", Version: 1},
		Events: []Event{
			{Kind: "context_extended", At: at,
				Payload: `{"manifest_id":"context_1","attempt_id":"attempt_1","reference_count":10,"version":1}`},
			{Kind: "context_extended", At: at,
				Payload: `{"manifest_id":"context_gone","version":2}`},
		},
	}
	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	events := []string{}
	for _, step := range trace.Steps {
		if strings.HasPrefix(step.ID, "event-") {
			events = append(events, step.ID+":"+step.Title)
		}
	}
	if len(events) != 1 || events[0] != "event-2:Context recorded" {
		t.Fatalf("context receipts = %v, want only the manifest the page cannot show", events)
	}
}

// A phase card explains what the stage is in plain words; the host's canned
// checklist never prints as a "next" that contradicts the following card,
// and the JSON payload renders only when it holds something the card does
// not already present.
func TestPhaseCardsSpeakPlainlyAndDropRoutinePayloads(t *testing.T) {
	payload := `{"phase":"planning","state":"planning","status":"Planning the work","next_action":"Establish the evidence plan"}`
	if !routinePhasePayload(payload) {
		t.Fatal("a payload holding only the presented fields must be routine")
	}
	if routinePhasePayload(`{"phase":"planning","worker_id":"w-4"}`) {
		t.Fatal("a payload with extra fields must keep its JSON detail")
	}
	identity := func(text string) string { return text }
	summary := phaseCardSummary(decodePhasePayload(payload), "Planning the work", "Planning the work", identity)
	if !strings.Contains(summary, "no model is running yet") || strings.Contains(summary, "Next:") {
		t.Fatalf("planning summary = %q, want the explanation without the canned checklist", summary)
	}
	blocked := phaseCardSummary(phasePayload{Phase: "waiting", NextAction: "Ask the operator which account to use"},
		"The AI provider is rate-limiting requests; the work is queued.", "Waiting", identity)
	if !strings.Contains(blocked, "rate-limiting") || !strings.Contains(blocked, "Next: Ask the operator") {
		t.Fatalf("waiting summary = %q, want the real status and the meaningful next action", blocked)
	}
}

// A chip beside a title must mean something: routine success states render
// nothing, trouble and audit outcomes render.
func TestStepChipsOnlySurfaceInformativeStates(t *testing.T) {
	for _, testCase := range []struct {
		step TraceStep
		want string
	}{
		{TraceStep{ID: "prompt", State: "recorded"}, ""},
		{TraceStep{ID: "event-2", State: "planning"}, ""},
		{TraceStep{ID: "result", State: "completed", Tone: "good"}, ""},
		{TraceStep{ID: "attempt-1", State: "failed", Tone: "bad"}, "failed"},
		{TraceStep{ID: "record-1", State: "waiting_operator", Tone: "warn"}, "waiting operator"},
		{TraceStep{ID: "audit-3", State: "ignored"}, "ignored"},
	} {
		if got := stepChip(testCase.step); got != testCase.want {
			t.Fatalf("chip for %s state %q = %q, want %q",
				testCase.step.ID, testCase.step.State, got, testCase.want)
		}
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

func TestAuditTracePresentsSlackReactionAndStandingRuleMeaning(t *testing.T) {
	audit := AuditRow{
		Kind: "standing_rule.acknowledged", Outcome: "reacted", Actor: "responder",
		Object: "slack_message_123", Detail: "eyes", Repeats: 1,
	}
	summary, stats := auditTracePresentation(audit, func(text string) string { return text })
	if summary != "" {
		t.Fatalf("legacy evaluation summary = %q", summary)
	}
	if len(stats) != 4 || stats[0] != (TraceStat{"Active rules", "Not recorded"}) ||
		stats[1] != (TraceStat{"Matched", "At least 1"}) ||
		stats[2] != (TraceStat{"Skipped", "Not recorded"}) ||
		stats[3] != (TraceStat{"Working marker", "👀"}) {
		t.Fatalf("legacy evaluation stats = %+v", stats)
	}
	if got := auditTraceWhy(audit); got != "" {
		t.Fatalf("legacy evaluation has generic explanation = %q", got)
	}
	if got := eventTitle(audit.Kind); got != "Standing rules" {
		t.Fatalf("audit title = %q", got)
	}
	details := auditTraceDetails(audit, func(text string) string { return text })
	if len(details) != 1 || !details[0].Open ||
		details[0].Label != "Matched rule - details not recorded" ||
		!strings.Contains(details[0].Body, "did not save the rule name") {
		t.Fatalf("legacy evaluation details = %+v", details)
	}
}

func TestEpisodeMetricsUseStandingRuleReactionAsTimeToReact(t *testing.T) {
	received := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)
	metrics := episodeMetrics(config.Pricing{}, episodePage{
		Source: SourceInput{Received: received},
		Audit: []AuditRow{{
			Kind: "standing_rule.acknowledged", Detail: "eyes",
			At: received.Add(850 * time.Millisecond),
		}},
	})
	if len(metrics) < 2 || metrics[1].Label != "Time to respond" ||
		!strings.Contains(metrics[1].Detail, "Acknowledged in 850ms") {
		t.Fatalf("acknowledgement is not on the respond card = %+v", metrics)
	}
}

func TestSupersededEpisodeShowsRetriesAndSuccessorReply(t *testing.T) {
	received := time.Date(2026, 8, 12, 18, 58, 27, 0, time.UTC)
	replied := received.Add(time.Hour + 19*time.Minute + 35*time.Second)
	completed := replied.Add(-2 * time.Second)
	page := episodePage{
		Item:   Item{State: "superseded"},
		Source: SourceInput{Received: received},
		Turns:  []Turn{{RunID: "run-original", Failures: 19}},
		Effects: []SideEffect{{
			Kind: "work episode", State: "completed", ID: "episode-successor",
			Title: "No theories?", At: completed, Responded: true, ResponseAt: replied,
		}},
	}
	metrics := episodeMetrics(config.Pricing{}, page)
	if metrics[0].Value != "Superseded" ||
		!strings.Contains(metrics[0].Detail, "A newer episode replied: No theories?") {
		t.Fatalf("outcome = %+v", metrics[0])
	}
	if metrics[1].Missing || metrics[1].Value != "1h 19m" ||
		!strings.Contains(metrics[1].Detail, "A successor episode replied in Slack") {
		t.Fatalf("response = %+v", metrics[1])
	}
	if metrics[3].Value != "19" ||
		!strings.Contains(metrics[3].Detail, "19 processing failures") {
		t.Fatalf("errors = %+v", metrics[3])
	}
	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	var successor TraceStep
	for _, step := range trace.Steps {
		if step.Href != "" {
			successor = step
			break
		}
	}
	if successor.Href != "/episodes/episode-successor" ||
		!successor.At.Equal(completed) {
		t.Fatalf("successor trace = %+v", successor)
	}
}

func TestAuditTraceExplainsEveryMatchedAndSkippedStandingRule(t *testing.T) {
	evaluation := core.StandingRuleEvaluationAudit{
		Checked: 3, Matched: 1, Acknowledged: "eyes",
		Rules: []core.StandingRuleEvaluation{
			{
				Name: "Review Terraform plans", Matched: true,
				Why:      "Matched because this is an app message about a Terraform run that is planned.",
				Trigger:  "App messages about Terraform runs when the state is planned.",
				Work:     "Reviews the saved plan and checks the Terraform changes for red flags.",
				Delivery: "Adds 👀 while it checks and replies in the source message's thread when there is a useful finding.",
			},
			{
				Name:     "Investigate operational alerts",
				Why:      "Skipped because this is a Terraform run update, not an operational alert.",
				Trigger:  "App messages about operational alerts.",
				Work:     "Investigates whether the alert is a real issue.",
				Delivery: "Replies in the source message's thread for a confirmed issue.",
			},
			{
				Name:     "Verify deployments",
				Why:      "Skipped because this is a Terraform run update, not a deployment.",
				Trigger:  "App messages about deployments.",
				Work:     "Checks the deployed revision and service health.",
				Delivery: "Replies in the source message's thread for a final result.",
			},
		},
	}
	detail, err := json.Marshal(evaluation)
	if err != nil {
		t.Fatal(err)
	}
	audit := AuditRow{
		Kind: "standing_rules.evaluated", Outcome: "matched", Detail: string(detail),
	}

	summary, stats := auditTracePresentation(audit, func(text string) string { return text })
	if summary != "" {
		t.Fatalf("evaluation summary = %q", summary)
	}
	if len(stats) != 4 || stats[0].Value != "3" || stats[1].Value != "1" ||
		stats[2].Value != "2" || stats[3].Value != "👀" {
		t.Fatalf("evaluation stats = %+v", stats)
	}
	details := auditTraceDetails(audit, func(text string) string { return text })
	if len(details) != 3 || !details[0].Open ||
		details[0].Label != "Matched - Review Terraform plans" ||
		details[1].Label != "Skipped - Investigate operational alerts" {
		t.Fatalf("evaluation details = %+v", details)
	}
	for _, want := range []string{
		"Why it matched\nMatched because", "Why it did not match\nSkipped because",
		"What it watches", "What it does", "Slack behavior",
		"This workflow now controls", "None. This rule does not affect",
	} {
		var found bool
		for _, detail := range details {
			found = found || strings.Contains(detail.Body, want)
		}
		if !found {
			t.Fatalf("evaluation details missing %q: %+v", want, details)
		}
	}
	if auditTraceWhy(audit) != "" {
		t.Fatalf("evaluation has generic explanation: %q", auditTraceWhy(audit))
	}
	if eventTitle(audit.Kind) != "Standing rules" {
		t.Fatalf("evaluation title = %q", eventTitle(audit.Kind))
	}
}

func TestPromptSegmentsPreserveEveryCharacterInOrder(t *testing.T) {
	prompt := "SYSTEM: one\n<trusted-responder-context>trusted</trusted-responder-context>\n" +
		"<untrusted-slack-context>{\"channel_id\":\"C1\",\"prior_operational_context\":{\"open_commitments\":[\"check rollout\"]}," +
		"\"structured_memory\":{\"goal\":\"check\"},\"related_situations\":[{\"summary\":\"earlier alert\"}]," +
		"\"target_message\":{\"text\":\"hello\"},\"repository\":\"emisar\"}</untrusted-slack-context>\nUSER: hello"
	segments := promptSegments(prompt)
	var rebuilt strings.Builder
	sources := map[string]bool{}
	bodies := map[string]string{}
	for _, segment := range segments {
		rebuilt.WriteString(segment.Body)
		sources[segment.Source] = true
		bodies[segment.Source] += segment.Body
		if segment.Tokens < 1 || segment.Hint == "" {
			t.Fatalf("segment lacks token provenance: %+v", segment)
		}
	}
	if rebuilt.String() != prompt {
		t.Fatalf("segments changed prompt:\n got %q\nwant %q", rebuilt.String(), prompt)
	}
	for _, source := range []string{
		"Operational memory", "Conversation memory", "Related conversation summaries",
		"Slack channel", "Source Slack message", "Repository selection", "Safety boundary",
	} {
		if !sources[source] {
			t.Fatalf("prompt segments do not identify %q: %+v", source, segments)
		}
	}
	if strings.Contains(bodies["Slack channel"], "<untrusted-slack-context>") ||
		strings.Contains(bodies["Repository selection"], "</untrusted-slack-context>") {
		t.Fatalf("trust wrapper was attributed to semantic prompt fields: %+v", segments)
	}
	if !strings.Contains(bodies["Safety boundary"], "<untrusted-slack-context>") ||
		!strings.Contains(bodies["Safety boundary"], "</untrusted-slack-context>") {
		t.Fatalf("trust wrapper was not identified as a safety boundary: %+v", segments)
	}
}

func TestPromptTextSectionsStartCollapsed(t *testing.T) {
	page := episodePage{Manifest: ManifestRow{
		Version: 1,
		SubmittedPrompt: `SYSTEM: inspect the request
<untrusted-slack-context>{"target_message":{"text":"check this"}}</untrusted-slack-context>
USER: check this`,
	}}

	trace := buildEpisodeTrace(config.Pricing{}, page, nil)
	for _, step := range trace.Steps {
		if step.ID != "prompt" {
			continue
		}
		if len(step.Details) == 0 {
			t.Fatal("prompt step has no text sections")
		}
		for _, detail := range step.Details {
			if detail.Open {
				t.Fatalf("prompt text section starts expanded: %q", detail.Label)
			}
		}
		return
	}
	t.Fatal("trace has no prompt step")
}

func TestPromptContextDetailsExplainSlackAndOperationalMemory(t *testing.T) {
	prompt := `SYSTEM
<untrusted-slack-context>
{
  "channel_id":"C1",
  "repository":"emisar",
  "target_message":{"message_ts":"1786408526.961689","sender_id":"U1","text":"check this","mentions_responder":true},
  "recent_messages":[{"message_ts":"1786408500.100","sender_id":"U2","text":"deploy finished"},{"message_ts":"1786408510.100","sender_id":"U2","text":"health checks passed"}],
  "structured_memory":{"goal":"Verify the rollout","constraints":["Reply in threads","Show before and after values"]},
  "prior_operational_context":{"recent_same_channel_evidence":[{"id":"ev_secret","claim":"The rollout finished","observation":"All checks passed","source_type":"github","source_name":"GitHub checks","observed_at":"2026-08-10T08:00:00Z","confidence":"high"},{"id":"ev_health","claim":"The rollout is healthy","observation":"Readiness passed","source_type":"emisar","source_name":"Emisar","observed_at":"2026-08-10T08:01:00Z","confidence":"high"}]}
}
</untrusted-slack-context>
USER: check this`
	present := func(value string) string {
		return strings.NewReplacer("<@U1>", "@Andrew Dryga", "<@U2>", "@Trevin Miller", "C1", "#infra").Replace(value)
	}
	details, layers := promptContextDetails(prompt, present, map[string][]string{
		"prior_evidence":     {"earlier evidence records from this channel were omitted to fit the turn"},
		"related_situations": {"summaries of related conversations were omitted to fit the turn"},
	})
	if layers != 2 {
		t.Fatalf("memory layers = %d, want 2", layers)
	}
	joined := ""
	counts := make(map[string]int, len(details))
	for _, detail := range details {
		joined += detail.Group + "\n" + detail.GroupDetail + "\n" + detail.Status + "\n" + detail.Label + "\n" + detail.Description + "\n" + detail.Body + "\n"
		counts[detail.Label] = detail.Count
		if detail.Inert {
			// An empty slot renders as a plain line; there is nothing to open.
			continue
		}
		if !detail.Open {
			t.Fatalf("human-readable prompt source is collapsed before trace presentation: %+v", detail)
		}
		if !detail.ShowCount {
			t.Fatalf("prompt source has no entry count: %+v", detail)
		}
	}
	for _, want := range []string{
		"Operational memory · Recent same channel evidence",
		"The rollout finished", "Observed: All checks passed", "Source: GitHub checks",
		"Conversation memory · Goal", "Verify the rollout", "Conversation memory · Constraints",
		"Source Slack message", "@Andrew Dryga\ncheck this", "Recent Slack messages",
		"@Trevin Miller\ndeploy finished", "Slack channel", "#infra", "Repository selection", "emisar",
		"A bounded chronological window around the triggering message",
		"The 10 newest evidence records from this channel",
		"Not sent", "This request did not resolve to a separate referenced thread",
		"Trimmed", "Operational memory · Channel evidence",
		"earlier evidence records from this channel were omitted to fit the turn",
		"summaries of related conversations were omitted to fit the turn",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("readable prompt context missing %q:\n%s", want, joined)
		}
	}
	for label, want := range map[string]int{
		"Operational memory · Recent same channel evidence": 2,
		"Conversation memory · Goal":                        1,
		"Conversation memory · Constraints":                 2,
		"Source Slack message":                              1,
		"Recent Slack messages":                             2,
		"Slack channel":                                     1,
		"Repository selection":                              1,
	} {
		if got := counts[label]; got != want {
			t.Fatalf("context count for %q = %d, want %d", label, got, want)
		}
	}
	for _, unwanted := range []string{
		"ev_secret", "mentions_responder", `"sender_id"`,
		// A layer absent because the budget cut it must not claim irrelevance.
		"None of the recent conversation summaries were relevant enough to include.",
	} {
		if strings.Contains(joined, unwanted) {
			t.Fatalf("prompt context leaked storage field %q:\n%s", unwanted, joined)
		}
	}
}

func TestContextReferenceDetailsSeparateReplayMetadataFromInputs(t *testing.T) {
	runtime, replay := contextReferenceDetails([]ContextRef{
		{Kind: "source_input", What: "watch in #infra", Visibility: "eligible"},
		{Kind: "compiled_prompt", What: "attempt run_secret", Visibility: "private", Digest: "abc123"},
		{Kind: "assembled_context", What: "attempt run_secret", Visibility: "private", Digest: "def456"},
		{Kind: "repository", What: "emisar @ deadbeef", Visibility: "eligible"},
		{Kind: "repository", What: "emisar-docs @ 12341234", Visibility: "companion"},
		{Kind: "execution_policy", What: "emisar-conversation", Visibility: "private"},
		{Kind: "artifact", What: "github-pr-529.md (text/markdown)", Visibility: "eligible",
			FullDigest: "5256adaff57a0000", Digest: "5256adaff57a"},
	}, func(value string) string { return value }, map[string]bool{"5256adaff57a0000": true})
	if len(runtime) != 1 || len(replay) != 2 {
		t.Fatalf("context details = %+v / %+v, want one runtime table and two replay facts", runtime, replay)
	}
	if replay[0] != (TraceStat{"Final prompt", "abc123"}) ||
		replay[1] != (TraceStat{"Selected context", "def456"}) {
		t.Fatalf("replay facts = %+v, want flat fingerprint pairs", replay)
	}
	joined := ""
	for _, detail := range runtime {
		joined += detail.Group + "\n" + detail.Label + "\n" + detail.Description + "\n"
		if detail.Table != nil {
			joined += strings.Join(detail.Table.Headers, "\n") + "\n"
			for _, row := range detail.Table.Rows {
				joined += strings.Join(row.Cells, "\n") + string(row.Href) + "\n"
			}
		}
	}
	for _, want := range []string{
		"Runtime access", "Repositories and session controls", "Repository snapshot", "emisar", "deadbeef",
		"Companion repository", "Read-only companion checkout", "emisar-docs",
		"Execution policy", "Controls tools and whether files can change",
		"Exact file handed to the model", "/artifacts/5256adaff57a0000",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("context details missing %q:\n%s", want, joined)
		}
	}
	for _, unwanted := range []string{"attempt run_secret", "Visibility:"} {
		if strings.Contains(joined, unwanted) {
			t.Fatalf("context details leaked %q:\n%s", unwanted, joined)
		}
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

func TestResultSideEffectsShowsEveryScheduledTaskOffer(t *testing.T) {
	parsed, err := decision.ParseWatchDecision(`{
	  "action":"reply",
	  "reason":"Two follow-up checks need confirmation.",
	  "message":"I can schedule both checks together.",
	  "operations":[
	    {"id":"schedule-zot-tomorrow","type":"offer_schedule","schedule_offer":{"title":"Check Zot tomorrow","prompt":"Check Zot logs for the fixed authentication failure.","recurrence":"once","start_at":"2026-08-12T20:00:00Z","timezone":"America/Merida","expires_in":"7d"}},
	    {"id":"schedule-zot-three-days","type":"offer_schedule","schedule_offer":{"title":"Check Zot in three days","prompt":"Check Zot logs for the fixed authentication failure.","recurrence":"once","start_at":"2026-08-14T20:00:00Z","timezone":"America/Merida","expires_in":"7d"}},
	    {"id":"complete","type":"complete_episode","completion":{"message":"I can schedule both checks together."}}
	  ]
	}`, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}

	effects := resultSideEffects(parsed, "completed")
	if len(effects) != 2 {
		t.Fatalf("effects = %+v, want two scheduled task offers", effects)
	}
	if effects[0].Kind != "scheduled task" || effects[0].Title != "Check Zot tomorrow" ||
		effects[1].Kind != "scheduled task" || effects[1].Title != "Check Zot in three days" {
		t.Fatalf("effects = %+v, want both scheduled task offers in order", effects)
	}
}

func TestEpisodeTimelineDoesNotTruncateEpisodeOwnedRecords(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	for index := 0; index < 425; index++ {
		fixture.exec(`INSERT INTO work_episode_events
		  (id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at)
		  VALUES (?, 'episode-1', ?, ?, 'responder', ?, ?, ?)`,
			fmt.Sprintf("event-%03d", index), index+1, fmt.Sprintf("event.%03d", index),
			fmt.Sprintf("event-idem-%03d", index), fmt.Sprintf(`{"index":%d}`, index), fixture.stamp)
	}
	for index := 0; index < 125; index++ {
		fixture.exec(`INSERT INTO evidence
		  (id, channel_id, source_input, claim, observation, source_type, source_name,
		   target, created_at)
		  VALUES (?, 'C1', 'input-1', ?, ?, 'tool', ?, ?, ?)`,
			fmt.Sprintf("evidence-%03d", index), fmt.Sprintf("claim %03d", index),
			fmt.Sprintf("observation %03d", index), fmt.Sprintf("source %03d", index),
			fmt.Sprintf("target %03d", index), fixture.stamp)
	}
	for index := 0; index < 75; index++ {
		fixture.exec(`INSERT INTO audit_events
		  (id, kind, actor_id, object_id, outcome, detail, created_at)
		  VALUES (?, 'episode.test', 'responder', 'run-1', 'recorded', ?, ?)`,
			fmt.Sprintf("audit-%03d", index), fmt.Sprintf("audit detail %03d", index), fixture.stamp)
	}
	fixture.exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, result_json, terminal_state, state,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id, attempt_id, attempt_number)
	  VALUES ('run-2','triage','C1','1786000000.000001','C1:1786000000.000001',
	          'recheck','input-2','U1','emisar','idem-2',?,'completed','completed',
	          ?,?,?,?,'episode-1','attempt-2',2)`, fixture.result, fixture.stamp,
		fixture.stamp, fixture.stamp, fixture.stamp)
	for index := 0; index < 3; index++ {
		fixture.exec(`INSERT INTO episode_wakeups
		  (id, episode_id, kind, event_matcher_json, state, last_observation_json,
		   created_at, updated_at)
		  VALUES (?, 'episode-1', 'terraform_run', ?, 'pending', '{}', ?, ?)`,
			fmt.Sprintf("wakeup-%d", index), fmt.Sprintf(`{"run_id":"run-%d"}`, index),
			fixture.stamp, fixture.stamp)
	}

	reader := fixture.reader()
	defer reader.Close()
	ctx := context.Background()
	assertLength := func(name string, got any, length, want int) {
		t.Helper()
		if length != want {
			t.Fatalf("%s length = %d, want %d: %#v", name, length, want, got)
		}
	}
	events, err := reader.Events(ctx, "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	assertLength("events", events, len(events), 425)
	evidence, err := reader.Evidence(ctx, "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	assertLength("evidence", evidence, len(evidence), 125)
	audit, err := reader.AuditForEpisode(ctx, "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	assertLength("audit", audit, len(audit), 75)
	turns, err := reader.Turns(ctx, "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	assertLength("turns", turns, len(turns), 2)
	wakeups, err := reader.Wakeups(ctx, "episode-1", "")
	if err != nil {
		t.Fatal(err)
	}
	assertLength("wakeups", wakeups, len(wakeups), 3)
}

func TestEpisodeTimelinePreservesEveryFoldedOccurrence(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	for index, second := range []int{1, 7, 19} {
		at := time.Date(2026, 8, 11, 12, 0, second, 0, time.UTC).Format(time.RFC3339Nano)
		fixture.exec(`INSERT INTO work_episode_events
		  (id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at)
		  VALUES (?, 'episode-1', ?, 'waiting', 'responder', ?, '{"status":"Waiting"}', ?)`,
			fmt.Sprintf("repeat-%d", index), index+1, fmt.Sprintf("repeat-idem-%d", index), at)
	}
	for index, second := range []int{2, 8, 20} {
		at := time.Date(2026, 8, 11, 12, 1, second, 0, time.UTC).Format(time.RFC3339Nano)
		fixture.exec(`INSERT INTO audit_events
		  (id, kind, actor_id, object_id, outcome, detail, created_at)
		  VALUES (?, 'episode.test', 'responder', 'run-1', 'recorded', 'same audit', ?)`,
			fmt.Sprintf("repeat-audit-%d", index), at)
	}

	reader := fixture.reader()
	defer reader.Close()
	events, err := reader.Events(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	audit, err := reader.AuditForEpisode(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Occurrences) != 3 {
		t.Fatalf("folded events = %+v, want one event with three occurrences", events)
	}
	if len(audit) != 1 || len(audit[0].Occurrences) != 3 {
		t.Fatalf("folded audit = %+v, want one row with three occurrences", audit)
	}
	trace := buildEpisodeTrace(config.Pricing{}, episodePage{Events: events, Audit: audit}, nil)
	occurrenceDetails := 0
	for _, step := range trace.Steps {
		for _, detail := range step.Details {
			if detail.Label != "All occurrences" {
				continue
			}
			occurrenceDetails++
			if detail.Count != 3 || detail.Open || !strings.Contains(detail.Body, "2026-08-11 12:") {
				t.Fatalf("occurrence detail = %+v", detail)
			}
		}
	}
	if occurrenceDetails != 2 {
		t.Fatalf("occurrence detail count = %d, want 2", occurrenceDetails)
	}
}

func TestEpisodeArtifactsCoverEveryDurableLifecycle(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	fixture.exec(`INSERT INTO commitments (episode_id, title)
	  VALUES ('episode-1', 'Own the rollout review')`)
	fixture.exec(`INSERT INTO work_episode_progress
	  (id, episode_id, sequence, phase, summary, created_at)
	  VALUES ('progress-1','episode-1',1,'investigating','Checking the rollout',?)`, fixture.stamp)
	fixture.exec(`INSERT INTO episode_goals
	  (id, episode_id, kind, requested_outcome, completion_contract,
	   authority_requirement, state, created_at, updated_at)
	  VALUES ('goal-1','episode-1','verification','Verify production health',
	          'Report a decision with fresh evidence','read_only','completed',?,?)`, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO scheduled_tasks
	  (id, team_id, channel_id, repository, title, prompt, recurrence, start_at,
	   actor_id, source_ref, expires_at, created_at, updated_at)
	  VALUES ('task-1','T1','C1','emisar','Daily health review','Check production health',
	          'once',?,'U1','slack:C1:1786000000.000001',?,?,?)`,
		fixture.stamp, fixture.expires, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO scheduled_task_runs
	  (task_id, scheduled_for, source_input, agent_run_id, outcome, started_at,
	   completed_at, created_at, updated_at, episode_id)
	  VALUES ('task-1',?,'input-1','run-1','completed',?,?,?,?, 'episode-1')`,
		fixture.stamp, fixture.stamp, fixture.stamp, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO evaluation_decisions
	  (id, channel_id, source_input, mode, action, reason, evidence_count,
	   coverage_count, created_at)
	  VALUES ('evaluation-1','C1','input-1','proactive','reply',
	          'The alert needs investigation',3,2,?)`, fixture.stamp)
	fixture.exec(`INSERT INTO standing_rules
	  (id, channel_id, repository, trigger_name, action_name, source_kind,
	   source_ref, actor_id, expires_at, created_at, updated_at)
	  VALUES ('rule-1','C1','emisar','terraform_plan','review_terraform_plan','app',
	          'slack:C1:rule','U1',?,?,?)`, fixture.expires, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO standing_rule_runs
	  (rule_id, source_input, event_id, outcome, created_at)
	  VALUES ('rule-1','input-1','event-1','completed',?)`, fixture.stamp)
	fixture.exec(`INSERT INTO standing_assignments
	  (id, channel_id, signal_pattern, repository, path_globs_json, change_class,
	   daily_budget, actor_id, enabled, confirmed_at, expires_at, created_at, updated_at)
	  VALUES ('assignment-1','C1','dependency update','emisar','["portal/**"]',
	          'dependency_upgrade',2,'U1',1,?,?,?,?)`,
		fixture.stamp, fixture.expires, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO standing_assignment_actions
	  (id, assignment_id, correlation_key, episode_id, outcome, created_at)
	  VALUES ('assignment-action-1','assignment-1','dependency:one','episode-1','prepared',?)`, fixture.stamp)
	fixture.exec(`INSERT INTO feedback_items
	  (id, workspace_id, channel_id, thread_ts, message_ts, target_message_ts,
	   user_id, source, category, sentiment, summary, details, context_json,
	   episode_id, agent_run_id, source_ref, status, created_at, updated_at)
	  VALUES ('feedback-1','T1','C1','1786000000.000001','1786000001.000001',
	          '1786000000.000001','U1','message','correction','negative',
	          'The reply missed the rollout','Use exact deployment evidence','{}',
	          'episode-1','run-1','slack:C1:1786000001.000001','open',?,?)`, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO fixture_candidates
	  (id, episode_id, run_id, capability, correction_class, correction, status,
	   reviewed_by, created_at, expires_at, updated_at)
	  VALUES ('candidate-1','episode-1','run-1','triage','unsupported_claim',
	          'Do not claim recovery from alert state alone','pending','',?,?,?)`,
		fixture.stamp, fixture.expires, fixture.stamp)
	fixture.exec(`INSERT INTO incidents
	  (id, route, repository, correlation_key, title, status, workflow, created_at, updated_at)
	  VALUES ('incident-1','slack','emisar','correlation-1','Production rollout','active',
	          'investigate',?,?)`, fixture.stamp, fixture.stamp)
	fixture.exec(`UPDATE agent_runs SET incident_id = 'incident-1' WHERE id = 'run-1'`)
	fixture.exec(`INSERT INTO timeline_events
	  (id, incident_id, channel_id, kind, actor_id, title, detail, created_at)
	  VALUES ('timeline-1','incident-1','C1','investigation','responder',
	          'Rollout inspected','The new allocation is healthy',?)`, fixture.stamp)
	fixture.exec(`INSERT INTO publications
	  (incident_id, repository, base_branch, head_branch, parent_head, candidate_tree,
	   commit_sha, remote_sha, pr_number, pr_url, state, created_at, updated_at, published_at)
	  VALUES ('incident-1','emisar','main','responder/fix','parent','tree','commit','remote',
	          42,'https://github.com/example/emisar/pull/42','published',?,?,?)`,
		fixture.stamp, fixture.stamp, fixture.stamp)
	fixture.exec(`INSERT INTO publication_lifecycle_events
	  (id, incident_id, kind, state, summary, source_channel_id, source_message_ts, created_at)
	  VALUES ('publication-event-1','incident-1','checks','passed',
	          'All checks passed','C1','1786000000.000001',?)`, fixture.stamp)
	fixture.exec(`INSERT INTO quality_findings
	  (id, run_id, episode_ids, channel_id, verdict, disposition, severity, summary,
	   expected_behavior, evidence, code_evidence, suspected_components,
	   regression_test, challenger_summary, challenger_evidence, artifacts, created_at)
	  VALUES ('finding-1','run-1','["episode-1"]','C1','confirmed','integrated','high',
	          'The reply was incomplete','Show the complete lifecycle','["slack"]',
	          '["reader"]','["internal/webui"]','TestEpisodeArtifactsCoverEveryDurableLifecycle',
	          'The finding survived review','["fixture"]','quality/finding-1',?)`, fixture.stamp)

	reader := fixture.reader()
	defer reader.Close()
	artifacts, err := reader.Artifacts(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	wantKinds := map[string]int{
		"commitment": 1, "progress": 1, "goal": 1, "scheduled_run": 1,
		"evaluation": 1, "standing_rule_run": 1, "standing_assignment_action": 1,
		"feedback": 1, "replay_candidate": 1, "incident_timeline": 1,
		"publication_lifecycle": 1, "publication": 1, "quality_finding": 1,
	}
	gotKinds := make(map[string]int, len(wantKinds))
	for _, artifact := range artifacts {
		gotKinds[artifact.Kind]++
		if artifact.ID == "" || artifact.Title == "" || artifact.State == "" {
			t.Fatalf("artifact has an incomplete identity: %+v", artifact)
		}
	}
	if len(gotKinds) != len(wantKinds) {
		t.Fatalf("artifact kinds = %v, want %v", gotKinds, wantKinds)
	}
	for kind, want := range wantKinds {
		if got := gotKinds[kind]; got != want {
			t.Fatalf("artifact kind %q count = %d, want %d; all kinds = %v", kind, got, want, gotKinds)
		}
	}
	trace := buildEpisodeTrace(config.Pricing{}, episodePage{Artifacts: artifacts}, nil)
	artifactSteps := 0
	for _, step := range trace.Steps {
		if !strings.HasPrefix(step.ID, "record-") {
			continue
		}
		artifactSteps++
		for _, detail := range step.Details {
			if detail.Open {
				t.Fatalf("large artifact detail is open by default: %+v", step)
			}
		}
	}
	if artifactSteps != 13 {
		t.Fatalf("artifact trace steps = %d, want 13", artifactSteps)
	}
}

func TestEpisodeArtifactsKeepPublicationWhenIncidentTimelineIsUnavailable(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	fixture.exec(`INSERT INTO incidents
	  (id, route, repository, correlation_key, title, status, workflow, created_at, updated_at)
	  VALUES ('incident-1','slack','emisar','correlation-1','Production rollout','active',
	          'investigate',?,?)`, fixture.stamp, fixture.stamp)
	fixture.exec(`UPDATE agent_runs SET incident_id = 'incident-1' WHERE id = 'run-1'`)
	fixture.exec(`INSERT INTO publications
	  (incident_id, repository, base_branch, head_branch, parent_head, candidate_tree,
	   commit_sha, remote_sha, pr_number, pr_url, state, created_at, updated_at, published_at)
	  VALUES ('incident-1','emisar','main','responder/fix','parent','tree','commit','remote',
	          42,'https://github.com/example/emisar/pull/42','published',?,?,?)`,
		fixture.stamp, fixture.stamp, fixture.stamp)
	fixture.closeAndDrop("timeline_events")

	reader, err := OpenReader(fixture.path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	artifacts, err := reader.Artifacts(context.Background(), "episode-1")
	if err == nil || !strings.Contains(err.Error(), "timeline") {
		t.Fatalf("projection error = %v, want timeline failure", err)
	}
	for _, artifact := range artifacts {
		if artifact.Kind == "publication" && artifact.ID == "incident-1" {
			return
		}
	}
	t.Fatalf("partial artifacts = %+v, projection error = %v, want publication retained", artifacts, err)
}

func TestEpisodeArtifactsReturnPartialResultsWhenOptionalProjectionIsMissing(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	fixture.exec(`INSERT INTO commitments (episode_id, title)
	  VALUES ('episode-1', 'Keep the usable trace')`)
	if err := fixture.db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", fixture.path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DROP TABLE quality_findings`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	fixture.db = nil

	reader, err := OpenReader(fixture.path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	artifacts, err := reader.Artifacts(context.Background(), "episode-1")
	if err == nil || !strings.Contains(err.Error(), "quality findings") {
		t.Fatalf("projection error = %v, want the unavailable projection named", err)
	}
	if len(artifacts) != 1 || artifacts[0].Kind != "commitment" {
		t.Fatalf("partial artifacts = %+v, want the usable commitment", artifacts)
	}
}

func TestEpisodeSideEffectsPreserveTurnChronologyAndPreferConfirmedMemory(t *testing.T) {
	t1 := time.Date(2026, 8, 10, 8, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Minute)
	t3 := t2.Add(time.Minute)
	turns := []Turn{
		{Updated: t1, Effects: []SideEffect{
			{Kind: "standing rule", State: "offered", Title: "Review plans"},
			{Kind: "conversation memory", State: "saved", Title: "Goal", Detail: "Old goal"},
		}},
		{Updated: t2, Effects: []SideEffect{
			{Kind: "scheduled task", State: "offered", Title: "Daily review"},
		}},
	}
	confirmed := []SideEffect{
		{Kind: "conversation memory", State: "saved", Title: "Goal", Detail: "Current goal", At: t3},
	}

	effects := episodeSideEffects(turns, confirmed)
	if len(effects) != 3 {
		t.Fatalf("effects = %+v, want two inferred offers and one confirmed memory change", effects)
	}
	if effects[0].Title != "Review plans" || !effects[0].At.Equal(t1) {
		t.Fatalf("first effect = %+v, want first turn timestamp", effects[0])
	}
	if effects[1].Title != "Daily review" || !effects[1].At.Equal(t2) {
		t.Fatalf("second effect = %+v, want second turn timestamp", effects[1])
	}
	if effects[2].Detail != "Current goal" || !effects[2].At.Equal(t3) {
		t.Fatalf("confirmed effect = %+v", effects[2])
	}
}

func TestSuccessorSideEffectUsesCompletionAndReplyTimes(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	created := time.Date(2026, 8, 11, 12, 5, 0, 0, time.UTC)
	completed := created.Add(10 * time.Minute)
	replied := completed.Add(2 * time.Second)
	stamp := func(value time.Time) string { return value.Format(time.RFC3339Nano) }
	fixture.exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, terminal_state, state,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id)
	  VALUES ('run-child','triage','C1','1786000000.000001','C1:1786000000.000001',
	          'recheck','child-source','U1','emisar','idem-child','completed','completed',
	          ?,?,?,?,'episode-child')`, stamp(created), stamp(created), stamp(completed), stamp(completed))
	fixture.exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, phase, status, next_action,
	   created_at, updated_at, completed_at, lifecycle_state, parent_episode_id,
	   channel_id, thread_ts, anchor_ts)
	  VALUES ('episode-child','run-child','focused_check','read_only','No theories?',
	          'finished','Completed','',?,?,?,'completed','episode-1','C1',
	          '1786000000.000001','1786000000.000001')`, stamp(created), stamp(completed), stamp(completed))
	fixture.exec(`INSERT INTO slack_deliveries
	  (id, operation, kind, channel_id, thread_ts, message_ts, body_json, state,
	   next_attempt_at, created_at, updated_at, episode_id, response_root)
	  VALUES ('child-reply','post','notice','C1','1786000000.000001','1786000602.000001',
	          '{}','sent',?,?,?,'episode-child',1)`, stamp(created), stamp(completed), stamp(replied))
	reader := fixture.reader()
	defer reader.Close()
	effects, err := reader.SideEffects(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(effects) != 1 || effects[0].ID != "episode-child" ||
		!effects[0].At.Equal(completed) || !effects[0].Responded ||
		!effects[0].ResponseAt.Equal(replied) {
		t.Fatalf("successor effect = %+v", effects)
	}
}

func TestSuccessorReplyFollowsTheWholeEpisodeChain(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	stamp := func(second int) string {
		return time.Date(2026, 8, 11, 12, 0, second, 0, time.UTC).Format(time.RFC3339Nano)
	}
	for _, episode := range []struct {
		id, parent, run string
		second          int
	}{
		{"episode-child", "episode-1", "run-child", 10},
		{"episode-grandchild", "episode-child", "run-grandchild", 20},
	} {
		fixture.exec(`INSERT INTO agent_runs
		  (id, mode, channel_id, conversation_key, source_kind, source_id, user_id,
		   idempotency_key, terminal_state, state, next_attempt_at, created_at,
		   updated_at, completed_at, episode_id)
		  VALUES (?, 'triage', 'C1', ?, 'recheck', ?, 'U1', ?, 'completed',
		          'completed', ?, ?, ?, ?, ?)`, episode.run, episode.id,
			episode.id+"-source", episode.id+"-key", stamp(episode.second),
			stamp(episode.second), stamp(episode.second), stamp(episode.second), episode.id)
		fixture.exec(`INSERT INTO work_episodes
		  (id, agent_run_id, effort, authority, objective, phase, status, next_action,
		   created_at, updated_at, completed_at, lifecycle_state, parent_episode_id)
		  VALUES (?, ?, 'focused_check', 'read_only', ?, 'finished', 'Completed', '',
		          ?, ?, ?, 'completed', ?)`, episode.id, episode.run, episode.id,
			stamp(episode.second), stamp(episode.second), stamp(episode.second), episode.parent)
	}
	fixture.exec(`INSERT INTO slack_deliveries
	  (id, operation, kind, channel_id, message_ts, body_json, state,
	   next_attempt_at, created_at, updated_at, episode_id, response_root)
	  VALUES ('grandchild-reply','post','notice','C1','1700.1','{}','sent',
	          ?,?,?,'episode-grandchild',1)`, stamp(20), stamp(20), stamp(21))
	reader := fixture.reader()
	defer reader.Close()
	effects, err := reader.SideEffects(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	page := episodePage{Item: Item{State: "superseded"}, Source: SourceInput{
		Received: time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC),
	}, Effects: effects}
	metrics := episodeMetrics(config.Pricing{}, page)
	if len(effects) != 2 || effects[0].Responded || !effects[1].Responded ||
		metrics[1].Missing || metrics[1].Value != "21.0s" {
		t.Fatalf("chain effects=%+v response=%+v", effects, metrics[1])
	}
}

func TestEpisodeTimelineStartsWithExplicitMissingInput(t *testing.T) {
	created := time.Date(2026, 8, 10, 8, 0, 0, 0, time.UTC)
	trace := buildEpisodeTrace(config.Pricing{}, episodePage{
		Item: Item{Created: created},
		Rejections: []Rejection{{
			RunID: "run-1", Outcome: "corrected", Detail: "The result did not match the contract.",
			At: created.Add(time.Second),
		}},
	}, nil)

	if len(trace.Steps) < 2 {
		t.Fatalf("trace steps = %+v", trace.Steps)
	}
	if trace.Steps[0].ID != "source-missing" || trace.Steps[0].Title != "Starting input unavailable" {
		t.Fatalf("first step = %+v", trace.Steps[0])
	}
	if trace.Steps[1].ID != "rejection-1" {
		t.Fatalf("second step = %+v, want host rejection after explicit input gap", trace.Steps[1])
	}
}

func TestEpisodeProjectionInventoryCoversEveryEpisodeLinkedTable(t *testing.T) {
	fixture := newEpisodeProjectionFixture(t)
	defer fixture.db.Close()

	// Each entry names the reader surface responsible for rendering records from
	// that table. Keeping the inventory next to the projection tests makes a new
	// episode-owned table fail loudly until the timeline has an intentional home.
	projected := map[string]string{
		"agent_runs":                  "model turns",
		"claim_assessments":           "claim ledger",
		"commitments":                 "durable records",
		"context_manifests":           "prompt manifests",
		"conversation_memory_changes": "memory changes",
		"episode_attempts":            "attempts and corrections",
		"episode_goals":               "durable records",
		"episode_wakeups":             "automatic follow-ups",
		"feedback_items":              "durable records",
		"fixture_candidates":          "durable records",
		"quality_findings":            "durable records",
		"scheduled_task_runs":         "durable records",
		"slack_deliveries":            "Slack deliveries",
		"standing_assignment_actions": "durable records",
		"work_episode_events":         "episode event stream",
		"work_episode_progress":       "durable records",
	}

	rows, err := fixture.db.Query(`
	  SELECT DISTINCT m.name
	  FROM sqlite_master AS m
	  JOIN pragma_table_info(m.name) AS p
	  WHERE m.type = 'table' AND p.name IN ('episode_id', 'episode_ids')
	  ORDER BY m.name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	actual := map[string]bool{}
	for rows.Next() {
		var table string
		if err := rows.Scan(&table); err != nil {
			t.Fatal(err)
		}
		actual[table] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}

	var missingSurface, staleInventory []string
	for table := range actual {
		if projected[table] == "" {
			missingSurface = append(missingSurface, table)
		}
	}
	for table := range projected {
		if !actual[table] {
			staleInventory = append(staleInventory, table)
		}
	}
	sort.Strings(missingSurface)
	sort.Strings(staleInventory)
	if len(missingSurface) > 0 || len(staleInventory) > 0 {
		t.Fatalf("episode projection inventory drifted; missing surfaces=%v stale entries=%v", missingSurface, staleInventory)
	}
}

type episodeProjectionFixture struct {
	t              *testing.T
	db             *sql.DB
	path           string
	stamp, expires string
	result         string
}

func (f *episodeProjectionFixture) closeAndDrop(table string) {
	f.t.Helper()
	if err := f.db.Close(); err != nil {
		f.t.Fatal(err)
	}
	db, err := sql.Open("sqlite", f.path)
	if err != nil {
		f.t.Fatal(err)
	}
	if _, err := db.Exec(`DROP TABLE ` + table); err != nil {
		f.t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		f.t.Fatal(err)
	}
	f.db = nil
}

func newEpisodeProjectionFixture(t *testing.T) *episodeProjectionFixture {
	t.Helper()
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
	stamp := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	fixture := &episodeProjectionFixture{
		t: t, db: db, path: path, stamp: stamp,
		expires: time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano),
		result:  `{"action":"reply","message":"Done.","reason":"The work is complete."}`,
	}
	fixture.exec(`INSERT INTO slack_channel_memberships (channel_id, channel_name, observed_at)
	  VALUES ('C1','infra',?)`, stamp)
	fixture.exec(`INSERT INTO slack_inputs
	  (id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
	   user_id, text, state, next_attempt_at, received_at, updated_at)
	  VALUES ('input-1','envelope-1','event-1','message','T1','C1','1786000000.000001',
	          '1786000000.000001','U1','Check the rollout','completed',?,?,?)`,
		stamp, stamp, stamp)
	fixture.exec(`INSERT INTO slack_inputs
	  (id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
	   user_id, text, state, next_attempt_at, received_at, updated_at)
	  VALUES ('input-2','envelope-2','event-2','recheck','T1','C1','1786000000.000001',
	          '','U1','Continue the rollout check','completed',?,?,?)`, stamp, stamp, stamp)
	fixture.exec(`INSERT INTO agent_runs
	  (id, mode, channel_id, thread_ts, conversation_key, source_kind, source_id,
	   user_id, repository, idempotency_key, result_json, terminal_state, state,
	   next_attempt_at, created_at, updated_at, completed_at, episode_id, attempt_id, attempt_number)
	  VALUES ('run-1','triage','C1','1786000000.000001','C1:1786000000.000001',
	          'watch','input-1','U1','emisar','idem-1',?,'completed','completed',
	          ?,?,?,?,'episode-1','attempt-1',1)`, fixture.result, stamp, stamp, stamp, stamp)
	fixture.exec(`INSERT INTO work_episodes
	  (id, agent_run_id, effort, authority, objective, phase, status, next_action,
	   created_at, updated_at, completed_at, lifecycle_state, channel_id, thread_ts,
	   anchor_ts, latest_attempt_id)
	  VALUES ('episode-1','run-1','focused_check','read_only','Check the rollout',
	          'complete','Completed','None',?,?,?,'completed','C1','1786000000.000001',
	          '1786000000.000001','attempt-1')`, stamp, stamp, stamp)
	return fixture
}

func (f *episodeProjectionFixture) exec(query string, args ...any) {
	f.t.Helper()
	if f.db == nil {
		f.t.Fatal("fixture database is closed")
	}
	if _, err := f.db.ExecContext(context.Background(), query, args...); err != nil {
		f.t.Fatalf("seed: %v\n%s", err, query)
	}
}

func (f *episodeProjectionFixture) reader() *Reader {
	f.t.Helper()
	if f.db != nil {
		if err := f.db.Close(); err != nil {
			f.t.Fatal(err)
		}
		f.db = nil
	}
	reader, err := OpenReader(f.path)
	if err != nil {
		f.t.Fatal(err)
	}
	return reader
}

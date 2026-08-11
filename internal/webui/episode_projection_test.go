package webui

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
		"Operational memory",
		"Conversation memory",
		"Related conversation summaries",
		"Source Slack message",
		"User request",
		"tokens",
		"Time to respond",
		"Episode cost / tokens",
		"47.9s",
		"Started 2026-08-10 08:14 UTC",
		"Time to react",
		"1.4s",
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

func TestPromptContextDetailsExplainSlackAndOperationalMemory(t *testing.T) {
	prompt := `SYSTEM
<untrusted-slack-context>
{
  "channel_id":"C1",
  "repository":"emisar",
  "target_message":{"message_ts":"1786408526.961689","sender_id":"U1","text":"check this","mentions_responder":true},
  "recent_messages":[{"message_ts":"1786408500.100","sender_id":"U2","text":"deploy finished"}],
  "structured_memory":{"goal":"Verify the rollout","constraints":["Reply in threads"]},
  "prior_operational_context":{"recent_same_channel_evidence":[{"id":"ev_secret","claim":"The rollout finished","observation":"All checks passed","source_type":"github","source_name":"GitHub checks","observed_at":"2026-08-10T08:00:00Z","confidence":"high"}]}
}
</untrusted-slack-context>
USER: check this`
	present := func(value string) string {
		return strings.NewReplacer("<@U1>", "@Andrew Dryga", "<@U2>", "@Trevin Miller", "C1", "#infra").Replace(value)
	}
	details, layers := promptContextDetails(prompt, present)
	if layers != 2 {
		t.Fatalf("memory layers = %d, want 2", layers)
	}
	joined := ""
	for _, detail := range details {
		joined += detail.Label + "\n" + detail.Body + "\n"
	}
	for _, want := range []string{
		"Operational memory · Recent same channel evidence",
		"The rollout finished", "Observed: All checks passed", "Source: GitHub checks",
		"Conversation memory · Goal", "Verify the rollout", "Source Slack message",
		"@Andrew Dryga\ncheck this", "Recent Slack messages", "@Trevin Miller\ndeploy finished",
		"Slack channel\n#infra", "Repository selection\nemisar",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("readable prompt context missing %q:\n%s", want, joined)
		}
	}
	for _, unwanted := range []string{"ev_secret", "mentions_responder", `"sender_id"`} {
		if strings.Contains(joined, unwanted) {
			t.Fatalf("prompt context leaked storage field %q:\n%s", unwanted, joined)
		}
	}
}

func TestContextReferenceDetailsSeparateReplayMetadataFromInputs(t *testing.T) {
	details := contextReferenceDetails([]ContextRef{
		{Kind: "source_input", What: "watch in #infra", Visibility: "eligible"},
		{Kind: "compiled_prompt", What: "attempt run_secret", Visibility: "private", Digest: "abc123"},
		{Kind: "assembled_context", What: "attempt run_secret", Visibility: "private", Digest: "def456"},
		{Kind: "repository", What: "emisar @ deadbeef", Visibility: "eligible"},
		{Kind: "execution_policy", What: "emisar-conversation", Visibility: "private"},
	}, func(value string) string { return value })
	if len(details) != 3 {
		t.Fatalf("context details = %+v, want repository, policy, and replay metadata", details)
	}
	joined := ""
	for _, detail := range details {
		joined += detail.Label + "\n" + detail.Body + "\n"
	}
	for _, want := range []string{"Repository snapshot", "Execution policy", "Replay metadata", "Prompt fingerprint: abc123", "Assembled context fingerprint: def456"} {
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

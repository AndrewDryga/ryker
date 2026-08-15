package service

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// runOneTriageTurn drives a single Slack mention to a finished agent run and
// returns the episode's context manifest, which is the per-attempt row usage is
// recorded on.
func runOneTriageTurn(
	t *testing.T,
	coopClient *fakeCoop,
) core.ContextManifest {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack_usage", EnvelopeID: "env_usage", EventID: "EvUsage",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.300", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> is the API healthy?",
	}); err != nil || !created {
		t.Fatalf("admit mention = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	run, err := st.GetAgentRunBySource(ctx, "watch", "slack_usage")
	if err != nil {
		t.Fatalf("load the agent run: %v", err)
	}
	manifest, err := st.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		t.Fatalf("load the attempt context manifest: %v", err)
	}
	return manifest
}

// The whole point of the feature: a turn Coop measured has to reach the row the
// control plane reads, or the Usage page shows nothing while the numbers exist
// one API call away.
func TestFinishedTurnRecordsItsTokensOnTheAttemptManifest(t *testing.T) {
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"The API is healthy."}`
	coopClient.completeUsage = coop.Usage{
		InputTokens: 4200, CachedInputTokens: 3100, OutputTokens: 260, ReasoningTokens: 48,
	}
	manifest := runOneTriageTurn(t, coopClient)
	want := core.ContextUsage{
		InputTokens: 4200, CachedInputTokens: 3100, OutputTokens: 260, ReasoningTokens: 48,
	}
	if manifest.Usage != want {
		t.Fatalf("attempt usage = %+v, want %+v", manifest.Usage, want)
	}
}

// An adapter that reports nothing must leave the row saying so. ACP does not
// require usage, and a zero written as though it were measured would let the
// control plane present "0 tokens" for a turn nobody counted — a guess wearing
// the clothes of a measurement.
func TestUnmeasuredTurnLeavesTheAttemptManifestUnrecorded(t *testing.T) {
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"The API is healthy."}`
	manifest := runOneTriageTurn(t, coopClient)
	if manifest.Usage.Recorded() {
		t.Fatalf("an unmeasured turn was recorded as usage: %+v", manifest.Usage)
	}
}

// Timing has to land even when tokens do not, which today is every real turn:
// Coop's ACP path reports no usage at all, so a latency write conditioned on
// tokens would record nothing and the wall-clock columns would stay as empty as
// the ones they were added to fill.
func TestFinishedTurnRecordsItsWallClockWithoutAnyTokens(t *testing.T) {
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"The API is healthy."}`
	coopClient.completeQueuedAt = time.Date(2026, 8, 8, 12, 0, 0, 0, time.UTC)
	coopClient.completeQueuedFor = 400 * time.Millisecond
	coopClient.completeProviderDuration = 37 * time.Second
	manifest := runOneTriageTurn(t, coopClient)
	if manifest.Usage.Recorded() {
		t.Fatalf("a turn with no reported tokens invented some: %+v", manifest.Usage)
	}
	if !manifest.Latency.Recorded() {
		t.Fatalf("a timed turn reported no latency: %+v", manifest.Latency)
	}
	if manifest.Latency.Turns != 1 ||
		manifest.Latency.Queued != 400*time.Millisecond ||
		manifest.Latency.Provider != 37*time.Second {
		t.Fatalf("attempt latency = %+v", manifest.Latency)
	}
}

// A turn Coop never timestamped must not read as an instant one. The
// distinction is the same one the token columns keep, and for the same reason:
// "nobody measured this" and "this took no time" are different claims and only
// one of them is ever true.
func TestUntimedTurnLeavesTheAttemptLatencyUnrecorded(t *testing.T) {
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"The API is healthy."}`
	manifest := runOneTriageTurn(t, coopClient)
	if manifest.Latency.Recorded() {
		t.Fatalf("an untimed turn was recorded as latency: %+v", manifest.Latency)
	}
}

// The budget path has been trimming watch context for as long as it has
// existed and never wrote down a word of it, so every manifest on the deployed
// databases claims nothing was ever left out. What the model is told it is
// missing has to reach the record too, or "why did it say that" stays
// unanswerable an hour later.
func TestDroppedContextLayersReachTheAttemptManifest(t *testing.T) {
	var recent []decisionpkg.WatchContextMessage
	for index := range 400 {
		recent = append(recent, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("1700.%03d", index),
			SenderID:  "U123ABC", SenderType: "operator",
			Text: strings.Repeat("an operator said something at length. ", 40),
		})
	}
	cfg := serviceConfig(t)
	_, omitted := (&Service{cfg: cfg}).watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.400",
			UserID: cfg.Slack.Operators[0], Kind: "message",
			Text: "How is the health of our infrastructure?",
		},
		"U999BOT", false, recent, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, "", nil, WatchPromptBudget(0),
	)
	if len(omitted) == 0 {
		t.Fatal("a prompt trimmed to fit reported nothing omitted")
	}
	for _, omission := range omitted {
		if omission.Kind == "" || omission.SourceRef == "" || omission.Reason == "" {
			t.Fatalf("an omission cannot be read back: %+v", omission)
		}
	}
	references := core.OmittedContextReferences(omitted)
	if len(references) != len(omitted) {
		t.Fatalf("recorded %d references for %d omissions", len(references), len(omitted))
	}
	for _, reference := range references {
		// The store treats an empty omitted_reason as "this went in", so a
		// reference recording a gap has to carry one or it silently becomes a
		// claim that the context was complete.
		if reference.OmittedReason == "" || reference.Visibility != "omitted" {
			t.Fatalf("an omitted reference reads as included: %+v", reference)
		}
	}
}

// Fixtures are harvested from context_manifests.submitted_prompt, which the
// repository treats as "the prompt that produced this result". For every
// corrected turn the column held the FIRST prompt: the attempt's manifest was
// written once, on the first prepare, and the retry that actually carried the
// <host-structured-correction> block reused it untouched. So the exact prompt
// that produced a broken production result was NOT on disk anywhere — the
// stored result_json was the corrected turn's and the stored prompt was the
// rejected turn's — and corrections are precisely the turns worth replaying.
// That pairing is the assumption the whole eval-fixture pipeline rests on.
func TestACorrectedRetryRecordsThePromptItActuallySent(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 3
	cfg.Slack.SummonChannels = []string{"CFOLLOW"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	// One envelope, twice: the first copy has its claim_id stripped so the host
	// refuses it, the second is the accepted original. Only the second prompt
	// can carry a correction block, so the two are trivially told apart.
	const evidence = `{"claim":"checkout latency cause",` +
		`"observation":"p99 write latency is 40ms on va1-cass-3","relation":"supports",` +
		`"health_effect":"risk","source_type":"monitoring","source_name":"grafana",` +
		`"confidence":"high","freshness":"live query",` +
		`"dimensions":{"service":"checkout","environment":"production"}}`
	envelope := func(evidenceJSON string) string {
		return `{"action":"reply",
			"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":2},
			"reason":"direct question with evidence",
			"operations":[
				{"id":"ev-1","type":"record_evidence","evidence":` + evidenceJSON + `},
				{"id":"complete","type":"complete_episode","completion":{"message":"Checkout is slow because va1-cass-3 writes at 40ms p99.","completion":{"status":"decision_ready","summary":"cause identified"}}}]}`
	}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		envelope(evidence),
		envelope(`{"claim_id":"application.functional_behavior",` + evidence[1:]),
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack-corrected-prompt", EnvelopeID: "env-corrected-prompt",
		EventID: "event-corrected-prompt", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CFOLLOW", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@U999BOT> why is checkout slow?",
	}); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err := st.GetAgentRunBySource(ctx, "watch", "slack-corrected-prompt")
	// Failures stays 0: a correction round is not a failed attempt, so the
	// pending state and the recorded correction are what say a retry is queued.
	if err != nil || run.State != core.AgentRunPending || run.Failures != 0 ||
		run.LastError == "" {
		t.Fatalf("the first turn was not corrected, so this test no longer "+
			"exercises a correction retry: run = %+v, %v", run, err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("expected a rejected turn and its corrected retry, got %d prompts",
			len(coopClient.submitPrompts))
	}
	const marker = "<host-structured-correction>"
	if strings.Contains(coopClient.submitPrompts[0], marker) {
		t.Fatal("the first prompt already carries a correction block; the two " +
			"submitted prompts are no longer distinguishable by it")
	}
	if !strings.Contains(coopClient.submitPrompts[1], marker) {
		t.Fatalf("the retry carried no correction block:\n%.2000s",
			coopClient.submitPrompts[1])
	}
	latest, err := st.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		t.Fatalf("load the episode's latest context manifest: %v", err)
	}
	if !strings.Contains(latest.SubmittedPrompt, marker) {
		t.Fatalf("the recorded prompt is not the one that produced the stored "+
			"result: the manifest holds the rejected turn's prompt, so this "+
			"episode's fixture would replay a prompt the model never answered:\n%.2000s",
			latest.SubmittedPrompt)
	}
	if latest.SubmittedPrompt != coopClient.submitPrompts[1] {
		t.Fatal("the recorded prompt is not byte-identical to the one submitted")
	}
	if latest.Version != 2 || latest.ParentManifestID == "" {
		t.Fatalf("the corrected retry did not extend the first manifest: "+
			"version = %d, parent = %q", latest.Version, latest.ParentManifestID)
	}
	first, err := st.GetContextManifest(ctx, latest.ParentManifestID)
	if err != nil {
		t.Fatalf("load the parent context manifest: %v", err)
	}
	if first.Version != 1 || first.SubmittedPrompt != coopClient.submitPrompts[0] {
		t.Fatalf("the first manifest no longer holds the rejected turn's prompt: "+
			"version = %d", first.Version)
	}
}

// The transport cuts the middle out of an oversized prompt. Before this the
// only trace was a process-local counter that knew how many prompts had been
// cut and never which episode's, so an operator holding one bad answer could
// not learn that half its context had been removed in flight.
func TestAnElidedPromptIsRecordedAgainstTheAttemptThatSufferedIt(t *testing.T) {
	over := core.AppendElidedPrompt(nil, "agent-run:run_1:prompt", coop.MaxPromptBytes+2048, coop.MaxPromptBytes)
	if len(over) != 1 {
		t.Fatalf("an oversized prompt recorded %d omissions", len(over))
	}
	if !strings.Contains(over[0].Reason, "2048 bytes") {
		t.Fatalf("the omission does not say how much was cut: %q", over[0].Reason)
	}
	if fits := core.AppendElidedPrompt(nil, "agent-run:run_1:prompt", 10, coop.MaxPromptBytes); len(fits) != 0 {
		t.Fatalf("a prompt that fits claimed it was elided: %+v", fits)
	}
}

// A prompt carries whatever the turn was assembled from, and this process knows
// its own credentials. The archive copy is the one an export would hand over —
// record-episode already refuses to write a fixture without running every
// string through the production sanitizer first, and the copy that now outlives
// the turn answers to the same rule or the discipline is one table wide.
//
// Redaction happens BEFORE the write, never on the way out, because a database
// that has held a secret has held it: a reader with a sqlite3 binary does not
// pass through the code that would have cleaned it.
func TestTheRetainedPromptIsRedactedBeforeItIsWritten(t *testing.T) {
	const secret = "xoxb-9911-not-a-real-token"
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"Rotated."}`
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000, secret), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack_secret", EnvelopeID: "env_secret", EventID: "EvSecret",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.400", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> the deploy is failing with " + secret + " in the log",
	}); err != nil || !created {
		t.Fatalf("admit mention = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	run, err := st.GetAgentRunBySource(ctx, "watch", "slack_secret")
	if err != nil {
		t.Fatalf("load the agent run: %v", err)
	}
	latest, err := st.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		t.Fatalf("load the attempt context manifest: %v", err)
	}
	manifest, err := st.GetContextManifest(ctx, latest.ID)
	if err != nil {
		t.Fatalf("re-read the manifest: %v", err)
	}
	if manifest.RetainedPrompt == "" {
		t.Fatal("no prompt was retained for the attempt, so nothing outlives the turn")
	}
	if strings.Contains(manifest.RetainedPrompt, secret) {
		t.Fatal("the retained prompt still carries the credential it was assembled with")
	}
	if !strings.Contains(manifest.RetainedPrompt, "[REDACTED]") {
		t.Fatalf("the retained prompt was not sanitized at all: %d bytes with no redaction",
			len(manifest.RetainedPrompt))
	}
	// The archive is a redaction OF the submitted prompt, not an alias for it.
	// Were these two ever the same string, the assertions above would pass just
	// as happily on a sanitizer that had been handed no secrets at all.
	if !strings.Contains(manifest.SubmittedPrompt, secret) {
		t.Fatal("the submitted prompt lost the credential too, so this test proves nothing " +
			"about the archive copy in particular")
	}
	// The service sanitizer bounds Slack messages at MaxAssistantBytes. Reaching
	// for it directly would quietly cut a real 175 KB prompt down to twelve
	// kilobytes and stamp "_Response truncated._" on the end of the archive.
	if strings.Contains(manifest.RetainedPrompt, "_Response truncated._") {
		t.Fatal("the retained prompt was truncated by the Slack-sized sanitizer")
	}
}

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
		"U999BOT", false, recent, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "", nil, WatchPromptBudget(0),
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

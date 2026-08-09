package service

import (
	"context"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
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

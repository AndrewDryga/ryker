package service

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestSuccessfulOutcomeClearsLegacyPausedReaction(t *testing.T) {
	slack := &fakeSlack{}
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Audit(context.Background(), core.AuditEvent{
		Kind: "slack.paused", ObjectID: "legacy-paused", Outcome: "queued",
	}); err != nil {
		t.Fatal(err)
	}
	svc := &Service{store: st, slack: slack, log: slog.New(slog.DiscardHandler)}
	svc.clearInputPaused(context.Background(), core.SlackInput{
		ID: "legacy-paused", ChannelID: "COPS", MessageTS: "1700.100",
	})
	if len(slack.removedReactions) != 1 ||
		slack.removedReactions[0].name != pausedReaction ||
		slack.removedReactions[0].channel != "COPS" ||
		slack.removedReactions[0].timestamp != "1700.100" {
		t.Fatalf("removed reactions = %+v", slack.removedReactions)
	}
	queued, err := st.PauseCleanup.Queued(context.Background(), "legacy-paused")
	if err != nil || queued {
		t.Fatalf("legacy pause remains queued = %t, %v", queued, err)
	}
}

func TestSuccessfulModernOutcomeDoesNotInventPauseHistory(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	(&Service{store: st, slack: slack, log: slog.New(slog.DiscardHandler)}).clearInputPaused(
		context.Background(), core.SlackInput{
			ID: "modern-input", ChannelID: "COPS", MessageTS: "1700.101",
		},
	)
	if len(slack.removedReactions) != 0 {
		t.Fatalf("modern input triggered legacy cleanup: %+v", slack.removedReactions)
	}
	queued, err := st.PauseCleanup.Queued(context.Background(), "modern-input")
	if err != nil || queued {
		t.Fatalf("modern input gained pause history = %t, %v", queued, err)
	}
}

func TestClearingLegacyPauseWithoutMessageOrSlackSupportIsHarmless(t *testing.T) {
	ctx := context.Background()
	(&Service{slack: &fakeSlack{}}).clearInputPaused(ctx, core.SlackInput{})
	(&Service{}).clearInputPaused(ctx, core.SlackInput{
		ChannelID: "COPS", MessageTS: "1700.100",
	})
}

func TestFailedLegacyPauseCleanupDoesNotFailOutcome(t *testing.T) {
	svc := &Service{
		slack: &refusingUnreactSlack{}, log: slog.New(slog.DiscardHandler),
	}
	// Cleanup is best effort and deliberately returns no error to propagate.
	svc.clearInputPaused(context.Background(), core.SlackInput{
		ID: "legacy-paused", ChannelID: "COPS", MessageTS: "1700.100",
	})
}

func TestLegacyTerminalPauseRetriesAcrossRestartUntilCleared(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "pre-upgrade-paused", Kind: "mention", ChannelID: "COPS",
		MessageTS: "1700.300", UserID: "U123ABC", Text: "check it",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit legacy input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ThreadTS: input.MessageTS, ConversationKey: "channel:COPS",
		SourceKind: "watch", SourceID: input.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, applied, err := st.FinishAgentRunFailure(
		ctx, run.ID, "old terminal failure", nil, store.AgentRunFailureEffects{},
	); err != nil || !applied {
		t.Fatalf("finish legacy failure = %t, %v", applied, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.paused", ObjectID: input.ID, Outcome: "queued",
		Detail: "answer deferred; the work stays queued",
	}); err != nil {
		t.Fatal(err)
	}
	first := &Service{store: st, slack: &refusingUnreactSlack{}, log: slog.New(slog.DiscardHandler)}
	if err := first.processLegacyPauseCleanup(ctx); err == nil {
		t.Fatal("transient Slack failure did not retain cleanup work")
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	slack := &fakeSlack{}
	restarted := &Service{store: reopened, slack: slack, log: slog.New(slog.DiscardHandler)}
	if err := restarted.processLegacyPauseCleanup(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.removedReactions) != 1 || slack.removedReactions[0].timestamp != input.MessageTS {
		t.Fatalf("legacy pause removal = %+v", slack.removedReactions)
	}
	if err := restarted.processLegacyPauseCleanup(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("cleanup receipt did not suppress replay: %v", err)
	}
}

type refusingUnreactSlack struct{ fakeSlack }

func (s *refusingUnreactSlack) Unreact(context.Context, string, string, string) error {
	return errors.New("Slack unavailable")
}

package service

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// reactingSlack records reactions so a test can tell a pause from silence.
type reactingSlack struct {
	fakeSlack
	reactions []string
}

func (s *reactingSlack) React(_ context.Context, _, _, reaction string) error {
	s.reactions = append(s.reactions, reaction)
	return nil
}

// A message Responder could not answer is paused, never explained.
//
// "Responder could not complete this check. Coop ended the agent turn before it
// produced a usable response." went to a shared channel, once per retry, and
// described Responder's own plumbing to someone who had asked about their
// infrastructure. Nobody reading it could act on it.
func TestUnansweredMessageIsPausedRatherThanExplained(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &reactingSlack{}
	svc := &Service{cfg: cfg, store: st, slack: slack, log: slog.New(slog.DiscardHandler)}

	svc.markInputPaused(ctx, core.SlackInput{
		ID: "slack_paused", ChannelID: "COPS", MessageTS: "1700.100",
	})

	if len(slack.posts) != 0 {
		t.Fatalf("pausing a message posted to the channel: %+v", slack.posts)
	}
	if len(slack.reactions) != 1 || slack.reactions[0] != pausedReaction {
		t.Fatalf("reactions = %v, want exactly [%s]", slack.reactions, pausedReaction)
	}
}

// A message with no channel or timestamp cannot be reacted to, and must not
// cause anything else to fail.
func TestPausingWithoutAMessageIsHarmless(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &reactingSlack{}
	svc := &Service{cfg: cfg, store: st, slack: slack, log: slog.New(slog.DiscardHandler)}

	svc.markInputPaused(ctx, core.SlackInput{ID: "slack_no_message"})
	if len(slack.reactions) != 0 || len(slack.posts) != 0 {
		t.Fatalf("reacted to nothing: %v %+v", slack.reactions, slack.posts)
	}
}

// The reaction is a courtesy; the queue is the guarantee. A Slack failure must
// not take the run down with it.
func TestAFailedReactionDoesNotFailTheRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := &Service{
		cfg: cfg, store: st, slack: &refusingSlack{}, log: slog.New(slog.DiscardHandler),
	}

	// markInputPaused returns nothing: there is no failure for a caller to
	// propagate, which is the point.
	svc.markInputPaused(ctx, core.SlackInput{
		ID: "slack_paused", ChannelID: "COPS", MessageTS: "1700.100",
	})
}

type refusingSlack struct{ fakeSlack }

func (s *refusingSlack) React(_ context.Context, _, _, _ string) error {
	return errors.New("slack is unavailable")
}

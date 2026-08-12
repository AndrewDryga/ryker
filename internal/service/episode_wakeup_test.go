package service

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestEpisodeWakeupQueuesFreshAttemptOnSameEpisode(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1.0",
		ConversationKey: "thread:COPS:1.0", SourceKind: "watch", SourceID: "source-1",
		UserID: "U123ABC", Repository: "repo", Prompt: "Check the rollout",
		Episode: &core.WorkEpisode{WorkspaceID: cfg.Slack.TeamID, Mode: core.EpisodeCheck},
	})
	if err != nil || !created {
		t.Fatalf("queue original attempt = %+v, %t, %v", run, created, err)
	}
	wakeup, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		EpisodeID: run.EpisodeID, Kind: "external_event",
		DueAt: time.Now().UTC().Add(-time.Second), Deadline: time.Now().UTC().Add(time.Hour),
		EventMatcher: []byte(`{"provider":"github","state":"terminal"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processEpisodeWakeup(ctx); err != nil {
		t.Fatal(err)
	}
	resumed, err := st.GetAgentRunBySource(ctx, "watch", "episode_wakeup_"+wakeup.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.EpisodeID != run.EpisodeID || resumed.AttemptID == run.AttemptID ||
		resumed.AttemptNumber != 2 {
		t.Fatalf("resumed attempt = %+v; original = %+v", resumed, run)
	}
	input, err := st.GetSlackInput(ctx, "episode_wakeup_"+wakeup.ID)
	if err != nil {
		t.Fatal(err)
	}
	if input.State != "done" {
		t.Fatalf("synthetic wake-up input state = %q, want done", input.State)
	}
	for _, expected := range []string{
		`"provider":"github"`,
		`"state":"terminal"`,
		"stay silent",
		"still nonterminal",
	} {
		if !strings.Contains(resumed.Prompt, expected) {
			t.Fatalf("resumed prompt lacks %q:\n%s", expected, resumed.Prompt)
		}
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, run.EpisodeID)
	if err != nil || len(wakeups) != 1 || wakeups[0].State != core.WakeupResolved {
		t.Fatalf("wakeups = %+v, %v", wakeups, err)
	}
}

// A resumed wait answers where the episode was talking, never the whole channel.
//
// The destination thread is normally bound when the episode is created, but it
// can be empty: one Terraform lifecycle episode reached its wakeup with
// destination_thread_ts unset while every sibling in the same channel had one.
// The timer propagated "no thread" faithfully and a reply that belonged under a
// run notification went to the whole channel. The attempt that scheduled the
// wait knows where it was talking, so that is the fallback — posting at channel
// level is the loudest possible reading of missing information, and the one a
// resumed wait should never choose on its own.
func TestAResumedWaitKeepsTheThreadTheAttemptWasTalkingIn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.500",
		ConversationKey: "operation:terraform:run-xKwY", SourceKind: "watch",
		SourceID: "source-thread", UserID: "U123ABC", Repository: "repo",
		Prompt:  "Watch the apply",
		Episode: &core.WorkEpisode{WorkspaceID: cfg.Slack.TeamID, Mode: core.EpisodeCheck},
	})
	if err != nil || !created {
		t.Fatalf("queue attempt = %+v, %t, %v", run, created, err)
	}
	// Reproduce the state the real episode was in: bound to a channel, with no
	// destination thread, while its attempt knows the thread it was talking in.
	// Every sibling episode in that channel had one; this one did not, and the
	// wakeup had nothing to inherit.
	raw, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.ExecContext(ctx,
		`UPDATE work_episodes SET destination_thread_ts = '' WHERE id = ?`, run.EpisodeID,
	); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.Destination.ThreadTS != "" {
		t.Fatalf("the destination thread was not cleared: %q", episode.Destination.ThreadTS)
	}
	wakeup, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		EpisodeID: run.EpisodeID, Kind: "external_event",
		DueAt: time.Now().UTC().Add(-time.Second), Deadline: time.Now().UTC().Add(time.Hour),
		EventMatcher: []byte(`{"provider":"terraform","state":"applied"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processEpisodeWakeup(ctx); err != nil {
		t.Fatal(err)
	}
	resumed, err := st.GetAgentRunBySource(ctx, "watch", "episode_wakeup_"+wakeup.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.ThreadTS != "1700.500" {
		t.Fatalf("the resumed attempt would answer in %q, not the thread the "+
			"original attempt was talking in", resumed.ThreadTS)
	}
	input, err := st.GetSlackInput(ctx, "episode_wakeup_"+wakeup.ID)
	if err != nil {
		t.Fatal(err)
	}
	if input.ThreadTS != "1700.500" {
		t.Fatalf("the synthetic input lost the thread: %q", input.ThreadTS)
	}
}

package service

import (
	"context"
	"database/sql"
	"encoding/json"
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
// Covers: TestScheduledVerificationTerminalOutcomeReachesOriginalThread
// Covers: TestATerminalEpisodeWakeupDeliversItsCompletion
// Covers: TestScheduledVerificationReportsItsTerminalOutcome
// Covers: TestScheduledVerificationBlockerReachesAcceptedWorkThread
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
	if _, err := raw.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'completed', terminal_state = 'completed', completed_at = ?
		WHERE id = ?`, time.Now().UTC().Format(core.TimestampFormat), run.ID,
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
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"operations":[{"id":"complete","type":"complete_episode","completion":{"message":"The rollout verification is blocked because the deployment record is unavailable.","completion":{"status":"blocked","summary":"The accepted rollout check could not read its required source.","material_gaps":["The deployment record is unavailable."],"blocker_kind":"source_unavailable","attempts":["Queried the configured deployment source."],"next_action":"Restore deployment-record access, then retry this scheduled verification."}}}]}`
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
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
	var state struct {
		ResponseThreadTS     string `json:"response_thread_ts"`
		ConversationFollowup bool   `json:"conversation_followup"`
	}
	if err := json.Unmarshal(input.Frozen, &state); err != nil {
		t.Fatal(err)
	}
	if state.ResponseThreadTS != "1700.500" || !state.ConversationFollowup {
		t.Fatalf("the resumed context lost its accepted destination: %+v", state)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		resumed, _ = st.GetAgentRun(ctx, resumed.ID)
		t.Fatalf("the completed wakeup posted %d replies, want one; run=%+v", len(slackClient.posts), resumed)
	}
	if slackClient.posts[0].thread != "1700.500" {
		t.Fatalf(
			"the completed wakeup answered in %q, not the accepted thread",
			slackClient.posts[0].thread,
		)
	}
	if !strings.Contains(slackClient.posts[0].message.Text, "verification is blocked") {
		t.Fatalf("the scheduled blocker was silently suppressed: %+v", slackClient.posts[0])
	}
	finalEpisode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if finalEpisode.Destination.ThreadTS != "1700.500" {
		t.Fatalf("the final reply widened the episode destination to %q", finalEpisode.Destination.ThreadTS)
	}
}

func TestABoundThreadCannotBeWidenedByAnEmptyResponseRoute(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1800.100",
		ConversationKey: "thread:COPS:1800.100", SourceKind: "watch", SourceID: "source-bound",
		UserID: "U123ABC", Repository: "repo", Prompt: "Continue the accepted work",
		Episode: &core.WorkEpisode{
			WorkspaceID: cfg.Slack.TeamID, Mode: core.EpisodeCheck,
			Destination: core.BoundDestination{ChannelID: "COPS", ThreadTS: "1800.100"},
		},
	})
	if err != nil || !created {
		t.Fatalf("queue bound episode = %+v, %t, %v", run, created, err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.postInputMessageAtEpisodeResponse(
		ctx, "bound-thread-delivery", run.EpisodeID, "source-bound", "COPS", "",
		slackui.ConversationResponse("Still working in the accepted thread.", slackui.NewSanitizer(12000)),
		false,
	); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.GetSlackDelivery(ctx, "bound-thread-delivery")
	if err != nil {
		t.Fatal(err)
	}
	if delivery.ThreadTS != "1800.100" {
		t.Fatalf("an empty route widened the reply to %q", delivery.ThreadTS)
	}
	episode, err := st.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.Destination.ThreadTS != "1800.100" {
		t.Fatalf("an empty route widened the durable destination to %q", episode.Destination.ThreadTS)
	}
}

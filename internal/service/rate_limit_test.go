package service

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/provider"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The wording providers actually use. Classify has to recognise all of these,
// because a rate limit that is not recognised is a rate limit that fails the
// run and posts an error.
func TestProviderRateLimitWordingIsRecognised(t *testing.T) {
	for _, detail := range []string{
		"429 Too Many Requests",
		"rate limit exceeded, retry after 60s",
		"Error: TOO MANY REQUESTS",
		"ACP request failed: rate limit reached for gpt-5.6-sol",
	} {
		if kind := provider.Classify(detail).Kind; kind != provider.KindRateLimit {
			t.Fatalf("Classify(%q).Kind = %q, want rate_limit", detail, kind)
		}
	}
	// A quota is not a rate limit: waiting does not fix it, so it must keep
	// failing normally rather than queueing forever.
	for _, detail := range []string{
		"insufficient_quota",
		"You have exceeded your usage limit",
		"credit balance is too low",
	} {
		if kind := provider.Classify(detail).Kind; kind == provider.KindRateLimit {
			t.Fatalf("Classify(%q) treated a quota as a rate limit", detail)
		}
	}
}

// A rate-limited run must be requeued without spending an attempt, and must not
// be reported anywhere the user can see.
func TestRateLimitedRunIsRequeuedWithoutSpendingAnAttempt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.log = slog.New(slog.DiscardHandler)

	run := seedPreparingRun(t, st)
	before := run.Failures

	handled, requeueErr := svc.requeueIfRateLimited(ctx, run, errors.New("429 Too Many Requests"))
	if requeueErr != nil {
		t.Fatalf("requeue: %v", requeueErr)
	}
	if !handled {
		t.Fatal("a 429 was not recognised as a rate limit, so the run would fail normally")
	}

	after, getErr := st.GetAgentRun(ctx, run.ID)
	if getErr != nil {
		t.Fatal(getErr)
	}
	if after.Failures != before {
		t.Fatalf(
			"a rate limit spent an attempt (%d -> %d); enough of those and the "+
				"user gets an error for work that was never wrong",
			before, after.Failures,
		)
	}
	if after.State != core.AgentRunPending {
		t.Fatalf("run state = %q, want pending so the work stays queued", after.State)
	}
	if after.NextAttemptAt.IsZero() || !after.NextAttemptAt.After(svc.now()) {
		t.Fatalf("run is not scheduled for a later attempt: %v", after.NextAttemptAt)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("a rate limit was reported in Slack: %+v", slack.posts)
	}
	// It still has to be visible somewhere an operator looks.
	if after.LastError == "" {
		t.Fatal("last_error is empty; status and logs would not show why work is waiting")
	}
}

// Anything that is not a rate limit must keep failing normally, or a genuine
// error would queue forever in silence.
func TestNonRateLimitFailuresAreNotRequeuedSilently(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.log = slog.New(slog.DiscardHandler)
	run := seedPreparingRun(t, st)

	for _, cause := range []string{
		"insufficient_quota",
		"connection refused",
		"invalid persisted triage context",
	} {
		handled, requeueErr := svc.requeueIfRateLimited(ctx, run, errors.New(cause))
		if requeueErr != nil {
			t.Fatal(requeueErr)
		}
		if handled {
			t.Fatalf("%q was treated as a rate limit and would queue forever", cause)
		}
	}
}

// seedPreparingRun creates a run in the state the retry paths act on.
//
// RequeueRateLimitedAgentRun only matches 'preparing' or 'finalizing', which is
// what the run is when a provider call fails, so a run in any other state would
// make this test pass for the wrong reason.
func seedPreparingRun(t *testing.T, st *store.Store) core.AgentRun {
	t.Helper()
	ctx := context.Background()
	input := core.SlackInput{
		ID: "slack_rate_limited", EnvelopeID: "env_rate_limited",
		EventID: "EvRateLimited", Kind: "mention", TeamID: "T1",
		ChannelID: "CWATCH", MessageTS: "1700.500", UserID: "U123ABC",
		Text: "How is the platform?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_rate_limited", Mode: core.AgentRunTriage,
		ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "k", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Repository: "repo", Prompt: "check",
		IdempotencyKey: "idem_rate_limited",
	})
	if err != nil {
		t.Fatalf("enqueue run: %v", err)
	}
	// LeaseAgentRun moves it to 'preparing', which is the state the retry
	// paths act on.
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatalf("lease run: %v", err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased %q, want %q", leased.ID, run.ID)
	}
	return leased
}

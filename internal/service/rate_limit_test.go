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
	// A quota is classified separately, and it also waits — it recovers on a
	// billing boundary rather than in a burst window, so it gets its own,
	// longer delay rather than being treated as the same thing.
	for _, detail := range []string{
		"insufficient_quota",
		"You have exceeded your usage limit",
		"credit balance is too low",
		// The wording codex actually produced on 2026-08-07.
		"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage " +
			"to purchase more credits or try again at Aug 11th, 2026 3:27 AM.",
	} {
		kind := provider.Classify(detail).Kind
		if kind == provider.KindRateLimit {
			t.Fatalf("Classify(%q) collapsed a quota into a rate limit", detail)
		}
		if kind != provider.KindUsageLimit {
			t.Fatalf("Classify(%q).Kind = %q, want usage_limit", detail, kind)
		}
	}
	if providerBackoff[provider.KindUsageLimit] <= providerBackoff[provider.KindRateLimit] {
		t.Fatal("a spent quota must wait longer than a rate limit; it recovers on a billing boundary")
	}
}

// A spent quota must queue, not fail.
//
// It was treated as terminal on the reasoning that a quota "does not recover on
// its own". The provider disagreed: on 2026-08-07 codex refused every turn with
// "You have hit your usage limit ... try again at Aug 11th", and every one of
// those became an error in Slack for work that was fine.
func TestSpentQuotaWaitsInsteadOfFailing(t *testing.T) {
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

	handled, requeueErr := svc.requeueIfRateLimited(ctx, run, errors.New(
		"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage "+
			"to purchase more credits or try again at Aug 11th, 2026 3:27 AM."))
	if requeueErr != nil {
		t.Fatal(requeueErr)
	}
	if !handled {
		t.Fatal("a spent quota was treated as a real failure, so Slack gets an error for good work")
	}
	after, getErr := st.GetAgentRun(ctx, run.ID)
	if getErr != nil {
		t.Fatal(getErr)
	}
	if after.Failures != run.Failures {
		t.Fatalf("a quota spent an attempt (%d -> %d)", run.Failures, after.Failures)
	}
	if after.State != core.AgentRunPending {
		t.Fatalf("run state = %q, want pending", after.State)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("a spent quota was reported in Slack: %+v", slack.posts)
	}
	// It waits longer than a rate limit would.
	if !after.NextAttemptAt.After(svc.now().Add(provider.RateLimitRetryDelay)) {
		t.Fatalf("a quota is retried as soon as a rate limit: %v", after.NextAttemptAt)
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

// Anything the provider did not refuse must keep failing normally, or a genuine
// error would queue forever in silence.
//
// This is the line that makes waiting safe. A refusal is the provider declining
// work it will accept later; a broken connection or a malformed context is the
// work being wrong, and hiding that would turn a visible bug into a stalled
// queue nobody is looking at.
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
		"connection refused",
		"invalid persisted triage context",
		"the structured Slack response is invalid",
		"context deadline exceeded",
	} {
		handled, requeueErr := svc.requeueIfRateLimited(ctx, run, errors.New(cause))
		if requeueErr != nil {
			t.Fatal(requeueErr)
		}
		if handled {
			t.Fatalf("%q was treated as a provider refusal and would queue forever", cause)
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

// The string Responder actually receives must be recognised.
//
// The classifier matched "acl request was rejected" while the transport emits
// "ACP request was rejected" — one letter apart, and the reason nothing
// downstream ever handled it. Every such refusal fell through to the default
// and failed the run, which is how a spent quota reached Slack as "Responder
// could not complete this check" for four days.
func TestUnexplainedACPRefusalWaitsRatherThanFailing(t *testing.T) {
	if kind := provider.Classify("ACP request was rejected").Kind; kind != provider.KindProviderRefused {
		t.Fatalf("Classify(\"ACP request was rejected\").Kind = %q; the exact string the transport emits must be handled", kind)
	}
	if _, waits := providerBackoff[provider.KindProviderRefused]; !waits {
		t.Fatal("an unexplained refusal fails the run, so it reaches Slack")
	}

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

	handled, requeueErr := svc.requeueIfRateLimited(
		ctx, run, errors.New("ACP request was rejected"),
	)
	if requeueErr != nil {
		t.Fatal(requeueErr)
	}
	if !handled {
		t.Fatal("the refusal was treated as a real failure")
	}
	after, getErr := st.GetAgentRun(ctx, run.ID)
	if getErr != nil {
		t.Fatal(getErr)
	}
	if after.State != core.AgentRunPending || after.Failures != run.Failures {
		t.Fatalf("run = %q with %d failures; want pending and no attempt spent",
			after.State, after.Failures)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("an unexplained refusal reached Slack: %+v", slack.posts)
	}
}

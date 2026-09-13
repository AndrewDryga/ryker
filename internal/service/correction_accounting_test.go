package service

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// A correction loop still stops, now that failure_count no longer counts it.
//
// This is the sharp edge of splitting the two numbers. The correction budget
// used to ride on failure_count: `terminalStructuredCorrection(run.Failures+1,
// …)`. Take corrections out of failure_count and leave that alone, and
// run.Failures is 0 forever, the budget never trips, and a nineteen-round loop
// becomes an endless one — a worse bug than the accounting it was fixing, on
// the exact runs that already cycle most (blitz run_3a615b9db and five more
// the same day).
//
// So the count moved to the run's context envelope, where the watch path had
// always kept it, and this holds that shut: a model that answers the same
// unusable way every round is corrected up to the budget and then told to
// stop, not corrected forever.
func TestACyclingCorrectionLoopStillStopsWithoutSpendingFailures(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 4
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	coopClient := newFakeCoop()
	// One answer, returned every round: a deep-work reply with no completion
	// assessment. The fake keeps replaying its last completed turn once the
	// queue drains, which is exactly a model that does not learn.
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,` +
			`"ownership":3,"contribution":"decision","material":true},` +
			`"reason":"checked production","operations":[{"id":"complete",` +
			`"type":"complete_episode","completion":{"message":"Production is healthy."}}]}`,
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)

	input := core.SlackInput{
		ID: "cycling-correction", EnvelopeID: "cycling-envelope",
		EventID: "cycling-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.900", UserID: "U123ABC",
		Text: "<@UBOT> Give me a decision-ready production health assessment. " +
			"Cover recent changes, hosts, workloads, dependencies, application " +
			"behavior, and SLOs.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	// Twice the budget. If the loop is unbounded this never leaves pending and
	// the corrections counter climbs without limit.
	corrections := 0
	for round := 0; round < 2*cfg.Limits.MaxAgentRunAttempts+4; round++ {
		if err := svc.processAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
		svc.pollAgentRuns(ctx)
		run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil {
			t.Fatal(err)
		}
		if run.Failures != 0 {
			t.Fatalf("round %d spent a failure on a correction: failures = %d", round, run.Failures)
		}
		var state decisionpkg.WatchTurnState
		if len(run.Context) > 0 {
			_ = json.Unmarshal(run.Context, &state)
		}
		corrections = state.StructuredCorrections
		if run.State != core.AgentRunPending {
			break
		}
	}

	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.State == core.AgentRunPending {
		t.Fatalf(
			"the correction loop never terminated: state = %s, corrections = %d, "+
				"failures = %d",
			run.State, corrections, run.Failures,
		)
	}
	if corrections > cfg.Limits.MaxAgentRunAttempts {
		t.Fatalf(
			"the loop ran %d corrections against a budget of %d",
			corrections, cfg.Limits.MaxAgentRunAttempts,
		)
	}
	// The whole point of the split: the operator-facing count says corrections,
	// not failures.
	if run.Failures != 0 {
		t.Fatalf("a correction-only loop reported failures = %d", run.Failures)
	}
	if corrections == 0 {
		t.Fatal("no correction was counted, so this test no longer exercises the loop")
	}
}

// The incident and engineering-task correction budget counts corrections.
//
// It used to count `run.Failures+1`, which worked only because a correction
// requeue bumped failure_count. It no longer does, so the budget reads the
// run's own correction counter instead — and if it ever goes back, this run
// never stops being corrected. Nothing else in the suite covers it: reverting
// this to run.Failures leaves the whole service package green while the
// incident loop runs forever.
func TestTheIncidentCorrectionBudgetCountsCorrectionsNotFailures(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 3
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, ChannelID: "COPS", ThreadTS: "1700.950",
		ConversationKey: "channel:COPS", SourceKind: "slack", SourceID: "incident-correction-budget",
	})
	if err != nil {
		t.Fatal(err)
	}
	assembled, err := json.Marshal(assembledAgentContext{
		Repository: "repo", CapturedAt: time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetAgentRunContext(ctx, queued.ID, assembled); err != nil {
		t.Fatal(err)
	}

	// failure_count stays where a correction leaves it: zero. The budget has to
	// come from somewhere else or it never trips.
	for round := 1; round <= cfg.Limits.MaxAgentRunAttempts; round++ {
		run, err := st.GetAgentRun(ctx, queued.ID)
		if err != nil {
			t.Fatal(err)
		}
		if run.Failures != 0 {
			t.Fatalf("round %d: failures = %d, so this test is not proving the split", round, run.Failures)
		}
		spent, err := svc.spendStructuredCorrection(ctx, run, nil, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		if last := round == cfg.Limits.MaxAgentRunAttempts; spent != last {
			t.Fatalf("round %d of %d: spent = %t, want %t",
				round, cfg.Limits.MaxAgentRunAttempts, spent, last)
		}
	}

	run, err := st.GetAgentRun(ctx, queued.ID)
	if err != nil {
		t.Fatal(err)
	}
	stored, ok := decodeAssembledAgentContext(run.Context)
	if !ok {
		t.Fatal("the run's assembled context no longer decodes")
	}
	// One short of the budget: the round that spends it is refused before its
	// count is written, which is the same arithmetic the watch path uses.
	if stored.StructuredCorrections != cfg.Limits.MaxAgentRunAttempts-1 {
		t.Fatalf("recorded corrections = %d, want %d",
			stored.StructuredCorrections, cfg.Limits.MaxAgentRunAttempts-1)
	}
	if stored.Repository != "repo" {
		t.Fatalf("the run's assembled context was overwritten: %+v", stored)
	}
}

// An alert stream is one episode now, so its attempt number counts cards and
// wakeups rather than corrections. The second correction budget was bounded by
// that attempt number, which was right when every re-triggered alert opened a
// fresh episode and is wrong now: the Traefik memory stream of 2026-08-16 would
// have reached attempt 21 in an afternoon and been refused its FIRST correction
// having spent none.
//
// The budget it was protecting is real — one episode once took twenty-one runs
// and a hundred and thirty corrections — so it is kept and measured directly:
// the corrections the episode actually spent, across every run it contains.
func TestALongLivedStreamEpisodeKeepsItsCorrectionBudget(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 4
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	first, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CSTREAMBUDGET",
		ConversationKey: "operation:CSTREAMBUDGET:alert:BGRAFANA:long-lived",
		SourceKind:      "watch", SourceID: "stream-budget-card",
		UserID: "BGRAFANA", Context: streamBudgetContext(0),
	})
	if err != nil {
		t.Fatal(err)
	}
	// Twenty-five cards and wakeups on one stream, none of which spent a
	// correction.
	run := first
	for run.AttemptNumber < 25 {
		run, _, err = st.QueueEpisodeAttempt(ctx, first.EpisodeID, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: first.ChannelID,
			ConversationKey: first.ConversationKey, SourceKind: "watch",
			SourceID: fmt.Sprintf("stream-budget-card-%02d", run.AttemptNumber+1),
			UserID:   first.UserID, Context: streamBudgetContext(0),
		})
		if err != nil {
			t.Fatalf("queue attempt %d: %v", run.AttemptNumber+1, err)
		}
	}
	spent, err := svc.spendStructuredCorrection(ctx, run, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if spent {
		t.Fatalf(
			"attempt %d of a stream that has spent no corrections was refused its first one",
			run.AttemptNumber,
		)
	}

	// The loop this budget exists for still stops. The corrections are spread
	// across the episode's runs, exactly as a model that answers the same
	// unusable way on every card spreads them.
	for index := range cfg.Limits.MaxAgentRunAttempts {
		sibling, _, queueErr := st.QueueEpisodeAttempt(ctx, first.EpisodeID, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: first.ChannelID,
			ConversationKey: first.ConversationKey, SourceKind: "watch",
			SourceID: fmt.Sprintf("stream-budget-spent-%02d", index),
			UserID:   first.UserID, Context: streamBudgetContext(1),
		})
		if queueErr != nil {
			t.Fatal(queueErr)
		}
		run = sibling
	}
	spent, err = svc.spendStructuredCorrection(ctx, run, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !spent {
		t.Fatal("an episode that spent its whole correction budget was granted another")
	}
}

// streamBudgetContext is a run context envelope the host will decode: it has to
// carry captured_at, or the correction path treats the run as having no context
// at all and stops for that reason instead of the budget.
func streamBudgetContext(corrections int) []byte {
	return fmt.Appendf(nil,
		`{"captured_at":%q,"structured_corrections":%d}`,
		time.Now().UTC().Format(time.RFC3339), corrections,
	)
}

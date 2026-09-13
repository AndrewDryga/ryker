package service

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/preparationnotice"
	"github.com/AndrewDryga/ryker/internal/sessionauthority"
	"github.com/AndrewDryga/ryker/internal/sessioncreate"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// A live Blitz alert spent eleven hours behind one preparation lease after
// Coop's repository refresh failed. The Slack blocker was attempted before the
// run was put back in the queue, so a delivery-side failure could abandon the
// accepted run in preparing and serialize every later message behind it.
func TestPreparationNoticeFailureCannotOwnTheAcceptedRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	raw, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	if _, err := raw.ExecContext(ctx, `
		CREATE TRIGGER fail_preparation_notice
		BEFORE INSERT ON slack_deliveries
		WHEN NEW.id LIKE 'watch_preparation_blocked_%'
		BEGIN
			SELECT RAISE(FAIL, 'injected Slack outbox failure');
		END`); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	state := decisionpkg.WatchTurnState{Generation: 1}
	cause := &coop.APIError{
		Status: 503, Code: "repository_unavailable",
		Detail: "exact repository refresh timed out",
	}

	if err := svc.retryAtNextSessionGeneration(ctx, run, &state, 1, cause); err != nil {
		t.Fatalf("delivery failure escaped after the run should have been requeued: %v", err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunPending || stored.Failures != 0 {
		t.Fatalf("accepted run was owned by its Slack notice: %+v", stored)
	}
}

func TestAgentWorkerReclaimsAbandonedPreparationBeforeLeasing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.WorkerStallAfter.Duration = 2 * time.Minute
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	raw, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	old := time.Now().UTC().Add(-10 * time.Minute).Format(core.TimestampFormat)
	if _, err := raw.ExecContext(
		ctx, `UPDATE agent_runs SET updated_at = ? WHERE id = ?`, old, run.ID,
	); err != nil {
		raw.Close()
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunRunning || stored.CoopTurnID == "" {
		t.Fatalf("reclaimed run did not reach Coop: %+v", stored)
	}
	if len(coopClient.submitKeys) != 1 {
		t.Fatalf("model submissions = %d, want 1", len(coopClient.submitKeys))
	}
}

// The production recovery edge is an accepted model turn, which retires the
// blocker in the same store transaction. Lifecycle tests below exercise the
// outbox races after that edge directly; store tests cover the atomic pairing.
func retirePreparationAfterRecovery(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	run core.AgentRun,
) {
	t.Helper()
	created, err := st.PreparationNotices.Retire(ctx, preparationnotice.Prefix(run))
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("accepted-turn recovery did not create a preparation retirement")
	}
}

func TestTerminalHumanTriageFailurePostsOneSanitizedNotice(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "human-terminal-failure", EnvelopeID: "env-human-terminal-failure",
		EventID: "event-human-terminal-failure", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@UBOT> check production health",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	const raw = "Coop API 500: secret internal transport detail"
	if err := svc.failPreparingTriageRun(
		ctx, run, input, decisionpkg.WatchTurnState{}, raw,
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != input.MessageTS {
		t.Fatalf("terminal failure notice = %+v", slack.posts)
	}
	// Superseded: the notice used to open "I couldn't finish this request".
	// Every failure card now leads with what stopped, in the header and again
	// as the first section, so the summary this asserts is the same fact under
	// its own name.
	content := slack.posts[0].message.Text + strings.Join(slack.posts[0].message.Sections, " ")
	if strings.Contains(content, raw) ||
		!strings.Contains(content, "Request needs a retry") ||
		!strings.Contains(content, "stopped retrying this request") {
		t.Fatalf("terminal notice leaked or omitted the useful summary: %q", content)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("terminal run = %+v, %v", stored, err)
	}
	followup := core.SlackInput{
		ID: "failure-thread-followup", Kind: "message", TeamID: input.TeamID,
		ChannelID: input.ChannelID, ThreadTS: input.MessageTS, MessageTS: "1700.200",
		UserID: input.UserID, Text: "try it again now",
	}
	admitted, err := svc.shouldAdmitChannelMessage(ctx, followup)
	if err != nil || !admitted {
		t.Fatalf("plain reply to terminal failure was not admitted = %t, %v", admitted, err)
	}
}

// Four Grafana cards were durably accepted but looked ignored for more than two hours while every
// attempt failed before a model turn: Coop could not refresh a configured repository. The first
// typed preparation blocker must become one idempotent thread notice, not twenty silent retries.
func TestRepositoryPreparationBlockerIsDeliveredOnceInTheBoundAlertThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	run := seedPreparingRun(t, st)
	run.Repository = "blitz-core"
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	episode, err = st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.777",
	}, "explicit_test_binding")
	if err != nil {
		t.Fatal(err)
	}
	blocker := &coop.APIError{
		Status: 503, Code: "repository_unavailable",
		Detail: "operation op_secret could not refresh /Users/private/blitz-core from origin/master",
	}
	if err := svc.retryAgentRun(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	// The production runs reached all twenty preparation attempts without an
	// operator-visible turn. Replaying the typed failure must keep one durable
	// status delivery rather than enqueueing one message per attempt.
	for attempt := 1; attempt < 20; attempt++ {
		clock.Advance(time.Minute)
		if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
			t.Fatal(err)
		}
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].channel != "CBOUND" ||
		slack.posts[0].thread != "1700.777" {
		t.Fatalf("preparation blocker posts = %+v", slack.posts)
	}
	content := slack.posts[0].message.Text + strings.Join(slack.posts[0].message.Sections, " ")
	for _, want := range []string{
		"Investigation queued", "blitz-core", "keep retrying this investigation automatically",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("preparation blocker lacks %q: %q", want, content)
		}
	}
	for _, secret := range []string{"op_secret", "/Users/private", "origin/master"} {
		if strings.Contains(content, secret) {
			t.Fatalf("preparation blocker leaked %q: %q", secret, content)
		}
	}
	if recent, err := st.HasRecentWatchReply(
		ctx, episode.Destination.ChannelID, episode.Destination.ThreadTS,
		"9999.999", time.Time{},
	); err != nil || recent {
		t.Fatalf("preparation status counted as a completed response = %t, %v", recent, err)
	}
	retirePreparationAfterRecovery(t, ctx, st, run)
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || len(slack.updates) != 0 || len(slack.deletes) != 1 ||
		slack.deletes[0].channel != "CBOUND" || slack.deletes[0].timestamp != "1700.001" {
		deliveries, _ := st.ListSlackDeliveriesByPrefix(ctx, preparationnotice.Prefix(run))
		t.Fatalf("normal catch-up did not retire the stale blocker: posts=%+v updates=%+v deletes=%+v deliveries=%+v",
			slack.posts, slack.updates, slack.deletes, deliveries)
	}
	// The same run can lose and regain repository access more than once. The
	// first retirement must close its epoch rather than poisoning the stable ID
	// or turning the next blocker into an update of a message Slack deleted.
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	retirePreparationAfterRecovery(t, ctx, st, run)
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 2 || len(slack.updates) != 0 || len(slack.deletes) != 2 ||
		slack.deletes[1].timestamp != "1700.002" {
		deliveries, _ := st.ListSlackDeliveriesByPrefix(ctx, preparationnotice.Prefix(run))
		t.Fatalf("second blocker epoch was not independently retired: posts=%+v updates=%+v deletes=%+v deliveries=%+v",
			slack.posts, slack.updates, slack.deletes, deliveries)
	}
}

// Seven copies of this notice were posted and deleted in fourteen minutes for
// run_7a3e49251ccac6c4972168958d2023eb. A refresh failure posted the blocker,
// the next attempt's ordinary pending state deleted it, and the eventual
// failure posted it again. Pending is still blocked: only an accepted model
// turn is recovery.
func TestPendingPreparationDoesNotDeleteAndRepostTheVisibleBlocker(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.790",
	}, "pending_after_failure_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	blocker := &coop.APIError{
		Status: 503, Code: "repository_unavailable", Detail: "refresh failed",
	}
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, &coop.OperationPendingError{
		ID: "op_refresh", Method: "CreateRemoteSession",
	}); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || len(slack.updates) != 0 || len(slack.deletes) != 0 {
		t.Fatalf("pending refresh churned the blocker: posts=%+v updates=%+v deletes=%+v",
			slack.posts, slack.updates, slack.deletes)
	}
}

// A repository recovered before the outbox posted its blocker in production.
// Recovery used to find no Slack timestamp, return without recording an
// intent, and then let the stale blocker land after the model turn started.
func TestRecoveryBeforePreparationBlockerDeliveryLeavesNoStaleReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.778",
	}, "pre_delivery_recovery_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, &coop.APIError{
		Status: 503, Code: "repository_unavailable", Detail: "refresh failed",
	}); err != nil {
		t.Fatal(err)
	}
	retirePreparationAfterRecovery(t, ctx, st, run)
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 || len(slack.updates) != 0 || len(slack.deletes) != 0 {
		t.Fatalf("recovered preparation posted stale Slack work: posts=%+v updates=%+v deletes=%+v",
			slack.posts, slack.updates, slack.deletes)
	}
}

// Slack can accept a blocker while its HTTP response is still in flight. A
// recovery intent must wait for that post's timestamp and then remove it; it
// cannot disappear merely because the blocker was already leased.
func TestRecoveryWhilePreparationBlockerIsSendingRetiresTheDeliveredReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.779",
	}, "sending_recovery_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, &coop.APIError{
		Status: 503, Code: "repository_unavailable", Detail: "refresh failed",
	}); err != nil {
		t.Fatal(err)
	}
	blocker, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || blocker.Operation != "post" {
		t.Fatalf("leased blocker = %+v, %v", blocker, err)
	}
	retirePreparationAfterRecovery(t, ctx, st, run)
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("retirement overtook sending blocker: %v", err)
	}
	if err := st.FinishSlackDelivery(ctx, blocker.ID, "1700.099", "sending"); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.deletes) != 1 || slack.deletes[0].channel != "CBOUND" ||
		slack.deletes[0].timestamp != "1700.099" {
		t.Fatalf("sending blocker was not retired after its timestamp arrived: %+v", slack.deletes)
	}
}

// A timed-out Slack post is reconciled separately from the delivery worker.
// Recovery must remain queued behind that uncertain write and delete it once
// reconciliation supplies the timestamp.
func TestRecoveryWhilePreparationBlockerIsUncertainRetiresTheReconciledReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.780",
	}, "uncertain_recovery_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, &coop.APIError{
		Status: 503, Code: "repository_unavailable", Detail: "refresh failed",
	}); err != nil {
		t.Fatal(err)
	}
	blocker, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	retirePreparationAfterRecovery(t, ctx, st, run)
	if err := st.RetrySlackDelivery(
		ctx, blocker.ID, "Slack response timed out", time.Now(), true, false,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("retirement overtook uncertain blocker: %v", err)
	}
	if err := st.FinishSlackDelivery(ctx, blocker.ID, "1700.100", "uncertain"); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.deletes) != 1 || slack.deletes[0].timestamp != "1700.100" {
		t.Fatalf("reconciled blocker was not retired: %+v", slack.deletes)
	}
}

// A repository can fail again while the previous blocker is being retired.
// Pending retirement is cancellable; an in-flight delete is not, so its new
// blocker must wait behind it and post a fresh message rather than updating a
// timestamp Slack is deleting.
func TestRecurringPreparationBlockerSurvivesPendingAndSendingRetirement(t *testing.T) {
	for _, retirementState := range []string{"pending", "sending"} {
		for _, changed := range []bool{false, true} {
			t.Run(retirementState+map[bool]string{false: "/same", true: "/changed"}[changed], func(t *testing.T) {
				ctx := context.Background()
				cfg := serviceConfig(t)
				st, err := store.Open(cfg.StateDir)
				if err != nil {
					t.Fatal(err)
				}
				defer st.Close()
				run := seedPreparingRun(t, st)
				run.Repository = "repo-a"
				episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
					ChannelID: "CBOUND", ThreadTS: "1700.781",
				}, "recurring_blocker_test"); err != nil {
					t.Fatal(err)
				}
				slack := &fakeSlack{}
				svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
				blocker := &coop.APIError{Status: 503, Code: "repository_unavailable", Detail: "refresh failed"}
				if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
					t.Fatal(err)
				}
				drainSlackDeliveries(t, ctx, svc)
				retirePreparationAfterRecovery(t, ctx, st, run)
				var leasedDelete core.SlackDelivery
				if retirementState == "sending" {
					leasedDelete, err = st.LeaseSlackDelivery(ctx, nil)
					if err != nil || leasedDelete.Operation != "delete" {
						t.Fatalf("leased retirement = %+v, %v", leasedDelete, err)
					}
				}
				if changed {
					run.Repository = "repo-b"
				}
				if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
					t.Fatal(err)
				}
				if retirementState == "sending" {
					if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
						t.Fatalf("new blocker overtook in-flight retirement: %v", err)
					}
					if err := st.FinishSlackDelivery(ctx, leasedDelete.ID, "1700.001", "sending"); err != nil {
						t.Fatal(err)
					}
				}
				drainSlackDeliveries(t, ctx, svc)
				if retirementState == "pending" {
					if len(slack.posts) != 1 || len(slack.updates) != 1 || len(slack.deletes) != 0 {
						t.Fatalf("pending retirement was not cancelled: posts=%+v updates=%+v deletes=%+v",
							slack.posts, slack.updates, slack.deletes)
					}
				} else if len(slack.posts) != 2 || len(slack.updates) != 0 {
					t.Fatalf("blocker after sending retirement did not start fresh: posts=%+v updates=%+v",
						slack.posts, slack.updates)
				}
			})
		}
	}
}

// Slack accepted a blocker but the POST response and then the first history
// lookup both timed out. Neither unknown result may be read as confirmed
// absence; the outbox must keep reconciling until it learns the timestamp and
// can retire the real message.
func TestPreparationRecoveryKeepsUnknownSlackPostUntilHistoryFindsIt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.782",
	}, "unknown_slack_post_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{
		postErr: errors.New("Slack POST timed out"), dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, &coop.APIError{
		Status: 503, Code: "repository_unavailable", Detail: "refresh failed",
	}); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	retirePreparationAfterRecovery(t, ctx, st, run)
	clock.Advance(time.Minute)
	slack.findDeliveryErr = errors.New("Slack history timed out")
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	deliveries, err := st.ListSlackDeliveriesByPrefix(ctx, preparationnotice.Prefix(run))
	if err != nil || len(deliveries) != 2 || deliveries[0].State != "uncertain" {
		t.Fatalf("unknown history discarded possible Slack post: %+v, %v", deliveries, err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("retirement overtook unknown Slack post: %v", err)
	}
	clock.Advance(time.Minute)
	slack.findDeliveryErr = nil
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	slack.postErr = nil
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || len(slack.deletes) != 1 ||
		slack.deletes[0].timestamp != "1700.001" {
		t.Fatalf("reconciled Slack blocker was not deleted exactly once: posts=%+v deletes=%+v",
			slack.posts, slack.deletes)
	}
}

// A retirement is cancellable only before Slack has seen it and only when the
// blocker it follows is durably known. Cancelling a delete behind an ambiguous
// post, or retrying a delete whose response was lost, can leave duplicates or
// update a timestamp Slack already removed.
func TestRecurringPreparationBlockerStaysBehindAmbiguousOrRetriedRetirement(t *testing.T) {
	for _, predecessor := range []string{"sending", "uncertain"} {
		t.Run("pending-delete-behind-"+predecessor, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			run := seedPreparingRun(t, st)
			episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
				ChannelID: "CBOUND", ThreadTS: "1700.783",
			}, "ambiguous_predecessor_test"); err != nil {
				t.Fatal(err)
			}
			slack := &fakeSlack{}
			svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
			blocker := &coop.APIError{Status: 503, Code: "repository_unavailable", Detail: "refresh failed"}
			if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
				t.Fatal(err)
			}
			original, err := st.LeaseSlackDelivery(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			if predecessor == "uncertain" {
				if err := st.RetrySlackDelivery(ctx, original.ID, "POST timed out", time.Now(), true, false); err != nil {
					t.Fatal(err)
				}
			}
			retirePreparationAfterRecovery(t, ctx, st, run)
			if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
				t.Fatal(err)
			}
			if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("recurring blocker escaped causal retirement: %v", err)
			}
			if err := st.FinishSlackDelivery(ctx, original.ID, "1700.101", predecessor); err != nil {
				t.Fatal(err)
			}
			drainSlackDeliveries(t, ctx, svc)
			if len(slack.deletes) != 1 || len(slack.posts) != 1 || len(slack.updates) != 0 {
				t.Fatalf("ambiguous predecessor lifecycle = posts=%+v updates=%+v deletes=%+v",
					slack.posts, slack.updates, slack.deletes)
			}
		})
	}

	t.Run("delete-retry", func(t *testing.T) {
		ctx := context.Background()
		cfg := serviceConfig(t)
		st, err := store.Open(cfg.StateDir)
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		run := seedPreparingRun(t, st)
		episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
			ChannelID: "CBOUND", ThreadTS: "1700.784",
		}, "delete_retry_test"); err != nil {
			t.Fatal(err)
		}
		slack := &fakeSlack{}
		svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
		clock := useTestClock(svc, st)
		blocker := &coop.APIError{Status: 503, Code: "repository_unavailable", Detail: "refresh failed"}
		if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
			t.Fatal(err)
		}
		drainSlackDeliveries(t, ctx, svc)
		retirePreparationAfterRecovery(t, ctx, st, run)
		slack.deleteErr = errors.New("delete response timed out")
		if err := svc.processSlackDelivery(ctx, nil); err != nil {
			t.Fatal(err)
		}
		if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
			t.Fatal(err)
		}
		slack.deleteErr = nil
		clock.Advance(time.Minute)
		drainSlackDeliveries(t, ctx, svc)
		if len(slack.deletes) != 2 || len(slack.posts) != 2 || len(slack.updates) != 0 {
			t.Fatalf("retried retirement was cancelled: posts=%+v updates=%+v deletes=%+v",
				slack.posts, slack.updates, slack.deletes)
		}
	})
}

// A second recovery belongs to the blocker admitted after an older delete.
// The older delete must not make that newer recovery disappear merely because
// it is still in flight.
func TestSecondPreparationRecoverySupersedesBlockerBehindOlderDelete(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.785",
	}, "second_recovery_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	blocker := &coop.APIError{Status: 503, Code: "repository_unavailable", Detail: "refresh failed"}
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	retirePreparationAfterRecovery(t, ctx, st, run)
	firstDelete, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || firstDelete.Operation != "delete" {
		t.Fatalf("first retirement = %+v, %v", firstDelete, err)
	}
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	retirePreparationAfterRecovery(t, ctx, st, run)
	if err := st.FinishSlackDelivery(ctx, firstDelete.ID, "1700.001", "sending"); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || len(slack.updates) != 0 {
		t.Fatalf("second recovery let its blocker post: posts=%+v updates=%+v", slack.posts, slack.updates)
	}
}

// A repository refresh can legitimately outlive the synchronous API poll.
// Posting a permanent thread reply at that ordinary handoff made healthy alerts
// look blocked even when the next scheduler pass started their model turn.
// Native work presence is enough until Coop reports an actual refresh failure.
func TestPendingWorkspacePreparationDoesNotPostAPermanentThreadReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ChangeEpisodeDestination(ctx, episode.ID, core.BoundDestination{
		ChannelID: "CBOUND", ThreadTS: "1700.777",
	}, "pending_refresh_test"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	state := decisionpkg.WatchTurnState{Generation: 1}
	pending := &coop.OperationPendingError{
		ID: "op_private", Method: "CreateSession",
		Cause: errors.New("fetch /Users/private/blitz-core is still running"),
	}
	if err := svc.retryAtNextSessionGeneration(ctx, run, &state, 1, pending); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 || len(slack.updates) != 0 {
		t.Fatalf("ordinary pending refresh posted a persistent notice: posts=%+v updates=%+v",
			slack.posts, slack.updates)
	}
}

// A live replay waited for another turn in its read-only Coop session to park.
// Every poll counted as a model failure even though this run had submitted no
// turn; seven retries accumulated while the other turn was still healthy.
func TestAuthorityConvergenceWaitDoesNotSpendAWatchModelAttempt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := seedPreparingRun(t, st)
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	state := decisionpkg.WatchTurnState{Generation: 1}
	cause := errors.Join(
		sessionauthority.ErrConvergence,
		errors.New("read-only session still has active or queued work"),
	)

	if err := svc.retryAtNextSessionGeneration(ctx, run, &state, 1, cause); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunPending || stored.Failures != 0 || stored.TerminalState != "" {
		t.Fatalf("authority convergence spent or lost accepted watch work: %+v", stored)
	}
}

// A refresh can fail once and then succeed directly, without first returning
// the transient pending shape. The accepted model turn is the authoritative
// recovery edge, so it must retire the earlier blocker too.
func TestSuccessfulTriageSubmissionRetiresPreparationBlocker(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSUBMIT"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "successful-preparation", EnvelopeID: "env-successful-preparation",
		EventID: "event-successful-preparation", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CSUBMIT", MessageTS: "1700.778",
		UserID: "BGRAFANA", Text: "[VA1 FIRING:1] WARNING | Ingress 5xx ratio high",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	alertStreamChannel(t, ctx, st, cfg, input.ChannelID)
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{{State: "running"}}
	slack := &fakeSlack{}
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	blocker := &coop.APIError{Status: 503, Code: "repository_unavailable", Detail: "refresh failed"}
	if err := svc.notifyRepositoryPreparationBlocked(ctx, run, blocker); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("precondition blocker posts = %+v", slack.posts)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.deletes) != 1 || slack.deletes[0].channel != input.ChannelID ||
		slack.deletes[0].timestamp != "1700.001" {
		t.Fatalf("successful submission did not retire blocker: %+v", slack.deletes)
	}
}

// A live alert on 2026-08-18 found 64 durable session-create keys left by old
// request shapes. Ryker preserved the run and its generation, but then
// waited thirty minutes before continuing the bounded catch-up even though no
// model turn had started. A busy alert channel must yield between bounded
// batches without turning one safe batch boundary into a half-hour outage.
func TestHistoricalSessionKeyCatchupResumesQuicklyWithoutSpendingAnAttempt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	clock := useTestClock(svc, st)
	run := seedPreparingRun(t, st)
	state := decisionpkg.WatchTurnState{Generation: 1}

	if err := svc.retryAtNextSessionGeneration(
		ctx, run, &state, 65, sessioncreate.HistoricalCreateKeysError("watch"),
	); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunPending || stored.Failures != 0 {
		t.Fatalf("bounded catch-up spent or lost the run: %+v", stored)
	}
	if delay := stored.NextAttemptAt.Sub(clock.Now()); delay > 5*time.Second {
		t.Fatalf("bounded catch-up retry delay = %s, want at most 5s", delay)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 || len(slack.updates) != 0 {
		t.Fatalf("bounded catch-up posted a persistent notice: posts=%+v updates=%+v",
			slack.posts, slack.updates)
	}
}

// On 2026-08-16 a teammate wrote "@Emisar there are issues atm with payments"
// in a watched channel, attached a screenshot, and got nothing: the run failed
// on the screenshot and the audit recorded failed_silent. They typed the name
// rather than picking the completion, so Slack sent no app_mention and the
// input arrived as an ordinary channel message — which WatchInputTargeted reads
// as room chatter nobody is owed an answer to. Twelve minutes later they solved
// it themselves.
//
// Silence is right for an unmatched bot card and for two humans talking past
// Ryker. It is never right for a message that said its name.
func TestAFailedAnswerToAMentionIsNotSilent(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "named-ryker-failure", EnvelopeID: "env-named-ryker-failure",
		EventID: "event-named-ryker-failure", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "@Emisar there are issues atm with payments, I just made a new account",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit named input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotName: "Emisar",
	}
	if err := svc.failPreparingTriageRun(
		ctx, run, input, decisionpkg.WatchTurnState{},
		`Slack file "image.png" content does not match declared media type "image/png"`,
	); err != nil {
		t.Fatal(err)
	}
	outcomes := auditOutcomes(t, cfg, "slack.watch", input.ID)
	if len(outcomes) != 1 || !strings.HasPrefix(outcomes[0], "failed_notified:") {
		t.Fatalf("audit outcomes = %v, want one failed_notified", outcomes)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != input.MessageTS {
		t.Fatalf("failure notice to a named request = %+v", slack.posts)
	}
}

// The other half of the same rule: an ambient message that never named
// Ryker still fails quietly, so a watched room does not fill with notices
// about work nobody asked for.
func TestAFailedAmbientMessageStaysSilent(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "ambient-failure", EnvelopeID: "env-ambient-failure",
		EventID: "event-ambient-failure", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "deploy finished, going to lunch",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit ambient input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotName: "Emisar",
	}
	if err := svc.failPreparingTriageRun(
		ctx, run, input, decisionpkg.WatchTurnState{}, "host preparation failed",
	); err != nil {
		t.Fatal(err)
	}
	outcomes := auditOutcomes(t, cfg, "slack.watch", input.ID)
	if len(outcomes) != 1 || !strings.HasPrefix(outcomes[0], "failed_silent:") {
		t.Fatalf("audit outcomes = %v, want one failed_silent", outcomes)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 {
		t.Fatalf("ambient failure posted to the room: %+v", slack.posts)
	}
}

func TestApprovalContinuationFailurePostsVerificationOnlyNotice(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "approval-continuation-failure", EnvelopeID: "env-approval-continuation-failure",
		EventID: "event-approval-continuation-failure", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "1700.100", MessageTS: "1700.200", UserID: "U123ABC",
		Text: "approval result",
	}
	if created, err := st.AdmitSyntheticSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit continuation = %t, %v", created, err)
	}
	if err := st.Intelligence.BindChannelSession(
		ctx, input.ChannelID, "repo", "ses_approval", 3, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.ThreadTS,
		ConversationKey: "channel:COPS", SourceKind: "emisar_approval:apr_1", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(ctx, run.ID, "ses_approval", 3, "repo", 0, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	run, err = st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	state := decisionpkg.WatchTurnState{
		ConversationFollowup: true, ApprovalContinuation: true,
		SessionID: "ses_approval", SessionChannelID: input.ChannelID,
		Generation: 1,
	}
	if err := svc.finishTriageRunFailure(ctx, run, input, state, "secret verifier transport detail"); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != input.ThreadTS {
		t.Fatalf("approval verification notice = %+v", slack.posts)
	}
	// Superseded: "couldn't verify or report" was the fallback line. The three
	// slots split that sentence — what stopped is the verification, what
	// survived is Emisar's record — and "before repeating any action" moved to
	// the context line every failure card carries its next step in.
	content := slack.posts[0].message.Text +
		strings.Join(slack.posts[0].message.Sections, " ") +
		strings.Join(slack.posts[0].message.Context, " ")
	for _, required := range []string{
		"stopped verifying its result", "before repeating any action",
	} {
		if !strings.Contains(content, required) {
			t.Fatalf("approval verification notice lacks %q: %q", required, content)
		}
	}
	if strings.Contains(content, "secret verifier") || strings.Contains(content, "action finished") {
		t.Fatalf("approval verification notice overclaimed or leaked diagnostics: %q", content)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("approval continuation run = %+v, %v", stored, err)
	}
	memory, err := st.Intelligence.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.SessionID != "ses_approval" || memory.Generation != 1 {
		t.Fatalf("approval continuation retired shared session = %+v, %v", memory, err)
	}
}

// A real production investigation used 17 tool calls before semantic validation exhausted its
// inner retries, yet the terminal Slack card claimed no model turn had started. Once a Coop turn
// exists, the delivered notice must describe failed finalization rather than failed preparation.
func TestFailureAfterAModelTurnNeverClaimsTheTurnDidNotStart(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	input := core.SlackInput{
		ID: "post-turn-terminal-failure", EnvelopeID: "env-post-turn-terminal-failure",
		EventID: "event-post-turn-terminal-failure", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.300", UserID: "U123ABC",
		Text: "<@UBOT> why is the daily health runbook broken?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	run.CoopTurnID = "turn_that_used_tools"
	run.CoopEventSequence = 17

	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.finishTriageRunFailure(
		ctx, run, input, decisionpkg.WatchTurnState{},
		"caller rejected semantic output after 3 attempts",
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("terminal failure posts = %+v", slack.posts)
	}
	content := slack.posts[0].message.Text +
		strings.Join(slack.posts[0].message.Sections, " ") +
		strings.Join(slack.posts[0].message.Context, " ")
	if strings.Contains(content, "before a model turn started") ||
		!strings.Contains(content, "investigation ran") ||
		!strings.Contains(content, "saved work") {
		t.Fatalf("post-turn terminal notice describes the wrong stage: %q", content)
	}
}

func TestNewerHumanTurnSuppressesOlderCompletedReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	olderInput := core.SlackInput{
		ID: "human-old", EnvelopeID: "env-human-old", EventID: "event-human-old",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.100", UserID: "U123ABC", Text: "<@UBOT> use the old target",
		ReceivedAt: time.Now().UTC(),
	}
	newerInput := core.SlackInput{
		ID: "human-new", EnvelopeID: "env-human-new", EventID: "event-human-new",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		ThreadTS: "1700.100", MessageTS: "1700.200", UserID: "U123ABC",
		Text: "Correction: use the new target.", ReceivedAt: olderInput.ReceivedAt.Add(time.Second),
	}
	unrelatedInput := core.SlackInput{
		ID: "human-unrelated", EnvelopeID: "env-human-unrelated", EventID: "event-human-unrelated",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1800.100", UserID: "UOTHER", Text: "<@UBOT> separate question",
		ReceivedAt: olderInput.ReceivedAt.Add(500 * time.Millisecond),
	}
	for _, input := range []core.SlackInput{olderInput, unrelatedInput} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.100",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: olderInput.ID,
		UserID: olderInput.UserID, State: core.AgentRunRunning, StartedAt: olderInput.ReceivedAt,
		CreatedAt: olderInput.ReceivedAt, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, older.ID, "completed",
		[]byte(`{"action":"reply","attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"message":"Use the old target."}`),
		"", 1,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, older.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1800.100",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: unrelatedInput.ID,
		UserID: unrelatedInput.UserID, CreatedAt: unrelatedInput.ReceivedAt, Context: []byte(`{}`),
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	staged, err := st.GetAgentRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stale, err := svc.supersedeStaleHumanTriageResult(
		ctx, staged, olderInput, decisionpkg.WatchTurnState{},
	); err != nil || stale {
		t.Fatalf("unrelated channel turn suppressed the answer: stale=%t err=%v", stale, err)
	}
	if created, err := st.AdmitSlackInput(ctx, newerInput); err != nil || !created {
		t.Fatalf("admit correction = %t, %v", created, err)
	}
	staged, err = st.GetAgentRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.finalizeTriageAgentRun(ctx, staged); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); err == nil {
		t.Fatal("stale human reply was queued")
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, older.ID)
	if err != nil || episode.State != core.EpisodeSuperseded {
		t.Fatalf("stale episode = %+v, %v", episode, err)
	}
}

func TestOlderFailedAttemptCannotRetireNewerAttemptsSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "older-failed-input", EnvelopeID: "older-failed-envelope",
		EventID: "older-failed-event", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", MessageTS: "1700.300", UserID: "U123ABC",
		Text: "<@UBOT> investigate this",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit older input = %t, %v", created, err)
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID, Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: older.ConversationKey, SourceKind: "watch", SourceID: "new-owner",
		UserID: input.UserID, Context: []byte(`{}`),
	}); err != nil || !created {
		t.Fatalf("queue newer owner = %t, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "shared-session"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	older.Context = []byte(`{"session_id":"shared-session"}`)
	if err := svc.stageTerminalFinalizationFailure(
		ctx, older, errors.New("stale failure"),
	); err != nil {
		t.Fatal(err)
	}
	if coopClient.session.State != "open" {
		t.Fatalf("older attempt retired shared session: %+v", coopClient.session)
	}
	stored, err := st.GetAgentRun(ctx, older.ID)
	if err != nil || stored.State != core.AgentRunSuperseded {
		t.Fatalf("older attempt state = %+v, %v", stored, err)
	}
	if _, err := st.GetSlackDelivery(ctx, "watch_failure_"+input.ID); err == nil {
		t.Fatal("older attempt queued a failure notice")
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("older attempt queued fallback status clear: %v", err)
	}
}

func TestOlderEngineeringFinalizerCannotClearNewerAttemptStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "stale-finalizer-task", "Fix it", "summary", "U123ABC",
		"COPS", "1700.400", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.401"); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.RootTS,
		ConversationKey: "incident:" + task.ID,
		SourceKind:      "slack", SourceID: "older-task-turn", UserID: "U123ABC",
		State: core.AgentRunRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, older.ID, "completed", []byte(`{}`), "", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, older.ID); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.RootTS,
		ConversationKey: older.ConversationKey,
		SourceKind:      "slack", SourceID: "newer-task-turn", UserID: "U123ABC",
	}); !errors.Is(err, store.ErrConflict) || created {
		t.Fatalf("queue while task result finalizes = %t, %v", created, err)
	}
}

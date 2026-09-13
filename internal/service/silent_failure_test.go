package service

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	_ "modernc.org/sqlite"
)

// capturingLogger returns a logger and the buffer it writes to, so a test can
// assert that a failure was reported rather than only that it happened.
func capturingLogger() (*slog.Logger, *bytes.Buffer) {
	buffer := &bytes.Buffer{}
	return slog.New(slog.NewTextHandler(buffer, &slog.HandlerOptions{Level: slog.LevelDebug})), buffer
}

// A surface repaint that Slack keeps rejecting must stop, and must say so.
//
// This is the shape of the defect that went unnoticed for months: a surface
// refresh Slack refused was retried to the full twelve-attempt budget reserved
// for work an operator actually asked for. Nothing was logged, nothing was
// audited, and the only trace was a failed row in a table nobody reads. The
// suggested-prompts refresh that first showed this has since been deleted —
// the manifest declares those prompts and the API call never once succeeded —
// but the App Home is the same shape of write and inherits the same budget.
func TestFailingSurfaceRefreshGivesUpEarlyAndIsReported(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, logged := capturingLogger()
	slackClient := &fakeSlack{homeErr: errors.New("internal_error")}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), logger)
	// The queue backs off between attempts, so the clock has to move for the
	// next one to come due. Both the service and the store read it.
	clock := time.Now().UTC()
	svc.SetClock(func() time.Time { return clock })
	st.SetClock(func() time.Time { return clock })

	input := core.SlackInput{
		ID: "slack_home", EnvelopeID: "env-home", EventID: "ev-home",
		Kind: inputAppHome, TeamID: cfg.Slack.TeamID,
		ChannelID: "D123ABC", UserID: "U123ABC", ReceivedAt: clock,
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	for range cfg.Limits.MaxSlackInputAttempts {
		stored, err := st.GetSlackInput(ctx, input.ID)
		if err != nil {
			t.Fatal(err)
		}
		if stored.State == "failed" {
			break
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatal(err)
		}
		clock = clock.Add(10 * time.Minute)
	}

	if len(slackClient.homes) != surfaceRefreshAttempts {
		t.Fatalf(
			"Slack calls before giving up = %d, want %d",
			len(slackClient.homes), surfaceRefreshAttempts,
		)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "failed" {
		t.Fatalf("state after the budget = %q, want failed", stored.State)
	}
	if !strings.Contains(logged.String(), "Slack input attempt failed") ||
		!strings.Contains(logged.String(), "internal_error") ||
		!strings.Contains(logged.String(), "gave_up=true") {
		t.Fatalf("a surface refresh failed without saying so; log = %s", logged)
	}
}

// The Open button on the App Home is a link, and a link is finished when it is
// acknowledged.
//
// This is the production row, reproduced: action ryker_open_work_thread,
// value commitment_episode_run_19664690e12b6af7e, channel_id empty. It was not
// routed, so it fell through to the incident controls, which looked the
// commitment up as an incident, failed to find one, and tried to say so in an
// ephemeral message addressed to no channel at all. Slack answered
// channel_not_found twelve times over twenty-one minutes, for a button whose
// only job — opening a URL — Slack had already done in the client.
func TestAppHomeLinkButtonIsFinishedWithoutPostingAnywhere(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	input := core.SlackInput{
		ID: "slack_open_work", EnvelopeID: "env-open-work", EventID: "ev-open-work",
		Kind: "action", TeamID: cfg.Slack.TeamID, UserID: "U123ABC",
		ActionID:    slackui.ActionOpenWorkThread,
		ActionValue: "commitment_episode_run_19664690e12b6af7e",
		ReceivedAt:  svc.now().UTC(),
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "done" {
		t.Fatalf("state = %q, want done; a link button has nothing to retry", stored.State)
	}
	if len(slackClient.ephemerals) != 0 {
		t.Fatalf("posted %d ephemerals with no channel to post them in", len(slackClient.ephemerals))
	}
	// Nothing at all, not even a repaint. A click that already did its work in
	// the client should not send the App Home through a redraw, and an
	// unrouted link button reaches here as a stale incident control that tries
	// to explain itself.
	if len(slackClient.homes) != 0 {
		t.Fatalf("a link button caused %d App Home repaints; it is routed nowhere", len(slackClient.homes))
	}
}

// Any other App Home interaction that needs to answer has the same problem:
// there is no channel to answer in. It must repaint the surface the click came
// from rather than address the empty string and be rejected forever.
func TestChannellessInteractionRepaintsTheAppHomeInsteadOfFailing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	logger, logged := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), logger)

	input := core.SlackInput{
		ID: "slack_stale_control", EnvelopeID: "env-stale", EventID: "ev-stale",
		Kind: "action", TeamID: cfg.Slack.TeamID, UserID: "U123ABC",
		ActionID: slackui.ActionResolve, ActionValue: "inc_missing",
		ReceivedAt: svc.now().UTC(),
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "done" {
		t.Fatalf("state = %q, want done rather than a retry that cannot succeed", stored.State)
	}
	if len(slackClient.ephemerals) != 0 {
		t.Fatalf("posted %d ephemerals with no channel", len(slackClient.ephemerals))
	}
	if len(slackClient.homes) != 1 {
		t.Fatalf("App Home repaints = %d, want the reply to land where the click came from", len(slackClient.homes))
	}
	if !strings.Contains(logged.String(), "no channel to reply in") {
		t.Fatalf("a channelless interaction was handled silently; log = %s", logged)
	}
}

// A deployment that keeps its channels in the database still gets prewarmed.
//
// This is blitz exactly: watch_channels and summon_channels are both [] in
// YAML, all eight channels live in channel_configurations, and nobody had
// spoken yet so conversation_sessions was empty. Both of the sources prewarming
// read were therefore empty, the loop iterated nothing, and the function
// returned having done nothing and said nothing — through roughly thirty-five
// restarts, while the deployment whose channels happen to be in YAML prewarmed
// after every one.
func TestPrewarmUsesChannelsConfiguredInTheDatabase(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = nil
	cfg.Slack.SummonChannels = nil
	cfg.Coop.PrewarmSessions = 2
	repository := cfg.Repositories["repo"]
	repository.ConversationPolicy = "repo-conversation"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CDBONLY", Participation: "proactive", Repository: "repo",
		AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}
	logger, logged := capturingLogger()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), logger)

	svc.prewarmConversationSessions(ctx)

	session, err := st.GetConversationSession(ctx, "CDBONLY")
	if err != nil {
		t.Fatalf("a channel configured in the database was never prewarmed: %v", err)
	}
	if session.Policy != "repo-conversation" {
		t.Fatalf("prewarmed session = %+v", session)
	}
	if len(coopClient.prepareSessions) != 1 {
		t.Fatalf("prepared sessions = %v", coopClient.prepareSessions)
	}
	if !strings.Contains(logged.String(), "finished prewarming conversation sessions") {
		t.Fatalf("prewarming did not report its result; log = %s", logged)
	}
}

// A prewarm that decides to do nothing says so.
//
// Doing nothing can be correct — an empty workspace has nothing to warm — but
// it is indistinguishable from a broken source of truth unless it is stated,
// and that is precisely the ambiguity that hid the defect above.
func TestPrewarmSaysSoWhenItWarmsNothing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = nil
	cfg.Slack.SummonChannels = nil
	cfg.Coop.PrewarmSessions = 2
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, logged := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), logger)

	svc.prewarmConversationSessions(ctx)

	if !strings.Contains(logged.String(), "prewarmed no conversation sessions") {
		t.Fatalf("prewarming did nothing without saying so; log = %s", logged)
	}
}

// A configured channel whose repository declares no conversation policy is a
// legitimate skip, but it must still be legible: it used to look exactly like
// a channel that had been warmed, because neither produced any output.
func TestPrewarmNamesTheChannelsItSkips(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CNOPOLICY"}
	cfg.Coop.PrewarmSessions = 2
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, logged := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), logger)

	svc.prewarmConversationSessions(ctx)

	if !strings.Contains(logged.String(), "CNOPOLICY") ||
		!strings.Contains(logged.String(), "no conversation policy") {
		t.Fatalf("a skipped channel was skipped silently; log = %s", logged)
	}
}

// A channel configured for proactive participation that the bot is not in is
// a coverage hole, and it must be impossible to have one quietly.
//
// This is C091FK0HHAQ: configured proactive on the seventh, present = 0,
// joined_at NULL, and an observed_at two days staler than the seven channels
// beside it. Every alert posted there reached nobody. Neither record is wrong
// on its own, which is why nothing raised it — the only way to find it was to
// join channel_configurations against slack_channel_memberships by hand.
func TestConfiguredChannelTheBotCannotSeeIsReportedNotSwallowed(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, channelID := range []string{"CJOINED", "CABSENT"} {
		if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
			ChannelID: channelID, Participation: "proactive", Repository: "repo",
			AlertPolicy: "reply", ActorID: "U123ABC",
		}); err != nil {
			t.Fatal(err)
		}
	}
	logger, logged := capturingLogger()
	slackClient := &fakeSlack{channels: []slackui.Channel{
		{ID: "CJOINED", Name: "joined", Member: true},
		{ID: "CABSENT", Name: "frontend-ops-alerts", Member: false},
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), logger)

	if err := svc.reconcileSlackChannelMemberships(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}

	if !strings.Contains(logged.String(), "CABSENT") ||
		!strings.Contains(logged.String(), "not joined") {
		t.Fatalf("a configured channel the bot cannot see went unreported; log = %s", logged)
	}
	if strings.Contains(logged.String(), "CJOINED") {
		t.Fatalf("a channel the bot is in was reported as a gap; log = %s", logged)
	}

	// Reconciliation runs every minute. A standing gap is stated when it
	// appears, not 1,440 times a day, because a warning nobody can read is
	// another way of not saying it.
	logged.Reset()
	if err := svc.reconcileSlackChannelMemberships(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	if strings.Contains(logged.String(), "not joined") {
		t.Fatalf("an unchanged coverage gap was repeated; log = %s", logged)
	}

	// And it reaches the operator, not only the log.
	gaps, err := st.ListConfiguredChannelsMissingMembership(ctx, 25)
	if err != nil {
		t.Fatal(err)
	}
	home := slackui.AppendCoverageGaps(slackui.Notice("nothing else"), gaps)
	if !strings.Contains(home.Sections[0], "CABSENT") ||
		!strings.Contains(home.Sections[0], "Configured but not joined") {
		t.Fatalf("the App Home does not carry the coverage hole: %+v", home.Sections)
	}
}

// auditOutcomes reads back what the service recorded about one object, so a
// test can check the trail an operator would actually read rather than only the
// log line beside it. An empty objectID matches every object of that kind,
// which is how a caller checks work whose id the service generated.
func auditOutcomes(t *testing.T, cfg config.Config, kind, objectID string) []string {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(
		`SELECT outcome, detail FROM audit_events
		 WHERE kind = ? AND (? = '' OR object_id = ?) ORDER BY created_at, id`,
		kind, objectID, objectID,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var result []string
	for rows.Next() {
		var outcome, detail string
		if err := rows.Scan(&outcome, &detail); err != nil {
			t.Fatal(err)
		}
		result = append(result, outcome+": "+detail)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return result
}

// configureChannelsAndReconcile is the arrangement every join case shares: an
// operator has configured these channels, Slack reports this membership, and
// the reconciliation loop has run once.
func configureChannelsAndReconcile(
	t *testing.T,
	slackClient *fakeSlack,
	configured []string,
) (config.Config, *bytes.Buffer) {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, channelID := range configured {
		if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
			ChannelID: channelID, Participation: "proactive", Repository: "repo",
			AlertPolicy: "reply", ActorID: "U123ABC",
		}); err != nil {
			t.Fatal(err)
		}
	}
	logger, logged := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), logger)
	if err := svc.reconcileSlackChannelMemberships(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	return cfg, logged
}

// A public channel an operator configured but nobody invited the bot to is a
// hole Ryker is now allowed to close by itself.
//
// Reporting C091FK0HHAQ was only half an answer: an operator still had to read
// the warning and go type /invite. conversations.join needs no one, so the
// remaining question is only whether the door opens, and the outcome is
// recorded either way.
func TestConfiguredPublicChannelIsJoinedWithoutWaitingForAHuman(t *testing.T) {
	slackClient := &fakeSlack{channels: []slackui.Channel{
		{ID: "CPUBLIC", Name: "frontend-ops-alerts", Member: false},
	}}

	cfg, logged := configureChannelsAndReconcile(t, slackClient, []string{"CPUBLIC"})

	if !slices.Equal(slackClient.joined, []string{"CPUBLIC"}) {
		t.Fatalf("join attempts = %v, want the configured public channel", slackClient.joined)
	}
	if !strings.Contains(logged.String(), "joined a configured channel") {
		t.Fatalf("a join happened without saying so; log = %s", logged)
	}
	audited := auditOutcomes(t, cfg, "slack.channel.join", "CPUBLIC")
	if len(audited) != 1 || !strings.HasPrefix(audited[0], "joined: ") {
		t.Fatalf("join audit = %v, want one joined row", audited)
	}
}

// A private channel cannot be entered by an app, and saying "the join failed"
// would send an operator to look for a fault instead of running /invite.
//
// Slack's answer here is method_not_supported_for_channel_type and it will be
// the same answer forever, so the attempt is not made at all: the audit names
// the repair rather than the refusal.
func TestConfiguredPrivateChannelAsksForAnInviteInsteadOfTrying(t *testing.T) {
	slackClient := &fakeSlack{channels: []slackui.Channel{
		{ID: "CPRIVATE", Name: "security-incidents", Member: false, Private: true},
	}}

	cfg, logged := configureChannelsAndReconcile(t, slackClient, []string{"CPRIVATE"})

	if len(slackClient.joined) != 0 {
		t.Fatalf("tried to join a private channel: %v", slackClient.joined)
	}
	if !strings.Contains(logged.String(), "/invite") {
		t.Fatalf("the private-channel repair was not stated; log = %s", logged)
	}
	audited := auditOutcomes(t, cfg, "slack.channel.join", "CPRIVATE")
	if len(audited) != 1 || !strings.HasPrefix(audited[0], "private_needs_invite: ") {
		t.Fatalf("private channel audit = %v", audited)
	}
}

// The build asking for a scope and the installation granting it are two
// different events, and the code has to survive the gap between them.
//
// deploy/slack-app-manifest.yaml requests channels:join, but a manifest change
// only takes effect when a person reinstalls the app. Until then Slack answers
// missing_scope, and the only useful thing to say is which human action fixes
// it — retrying cannot, and reporting it as an ordinary join failure would hide
// the one instruction that works.
func TestJoinWithoutTheScopeSaysTheAppMustBeReinstalled(t *testing.T) {
	slackClient := &fakeSlack{
		channels: []slackui.Channel{{ID: "CPUBLIC", Name: "frontend-ops-alerts"}},
		joinErr:  errors.New("missing_scope"),
	}

	cfg, logged := configureChannelsAndReconcile(t, slackClient, []string{"CPUBLIC"})

	if len(slackClient.joined) != 1 {
		t.Fatalf("join attempts = %v, want exactly one rather than a retry loop", slackClient.joined)
	}
	if !strings.Contains(logged.String(), "channels:join") ||
		!strings.Contains(logged.String(), "reinstall") {
		t.Fatalf("a missing scope was reported as a generic failure; log = %s", logged)
	}
	audited := auditOutcomes(t, cfg, "slack.channel.join", "CPUBLIC")
	if len(audited) != 1 || !strings.HasPrefix(audited[0], "missing_scope: ") ||
		!strings.Contains(audited[0], "invite the bot manually") {
		t.Fatalf("missing scope audit = %v", audited)
	}
}

// Slack has already answered these; asking again eleven more times cannot
// change the answer, and the eleven extra rejections are the only thing the
// budget buys.
func TestPermanentSlackErrorIsNotRetried(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, logged := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), logger)

	input := core.SlackInput{
		ID: "slack_permanent", EnvelopeID: "env-permanent", EventID: "ev-permanent",
		Kind: "action", TeamID: cfg.Slack.TeamID, UserID: "U123ABC",
		ReceivedAt: svc.now().UTC(),
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	// Only a leased input can be failed, which is the state it is in when a
	// handler reports an error.
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.retrySlackInput(ctx, leased, errors.New("channel_not_found")); err != nil {
		t.Fatal(err)
	}

	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "failed" {
		t.Fatalf("state after a permanent Slack error = %q, want failed on the first attempt", stored.State)
	}
	if !strings.Contains(logged.String(), "channel_not_found") {
		t.Fatalf("a permanent Slack failure was not reported; log = %s", logged)
	}
}

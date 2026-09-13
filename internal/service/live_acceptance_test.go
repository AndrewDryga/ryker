package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

const liveAcceptanceTimeout = 8 * time.Minute

// TestLiveSlackAcceptance deliberately crosses the real Slack, Coop, model,
// repository, and configured MCP boundaries. It is opt-in so ordinary tests
// cannot spend model budget or write to a workspace.
func TestLiveSlackAcceptance(t *testing.T) {
	configPath := os.Getenv("RYKER_LIVE_CONFIG")
	channelID := os.Getenv("RYKER_LIVE_CHANNEL")
	if configPath == "" || channelID == "" {
		t.Skip("set RYKER_LIVE_CONFIG and RYKER_LIVE_CHANNEL to run live acceptance")
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	botToken, err := cfg.Secret(cfg.Slack.BotTokenEnv)
	if err != nil {
		t.Fatal(err)
	}
	appToken, err := cfg.Secret(cfg.Slack.AppTokenEnv)
	if err != nil {
		t.Fatal(err)
	}
	emisarToken, err := cfg.Secret(cfg.Coop.EmisarTokenEnv)
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	slackClient := slackui.New(botToken, appToken)
	channel, err := slackClient.GetChannel(ctx, channelID)
	if err != nil {
		t.Fatal(err)
	}
	if !validLiveAcceptanceChannel(channel) {
		t.Fatalf(
			"live acceptance requires an active joined #test channel, got %+v",
			channel,
		)
	}
	if _, err := slackClient.Preflight(
		ctx,
		cfg.Slack.TeamID,
		cfg.Slack.Operators,
		cfg.Slack.InviteUsers,
		cfg.Slack.SummonChannels,
		cfg.Slack.WatchChannels,
	); err != nil {
		t.Fatalf(
			"Slack app installation does not match the shipped manifest: %v; "+
				"apply deploy/slack-app-manifest.yaml and reinstall the app before testing",
			err,
		)
	}

	cfg.StateDir = t.TempDir()
	cfg.Slack.WatchSettleDelay = config.Duration{}
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := st.Close(); err != nil {
			t.Errorf("close acceptance store: %v", err)
		}
	})

	coopClient := coop.New(cfg.Coop.Socket, cfg.Coop.RequestTimeout.Duration)
	svc := New(
		cfg,
		st,
		coopClient,
		slackClient,
		nil,
		slackui.NewSanitizer(
			cfg.Limits.MaxAssistantBytes,
			botToken,
			appToken,
			emisarToken,
		),
		slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
			Level: slog.LevelWarn,
		})),
	)
	if err := svc.Initialize(ctx); err != nil {
		t.Fatal(err)
	}

	runID := fmt.Sprintf("live-acceptance-%d", time.Now().UTC().Unix())
	rootMessage := slackui.Message{
		Text:   "Emisar live acceptance run " + runID,
		Header: "Live product acceptance",
		Markdown: "This thread is an automated, non-mutating acceptance run against the real " +
			"Slack, model, Coop, repository, and configured read-only tools.",
	}
	rootTS, err := slackClient.Post(ctx, runID, channelID, "", rootMessage)
	if err != nil {
		t.Fatal(err)
	}

	harness := liveAcceptanceHarness{
		t: t, ctx: ctx, cfg: cfg, store: st, service: svc,
		coop: coopClient, slack: slackClient,
		channelID: channelID, rootTS: rootTS, runID: runID,
	}
	t.Cleanup(harness.cleanupSession)

	first := harness.triage(
		"reply",
		"Reply concisely in Slack. State that this live acceptance run is active, identify the "+
			"configured repository, and say explicitly that no incident was created.",
	)
	assertLiveSlackMessage(t, first)
	firstText := renderedSlackMessage(first)
	if !strings.Contains(strings.ToLower(firstText), "no incident") {
		t.Fatalf("first live response did not state the incident boundary: %s", firstText)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.IncidentsTotal != 0 {
		t.Fatalf("ordinary live triage created %d incidents", metrics.IncidentsTotal)
	}

	followup := harness.triage(
		"followup",
		"What incident boundary did you state in your previous reply? Answer in one sentence.",
	)
	assertLiveSlackMessage(t, followup)
	if !strings.Contains(
		strings.ToLower(renderedSlackMessage(followup)),
		"no incident",
	) {
		t.Fatalf("follow-up did not use the previous turn: %+v", followup)
	}

	preference := harness.triage(
		"preference",
		"When I ask for infrastructure health, I always mean a deep check.",
	)
	assertLiveSlackMessage(t, preference)
	action := findMessageAction(preference, slackui.ActionRememberPreference)
	if action.ID == "" {
		t.Fatalf("preference request produced no confirmation action: %+v", preference)
	}
	harness.click("save-preference", action, rootTS)
	metrics, err = st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.PreferencesActive != 1 {
		t.Fatalf("confirmed preference count = %d, want 1", metrics.PreferencesActive)
	}

	task := harness.triage(
		"task-offer",
		"Find one genuine typo in the repository, fix only that typo, validate it, and commit it. "+
			"Do not push, merge, deploy, or change infrastructure.",
	)
	assertLiveSlackMessage(t, task)
	if action := findMessageAction(task, slackui.ActionStartTask); action.ID == "" {
		t.Fatalf("repository change request produced no engineering-task offer: %+v", task)
	}
}

func validLiveAcceptanceChannel(channel slackui.Channel) bool {
	testName := channel.Name == "test" || strings.HasSuffix(channel.Name, "-test")
	return testName && channel.Member && !channel.Archived
}

// Deployment-specific test channels are the normal live acceptance target.
// The Blitz acceptance stopped before posting anything on 2026-08-18 because
// its explicit joined channel was named #emisar-test rather than exactly #test.
func TestAnExplicitJoinedTestChannelMayUseDeploymentPrefix(t *testing.T) {
	channel := slackui.Channel{Name: "emisar-test", Member: true}
	if !validLiveAcceptanceChannel(channel) {
		t.Fatal("the explicit joined #emisar-test channel was rejected")
	}
	for _, unsafe := range []slackui.Channel{
		{Name: "contest", Member: true},
		{Name: "test-operations", Member: true},
		{Name: "emisar-test", Member: false},
		{Name: "emisar-test", Member: true, Archived: true},
	} {
		if validLiveAcceptanceChannel(unsafe) {
			t.Fatalf("unsafe live acceptance channel was accepted: %+v", unsafe)
		}
	}
}

type liveAcceptanceHarness struct {
	t         *testing.T
	ctx       context.Context
	cfg       config.Config
	store     *store.Store
	service   *Service
	coop      *coop.Client
	slack     *slackui.Client
	channelID string
	rootTS    string
	runID     string
	sequence  int
}

func liveAcceptanceInputID(runID, label string, sequence int) string {
	return fmt.Sprintf("%s_%s_%d", runID, label, sequence)
}

// Coop retains operation idempotency beyond the temporary Ryker store. A
// second live acceptance run reused live_reply_1 on 2026-08-18 and replayed a
// failed workspace preparation from August 12 instead of exercising this run.
func TestEveryLiveAcceptanceRunOwnsFreshInputIDs(t *testing.T) {
	first := liveAcceptanceInputID("live-acceptance-1", "reply", 1)
	second := liveAcceptanceInputID("live-acceptance-2", "reply", 1)
	if first == second {
		t.Fatalf("separate live runs reused input id %q", first)
	}
}

func (h *liveAcceptanceHarness) triage(label string, text string) slackui.Message {
	h.t.Helper()
	h.sequence++
	inputID := liveAcceptanceInputID(h.runID, label, h.sequence)
	input := core.SlackInput{
		ID: inputID, EnvelopeID: "env_" + inputID, EventID: "event_" + inputID,
		Kind: "mention", TeamID: h.cfg.Slack.TeamID,
		ChannelID: h.channelID, ThreadTS: h.rootTS, MessageTS: h.rootTS,
		UserID:     h.cfg.Slack.Operators[0],
		Text:       fmt.Sprintf("<@%s> %s", h.service.identity.BotUserID, text),
		ReceivedAt: time.Now().UTC(),
	}
	admitted, err := h.store.AdmitSlackInput(h.ctx, input)
	if err != nil || !admitted {
		h.t.Fatalf("admit %s = %t, %v", label, admitted, err)
	}
	if err := h.service.processSlackInput(h.ctx); err != nil {
		h.t.Fatalf("route %s: %v", label, err)
	}
	h.drainDeliveries()
	if err := h.service.processAgentRun(h.ctx); err != nil {
		h.t.Fatalf("start %s: %v", label, err)
	}

	deadline := time.Now().Add(liveAcceptanceTimeout)
	for time.Now().Before(deadline) {
		// A retryable session-creation failure returns the run to pending. Mirror
		// the scheduler here so the acceptance exercises the eventual retry
		// instead of polling forever after only one start attempt.
		if err := h.service.processAgentRun(h.ctx); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			h.t.Fatalf("continue %s: %v", label, err)
		}
		h.service.pollAgentRuns(h.ctx)
		for {
			err := h.service.processAgentRunFinalization(h.ctx)
			if errors.Is(err, store.ErrNotFound) {
				break
			}
			if err != nil {
				h.t.Fatalf("finalize %s: %v", label, err)
			}
		}
		h.drainDeliveries()
		run, err := h.store.GetAgentRunBySource(h.ctx, "watch", inputID)
		if err == nil && (run.State == core.AgentRunCompleted ||
			run.State == core.AgentRunFailed ||
			run.State == core.AgentRunCancelled ||
			run.State == core.AgentRunSuperseded) {
			if run.State != core.AgentRunCompleted {
				h.t.Fatalf(
					"%s ended as %s: %s",
					label,
					run.State,
					run.LastError,
				)
			}
			deliveries, err := h.store.ListSlackDeliveriesByPrefix(
				h.ctx, "watch_reply_"+inputID,
			)
			if err != nil {
				h.t.Fatalf("list %s Slack responses: %v", label, err)
			}
			delivery, ok := liveAcceptanceResponseDelivery(deliveries, run, inputID)
			if !ok {
				h.t.Fatalf("load %s Slack response: not found in %+v", label, deliveries)
			}
			if delivery.State != "sent" || delivery.ThreadTS != h.rootTS ||
				delivery.ChannelID != h.channelID {
				h.t.Fatalf("%s delivery routed incorrectly: %+v", label, delivery)
			}
			message, err := slackui.Decode(delivery.Body)
			if err != nil {
				h.t.Fatalf("decode %s response: %v", label, err)
			}
			return message
		}
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			h.t.Fatalf("load %s run: %v", label, err)
		}
		select {
		case <-h.ctx.Done():
			h.t.Fatal(h.ctx.Err())
		case <-time.After(500 * time.Millisecond):
		}
	}
	h.t.Fatalf("%s did not complete within %s", label, liveAcceptanceTimeout)
	return slackui.Message{}
}

func liveAcceptanceResponseDelivery(
	deliveries []core.SlackDelivery,
	run core.AgentRun,
	inputID string,
) (core.SlackDelivery, bool) {
	for _, delivery := range deliveries {
		if delivery.ResponseRoot && delivery.SourceInputID == inputID &&
			delivery.AgentRunID == run.ID && delivery.AgentRunKey == run.IdempotencyKey {
			return delivery, true
		}
	}
	return core.SlackDelivery{}, false
}

// Corrections and recovered submissions suffix their delivery identity with
// the execution key. The live acceptance reached a valid preference offer on
// 2026-08-18, then called it missing because it looked only for the legacy
// unsuffixed ID instead of the durable response ownership fields.
func TestLiveAcceptanceFindsTheCurrentRunsSuffixedResponse(t *testing.T) {
	run := core.AgentRun{ID: "run-current", IdempotencyKey: "run:current:recovery_2"}
	delivery, ok := liveAcceptanceResponseDelivery([]core.SlackDelivery{
		{
			ID: "watch_reply_input_exec_old", SourceInputID: "input",
			AgentRunID: "run-old", AgentRunKey: "run:old", ResponseRoot: true,
		},
		{
			ID: "watch_reply_input_exec_recovery_2", SourceInputID: "input",
			AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey, ResponseRoot: true,
		},
	}, run, "input")
	if !ok || delivery.ID != "watch_reply_input_exec_recovery_2" {
		t.Fatalf("current response = %+v, found=%t", delivery, ok)
	}
}

func (h *liveAcceptanceHarness) click(
	label string,
	action slackui.Action,
	messageTS string,
) {
	h.t.Helper()
	h.sequence++
	inputID := liveAcceptanceInputID(h.runID, label, h.sequence)
	input := core.SlackInput{
		ID: inputID, EnvelopeID: "env_" + inputID, EventID: "event_" + inputID,
		Kind: "action", TeamID: h.cfg.Slack.TeamID,
		ChannelID: h.channelID, ThreadTS: h.rootTS, MessageTS: messageTS,
		UserID:   h.cfg.Slack.Operators[0],
		ActionID: action.ID, ActionValue: action.Value,
		ReceivedAt: time.Now().UTC(),
	}
	admitted, err := h.store.AdmitSlackInput(h.ctx, input)
	if err != nil || !admitted {
		h.t.Fatalf("admit %s = %t, %v", label, admitted, err)
	}
	if err := h.service.processSlackInput(h.ctx); err != nil {
		h.t.Fatalf("process %s: %v", label, err)
	}
	h.drainDeliveries()
}

func (h *liveAcceptanceHarness) drainDeliveries() {
	h.t.Helper()
	for range 100 {
		err := h.service.processSlackDelivery(h.ctx, nil)
		if errors.Is(err, store.ErrNotFound) {
			return
		}
		if err != nil {
			h.t.Fatalf("deliver live Slack output: %v", err)
		}
	}
	h.t.Fatal("live Slack delivery queue did not drain")
}

func (h *liveAcceptanceHarness) cleanupSession() {
	memory, err := h.store.Intelligence.GetChannelMemory(context.Background(), h.channelID)
	if err != nil || memory.SessionID == "" {
		return
	}
	session, err := h.coop.GetSession(context.Background(), memory.SessionID)
	if err != nil {
		h.t.Errorf("inspect acceptance session for cleanup: %v", err)
		return
	}
	if session.State == "open" {
		session, _, err = h.coop.Close(
			context.Background(),
			"live_acceptance_close_"+memory.SessionID,
			session.ID,
			session.Revision,
		)
		if err != nil {
			h.t.Errorf("close acceptance session: %v", err)
			return
		}
	}
	plan, _, err := h.coop.PlanDiscard(
		context.Background(),
		"live_acceptance_plan_"+memory.SessionID,
		session.ID,
		session.Revision,
		false,
		false,
	)
	if err != nil {
		h.t.Errorf("plan acceptance cleanup: %v", err)
		return
	}
	if plan.Plan.Workspace.Dirty || plan.Plan.Workspace.Unmerged ||
		plan.Plan.Workspace.Running {
		h.t.Errorf("acceptance session %s is not clean enough to discard", session.ID)
		return
	}
	if _, _, err := h.coop.Discard(
		context.Background(),
		"live_acceptance_discard_"+memory.SessionID,
		session.ID,
		plan.OperationID,
	); err != nil {
		h.t.Errorf("discard acceptance session: %v", err)
		return
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		session, err = h.coop.GetSession(context.Background(), memory.SessionID)
		if err != nil {
			h.t.Errorf("verify acceptance session cleanup: %v", err)
			return
		}
		if session.State == "discarded" {
			return
		}
		if time.Now().After(deadline) {
			h.t.Errorf(
				"acceptance session %s state after cleanup = %s, want discarded",
				session.ID,
				session.State,
			)
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func findMessageAction(message slackui.Message, actionID string) slackui.Action {
	for _, action := range message.Actions {
		if action.ID == actionID {
			return action
		}
	}
	for _, row := range message.Rows {
		for _, action := range append(append([]slackui.Action{}, row.Actions...), row.Overflow...) {
			if action.ID == actionID {
				return action
			}
		}
	}
	for _, action := range message.Overflow {
		if action.ID == actionID {
			return action
		}
	}
	return slackui.Action{}
}

// Modern cards keep controls beside the row they affect. The live acceptance
// found a valid Remember button on its preference row, then called it missing
// because its helper searched only the retired bottom action bar.
func TestLiveAcceptanceFindsActionsAcrossTheWholeCard(t *testing.T) {
	want := slackui.Action{ID: slackui.ActionRememberPreference, Value: "offer"}
	message := slackui.Message{Rows: []slackui.Row{{Actions: []slackui.Action{want}}}}
	if got := findMessageAction(message, want.ID); got != want {
		t.Fatalf("row action = %+v, want %+v", got, want)
	}
}

func assertLiveSlackMessage(t *testing.T, message slackui.Message) {
	t.Helper()
	if strings.TrimSpace(message.Text) == "" {
		t.Fatal("Slack fallback text is empty")
	}
	if len(message.Blocks()) == 0 || len(message.Blocks()) > 50 {
		t.Fatalf("Slack block count = %d", len(message.Blocks()))
	}
	rendered := renderedSlackMessage(message)
	for _, forbidden := range []string{
		`"action":`,
		`"evidence":`,
		`"coverage":`,
		"hidden reasoning",
		"internal tool output",
	} {
		if strings.Contains(strings.ToLower(rendered), strings.ToLower(forbidden)) {
			t.Fatalf("Slack response exposed internal protocol %q: %s", forbidden, rendered)
		}
	}
}

func renderedSlackMessage(message slackui.Message) string {
	parts := []string{message.Header, message.Markdown, message.Text}
	parts = append(parts, message.Sections...)
	// The ledger is read text, not decoration — the help card's command
	// reference lives there and nowhere else — so a helper that claims to
	// render the message has to include it.
	parts = append(parts, renderedLedger(message.Ledger)...)
	parts = append(parts, message.Context...)
	return strings.Join(parts, "\n")
}

func renderedLedger(steps []slackui.LedgerStep) []string {
	var lines []string
	for _, step := range steps {
		lines = append(lines, strings.TrimSpace(strings.Join(
			[]string{step.Label, step.Detail, step.When, step.Owner}, " ",
		)))
		lines = append(lines, renderedLedger(step.Children)...)
	}
	return lines
}

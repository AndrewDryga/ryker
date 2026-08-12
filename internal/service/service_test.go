package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestGeneratedVisualLegacyUncertainMissingScopeFailsImmediately(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	data := []byte("\x89PNG\r\n\x1a\nchart")
	digest := sha256.Sum256(data)
	digestHex := hex.EncodeToString(digest[:])
	coopClient := newFakeCoop()
	coopClient.turn = coop.Turn{ID: "turn_visual", SessionID: "ses_1", OutputArtifacts: []coop.OutputArtifact{{
		ID: "artifact_visual", Name: "load.png", MediaType: "image/png", SHA256: digestHex, Bytes: int64(len(data)),
	}}}
	coopClient.outputArtifacts = map[string]coop.OutputArtifact{
		"artifact_visual": {ID: "artifact_visual", MediaType: "image/png", SHA256: digestHex, Bytes: int64(len(data)), Data: data},
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.enqueueGeneratedVisuals(ctx, "out_legacy", "", "", "", "C123", "1700.001", "ses_1", "turn_visual", []core.GeneratedVisual{{
		Artifact: "load.png", Title: "Production load", AltText: "Line chart of production load over 24 hours.",
	}}, nil); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(
		ctx, leased.ID, "GetUploadURLExternal: missing_scope", time.Now(), true, false,
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.historyRequests) != 0 {
		t.Fatalf("definitive missing_scope was reconciled through Slack history: %+v", slackClient.historyRequests)
	}
	delivery, err := st.GetSlackDelivery(ctx, "out_legacy_visual_01")
	if err != nil || delivery.State != "failed" {
		t.Fatalf("legacy visual delivery = %+v err=%v", delivery, err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 || !strings.Contains(slackClient.posts[0].message.Text, "files:write") {
		t.Fatalf("legacy upload failure reply = %+v", slackClient.posts)
	}
}

func TestSocketEventIsPersistedBeforeAcknowledgement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CINCIDENT"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{"event_id": "Ev123"})
	request := &socketmode.Request{EnvelopeID: "env-1", Payload: payload}
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U123ABC", Channel: "CINCIDENT", TimeStamp: "1700.2",
				ThreadTimeStamp: "1700.1", Text: "What changed?",
			}},
		},
		Request: request,
	})
	if socket.acks != 1 {
		t.Fatalf("acks = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if input.EventID != "Ev123" || input.ThreadTS != "1700.1" || input.Text != "What changed?" {
		t.Fatalf("persisted input = %+v", input)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}

	// Top-level channel conversation is persisted too; routing and authorization
	// happen in the durable input worker.
	payload, _ = json.Marshal(map[string]any{"event_id": "Ev124"})
	request = &socketmode.Request{EnvelopeID: "env-2", Payload: payload}
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U123ABC", Channel: "CINCIDENT", TimeStamp: "1700.3", Text: "ordinary chatter",
			}},
		},
		Request: request,
	})
	if socket.acks != 2 {
		t.Fatalf("top-level event was not acknowledged: %d", socket.acks)
	}
	input, err = st.LeaseSlackInput(ctx)
	if err != nil || input.ThreadTS != "" || input.MessageTS != "1700.3" ||
		input.Text != "ordinary chatter" {
		t.Fatalf("top-level conversation = %+v, %v", input, err)
	}
}

func TestSocketAdmitsMentionOnlyOnce(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	text := "<@U999BOT> inspect current infrastructure health"

	payload, _ := json.Marshal(map[string]any{"event_id": "EvMessageMention"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U123ABC", Channel: "CWATCH", TimeStamp: "1700.10", Text: text,
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-message-mention", Payload: payload},
	})
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("message event containing app mention was admitted: %v", err)
	}

	payload, _ = json.Marshal(map[string]any{"event_id": "EvAppMention"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.AppMentionEvent{
				User: "U123ABC", Channel: "CWATCH", TimeStamp: "1700.10", Text: text,
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-app-mention", Payload: payload},
	})
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "mention" || input.EventID != "EvAppMention" ||
		input.Text != text {
		t.Fatalf("authoritative app mention = %+v, %v", input, err)
	}
	if socket.acks != 2 {
		t.Fatalf("acknowledgements = %d, want 2", socket.acks)
	}
}

func TestSocketAdmitsAtomicMemberJoinedEventForBotOnly(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{"event_id": "EvMemberJoined"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MemberJoinedChannelEvent{
				User: "U999BOT", Channel: "CJOINED", Inviter: "U123ABC",
				EventTimestamp: "1785574912.610529",
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-member-joined", Payload: payload},
	})
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "channel_joined" || input.UserID != "U123ABC" {
		t.Fatalf("member joined input = %+v, %v", input, err)
	}
}

func TestSlashCommandIsPersistedBeforeAcknowledgement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	request := &socketmode.Request{EnvelopeID: "env-slash", AcceptsResponsePayload: true}
	svc.admitSlashCommand(ctx, socketmode.Event{
		Type: socketmode.EventTypeSlashCommand,
		Data: slack.SlashCommand{
			TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", UserID: "U123ABC",
			Command: "/responder", Text: "proactive on",
		},
		Request: request,
	})
	if socket.acks != 1 {
		t.Fatalf("slash acknowledgement = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "slash" || input.ActionID != "/responder" ||
		input.Text != "proactive on" || input.ChannelID != "CWATCH" {
		t.Fatalf("persisted slash command = %+v, %v", input, err)
	}
}

func TestSlashFeedbackFailureKeepsCommandForDurableRetry(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{ephemeralErr: errors.New("Slack ephemeral delivery failed")}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	input := core.SlackInput{
		ID: "slash-feedback-retry", EnvelopeID: "env-slash-feedback-retry",
		EventID: "event-slash-feedback-retry", Kind: "slash",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", UserID: "U123ABC",
		Text: "proactive on", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit slash command = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "retry" {
		t.Fatalf("failed feedback was not retained for retry: %+v, %v", stored, err)
	}
	setting, err := st.GetSlackSetting(
		ctx,
		"channel",
		input.ChannelID,
		proactiveSettingName,
	)
	if err != nil || setting.Value != "on" {
		t.Fatalf("idempotent command mutation was not preserved: %+v, %v", setting, err)
	}
}

func TestSlashProactiveOverrides(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSTATIC"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	run := func(id, channel, text string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: channel,
			UserID: "U123ABC", Text: text, ActionID: "/responder",
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		stored, err := st.GetSlackInput(ctx, id)
		if err != nil || stored.State != "done" {
			t.Fatalf("stored %s = %+v, %v", id, stored, err)
		}
	}

	run("slash-global-on", "CCONTROL", "proactive global on")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || !enabled {
		t.Fatalf("global proactive on = %v, %v", enabled, err)
	}
	run("slash-channel-off", "COTHER", "proactive off")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || enabled {
		t.Fatalf("channel proactive off = %v, %v", enabled, err)
	}
	run("slash-status", "COTHER", "status")
	statusMessage := slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	if statusMessage.Header != "Responder is passive in this channel" ||
		!strings.Contains(strings.Join(statusMessage.Sections, "\n"), "ignores ordinary human and app messages") ||
		len(statusMessage.Fields) != 4 ||
		!strings.Contains(statusMessage.Fields[0].Value, "force passive behavior") ||
		!strings.Contains(statusMessage.Fields[1].Value, "proactive by default") ||
		strings.Contains(statusMessage.Text, "responder.yaml") ||
		strings.Contains(statusMessage.Text, "inherit") {
		t.Fatalf("slash status does not explain effective behavior = %+v", statusMessage)
	}
	run("slash-channel-inherit", "COTHER", "proactive inherit")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || !enabled {
		t.Fatalf("channel inherit = %v, %v", enabled, err)
	}
	run("slash-global-inherit", "CCONTROL", "proactive global inherit")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || enabled {
		t.Fatalf("global inherit non-configured channel = %v, %v", enabled, err)
	}
	if enabled, err := svc.proactiveEnabled(ctx, "CSTATIC"); err != nil || !enabled {
		t.Fatalf("global inherit configured channel = %v, %v", enabled, err)
	}
}

func TestSlashSettingsRejectUnauthorizedUsers(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slash-denied", EnvelopeID: "env-denied", EventID: "event-denied",
		Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: "UOTHER", Text: "proactive global on", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetSlackSetting(
		ctx, "global", "", proactiveSettingName,
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unauthorized global setting = %v", err)
	}
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "not listed in `slack.operators`") ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "administrator must add") {
		t.Fatalf("denial response = %+v", slackClient.ephemerals)
	}
}

func TestSlashHelpButtonsRouteToReadOnlyCommands(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	helpInput := core.SlackInput{
		ID: "slash-help", EnvelopeID: "env-slash-help", EventID: "event-slash-help",
		Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CCONTROL",
		UserID: "U123ABC", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, helpInput); err != nil || !created {
		t.Fatalf("admit help = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	help := slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	if help.Header != "Responder command guide" || len(help.Actions) != 3 ||
		help.Actions[0].ID != slackui.ActionCommandStatus ||
		help.Actions[1].ID != slackui.ActionCommandOpenIncidents ||
		help.Actions[2].ID != slackui.ActionCommandAllIncidents {
		t.Fatalf("interactive help = %+v", help)
	}
	helpContent := strings.Join(help.Sections, "\n")
	for _, command := range []string{
		"`/responder preferences`",
		"`/responder rules`",
	} {
		if !strings.Contains(helpContent, command) {
			t.Fatalf("interactive help lacks %s: %+v", command, help)
		}
	}
	actionIDs := make(map[string]bool)
	for _, action := range help.Actions {
		if actionIDs[action.ID] {
			t.Fatalf("interactive help repeats action ID %q: %+v", action.ID, help)
		}
		actionIDs[action.ID] = true
	}
	action := core.SlackInput{
		ID: "action-status", EnvelopeID: "env-action-status",
		EventID: "event-action-status", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: "CCONTROL", UserID: "U123ABC",
		ActionID: slackui.ActionCommandStatus, ActionValue: "status",
	}
	if created, err := st.AdmitSlackInput(ctx, action); err != nil || !created {
		t.Fatalf("admit action = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	status := slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	if status.Header != "Responder is passive in this channel" {
		t.Fatalf("help status action = %+v", status)
	}
}

func TestMalformedDeepCompletionIsCorrectedAndRetried(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 3
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{
		  "action":"reply",
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},
		  "message":"Application impact still needs investigation.",
		  "coverage":[
		    {"layer":"change","status":"healthy","detail":"revision is current"},
		    {"layer":"host","status":"healthy","detail":"hosts respond"},
		    {"layer":"runtime","status":"healthy","detail":"runtime responds"},
		    {"layer":"workload","status":"healthy","detail":"workloads run"},
		    {"layer":"dependency","status":"healthy","detail":"dependencies respond"},
		    {"layer":"application","status":"unknown","detail":"not queried"},
		    {"layer":"slo","status":"unknown","detail":"not queried"}
		  ],
		  "completion":{"status":"blocked","summary":"Impact is unknown.","material_gaps":["application and SLO impact"],"next_action":"Query application and SLO telemetry"}
		}`,
		`{
		  "action":"reply",
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},
		  "message":"Core infrastructure responds, but customer impact cannot be verified with the configured sources.",
		  "coverage":[
		    {"layer":"change","status":"healthy","detail":"revision is current"},
		    {"layer":"host","status":"healthy","detail":"hosts respond"},
		    {"layer":"runtime","status":"healthy","detail":"runtime responds"},
		    {"layer":"workload","status":"healthy","detail":"workloads run"},
		    {"layer":"dependency","status":"healthy","detail":"dependencies respond"},
		    {"layer":"application","status":"unknown","detail":"the application telemetry source denied access"},
		    {"layer":"slo","status":"unknown","detail":"the SLO telemetry source denied access"}
		  ],
		  "completion":{"status":"blocked","summary":"Customer impact cannot be verified because monitoring access is denied.","material_gaps":["application and SLO impact"],"blocker_kind":"access_denied","attempts":["Queried the configured application and SLO source; it returned permission denied"],"next_action":"Grant the monitoring identity read access, then retry"}
		}`,
	}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-completion-retry", EnvelopeID: "env-completion-retry",
		EventID: "EvCompletionRetry", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.710", UserID: "U123ABC",
		Text: "<@U999BOT> Give me a decision-ready production health assessment.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunPending || run.Failures != 1 ||
		!strings.Contains(run.LastError, "blocker_kind") {
		t.Fatalf("corrected run = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("invalid partial result reached Slack: %+v", slackClient.posts)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("retried run = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(strings.Join(slackClient.posts[0].message.Context, "\n"), "Blocked:") {
		t.Fatalf("retried Slack result = %+v", slackClient.posts)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[1], "blocker_kind") {
		t.Fatalf("correction prompt was not carried into retry: %v", coopClient.submitPrompts)
	}
}

// Terminal notices are reserved for accepted human requests. Retryable failures
// remain queued; terminal targeted work says what the operator can do next.

func TestStructuredCorrectionBudgetIsBounded(t *testing.T) {
	if terminalStructuredCorrection(1, 1, 20) ||
		terminalStructuredCorrection(19, 1, 20) ||
		!terminalStructuredCorrection(20, 1, 20) ||
		!terminalStructuredCorrection(1, 1, 1) {
		t.Fatal("structured correction budget does not honor the configured run attempts")
	}
}

func TestToolFailureBlockerOffersBoundedRepositoryFix(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	const taskPrompt = "Replace jq gsub and test usage in the hcp-terraform pack with regex-free core jq operations, preserve cleanup and plan-version validation, add regression coverage for jq without Oniguruma, then run the focused pack tests."
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		"operations":[
			{"id":"evidence-source","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"The HCP Terraform pack depends on optional jq regex support.","observation":"The shared filter uses gsub and plan-version validation uses test; both fail on jq builds without Oniguruma.","relation":"supports","health_effect":"none","source_type":"repository","source_id":"repo:hcp-terraform","source_name":"packs/hcp-terraform scripts","observed_at":"2026-08-04T12:00:00Z","freshness":"current checkout","confidence":"high","dimensions":{"repository":"repo","revision":"current"}}},
			{"id":"offer-fix","type":"offer_task","task":{"kind":"engineering","title":"Make the HCP Terraform pack portable across jq builds","repository":"repo","prompt":` + fmt.Sprintf("%q", taskPrompt) + `}},
			{"id":"complete","type":"complete_episode","completion":{"message":"The HCP inspection is blocked because this runner's jq lacks optional regex support. The source fix is bounded: replace the two regex-dependent expressions while preserving cleanup, output limits, and version checks.","completion":{"status":"blocked","summary":"HCP run details remain unavailable until the pack is portable.","material_gaps":["The failed Terraform resource and partial-apply state remain unavailable."],"blocker_kind":"tool_failure","attempts":["Ran tfc.run_details and tfc.run_diagnostics; both failed on unsupported jq regex functions."],"next_action":"Apply and validate the bounded pack compatibility fix, publish its immutable version, then rerun both inspections."}}}
		]
	}`
	if _, err := decisionpkg.ParseWatchDecision(coopClient.completeOnSubmit, testDecodeClock); err != nil {
		t.Fatalf("parse tool blocker decision: %v", err)
	}

	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-hcp-jq-fix", EnvelopeID: "env-hcp-jq-fix",
		EventID: "event-hcp-jq-fix", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1701.200", UserID: "U123ABC",
		Text: "<@U999BOT> Can you fix the HCP Terraform inspection blocker?",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("tool blocker offer posts = %+v", slackClient.posts)
	}
	offer := slackClient.posts[0].message
	content := offer.Text + "\n" + offer.Markdown + "\n" + strings.Join(offer.Sections, "\n")
	if strings.Contains(content, "Confirm the engineering task below") ||
		strings.Contains(content, "No engineering task has been created") ||
		!strings.Contains(content, "HCP inspection is blocked") ||
		!strings.Contains(content, "Make the HCP Terraform pack portable") {
		t.Fatalf("tool blocker offer content = %+v", offer)
	}
	if len(offer.Actions) != 1 || offer.Actions[0].ID != slackui.ActionStartTask ||
		offer.Actions[0].Label != "Prepare code fix" {
		t.Fatalf("tool blocker offer actions = %+v", offer.Actions)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || state.OfferedTaskPrompt != taskPrompt ||
		state.OfferedTaskRepository != "repo" {
		t.Fatalf("persisted tool blocker offer = %+v, %v", state, err)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("tool blocker task started before confirmation = %+v, %v", incidents, err)
	}
}

func TestCleanupDiscardsOnlyCleanOwnedSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "rotated watch state", false, time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf("clean session was not discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
}

func TestCleanupRetryUsesFreshPlanOperationAfterWorkspaceChanges(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.discardPlanErrors = []error{
		&coop.APIError{Status: 500, Code: "internal_error"},
		nil,
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	now := time.Now().UTC()
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "rotated watch state", false,
		now.Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, now); err == nil {
		t.Fatal("first transient plan failure was not returned")
	}
	if err := svc.processCleanup(ctx, now.Add(3*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.discardPlanKeys) != 2 ||
		coopClient.discardPlanKeys[0] == coopClient.discardPlanKeys[1] {
		t.Fatalf("cleanup plan operation keys = %v", coopClient.discardPlanKeys)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf("cleaned session was not reclaimed: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
}

func TestCleanupRetainsDirtySession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.discardPlan.OperationID = "op_dirty"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Dirty = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "closed task", false, time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 0 || coopClient.session.State != "closed" {
		t.Fatalf("dirty session was discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
}

func TestCleanupDiscardsCleanSessionWhoseBaseBranchAdvanced(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.session.BaseCommit = "abc123"
	coopClient.discardPlan.OperationID = "op_stale_base"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Head = "abc123"
	coopClient.discardPlan.Plan.Workspace.Unmerged = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "rotated watch state", false,
		time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf("clean stale-base session was not discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
	if !slices.Equal(coopClient.discardAccepts, []bool{false, true}) {
		t.Fatalf("discard plan acceptance = %v", coopClient.discardAccepts)
	}
}

func TestCleanupDiscardsUntouchedExistingPullRequestSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.session.BaseCommit = "merge-base"
	coopClient.session.PullRequest = &coop.PullRequestBinding{
		Number: 514, Ref: "refs/pull/514/head", HeadCommit: "admitted-pr-head",
	}
	coopClient.discardPlan.OperationID = "op_pr_baseline"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Head = "admitted-pr-head"
	coopClient.discardPlan.Plan.Workspace.Unmerged = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "cancelled PR task", false,
		time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf("untouched PR session was not discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
	if !slices.Equal(coopClient.discardAccepts, []bool{false, true}) {
		t.Fatalf("discard plan acceptance = %v", coopClient.discardAccepts)
	}
}

func TestCleanupBlocksCommitCreatedBetweenDiscardPlans(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.session.BaseCommit = "baseline"
	first := coop.DiscardPlan{OperationID: "op_first"}
	first.Plan.SessionID = coopClient.session.ID
	first.Plan.Revision = coopClient.session.Revision
	first.Plan.Workspace = coop.DiscardWorkspace{Head: "baseline", Unmerged: true}
	second := coop.DiscardPlan{OperationID: "op_second"}
	second.Plan.SessionID = coopClient.session.ID
	second.Plan.Revision = coopClient.session.Revision
	second.Plan.Workspace = coop.DiscardWorkspace{Head: "new-commit", Unmerged: true}
	coopClient.discardPlans = []coop.DiscardPlan{first, second}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "cancelled task", false,
		time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 0 {
		t.Fatal("workspace changed between plans but was discarded")
	}
	cleanup, err := st.GetCoopCleanup(ctx, coopClient.session.ID)
	if err != nil || cleanup.State != "blocked" ||
		!strings.Contains(cleanup.LastError, "changed while cleanup was being planned") {
		t.Fatalf("cleanup after between-plan commit = %+v, %v", cleanup, err)
	}
}

func TestOperationsHomeDoesNotExposeWorkToNonOperators(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	if err := svc.publishOperationsHome(ctx, "U_NOT_OPERATOR"); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.homes) != 1 {
		t.Fatalf("homes = %+v", slackClient.homes)
	}
	home := slackClient.homes[0].message
	rendered := strings.Join(home.Sections, "\n")
	if !strings.Contains(rendered, "dashboard access is restricted") ||
		strings.Contains(rendered, "Current work") {
		t.Fatalf("restricted home = %+v", home)
	}
}

type fakeEmisar struct {
	state emisar.RunState
	err   error
	calls int
}

func (f *fakeEmisar) WaitForRun(context.Context, string) (emisar.RunState, error) {
	f.calls++
	return f.state, f.err
}

func createBoundIncident(t *testing.T, ctx context.Context, st *store.Store) core.Incident {
	t.Helper()
	event := core.WebhookEvent{Signals: []core.Signal{{
		Route: "grafana", SourceID: "alert-bound", EventID: "event-bound",
		Repository: "repo", CorrelationKey: "bound", Status: core.SignalFiring,
		Title: "API unavailable", Severity: "critical",
		Summary:    "API requests are timing out.",
		SourceURL:  "https://grafana.example.test/alerting/1",
		ReceivedAt: time.Now().UTC(),
	}}}
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("create incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "inc-api"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	incident, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	return incident
}

func stageAgentRunWithMissingConversationSource(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
) core.AgentRun {
	t.Helper()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx,
		incident.ID,
		"ses_finalization",
		"incident-finalization",
		1,
	); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "slack", SourceID: "missing-slack-source",
		Repository: incident.Repository, Prompt: "investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue agent run = %+v, %v, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx,
		leased.ID,
		"ses_finalization",
		0,
		incident.Repository,
		0,
		leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx,
		leased.ID,
		"coop_turn_finalization",
		2,
		0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx,
		leased.ID,
		"completed",
		[]byte(`{"message":"Investigation complete.","evidence":[],"coverage":[]}`),
		"",
		0,
	); err != nil {
		t.Fatal(err)
	}
	return run
}

type fakeCoop struct {
	session            coop.Session
	turn               coop.Turn
	changes            coop.Changes
	events             []coop.Event
	createKeys         []string
	createPolicies     []string
	createTasks        []string
	createSources      []coop.SessionSource
	prepareKeys        []string
	prepareSessions    []string
	prepareErrors      []error
	listSessions       []coop.Session
	createErrors       []error
	createResultState  string
	openAfterCreateKey string
	submitKeys         []string
	submitPrompts      []string
	submitArtifacts    [][]coop.InputArtifact
	submitState        string
	completeOnSubmit   string
	completeQueue      []string
	submitTurns        []coop.Turn
	discardPlan        coop.DiscardPlan
	discardPlans       []coop.DiscardPlan
	discardPlanKeys    []string
	discardPlanErrors  []error
	discardCalls       int
	discardAccepts     []bool
	outputArtifacts    map[string]coop.OutputArtifact
	getSessionErr      error
	getSessionStarted  chan<- struct{}
	releaseGetSession  <-chan struct{}
	// completeUsage is what the provider reported for each completed turn.
	// Zero by default, which is what an ACP adapter that reports nothing
	// produces, so every existing test keeps describing an unmeasured turn.
	completeUsage coop.Usage
	// completeQueuedAt, if set, stamps the completed turn with the three times
	// Coop reports. Unset leaves them zero, which is an older Coop and an
	// unmeasurable turn, so existing tests keep describing exactly that.
	completeQueuedAt         time.Time
	completeQueuedFor        time.Duration
	completeProviderDuration time.Duration
}

func newFakeCoop() *fakeCoop {
	return &fakeCoop{session: coop.Session{
		ID: "ses_1", ForkName: "responder-api-unavailable",
		Revision: 1, State: "open", Activity: "parked", MaxTurns: 100,
	}}
}

func (f *fakeCoop) Ready(context.Context) error { return nil }
func (f *fakeCoop) CreateSession(
	_ context.Context,
	key, policy, task string,
	sources ...coop.SessionSource,
) (coop.Session, coop.Operation, error) {
	f.createKeys = append(f.createKeys, key)
	f.createPolicies = append(f.createPolicies, policy)
	f.createTasks = append(f.createTasks, task)
	if len(sources) > 0 {
		f.createSources = append(f.createSources, sources[0])
		if sources[0].PullRequestNumber > 0 {
			f.session.PullRequest = &coop.PullRequestBinding{
				Number:     sources[0].PullRequestNumber,
				Ref:        fmt.Sprintf("refs/pull/%d/head", sources[0].PullRequestNumber),
				HeadCommit: sources[0].HeadCommit,
			}
		}
	} else {
		f.createSources = append(f.createSources, coop.SessionSource{})
	}
	if len(f.createErrors) > 0 {
		err := f.createErrors[0]
		f.createErrors = f.createErrors[1:]
		if err != nil {
			return coop.Session{}, coop.Operation{}, err
		}
	}
	if f.session.State == "closed" {
		f.session.State = "open"
		f.session.Activity = "parked"
	}
	if key == f.openAfterCreateKey {
		f.session.ID = "ses_2"
		f.session.State = "open"
		f.session.Activity = "parked"
		f.session.Revision = 1
	}
	result := f.session
	if f.createResultState != "" {
		result.State = f.createResultState
	}
	return result, coop.Operation{}, nil
}

func (f *fakeCoop) ListSessions(context.Context, int) ([]coop.Session, error) {
	return append([]coop.Session(nil), f.listSessions...), nil
}
func (f *fakeCoop) GetSession(ctx context.Context, _ string) (coop.Session, error) {
	if f.getSessionStarted != nil {
		select {
		case f.getSessionStarted <- struct{}{}:
		default:
		}
	}
	if f.releaseGetSession != nil {
		select {
		case <-ctx.Done():
			return coop.Session{}, ctx.Err()
		case <-f.releaseGetSession:
		}
	}
	if f.getSessionErr != nil {
		return coop.Session{}, f.getSessionErr
	}
	return f.session, nil
}
func (f *fakeCoop) OperationByKey(_ context.Context, key string) (coop.Operation, error) {
	for index, submittedKey := range f.submitKeys {
		if submittedKey == key {
			turnID := fmt.Sprintf("coop_turn_%d", index+1)
			return coop.Operation{
				ID: "op_" + turnID, Method: "SubmitTurn", State: "succeeded",
				ResourceType: "turn", ResourceID: turnID,
			}, nil
		}
	}
	return coop.Operation{}, errors.New("operation not found")
}
func (f *fakeCoop) PrepareSession(_ context.Context, key, sessionID string, expectedRevision int64) (coop.Session, error) {
	f.prepareKeys = append(f.prepareKeys, key)
	f.prepareSessions = append(f.prepareSessions, sessionID)
	if len(f.prepareErrors) > 0 {
		err := f.prepareErrors[0]
		f.prepareErrors = f.prepareErrors[1:]
		if err != nil {
			return coop.Session{}, err
		}
	}
	if expectedRevision != f.session.Revision {
		return coop.Session{}, &coop.APIError{Status: 409, Code: "revision_conflict"}
	}
	return f.session, nil
}
func (f *fakeCoop) SubmitTurn(_ context.Context, key, _ string, _ int64, prompt string) (coop.Turn, coop.Operation, error) {
	return f.SubmitTurnWithArtifacts(
		context.Background(), key, "", 0, prompt, nil,
	)
}

func (f *fakeCoop) SubmitTurnWithArtifacts(
	_ context.Context,
	key string,
	_ string,
	_ int64,
	prompt string,
	artifacts []coop.InputArtifact,
) (coop.Turn, coop.Operation, error) {
	f.submitKeys = append(f.submitKeys, key)
	f.submitPrompts = append(f.submitPrompts, prompt)
	f.submitArtifacts = append(f.submitArtifacts, artifacts)
	state := f.submitState
	if state == "" {
		state = "running"
	}
	f.turn = coop.Turn{
		ID:        fmt.Sprintf("coop_turn_%d", len(f.submitKeys)),
		SessionID: f.session.ID,
		State:     state,
	}
	f.session.ActiveTurnID = f.turn.ID
	f.session.Revision++
	if len(f.submitTurns) > 0 {
		scripted := f.submitTurns[0]
		f.submitTurns = f.submitTurns[1:]
		if scripted.ID == "" {
			scripted.ID = f.turn.ID
		}
		if scripted.SessionID == "" {
			scripted.SessionID = f.session.ID
		}
		f.turn = scripted
		if scripted.State == "completed" || scripted.State == "failed" ||
			scripted.State == "cancelled" {
			f.session.ActiveTurnID = ""
			f.session.Activity = "parked"
		}
		return f.turn, coop.Operation{}, nil
	}
	if f.completeOnSubmit != "" {
		f.complete(f.completeOnSubmit)
	} else if len(f.completeQueue) > 0 {
		message := f.completeQueue[0]
		f.completeQueue = f.completeQueue[1:]
		f.complete(message)
	}
	return f.turn, coop.Operation{}, nil
}
func (f *fakeCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	if f.turn.ID == "" {
		return coop.Turn{}, errors.New("missing turn")
	}
	return f.turn, nil
}
func (f *fakeCoop) GetOutputArtifact(_ context.Context, _, _, artifactID string) (coop.OutputArtifact, error) {
	artifact, ok := f.outputArtifacts[artifactID]
	if !ok {
		return coop.OutputArtifact{}, errors.New("missing output artifact")
	}
	return artifact, nil
}
func (f *fakeCoop) Events(_ context.Context, _ string, after int64, _ int) ([]coop.Event, error) {
	var result []coop.Event
	for _, event := range f.events {
		if event.Sequence > after {
			result = append(result, event)
		}
	}
	return result, nil
}
func (f *fakeCoop) Changes(context.Context, string) (coop.Changes, error) {
	return f.changes, nil
}
func (f *fakeCoop) Review(context.Context, string, string, int64) (coop.Review, coop.Operation, error) {
	return coop.Review{}, coop.Operation{}, nil
}
func (f *fakeCoop) Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error) {
	return f.turn, coop.Operation{}, nil
}
func (f *fakeCoop) Extend(_ context.Context, _ string, _ string, _ int64, additional int) (coop.Session, coop.Operation, error) {
	f.session.MaxTurns += additional
	f.session.Revision++
	f.session.State = "open"
	f.session.Activity = "parked"
	return f.session, coop.Operation{}, nil
}
func (f *fakeCoop) Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error) {
	f.session.State = "closed"
	return f.session, coop.Operation{}, nil
}
func (f *fakeCoop) PlanDiscard(
	_ context.Context, key string, _ string, _ int64, _ bool, acceptUnmerged bool,
) (coop.DiscardPlan, coop.Operation, error) {
	f.discardPlanKeys = append(f.discardPlanKeys, key)
	f.discardAccepts = append(f.discardAccepts, acceptUnmerged)
	if len(f.discardPlanErrors) != 0 {
		err := f.discardPlanErrors[0]
		f.discardPlanErrors = f.discardPlanErrors[1:]
		if err != nil {
			return coop.DiscardPlan{}, coop.Operation{}, err
		}
	}
	if len(f.discardPlans) != 0 {
		plan := f.discardPlans[0]
		f.discardPlans = f.discardPlans[1:]
		plan.Plan.Workspace.AcceptedUnmerged = acceptUnmerged
		return plan, coop.Operation{}, nil
	}
	if f.discardPlan.OperationID != "" {
		plan := f.discardPlan
		plan.Plan.Workspace.AcceptedUnmerged = acceptUnmerged
		return plan, coop.Operation{}, nil
	}
	var plan coop.DiscardPlan
	plan.OperationID = "op_discard_plan"
	plan.Plan.SessionID = f.session.ID
	plan.Plan.Revision = f.session.Revision
	return plan, coop.Operation{}, nil
}
func (f *fakeCoop) Discard(
	context.Context, string, string, string,
) (coop.Session, coop.Operation, error) {
	f.discardCalls++
	f.session.State = "discarded"
	return f.session, coop.Operation{}, nil
}

func (f *fakeCoop) complete(message string) {
	f.turn.State = "completed"
	f.turn.AssistantMessage = message
	f.turn.Usage = f.completeUsage
	if !f.completeQueuedAt.IsZero() {
		f.turn.QueuedAt = f.completeQueuedAt
		f.turn.StartedAt = f.completeQueuedAt.Add(f.completeQueuedFor)
		f.turn.FinishedAt = f.turn.StartedAt.Add(f.completeProviderDuration)
	}
	f.session.ActiveTurnID = ""
	f.session.State = "open"
	f.session.Activity = "parked"
	f.session.Revision++
	sequence := int64(len(f.events) + 1)
	f.events = append(f.events, coop.Event{
		ID: fmt.Sprintf("evt_%d", sequence), SessionID: f.session.ID, Sequence: sequence,
		TurnID: f.turn.ID, Type: "turn.completed",
	})
}

type slackPost struct {
	outboxID  string
	channel   string
	thread    string
	broadcast bool
	message   slackui.Message
}

type slackUpdate struct {
	channel string
	ts      string
	message slackui.Message
}

type slackStatus struct {
	channel string
	thread  string
	text    string
}

type slackReaction struct {
	channel   string
	timestamp string
	name      string
}

type slackFileUpload struct {
	channel string
	thread  string
	upload  slackui.FileUpload
}

type slackHistoryRequest struct {
	channel string
	thread  string
	target  string
	since   string
	limit   int
}

type fakeSlack struct {
	posts              []slackPost
	ephemerals         []slackPost
	updates            []slackUpdate
	statuses           []slackStatus
	reactions          []slackReaction
	removedReactions   []slackReaction
	homes              []slackPost
	homeErr            error
	joined             []string
	joinErr            error
	postErr            error
	ephemeralErr       error
	inviteErr          error
	inviteByChannel    map[string]error
	statusErr          error
	updateErr          error
	updateCall         int
	channel            slackui.Channel
	channelErr         error
	dedupePosts        bool
	createChannelCalls int
	history            []slackui.HistoryMessage
	historyErr         error
	historyRequests    []slackHistoryRequest
	channels           []slackui.Channel
	listChannelsErr    error
	files              map[string][]byte
	fileInfo           map[string]slackui.HistoryFile
	fileInfoRequests   []string
	fileInfoErr        error
	downloadErr        error
	downloads          []string
	uploads            []slackFileUpload
	uploadErr          error
	deniedUsers        map[string]bool
}

type fakeSocket struct {
	events    chan socketmode.Event
	acks      int
	connected bool
}

func (f *fakeSocket) Events() <-chan socketmode.Event { return f.events }
func (f *fakeSocket) Ack(socketmode.Request) error {
	f.acks++
	return nil
}
func (f *fakeSocket) Run(context.Context) error { return nil }
func (f *fakeSocket) Connected() bool           { return f.connected }
func (f *fakeSocket) SetConnected(value bool)   { f.connected = value }

func (f *fakeSlack) Auth(context.Context) (slackui.Identity, error) {
	return slackui.Identity{TeamID: "T123ABC", BotUserID: "U999BOT"}, nil
}
func (f *fakeSlack) CreateChannel(_ context.Context, name string, _ bool, _ string) (slackui.Channel, error) {
	f.createChannelCalls++
	return slackui.Channel{ID: "CINCIDENT", Name: name, Creator: "U999BOT", Created: time.Now()}, nil
}
func (f *fakeSlack) FindChannelByName(context.Context, string, string) (slackui.Channel, error) {
	return slackui.Channel{}, slackui.ErrNotFound
}
func (f *fakeSlack) GetChannel(_ context.Context, channelID string) (slackui.Channel, error) {
	if f.channelErr != nil {
		return slackui.Channel{}, f.channelErr
	}
	// channels is the workspace as Slack sees it, so a test that describes a
	// channel there gets the same answer from every lookup.
	for _, channel := range f.channels {
		if channel.ID == channelID {
			return channel, nil
		}
	}
	if f.channel.ID != "" {
		return f.channel, nil
	}
	return slackui.Channel{ID: "CWATCH", Name: "watch", Member: true}, nil
}
func (f *fakeSlack) ListChannels(context.Context, string) ([]slackui.Channel, error) {
	return slices.Clone(f.channels), f.listChannelsErr
}
func (f *fakeSlack) Invite(_ context.Context, channel string, _ ...string) error {
	if err := f.inviteByChannel[channel]; err != nil {
		return err
	}
	return f.inviteErr
}
func (f *fakeSlack) SetTopic(context.Context, string, string) error { return nil }
func (f *fakeSlack) Post(_ context.Context, outboxID, channel, thread string, message slackui.Message) (string, error) {
	f.posts = append(f.posts, slackPost{
		outboxID: outboxID, channel: channel, thread: thread, message: message,
	})
	return "1700.00" + string(rune('1'+len(f.posts)-1)), f.postErr
}
func (f *fakeSlack) PostBroadcast(
	_ context.Context,
	outboxID string,
	channel string,
	thread string,
	message slackui.Message,
) (string, error) {
	f.posts = append(f.posts, slackPost{
		outboxID:  outboxID,
		channel:   channel,
		thread:    thread,
		broadcast: true,
		message:   message,
	})
	return "1700.00" + string(rune('1'+len(f.posts)-1)), f.postErr
}
func (f *fakeSlack) PostEphemeral(_ context.Context, channel, user string, message slackui.Message) error {
	f.ephemerals = append(f.ephemerals, slackPost{
		channel: channel, thread: user, message: message,
	})
	return f.ephemeralErr
}
func (f *fakeSlack) Update(_ context.Context, channel, ts string, message slackui.Message) error {
	f.updateCall++
	f.updates = append(f.updates, slackUpdate{channel: channel, ts: ts, message: message})
	return f.updateErr
}
func (f *fakeSlack) Pin(context.Context, string, string) error { return nil }
func (f *fakeSlack) React(
	_ context.Context,
	channel string,
	timestamp string,
	reaction string,
) error {
	f.reactions = append(f.reactions, slackReaction{
		channel: channel, timestamp: timestamp, name: reaction,
	})
	return nil
}
func (f *fakeSlack) Unreact(
	_ context.Context,
	channel string,
	timestamp string,
	reaction string,
) error {
	f.removedReactions = append(f.removedReactions, slackReaction{
		channel: channel, timestamp: timestamp, name: reaction,
	})
	return nil
}
func (f *fakeSlack) SetStatus(_ context.Context, channel, thread, text string) error {
	f.statuses = append(f.statuses, slackStatus{channel: channel, thread: thread, text: text})
	return f.statusErr
}
func (f *fakeSlack) SetProgress(
	_ context.Context,
	channel string,
	thread string,
	text string,
	_ []string,
) error {
	return f.SetStatus(context.Background(), channel, thread, text)
}
func (f *fakeSlack) PublishHome(
	_ context.Context,
	user string,
	message slackui.Message,
) error {
	f.homes = append(f.homes, slackPost{thread: user, message: message})
	return f.homeErr
}
func (f *fakeSlack) JoinChannel(_ context.Context, channelID string) error {
	f.joined = append(f.joined, channelID)
	return f.joinErr
}
func (f *fakeSlack) UserAllowed(_ context.Context, userID, _ string) (bool, error) {
	return !f.deniedUsers[userID], nil
}
func (f *fakeSlack) UserGroupMembers(context.Context, string, string) ([]string, error) {
	return []string{"UOPERATOR"}, nil
}
func (f *fakeSlack) GetFile(_ context.Context, fileID string) (slackui.HistoryFile, error) {
	f.fileInfoRequests = append(f.fileInfoRequests, fileID)
	if f.fileInfoErr != nil {
		return slackui.HistoryFile{}, f.fileInfoErr
	}
	file, ok := f.fileInfo[fileID]
	if !ok {
		return slackui.HistoryFile{}, errors.New("missing fake Slack file info")
	}
	return file, nil
}
func (f *fakeSlack) DownloadFile(_ context.Context, fileURL string, writer io.Writer) error {
	f.downloads = append(f.downloads, fileURL)
	if f.downloadErr != nil {
		return f.downloadErr
	}
	data, ok := f.files[fileURL]
	if !ok {
		return errors.New("missing fake Slack file")
	}
	_, err := writer.Write(data)
	return err
}
func (f *fakeSlack) UploadFile(
	_ context.Context, channel, thread string, upload slackui.FileUpload,
) (slackui.FileDeliveryResult, error) {
	f.uploads = append(f.uploads, slackFileUpload{channel: channel, thread: thread, upload: upload})
	if f.uploadErr != nil {
		return slackui.FileDeliveryResult{}, f.uploadErr
	}
	return slackui.FileDeliveryResult{
		FileID:    fmt.Sprintf("F%03d", len(f.uploads)),
		MessageTS: fmt.Sprintf("1700.%03d", len(f.uploads)),
	}, nil
}
func (f *fakeSlack) RecentMessages(
	_ context.Context,
	channel string,
	thread string,
	target string,
	since string,
	limit int,
) ([]slackui.HistoryMessage, error) {
	f.historyRequests = append(f.historyRequests, slackHistoryRequest{
		channel: channel, thread: thread, target: target, since: since, limit: limit,
	})
	return slices.Clone(f.history), f.historyErr
}
func (f *fakeSlack) FindDeliveryMessage(
	_ context.Context,
	channel string,
	thread string,
	outboxID string,
) (string, error) {
	if f.dedupePosts {
		for index, post := range f.posts {
			if post.outboxID == outboxID && post.channel == channel && post.thread == thread {
				return fmt.Sprintf("1700.%03d", index+1), nil
			}
		}
	}
	return "", slackui.ErrNotFound
}
func (f *fakeSlack) FindDeliveryFile(
	_ context.Context, channel, thread, filename string,
) (slackui.FileDeliveryResult, error) {
	for index, upload := range f.uploads {
		if upload.channel == channel && upload.thread == thread && upload.upload.Filename == filename {
			return slackui.FileDeliveryResult{
				FileID:    fmt.Sprintf("F%03d", index+1),
				MessageTS: fmt.Sprintf("1700.%03d", index+1),
			}, nil
		}
	}
	return slackui.FileDeliveryResult{}, slackui.ErrNotFound
}

func serviceConfig(t *testing.T) config.Config {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "responder.yaml")
	body := `version: 1
state_dir: ` + filepath.Join(root, "state") + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
  invite_users: [U123ABC]
  watch_settle_delay: 0s
coop: {}
limits:
  engineering_task_creation_cooldown: 0s
repositories:
  repo:
    display_name: Repository
    coop_policy: repo-observe
    contributor_policy: repo-contributor
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func finishQueuedAgentRun(
	t *testing.T,
	ctx context.Context,
	svc *Service,
) {
	t.Helper()
	if err := svc.processAgentRun(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("process queued agent run: %v", err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		t.Fatalf("finalize queued agent run: %v", err)
	}
	drainSlackDeliveries(t, ctx, svc)
}

func drainSlackDeliveries(
	t *testing.T,
	ctx context.Context,
	svc *Service,
) {
	t.Helper()
	for range 100 {
		err := svc.processSlackDelivery(ctx, nil)
		if errors.Is(err, store.ErrNotFound) {
			return
		}
		if err != nil {
			t.Fatalf("deliver queued Slack work: %v", err)
		}
	}
	t.Fatal("Slack delivery queue did not drain")
}

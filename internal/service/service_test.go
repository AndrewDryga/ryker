package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestAlertToSlackAndCompletedCoopTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	signal := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "signal-event-1",
		Repository: "repo", CorrelationKey: "prod-api", Status: core.SignalFiring,
		Title: "API is unavailable", Severity: "critical", ReceivedAt: time.Now().UTC(),
	}
	if _, _, err := st.AdmitWebhook(ctx, "grafana", "delivery-1", "digest", []core.Signal{signal}); err != nil {
		t.Fatal(err)
	}
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || incidents[0].RootTS == "" {
		t.Fatalf("root incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processTurn(ctx); err != nil {
		t.Fatal(err)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.CoopSessionID == "" || incident.ActiveTurnID == "" {
		t.Fatalf("Coop binding = %+v", incident)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "is investigating..." ||
		slack.statuses[0].thread != incident.RootTS {
		t.Fatalf("active turn status = %+v", slack.statuses)
	}

	coopClient.complete("Verified the alert. The API process is healthy; the load balancer target is stale.")
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	svc.lastPost = time.Time{}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 2 {
		t.Fatalf("Slack posts = %+v", slack.posts)
	}
	if slack.posts[0].thread != "" || slack.posts[1].thread != incident.RootTS {
		t.Fatalf("thread mapping = %+v", slack.posts)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.ActiveTurnID != "" || incident.Workflow != core.WorkflowParked {
		t.Fatalf("terminal workflow = %+v", incident)
	}
	if len(slack.statuses) != 1 {
		t.Fatalf("terminal turn posted a misleading status: %+v", slack.statuses)
	}
}

func TestMixedCapacityBatchDispatchesAcceptedIncidentUpdate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxOpenIncidents = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	existing := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "event-1",
		Repository: "repo", CorrelationKey: "existing", Status: core.SignalFiring,
		Title: "Existing incident", ReceivedAt: time.Now().UTC(),
	}
	incidents, err := st.ApplySignals(
		ctx, core.WebhookEvent{Signals: []core.Signal{existing}}, time.Hour, 0, 1,
	)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("existing incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "inc-existing"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	resolved := existing
	resolved.EventID = "event-resolved"
	resolved.Status = core.SignalResolved
	deferred := existing
	deferred.SourceID = "alert-2"
	deferred.EventID = "event-new"
	deferred.CorrelationKey = "new"
	if _, _, err := st.AdmitWebhook(
		ctx, "grafana", "delivery-mixed", "digest-mixed", []core.Signal{resolved, deferred},
	); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || dirty[0].ID != incidents[0].ID {
		t.Fatalf("accepted incident card was not refreshed: %+v, %v", dirty, err)
	}
	updated, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil || updated.Status != core.IncidentMonitoring || updated.FiringCount != 0 {
		t.Fatalf("accepted incident was not updated: %+v, %v", updated, err)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil || metrics.WebhooksPending != 1 {
		t.Fatalf("deferred webhook was not retained: %+v, %v", metrics, err)
	}
}

func TestRepeatedFiringRefreshUpdatesCardAndAgentWithoutRawThreadPost(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.MarkInitialTurnQueued(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	repeat := core.Signal{
		Route: "grafana", SourceID: "alert-bound", EventID: "event-refresh",
		Repository: "repo", CorrelationKey: "bound", Status: core.SignalFiring,
		Title: "API unavailable", Severity: "critical",
		Summary: "API requests are still timing out.", SourceURL: "https://grafana.example.test/alerting/1",
		ReceivedAt: time.Now().UTC(),
	}
	event, _, err := st.AdmitWebhook(ctx, "grafana", "delivery-refresh", "digest-refresh", []core.Signal{repeat})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseOutbox(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("routine firing refresh queued raw Slack output: %v", err)
	}
	submission, err := st.GetTurnSubmissionBySource(ctx, "webhook", event.ID+":"+incident.ID)
	if err != nil || !strings.Contains(submission.Prompt, "still timing out") {
		t.Fatalf("agent did not receive firing refresh: %+v, %v", submission, err)
	}
}

func TestCommandsRequireExactWholeMessage(t *testing.T) {
	for _, command := range []string{
		"!respond status", "!respond update", "!respond changes", "!respond review",
		"!respond stop", "!respond extend", "!respond close", "!respond help",
	} {
		if _, ok := exactCommand(command); !ok {
			t.Fatalf("command %q was not recognized", command)
		}
	}
	for _, prose := range []string{
		"please !respond stop", "!respond stop after the test", "maybe close this",
	} {
		if _, ok := exactCommand(prose); ok {
			t.Fatalf("prose %q executed as a control", prose)
		}
	}
}

func TestSummonQuestionRepliesWithoutCreatingIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-summon-question", EnvelopeID: "envelope-summon-question",
		EventID: "event-summon-question", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CSUMMON", MessageTS: "1700.000", UserID: "U123ABC",
		Text: "<@U999BOT> how is the health of our infrastructure?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","message":"I checked current infrastructure state and found no active alerts."}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "no active alerts") {
		t.Fatalf("summon reply = %+v", slackClient.posts)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("summon question created incident = %+v, %v", incidents, err)
	}
	if len(coopClient.submitPrompts) != 1 ||
		!strings.Contains(coopClient.submitPrompts[0], `"mentions_responder":true`) {
		t.Fatalf("summon question did not use watched triage: %+v", coopClient.submitPrompts)
	}
}

func TestManualSummonGetsCapacityRejectionInOriginThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	cfg.Limits.MaxOpenIncidents = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	event := core.WebhookEvent{Signals: []core.Signal{{
		Route: "grafana", SourceID: "alert-1", EventID: "event-1",
		Repository: "repo", CorrelationKey: "existing", Status: core.SignalFiring,
		Title: "Existing incident", ReceivedAt: time.Now().UTC(),
	}}}
	if _, err := st.ApplySignals(ctx, event, time.Hour, 0, 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-manual-1", EnvelopeID: "envelope-1", EventID: "event-manual-1",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CSUMMON",
		MessageTS: "1700.001", UserID: "U123ABC",
		Text: "<@U999BOT> open an incident for checkout",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 || slack.posts[0].channel != "CSUMMON" ||
		slack.posts[0].thread != input.MessageTS ||
		!strings.Contains(slack.posts[0].message.Text, "open incident limit") {
		t.Fatalf("capacity response = %+v", slack.posts)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("capacity input was not completed: %v", err)
	}
}

func TestManualSummonCompletesHandoffToIncidentRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-manual-ready", EnvelopeID: "envelope-ready", EventID: "event-manual-ready",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CSUMMON",
		MessageTS: "1700.001", UserID: "U123ABC",
		Text: "<@U999BOT> open an incident for checkout",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	for count := 0; count < 4; count++ {
		err := svc.processOutbox(ctx)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	var handoff *slackPost
	for index := range slack.posts {
		if slack.posts[index].message.Header == "Incident room ready" {
			handoff = &slack.posts[index]
		}
	}
	if handoff == nil || handoff.channel != "CSUMMON" || handoff.thread != input.MessageTS ||
		!strings.Contains(handoff.message.Text, "<#CINCIDENT>") {
		t.Fatalf("manual handoff = %+v", slack.posts)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("manual incident = %+v, %v", incidents, err)
	}
	if err := svc.enqueueManualHandoff(ctx, incidents[0]); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("manual handoff was not idempotent: %v", err)
	}
}

func TestManualHandoffWaitsForUsableIncidentRoom(t *testing.T) {
	tests := []struct {
		name       string
		rootErr    error
		inviteErr  error
		wantRootTS bool
	}{
		{name: "root delivery uncertain", rootErr: errors.New("Slack timeout")},
		{name: "responder invite fails", inviteErr: errors.New("invite denied"), wantRootTS: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			incident, created, err := st.CreateManualIncident(
				ctx, "repo", "manual-source", "Investigate checkout", "Investigate checkout", "U123ABC",
				"CSUMMON", "1700.001", cfg.Limits.MaxOpenIncidents,
			)
			if err != nil || !created {
				t.Fatalf("manual incident = %+v, %v, %v", incident, created, err)
			}
			slack := &fakeSlack{postErr: test.rootErr, inviteErr: test.inviteErr}
			svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
			if err := svc.processChannel(ctx); err != nil {
				t.Fatal(err)
			}
			if err := svc.processOutbox(ctx); err != nil {
				t.Fatal(err)
			}
			if err := svc.processSession(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
				t.Fatal(err)
			}
			for _, post := range slack.posts {
				if post.message.Header == "Incident room ready" {
					t.Fatalf("handoff announced unusable room: %+v", slack.posts)
				}
			}
			incident, err = st.GetIncident(ctx, incident.ID)
			if err != nil || (incident.RootTS != "") != test.wantRootTS {
				t.Fatalf("root binding = %+v, %v", incident, err)
			}
			if _, err := st.LeaseOutbox(ctx); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("handoff was queued before room preparation: %v", err)
			}
		})
	}
}

func TestSlackWritesAlternateBetweenDirtyCardAndOutbox(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.enqueue(
		ctx, "out_fairness", incident, "notice", incident.RootTS, slackui.Notice("Queued reply"),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.updates) != 1 || len(slack.posts) != 0 {
		t.Fatalf("card was not given first write slot: updates=%d posts=%d", len(slack.updates), len(slack.posts))
	}
	rendered := slack.updates[0].message
	if len(rendered.Sections) < 2 ||
		!strings.Contains(rendered.Sections[1], "API requests are timing out") ||
		!slices.Contains(rendered.Context, "Alert source: <https://grafana.example.test/alerting/1|Open grafana.example.test>") {
		t.Fatalf("updated card omitted current signal evidence: %+v", rendered)
	}
	svc.lastPost = time.Time{}
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.updates) != 1 || len(slack.posts) != 1 {
		t.Fatalf("outbox was not given second write slot: updates=%d posts=%d", len(slack.updates), len(slack.posts))
	}
}

func TestDirtyCardBacksOffAfterTransientSlackFailure(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slack := &fakeSlack{updateErr: errors.New("Slack unavailable")}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processCard(ctx); err == nil {
		t.Fatal("card update failure was ignored")
	}
	if err := svc.processCard(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("card retry did not back off: %v", err)
	}
	if slack.updateCall != 1 {
		t.Fatalf("card retried without backoff: %d calls", slack.updateCall)
	}
	state := svc.retries["card:"+incident.ID]
	state.at = time.Time{}
	svc.retries["card:"+incident.ID] = state
	slack.updateErr = nil
	if err := svc.processCard(ctx); err != nil {
		t.Fatal(err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 0 || slack.updateCall != 2 {
		t.Fatalf("card did not recover: dirty=%+v calls=%d err=%v", dirty, slack.updateCall, err)
	}
}

func TestAcceptedOperatorReplySetsAndRefreshesNativeStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	input := core.SlackInput{
		ID: "slack-reply-1", EnvelopeID: "envelope-reply-1", EventID: "event-reply-1",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		ThreadTS: incident.RootTS, MessageTS: "1700.002", UserID: "U123ABC",
		Text: "Check whether the last deploy changed this.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack reply = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "is investigating your message..." {
		t.Fatalf("accepted reply status = %+v", slack.statuses)
	}
	svc.setNativeStatus(ctx, incident, "is investigating your message...")
	if len(slack.statuses) != 1 {
		t.Fatalf("status refreshed too early: %+v", slack.statuses)
	}
	statusKey := incident.ID + "@" + incident.ConversationThreadTS()
	status := svc.nativeStatus[statusKey]
	status.at = time.Now().Add(-76 * time.Second)
	svc.nativeStatus[statusKey] = status
	svc.setNativeStatus(ctx, incident, "is investigating your message...")
	if len(slack.statuses) != 2 {
		t.Fatalf("long-running status was not refreshed: %+v", slack.statuses)
	}
	if err := svc.enqueue(
		ctx, "out_status_reset", incident, "notice", incident.RootTS, slackui.Notice("Done"),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok := svc.nativeStatus[statusKey]; ok {
		t.Fatal("thread reply did not clear the local native-status cache")
	}
}

func TestIncidentSubthreadKeepsProgressOnTheSourceConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-subthread-reply", EnvelopeID: "envelope-subthread-reply",
		EventID: "event-subthread-reply", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, ThreadTS: "1700.777", MessageTS: "1700.778",
		UserID: "U123ABC", Text: "<@U999BOT> Check this follow-up in depth.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack subthread reply = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID:    cfg.Slack.TeamID,
		BotUserID: "U999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].thread != input.ThreadTS ||
		slack.statuses[0].text != "is investigating your message..." {
		t.Fatalf("accepted subthread status = %+v", slack.statuses)
	}
	if err := svc.processTurn(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.statuses) != 2 || slack.statuses[1].thread != input.ThreadTS ||
		slack.statuses[1].text != "is investigating..." {
		t.Fatalf("running subthread status = %+v", slack.statuses)
	}
}

func TestIncidentConversationAcceptsMessagesWithoutMentions(t *testing.T) {
	tests := []struct {
		name       string
		kind       string
		threadTS   string
		text       string
		wantPolicy string
		wantText   string
	}{
		{
			name: "pinned card reply", kind: "message", threadTS: "1700.001",
			text: "What should we do next?", wantPolicy: "directly addresses",
			wantText: "What should we do next?",
		},
		{
			name: "top level without mention", kind: "message",
			text: "The deploy finished; anything else?", wantPolicy: "ambient room conversation",
			wantText: "The deploy finished; anything else?",
		},
		{
			name: "top level mention", kind: "mention",
			text: "<@U999BOT> Are you following this?", wantPolicy: "directly addresses",
			wantText: "Are you following this?",
		},
		{
			name: "another conversation thread", kind: "message", threadTS: "1700.900",
			text: "I think the database is healthy.", wantPolicy: "ambient room conversation",
			wantText: "I think the database is healthy.",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			incident := createBoundIncident(t, ctx, st)
			if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
				t.Fatal(err)
			}
			input := core.SlackInput{
				ID: "slack-conversation", EnvelopeID: "envelope-conversation",
				EventID: "event-conversation", Kind: test.kind, TeamID: cfg.Slack.TeamID,
				ChannelID: incident.ChannelID, ThreadTS: test.threadTS, MessageTS: "1700.901",
				UserID: "U123ABC", Text: test.text,
			}
			if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
				t.Fatalf("admit conversation = %v, %v", created, err)
			}
			svc := New(
				cfg, st, newFakeCoop(), &fakeSlack{}, nil,
				slackui.NewSanitizer(12000), nil,
			)
			svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			submission, err := st.GetTurnSubmissionBySource(ctx, "slack", input.ID)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(submission.Prompt, test.wantPolicy) ||
				!strings.Contains(submission.Prompt, test.wantText) ||
				strings.Contains(submission.Prompt, "<@U999BOT>") {
				t.Fatalf("conversation prompt = %q", submission.Prompt)
			}
		})
	}
}

func TestConversationReplyReturnsToOriginWithoutIncidentChrome(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-top-level", EnvelopeID: "envelope-top-level", EventID: "event-top-level",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		MessageTS: "1700.500", UserID: "U123ABC", Text: "What's next?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit top-level message = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processTurn(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient.complete("The inspection is complete. Close the incident unless another gate should run.")
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 || slack.posts[0].thread != input.MessageTS ||
		slack.posts[0].message.Header != "" || len(slack.posts[0].message.Context) != 0 ||
		!strings.Contains(slack.posts[0].message.Text, "inspection is complete") {
		t.Fatalf("conversation reply = %+v", slack.posts)
	}
}

func TestAmbientConversationMayCompleteWithoutSlackReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-ambient", EnvelopeID: "envelope-ambient", EventID: "event-ambient",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		MessageTS: "1700.600", UserID: "U123ABC", Text: "Lunch arrived.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit ambient message = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processTurn(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(noConversationReply)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("silent conversation created outbox work: %v", err)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("silent conversation posted: %+v", slack.posts)
	}
}

func TestNativeStatusRetriesAfterTransientSlackFailure(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slack := &fakeSlack{statusErr: errors.New("Slack unavailable")}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.setNativeStatus(ctx, incident, "is investigating...")
	statusKey := incident.ID + "@" + incident.ConversationThreadTS()
	if _, ok := svc.nativeStatus[statusKey]; ok {
		t.Fatal("failed native status was cached as delivered")
	}
	if err := svc.enqueue(
		ctx, "out_failed_status_reset", incident, "notice", incident.RootTS, slackui.Notice("Request finished"),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	slack.statusErr = nil
	svc.setNativeStatus(ctx, incident, "is investigating...")
	if len(slack.statuses) != 2 || svc.nativeStatus[statusKey].text != "is investigating..." {
		t.Fatalf("native status did not recover: %+v", slack.statuses)
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

func TestDeletedChannelEventBlocksIncidentAndSuppressesSlackDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetSlackSetting(
		ctx,
		"channel",
		incident.ChannelID,
		"proactive",
		"on",
		"U123ABC",
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)
	payload, _ := json.Marshal(map[string]any{"event_id": "EvDeleted"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.ChannelDeletedEvent{
					Type: "channel_deleted", Channel: incident.ChannelID,
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-deleted", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("deletion event acknowledgements = %d", socket.acks)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelDeleted ||
		incident.Workflow != core.WorkflowBlocked ||
		!strings.Contains(incident.LastError, "room was deleted") {
		t.Fatalf("deleted incident = %+v", incident)
	}
	if _, err := st.GetSlackSetting(
		ctx,
		"channel",
		incident.ChannelID,
		"proactive",
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("deleted channel retained its Slack override: %v", err)
	}
	if err := svc.enqueue(
		ctx, "out-after-delete", incident, "notice", incident.RootTS,
		slackui.Notice("This must not be posted."),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("deleted room received posts: %+v", slackClient.posts)
	}
	failures, err := st.ListFailedWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	var suppressed bool
	for _, failure := range failures {
		if failure.ID == "out-after-delete" &&
			strings.Contains(failure.LastError, "delivery suppressed") {
			suppressed = true
		}
	}
	if !suppressed {
		t.Fatalf("suppressed delivery was not retained as failed work: %+v", failures)
	}
}

func TestIncidentChannelReconciliationDistinguishesArchiveAndUnreachable(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{
		channel: slackui.Channel{ID: incident.ChannelID, Name: incident.ChannelName, Archived: true},
	}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelArchived {
		t.Fatalf("archived reconciliation = %+v, %v", incident, err)
	}
	slackClient.channel.Archived = false
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelActive {
		t.Fatalf("active reconciliation = %+v, %v", incident, err)
	}
	slackClient.channel = slackui.Channel{}
	slackClient.channelErr = slackui.ErrNotFound
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelUnreachable ||
		incident.ChannelState == core.ChannelDeleted {
		t.Fatalf("unreachable reconciliation = %+v, %v", incident, err)
	}
}

func TestSocketAdmitsExternalAppsOnlyInWatchChannels(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	admitBotMessage := func(envelope, eventID, channel, botID string) {
		t.Helper()
		payload, _ := json.Marshal(map[string]any{"event_id": eventID})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID: cfg.Slack.TeamID,
				InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
					SubType: "bot_message", BotID: botID, Channel: channel,
					TimeStamp: "1700.4", Text: "alert notification",
				}},
			},
			Request: &socketmode.Request{EnvelopeID: envelope, Payload: payload},
		})
	}

	admitBotMessage("env-watch", "EvWatch", "CWATCH", "BEXTERNAL")
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "bot_message" || input.UserID != "BEXTERNAL" ||
		input.ChannelID != "CWATCH" {
		t.Fatalf("watched app message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}

	if err := st.SetSlackSetting(ctx, "global", "", proactiveSettingName, "on", "U123ABC"); err != nil {
		t.Fatal(err)
	}
	admitBotMessage("env-global", "EvGlobal", "CDYNAMIC", "BEXTERNAL")
	input, err = st.LeaseSlackInput(ctx)
	if err != nil || input.ChannelID != "CDYNAMIC" {
		t.Fatalf("globally watched app message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetSlackSetting(ctx, "global", "", proactiveSettingName, "off", "U123ABC"); err != nil {
		t.Fatal(err)
	}
	admitBotMessage("env-global-off", "EvGlobalOff", "CWATCH", "BEXTERNAL")
	admitBotMessage("env-other", "EvOther", "COTHER", "BEXTERNAL")
	admitBotMessage("env-self", "EvSelf", "CWATCH", "B999BOT")
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unwatched or self-authored app message was persisted: %v", err)
	}
	if socket.acks != 5 {
		t.Fatalf("acks = %d", socket.acks)
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

func TestSlashTurnLimitOverrides(t *testing.T) {
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
	if _, err := svc.turnLimitStatus(ctx, "COTHER"); err != nil {
		t.Fatalf("initial turn-limit status: %v", err)
	}
	run := func(id, channel, text string) slackui.Message {
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
		if len(slackClient.ephemerals) == 0 {
			stored, storedErr := st.GetSlackInput(ctx, id)
			t.Fatalf("process %s produced no response: input=%+v, error=%v", id, stored, storedErr)
		}
		return slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	}

	status := run("turn-status-default", "COTHER", "turn-limit")
	if !strings.Contains(status.Text, "up to 1000 agent requests") ||
		!strings.Contains(strings.Join(status.Sections, "\n"), "Operators do not choose") {
		t.Fatalf("default turn-limit status = %+v", status)
	}
	run("turn-global", "CCONTROL", "turn-limit global 2000")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 2000 {
		t.Fatalf("workspace turn limit = %d, %v", got, err)
	}
	run("turn-channel", "COTHER", "turn-limit 1500")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 1500 {
		t.Fatalf("channel turn limit = %d, %v", got, err)
	}
	run("turn-channel-inherit", "COTHER", "turn-limit inherit")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 2000 {
		t.Fatalf("inherited turn limit = %d, %v", got, err)
	}
	invalid := run("turn-invalid", "COTHER", "turn-limit 99")
	if !strings.Contains(invalid.Text, "between `100` and `10000`") {
		t.Fatalf("invalid turn-limit guidance = %+v", invalid)
	}
}

func TestRaisingTurnLimitResumesPreservedIncidentWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.TurnLimit = 100
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 3); err != nil {
		t.Fatal(err)
	}
	if err := st.SetIncidentError(
		ctx, incident.ID, core.WorkflowBlocked, turnLimitReachedMessage(100),
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "raise-preserved-work", EnvelopeID: "env-raise-preserved-work",
		EventID: "event-raise-preserved-work", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, UserID: "U123ABC", Text: "turn-limit 200",
		ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.Workflow != core.WorkflowParked || incident.LastError != "" {
		t.Fatalf("resumed incident = %+v, %v", incident, err)
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

func TestSlashStatusExplainsIncidentRoomBehavior(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slash-incident-status", EnvelopeID: "env-incident-status",
		EventID: "event-incident-status", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, UserID: "U123ABC", Text: "status",
		ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("ephemeral status count = %d", len(slackClient.ephemerals))
	}
	message := slackClient.ephemerals[0].message
	sections := strings.Join(message.Sections, "\n")
	for _, required := range []string{
		"Incident collaboration remains active regardless of proactive triage",
		"without an `@mention`",
		"Attached incident `" + slackui.ShortID(incident.ID) + "`",
		"Reply normally anywhere in this incident channel",
	} {
		if !strings.Contains(sections, required) {
			t.Fatalf("incident status lacks %q: %+v", required, message)
		}
	}
	for _, internal := range []string{"parked", "provisioning_channel", "responder.yaml"} {
		if strings.Contains(message.Text+"\n"+sections, internal) {
			t.Fatalf("incident status exposes internal label %q: %+v", internal, message)
		}
	}
}

func TestSlashIncidentDirectoryLinksChannelsAndIncludesClosedHistory(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetIncidentChannelState(
		ctx, incident.ChannelID, core.ChannelDeleted, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	run := func(id, text string) slackui.Message {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CCONTROL",
			UserID: "U123ABC", Text: text, ActionID: "/responder",
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		return slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	}
	open := run("slash-open-incidents", "incidents")
	if open.Header != "No open incidents" ||
		!strings.Contains(strings.Join(open.Sections, "\n"), "`/responder incidents all`") {
		t.Fatalf("open incident directory = %+v", open)
	}
	all := run("slash-all-incidents", "incidents all")
	content := all.Text + "\n" + strings.Join(all.Sections, "\n")
	for _, required := range []string{
		"All incidents (1)",
		slackui.ShortID(incident.ID),
		"API unavailable",
		"#inc-api (Slack room deleted)",
		"Closed",
		"1 alert firing",
	} {
		if !strings.Contains(all.Header+"\n"+content, required) {
			t.Fatalf("all incident directory lacks %q: %+v", required, all)
		}
	}
	if strings.Contains(content, "slack.com/app_redirect") {
		t.Fatalf("incident directory uses a redirect instead of a channel mention: %+v", all)
	}
	if strings.Contains(content, "<#CINCIDENT>") {
		t.Fatalf("deleted incident directory contains a broken channel mention: %+v", all)
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

func TestClosedIncidentControlsResolveByIDAndHideWithoutChanges(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-read-only", 1,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processCard(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.updates) != 1 ||
		len(slackClient.updates[0].message.Actions) != 0 {
		t.Fatalf("unchanged closed card controls = %+v", slackClient.updates)
	}
	runAction := func(id, actionID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
			MessageTS: incident.RootTS, UserID: "U123ABC",
			ActionID: actionID, ActionValue: incident.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		if err := svc.processOutbox(ctx); err != nil {
			t.Fatalf("deliver %s: %v", id, err)
		}
	}
	runAction("closed-changes", slackui.ActionChanges)
	if got := slackClient.posts[len(slackClient.posts)-1].message; !strings.Contains(
		got.Text+"\n"+strings.Join(got.Sections, "\n"),
		"no changes",
	) {
		t.Fatalf("closed changes response = %+v", got)
	}
	runAction("closed-review", slackui.ActionReview)
	if got := slackClient.posts[len(slackClient.posts)-1].message; !strings.Contains(
		got.Text+"\n"+strings.Join(got.Sections, "\n"),
		"no proposed code change",
	) {
		t.Fatalf("closed review response = %+v", got)
	}
}

func TestSlashProactiveOffPreemptsQueuedChannelMessage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	message := core.SlackInput{
		ID: "slack-before-off", EnvelopeID: "env-before-off", EventID: "event-before-off",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.700", UserID: "U123ABC", Text: "Please investigate this alert.",
	}
	command := core.SlackInput{
		ID: "slash-off", EnvelopeID: "env-slash-off", EventID: "event-slash-off",
		Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: "U123ABC", Text: "proactive off", ActionID: "/responder",
	}
	for _, input := range []core.SlackInput{message, command} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	commandState, err := st.GetSlackInput(ctx, command.ID)
	if err != nil || commandState.State != "done" {
		t.Fatalf("priority command = %+v, %v", commandState, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	messageState, err := st.GetSlackInput(ctx, message.ID)
	if err != nil || messageState.State != "done" {
		t.Fatalf("suppressed message = %+v, %v", messageState, err)
	}
	if len(coopClient.createKeys) != 0 || len(coopClient.submitKeys) != 0 {
		t.Fatalf("disabled message reached Coop: create=%v submit=%v",
			coopClient.createKeys, coopClient.submitKeys)
	}
}

func TestWatchedChannelDecisions(t *testing.T) {
	tests := []struct {
		name          string
		kind          string
		text          string
		decision      string
		wantState     string
		wantPosts     int
		wantIncidents int
		wantOffer     bool
	}{
		{
			name: "ignore", kind: "bot_message",
			decision: `{"action":"ignore"}`, wantState: "done",
		},
		{
			name: "reply", kind: "message",
			decision:  `{"action":"reply","message":"The deploy recovered; no action is needed."}`,
			wantState: "done", wantPosts: 1,
		},
		{
			name: "incident", kind: "bot_message",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantIncidents: 1,
		},
		{
			name: "human incident decision requires confirmation", kind: "message",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantOffer: true,
		},
		{
			name: "explicit human incident request", kind: "message",
			text:      "Please open an incident for the checkout HTTP 500 errors.",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantIncidents: 1,
		},
		{
			name: "malformed", kind: "bot_message", decision: `I would ignore this.`,
			wantState: "failed", wantPosts: 1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			cfg.Slack.WatchChannels = []string{"CWATCH"}
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			slack := &fakeSlack{}
			coopClient := newFakeCoop()
			coopClient.completeOnSubmit = test.decision
			svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
			svc.identity = slackui.Identity{
				TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
			}
			input := core.SlackInput{
				ID: "slack-watch-1", EnvelopeID: "env-watch-1", EventID: "EvWatch1",
				Kind: test.kind, TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
				MessageTS: "1700.500", UserID: "U123ABC",
				Text: "Checkout is returning HTTP 500 responses.",
			}
			if test.kind == "bot_message" {
				input.UserID = "BEXTERNAL"
			}
			if test.text != "" {
				input.Text = test.text
			}
			if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
				t.Fatalf("admit = %v, %v", created, err)
			}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			stored, err := st.GetSlackInput(ctx, input.ID)
			if err != nil || stored.State != test.wantState {
				t.Fatalf("stored input = %+v, %v", stored, err)
			}
			if len(slack.posts) != test.wantPosts {
				t.Fatalf("posts = %+v", slack.posts)
			}
			if len(slack.statuses) != 0 {
				t.Fatalf("ambient triage exposed a thread status: %+v", slack.statuses)
			}
			if test.name == "reply" {
				if slack.posts[0].thread != input.MessageTS ||
					!strings.Contains(slack.posts[0].message.Text, "deploy recovered") {
					t.Fatalf("threaded watch reply = %+v", slack.posts[0])
				}
			}
			if test.name == "malformed" {
				if slack.posts[0].thread != input.MessageTS ||
					!strings.Contains(slack.posts[0].message.Text, "could not complete this check") ||
					!strings.Contains(slack.posts[0].message.Text, "No incident was created") {
					t.Fatalf("watched failure reply = %+v", slack.posts[0])
				}
			}
			if test.wantOffer {
				message := slack.posts[0].message
				if len(message.Actions) != 1 ||
					message.Actions[0].ID != slackui.ActionOpenIncident ||
					message.Actions[0].Value != input.ID ||
					!strings.Contains(message.Text, "have not opened an incident") {
					t.Fatalf("human incident confirmation = %+v", message)
				}
				state, err := decodeWatchState(stored.Frozen)
				if err != nil || state.OfferedIncidentTitle != "Checkout error rate is elevated" {
					t.Fatalf("persisted incident offer = %+v, %v", state, err)
				}
			}
			incidents, err := st.ListIncidents(ctx, 10)
			if err != nil || len(incidents) != test.wantIncidents {
				t.Fatalf("incidents = %+v, %v", incidents, err)
			}
			if test.name == "incident" {
				signals, err := st.ListSignals(ctx, incidents[0].ID)
				if err != nil || len(signals) != 1 ||
					signals[0].Summary != input.Text ||
					signals[0].Labels["slack_origin_channel"] != input.ChannelID {
					t.Fatalf("watch incident signal = %+v, %v", signals, err)
				}
			}
			if len(coopClient.createKeys) != 1 ||
				coopClient.createKeys[0] != "responder:watch-session:CWATCH" ||
				len(coopClient.submitPrompts) != 1 ||
				!strings.Contains(coopClient.submitPrompts[0], "<untrusted-slack-context>") ||
				!strings.Contains(coopClient.submitPrompts[0], "recent_channel_messages") ||
				!strings.Contains(coopClient.submitPrompts[0], "declared intent and expected topology") ||
				!strings.Contains(coopClient.submitPrompts[0], "other available MCP servers and tools") ||
				!strings.Contains(coopClient.submitPrompts[0], "runner identities and connection state") ||
				!strings.Contains(coopClient.submitPrompts[0], "not by itself permission") ||
				!strings.Contains(coopClient.submitPrompts[0], "operator confirmation button") {
				t.Fatalf("watch Coop calls = keys=%v prompts=%v",
					coopClient.createKeys, coopClient.submitPrompts)
			}
		})
	}
}

func TestWatchedFailureKeepsPendingStatusUntilNoticeIsPosted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{postErr: errors.New("Slack is unavailable")}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `not a watch decision`
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-watch-failure", EnvelopeID: "env-watch-failure",
		EventID: "EvWatchFailure", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.700", UserID: "U123ABC",
		Text: "How is production health?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "retry" {
		t.Fatalf("stored input = %+v", stored)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "could not complete this check") {
		t.Fatalf("failure notice attempt = %+v", slack.posts)
	}
	if len(slack.statuses) != 0 {
		t.Fatalf("ambient failure exposed a thread status: %+v", slack.statuses)
	}
}

func TestWatchedIncidentOfferRequiresOperatorAndCreatesOnce(t *testing.T) {
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
	coopClient.completeOnSubmit = `{"action":"reply","message":"Two production runners are disconnected.","incident_title":"Two production runners disconnected"}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-health-question", EnvelopeID: "env-health-question",
		EventID: "event-health-question", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.800", UserID: "U123ABC",
		Text: "How is the health of our infrastructure?",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		len(slackClient.posts[0].message.Actions) != 1 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionOpenIncident {
		t.Fatalf("incident offer = %+v", slackClient.posts)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("question created incident before approval = %+v, %v", incidents, err)
	}

	click := func(id, userID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
			ThreadTS: source.MessageTS, MessageTS: "1700.801", UserID: userID,
			ActionID: slackui.ActionOpenIncident, ActionValue: source.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
	}
	click("incident-offer-unauthorized", "UOTHER")
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "Only a configured incident operator") {
		t.Fatalf("unauthorized offer response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("unauthorized click created incident = %+v, %v", incidents, err)
	}

	click("incident-offer-authorized", "U123ABC")
	click("incident-offer-repeated", "U123ABC")
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("authorized offer incidents = %+v, %v", incidents, err)
	}
	if len(slackClient.posts) != 2 ||
		slackClient.posts[1].thread != source.MessageTS ||
		!strings.Contains(slackClient.posts[1].message.Text, "opening a dedicated incident room") {
		t.Fatalf("incident creation acknowledgement = %+v", slackClient.posts)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Summary != source.Text ||
		signals[0].Labels["slack_origin_channel"] != source.ChannelID {
		t.Fatalf("approved offer evidence = %+v, %v", signals, err)
	}
}

func TestWatchedEngineeringRequestStaysInSourceThread(t *testing.T) {
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
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"message":"I can audit and update infra/ in a dedicated isolated working copy.",
		"task_title":"Audit infrastructure packs"
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-engineering-request", EnvelopeID: "env-engineering-request",
		EventID: "event-engineering-request", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.900", UserID: "U123ABC",
		Text: "Change infra/ to install every pack our production topology needs.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		len(slackClient.posts[0].message.Actions) != 1 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionStartTask ||
		slackClient.posts[0].message.Actions[0].Value != source.ID {
		t.Fatalf("engineering task offer = %+v", slackClient.posts)
	}
	stored, err := st.GetSlackInput(ctx, source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchState(stored.Frozen)
	if err != nil ||
		state.OfferedTaskTitle != "Audit infrastructure packs" ||
		state.OfferedTaskRepository != cfg.Slack.DefaultRepository {
		t.Fatalf("persisted task offer = %+v, %v", state, err)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("task started before approval = %+v, %v", incidents, err)
	}

	click := func(id, userID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
			ThreadTS: source.MessageTS, MessageTS: "1700.901", UserID: userID,
			ActionID: slackui.ActionStartTask, ActionValue: source.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
	}
	click("engineering-task-unauthorized", "UOTHER")
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "Only a configured operator") {
		t.Fatalf("unauthorized engineering task response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("unauthorized click created task = %+v, %v", incidents, err)
	}
	click("engineering-task-authorized", "U123ABC")
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || !incidents[0].IsEngineeringTask() {
		t.Fatalf("engineering task = %+v, %v", incidents, err)
	}
	if !incidents[0].IsThreadScoped() ||
		incidents[0].OriginChannelID != source.ChannelID ||
		incidents[0].OriginThreadTS != source.MessageTS {
		t.Fatalf("engineering task scope = %+v", incidents[0])
	}
	directoryEntry := incidentDirectoryEntry(incidents[0])
	if !strings.Contains(directoryEntry, "engineering task") ||
		!strings.Contains(directoryEntry, "repository work") ||
		strings.Contains(directoryEntry, "alert firing") {
		t.Fatalf("engineering task directory entry = %q", directoryEntry)
	}
	if len(slackClient.posts) != 2 ||
		!strings.Contains(slackClient.posts[1].message.Text, "Engineering task accepted") ||
		!strings.Contains(slackClient.posts[1].message.Text, "continuing in this thread") ||
		!strings.Contains(slackClient.posts[1].message.Text, "edit, test, and commit") {
		t.Fatalf("engineering task acknowledgement = %+v", slackClient.posts)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Labels["work_kind"] != "engineering_task" ||
		signals[0].Summary != source.Text {
		t.Fatalf("engineering task source = %+v, %v", signals, err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	if slackClient.createChannelCalls != 0 {
		t.Fatalf("thread task created %d Slack channels", slackClient.createChannelCalls)
	}
	if err := svc.processOutbox(ctx); err != nil {
		t.Fatal(err)
	}
	incidents, err = st.ListIncidents(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	task := incidents[0]
	if task.ChannelID != source.ChannelID || task.RootTS == "" ||
		task.ConversationThreadTS() != source.MessageTS {
		t.Fatalf("bound thread task = %+v", task)
	}
	taskCard := slackClient.posts[len(slackClient.posts)-1]
	if taskCard.channel != source.ChannelID ||
		taskCard.thread != source.MessageTS ||
		!strings.Contains(taskCard.message.Text, "Engineering task") {
		t.Fatalf("thread task card = %+v", taskCard)
	}
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	for count := 0; count < 4; count++ {
		err := svc.processOutbox(ctx)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, post := range slackClient.posts {
		if post.message.Header == "Engineering room ready" ||
			strings.Contains(post.message.Text, "<#CINCIDENT>") {
			t.Fatalf("thread task posted a room handoff = %+v", slackClient.posts)
		}
	}
	if err := svc.processTurn(ctx); err != nil {
		t.Fatal(err)
	}
	taskPrompt := coopClient.submitPrompts[len(coopClient.submitPrompts)-1]
	for _, required := range []string{
		"Complete this operator-approved engineering task",
		"File edits, tests, and commits are allowed",
		"Do not merge, push, deploy, sign, or mutate infrastructure",
	} {
		if !strings.Contains(taskPrompt, required) {
			t.Fatalf("dedicated task prompt lacks %q:\n%s", required, taskPrompt)
		}
	}

	followup := core.SlackInput{
		ID: "task-thread-followup", EnvelopeID: "env-task-thread-followup",
		EventID: "event-task-thread-followup", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: source.ChannelID, ThreadTS: source.MessageTS, MessageTS: "1700.902",
		UserID: "U123ABC", Text: "Also update the operations documentation.",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit task follow-up = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	queued, err := st.GetTurnSubmissionBySource(ctx, "slack", followup.ID)
	if err != nil || queued.IncidentID != task.ID {
		t.Fatalf("thread follow-up routing = %+v, %v", queued, err)
	}

	unrelated := core.SlackInput{
		ID: "task-channel-unrelated", EnvelopeID: "env-task-channel-unrelated",
		EventID: "event-task-channel-unrelated", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: source.ChannelID, MessageTS: "1700.903",
		UserID: "U123ABC", Text: "Unrelated shared-channel conversation.",
	}
	if created, err := st.AdmitSlackInput(ctx, unrelated); err != nil || !created {
		t.Fatalf("admit unrelated message = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if queued, err := st.GetTurnSubmissionBySource(ctx, "slack", unrelated.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unrelated message entered task session = %+v, %v", queued, err)
	}
}

func TestWatchedEngineeringRequestRequiresRepositoryWhenSeveralAreConfigured(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Repositories["backend"] = config.Repository{
		DisplayName: "Backend",
		CoopPolicy:  "backend-observe",
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"message":"I can make that repository change.",
		"task_title":"Update deployment packs"
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-ambiguous-repository", EnvelopeID: "env-ambiguous-repository",
		EventID: "event-ambiguous-repository", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.950", UserID: "U123ABC",
		Text: "Update the deployment packs.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		len(slackClient.posts[0].message.Actions) != 0 ||
		!strings.Contains(slackClient.posts[0].message.Text, "Which configured repository") ||
		!strings.Contains(slackClient.posts[0].message.Text, "Backend (`backend`)") ||
		!strings.Contains(slackClient.posts[0].message.Text, "Repository (`repo`)") {
		t.Fatalf("ambiguous repository response = %+v", slackClient.posts)
	}
	stored, err := st.GetSlackInput(ctx, source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchState(stored.Frozen)
	if err != nil {
		t.Fatal(err)
	}
	if state.OfferedTaskTitle != "" || state.OfferedTaskRepository != "" {
		t.Fatalf("ambiguous task offer was persisted: %+v", state)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("ambiguous task started work: %+v, %v", incidents, err)
	}
}

func TestExplicitIncidentRequestRecognition(t *testing.T) {
	for _, input := range []string{
		"Open an incident for this failure",
		"please create incident for checkout",
		"Declare the incident now",
		"turn this into an incident",
	} {
		if !explicitIncidentRequest(input) {
			t.Fatalf("explicit request was not recognized: %q", input)
		}
	}
	for _, input := range []string{
		"How healthy is production?",
		"This looks like an incident",
		"Should we open one?",
		"Investigate the disconnected runners",
	} {
		if explicitIncidentRequest(input) {
			t.Fatalf("ordinary conversation was treated as explicit: %q", input)
		}
	}
}

func TestWatchedDecisionReceivesFreshChronologicalChannelContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	inputs := []core.SlackInput{
		{
			ID: "slack-context-3", EnvelopeID: "env-context-3", EventID: "EvContext3",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000003", UserID: "U333",
			Text: "Yes, I am checking it now.",
		},
		{
			ID: "slack-context-1", EnvelopeID: "env-context-1", EventID: "EvContext1",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000001", UserID: "U111",
			Text: "Can someone review the deploy?",
		},
		{
			ID: "slack-context-2", EnvelopeID: "env-context-2", EventID: "EvContext2",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000002", UserID: "U222",
			Text: "<@U333> do you know what changed?",
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"ignore"}`
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	start := strings.Index(prompt, "<untrusted-slack-context>\n")
	end := strings.Index(prompt, "\n</untrusted-slack-context>")
	if start < 0 || end <= start {
		t.Fatalf("prompt has no bounded context: %s", prompt)
	}
	var evidence struct {
		TargetMessage  watchContextMessage   `json:"target_message"`
		RecentMessages []watchContextMessage `json:"recent_channel_messages"`
	}
	start += len("<untrusted-slack-context>\n")
	if err := json.Unmarshal([]byte(prompt[start:end]), &evidence); err != nil {
		t.Fatal(err)
	}
	if evidence.TargetMessage.Text != inputs[1].Text ||
		len(evidence.RecentMessages) != 3 {
		t.Fatalf("watch evidence = %+v", evidence)
	}
	wantTexts := []string{inputs[1].Text, inputs[2].Text, inputs[0].Text}
	for i, want := range wantTexts {
		if evidence.RecentMessages[i].Text != want {
			t.Fatalf("recent message %d = %+v, want %q",
				i, evidence.RecentMessages[i], want)
		}
	}
	if !evidence.RecentMessages[0].Target ||
		evidence.RecentMessages[1].MentionsResponder ||
		!strings.Contains(prompt, "people are talking to each other") ||
		!strings.Contains(prompt, "newer human message already answers the target") {
		t.Fatalf("conversation targeting guidance = %+v", evidence)
	}
	first, err := st.GetSlackInput(ctx, "slack-context-1")
	if err != nil || first.State != "done" {
		t.Fatalf("oldest source message was not processed first: %+v, %v", first, err)
	}
	for _, id := range []string{"slack-context-2", "slack-context-3"} {
		item, err := st.GetSlackInput(ctx, id)
		if err != nil || item.State != "pending" {
			t.Fatalf("later source message %s overtook target: %+v, %v", id, item, err)
		}
	}
}

func TestWatchedDecisionWaitsForNearbyConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 5 * time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-settle", EnvelopeID: "env-settle", EventID: "EvSettle",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000001", UserID: "U111", Text: "Is the deploy okay?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "retry" || len(coopClient.createKeys) != 0 {
		t.Fatalf("settling input = %+v, Coop creates=%v, error=%v",
			stored, coopClient.createKeys, err)
	}
}

func TestLateWatchedMessageCannotRespondAfterNewerDecision(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	newer := core.SlackInput{
		ID: "slack-late-new", EnvelopeID: "env-late-new", EventID: "EvLateNew",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000002", UserID: "U222", Text: "Newer event",
	}
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit newer = %v, %v", created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != newer.ID {
		t.Fatalf("lease newer = %+v, %v", leased, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ObjectID: "slack-late-new", Outcome: "ignored",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackInput(ctx, newer.ID); err != nil {
		t.Fatal(err)
	}
	older := core.SlackInput{
		ID: "slack-late-old", EnvelopeID: "env-late-old", EventID: "EvLateOld",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000001", UserID: "U111", Text: "Old delayed event",
	}
	if created, err := st.AdmitSlackInput(ctx, older); err != nil || !created {
		t.Fatalf("admit older = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, "slack-late-old")
	if err != nil || stored.State != "done" || len(coopClient.createKeys) != 0 {
		t.Fatalf("late input = %+v, Coop creates=%v, error=%v",
			stored, coopClient.createKeys, err)
	}
}

func TestIncidentTurnCapacityExtendsAutomatically(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 7); err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueTurn(ctx, core.TurnSubmission{
		IncidentID: incident.ID, SourceKind: "control", SourceID: "automatic-capacity",
		UserID: "U123ABC", Prompt: "Inspect current evidence.",
	}); err != nil || !created {
		t.Fatalf("queue turn = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.Revision = 7
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processTurn(ctx); err != nil {
		t.Fatal(err)
	}
	if coopClient.session.MaxTurns != 125 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("automatic capacity session = %+v, submissions = %v",
			coopClient.session, coopClient.submitKeys)
	}
	submission, err := st.GetTurnSubmissionBySource(ctx, "control", "automatic-capacity")
	if err != nil || submission.State != "submitted" {
		t.Fatalf("automatic-capacity submission = %+v, %v", submission, err)
	}
}

func TestAutomaticTurnCapacityHonorsConfiguredCeiling(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.TurnLimit = 100
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	_, err = svc.ensureTurnCapacity(ctx, "CWATCH", "", coopClient.session)
	var limitErr *automaticTurnLimitError
	if !errors.As(err, &limitErr) || limitErr.Limit != 100 {
		t.Fatalf("configured ceiling error = %T %v", err, err)
	}
	if coopClient.session.MaxTurns != 100 {
		t.Fatalf("capacity changed beyond ceiling: %+v", coopClient.session)
	}
}

func TestWatchedTurnResumesFromDurableState(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.submitState = "starting"
	input := core.SlackInput{
		ID: "slack-watch-resume", EnvelopeID: "env-watch-resume", EventID: "EvWatchResume",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.600", UserID: "U123ABC", Text: "Did the deploy recover?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	firstSlack := &fakeSlack{}
	svc := New(cfg, st, coopClient, firstSlack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "retry" || len(stored.Frozen) == 0 {
		t.Fatalf("running watch input = %+v, %v", stored, err)
	}
	if len(firstSlack.statuses) != 0 {
		t.Fatalf("ambient triage exposed a thread status: %+v", firstSlack.statuses)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	coopClient.complete(`{"action":"reply","message":"Yes, the deploy recovered."}`)
	time.Sleep(watchPollDelay + 100*time.Millisecond)
	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc = New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err = st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" || len(slack.posts) != 1 {
		t.Fatalf("resumed watch input = %+v, posts=%+v, %v", stored, slack.posts, err)
	}
	if len(slack.statuses) != 0 {
		t.Fatalf("resumed ambient triage exposed a thread status: %+v", slack.statuses)
	}
	if len(coopClient.createKeys) != 1 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("durable state replayed Coop mutations: create=%v submit=%v",
			coopClient.createKeys, coopClient.submitKeys)
	}
}

func TestParseWatchDecisionIsStrict(t *testing.T) {
	valid := []string{
		`{"action":"ignore"}`,
		`{"action":"reply","message":"I am looking at it."}`,
		`{"action":"reply","message":"Two runners are offline.","incident_title":"Two runners offline"}`,
		`{"action":"reply","message":"I can make that change.","task_title":"Audit infrastructure packs","task_repository":"repo","memory":{"topology":{"portal_hosts_declared":2,"runner_mapping":"Two current runners"}}}`,
		`{"action":"incident","title":"API unavailable"}`,
	}
	for _, input := range valid {
		if _, err := parseWatchDecision(input); err != nil {
			t.Fatalf("valid decision %s: %v", input, err)
		}
	}
	invalid := []string{
		`{"action":"ignore","message":"no"}`,
		`{"action":"reply","message":""}`,
		`{"action":"incident"}`,
		`{"action":"incident","title":"API unavailable","incident_title":"duplicate"}`,
		`{"action":"reply","message":"Choose a repository.","task_repository":"repo"}`,
		`{"action":"ignore","unknown":true}`,
		"```json\n{\"action\":\"ignore\"}\n```",
		`{"action":"ignore"} {"action":"ignore"}`,
	}
	for _, input := range invalid {
		if _, err := parseWatchDecision(input); err == nil {
			t.Fatalf("invalid decision accepted: %s", input)
		}
	}
}

func TestParseWatchDecisionNormalizesStructuredMemoryTopology(t *testing.T) {
	decision, err := parseWatchDecision(`{
		"action":"reply",
		"message":"I can make that change.",
		"task_title":"Audit infrastructure packs",
		"memory":{
			"topology":{
				"runner_mapping":"Two current runners",
				"portal_hosts_declared":2
			}
		}
	}`)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"portal_hosts_declared: 2",
		"runner_mapping: Two current runners",
	}
	if !slices.Equal(decision.Memory.Topology, want) {
		t.Fatalf("normalized topology = %#v, want %#v", decision.Memory.Topology, want)
	}
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

type fakeCoop struct {
	session          coop.Session
	turn             coop.Turn
	events           []coop.Event
	createKeys       []string
	createTasks      []string
	listSessions     []coop.Session
	createErrors     []error
	submitKeys       []string
	submitPrompts    []string
	submitState      string
	completeOnSubmit string
	discardPlan      coop.DiscardPlan
	discardCalls     int
}

func newFakeCoop() *fakeCoop {
	return &fakeCoop{session: coop.Session{
		ID: "ses_1", ForkName: "responder-api-unavailable",
		Revision: 1, State: "open", Activity: "parked", MaxTurns: 100,
	}}
}

func (f *fakeCoop) Ready(context.Context) error { return nil }
func (f *fakeCoop) CreateSession(_ context.Context, key, _, task string) (coop.Session, coop.Operation, error) {
	f.createKeys = append(f.createKeys, key)
	f.createTasks = append(f.createTasks, task)
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
	return f.session, coop.Operation{}, nil
}

func (f *fakeCoop) ListSessions(context.Context, int) ([]coop.Session, error) {
	return append([]coop.Session(nil), f.listSessions...), nil
}
func (f *fakeCoop) GetSession(context.Context, string) (coop.Session, error) {
	return f.session, nil
}
func (f *fakeCoop) SubmitTurn(_ context.Context, key, _ string, _ int64, prompt string) (coop.Turn, coop.Operation, error) {
	f.submitKeys = append(f.submitKeys, key)
	f.submitPrompts = append(f.submitPrompts, prompt)
	state := f.submitState
	if state == "" {
		state = "running"
	}
	f.turn = coop.Turn{ID: "coop_turn_1", SessionID: f.session.ID, State: state}
	f.session.ActiveTurnID = f.turn.ID
	f.session.Revision++
	if f.completeOnSubmit != "" {
		f.complete(f.completeOnSubmit)
	}
	return f.turn, coop.Operation{}, nil
}
func (f *fakeCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	if f.turn.ID == "" {
		return coop.Turn{}, errors.New("missing turn")
	}
	return f.turn, nil
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
	return coop.Changes{}, nil
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
	context.Context, string, string, int64, bool, bool,
) (coop.DiscardPlan, coop.Operation, error) {
	if f.discardPlan.OperationID != "" {
		return f.discardPlan, coop.Operation{}, nil
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

func TestOrphanReconciliationSchedulesOnlyResponderManagedSessions(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	coopClient := newFakeCoop()
	coopClient.listSessions = []coop.Session{
		{
			ID: "ses_orphan", ExternalRef: "engineering-task:task_1",
			ForkName: "remote-orphan", State: "closed", UpdatedAt: now.Add(-time.Hour),
		},
		{
			ID: "ses_unrelated", ExternalRef: "catalog-roadmap",
			ForkName: "catalog-roadmap", State: "closed", UpdatedAt: now.Add(-time.Hour),
		},
		{
			ID: "ses_fresh", ExternalRef: "incident:inc_fresh",
			ForkName: "remote-fresh", State: "closed", UpdatedAt: now,
		},
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileOrphanedResponderSessions(
		ctx, now.Add(-cfg.Retention.ClosedSessionGrace.Duration), now,
	); err != nil {
		t.Fatal(err)
	}
	item, err := st.NextCleanup(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if item.SessionID != "ses_orphan" || item.Reason != "orphaned Responder session" {
		t.Fatalf("scheduled cleanup = %+v", item)
	}
	for _, sessionID := range []string{"ses_unrelated", "ses_fresh"} {
		known, err := st.ResponderSessionKnown(ctx, sessionID)
		if err != nil {
			t.Fatal(err)
		}
		if known {
			t.Fatalf("session %s was incorrectly claimed by Responder", sessionID)
		}
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

func (f *fakeCoop) complete(message string) {
	f.turn.State = "completed"
	f.turn.AssistantMessage = message
	f.session.ActiveTurnID = ""
	f.session.State = "open"
	f.session.Activity = "parked"
	f.session.Revision++
	f.events = append(f.events, coop.Event{
		ID: "evt_1", SessionID: f.session.ID, Sequence: 1,
		TurnID: f.turn.ID, Type: "turn.completed",
	})
}

type slackPost struct {
	outboxID string
	channel  string
	thread   string
	message  slackui.Message
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

type fakeSlack struct {
	posts              []slackPost
	ephemerals         []slackPost
	updates            []slackUpdate
	statuses           []slackStatus
	suggested          []slackStatus
	homes              []slackPost
	postErr            error
	ephemeralErr       error
	inviteErr          error
	statusErr          error
	updateErr          error
	updateCall         int
	channel            slackui.Channel
	channelErr         error
	dedupePosts        bool
	createChannelCalls int
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
func (f *fakeSlack) GetChannel(context.Context, string) (slackui.Channel, error) {
	if f.channelErr != nil {
		return slackui.Channel{}, f.channelErr
	}
	if f.channel.ID != "" {
		return f.channel, nil
	}
	return slackui.Channel{ID: "CWATCH", Name: "watch", Member: true}, nil
}
func (f *fakeSlack) Invite(context.Context, string, ...string) error { return f.inviteErr }
func (f *fakeSlack) SetTopic(context.Context, string, string) error  { return nil }
func (f *fakeSlack) Post(_ context.Context, outboxID, channel, thread string, message slackui.Message) (string, error) {
	f.posts = append(f.posts, slackPost{
		outboxID: outboxID, channel: channel, thread: thread, message: message,
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
func (f *fakeSlack) SetSuggestedPrompts(
	_ context.Context,
	channel string,
	thread string,
) error {
	f.suggested = append(f.suggested, slackStatus{channel: channel, thread: thread})
	return nil
}
func (f *fakeSlack) PublishHome(
	_ context.Context,
	user string,
	message slackui.Message,
) error {
	f.homes = append(f.homes, slackPost{thread: user, message: message})
	return nil
}
func (f *fakeSlack) UserAllowed(context.Context, string, string) (bool, error) {
	return true, nil
}
func (f *fakeSlack) FindOutboxMessage(
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
repositories:
  repo:
    display_name: Repository
    coop_policy: repo-observe
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

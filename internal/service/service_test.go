package service

import (
	"context"
	"encoding/json"
	"errors"
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
		MessageTS: "1700.001", UserID: "U123ABC", Text: "<@U999BOT> investigate checkout",
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
		MessageTS: "1700.001", UserID: "U123ABC", Text: "<@U999BOT> investigate checkout",
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
				ctx, "repo", "manual-source", "Investigate checkout", "U123ABC",
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
	status := svc.nativeStatus[incident.ID]
	status.at = time.Now().Add(-76 * time.Second)
	svc.nativeStatus[incident.ID] = status
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
	if _, ok := svc.nativeStatus[incident.ID]; ok {
		t.Fatal("thread reply did not clear the local native-status cache")
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
	if _, ok := svc.nativeStatus[incident.ID]; ok {
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
	if len(slack.statuses) != 2 || svc.nativeStatus[incident.ID].text != "is investigating..." {
		t.Fatalf("native status did not recover: %+v", slack.statuses)
	}
}

func TestSocketEventIsPersistedBeforeAcknowledgement(t *testing.T) {
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

	// Top-level channel chatter is acknowledged and ignored rather than
	// becoming failed incident work.
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
		t.Fatalf("ignored event was not acknowledged: %d", socket.acks)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("top-level chatter was persisted: %v", err)
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
	session coop.Session
	turn    coop.Turn
	events  []coop.Event
}

func newFakeCoop() *fakeCoop {
	return &fakeCoop{session: coop.Session{
		ID: "ses_1", ForkName: "responder-api-unavailable",
		Revision: 1, State: "open", Activity: "parked",
	}}
}

func (f *fakeCoop) Ready(context.Context) error { return nil }
func (f *fakeCoop) CreateSession(context.Context, string, string, string) (coop.Session, coop.Operation, error) {
	return f.session, coop.Operation{}, nil
}
func (f *fakeCoop) GetSession(context.Context, string) (coop.Session, error) {
	return f.session, nil
}
func (f *fakeCoop) SubmitTurn(_ context.Context, _ string, _ string, _ int64, _ string) (coop.Turn, coop.Operation, error) {
	f.turn = coop.Turn{ID: "coop_turn_1", SessionID: f.session.ID, State: "running"}
	f.session.ActiveTurnID = f.turn.ID
	f.session.Revision++
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
	return f.session, coop.Operation{}, nil
}
func (f *fakeCoop) Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error) {
	f.session.State = "closed"
	return f.session, coop.Operation{}, nil
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
	channel string
	thread  string
	message slackui.Message
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
	posts      []slackPost
	updates    []slackUpdate
	statuses   []slackStatus
	postErr    error
	inviteErr  error
	statusErr  error
	updateErr  error
	updateCall int
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
	return slackui.Channel{ID: "CINCIDENT", Name: name, Creator: "U999BOT", Created: time.Now()}, nil
}
func (f *fakeSlack) FindChannelByName(context.Context, string, string) (slackui.Channel, error) {
	return slackui.Channel{}, slackui.ErrNotFound
}
func (f *fakeSlack) Invite(context.Context, string, ...string) error { return f.inviteErr }
func (f *fakeSlack) SetTopic(context.Context, string, string) error  { return nil }
func (f *fakeSlack) Post(_ context.Context, _ string, channel, thread string, message slackui.Message) (string, error) {
	f.posts = append(f.posts, slackPost{channel: channel, thread: thread, message: message})
	return "1700.00" + string(rune('1'+len(f.posts)-1)), f.postErr
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
func (f *fakeSlack) UserAllowed(context.Context, string, string) (bool, error) {
	return true, nil
}
func (f *fakeSlack) FindOutboxMessage(context.Context, string, string, string) (string, error) {
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

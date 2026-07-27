package service

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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
	outbox, err := st.LeaseOutbox(ctx)
	if err != nil || outbox.IncidentID != incidents[0].ID || outbox.ThreadTS != "1700.001" {
		t.Fatalf("accepted incident update was not dispatched: %+v, %v", outbox, err)
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

type fakeSlack struct {
	posts []slackPost
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
func (f *fakeSlack) Invite(context.Context, string, ...string) error { return nil }
func (f *fakeSlack) SetTopic(context.Context, string, string) error  { return nil }
func (f *fakeSlack) Post(_ context.Context, _ string, channel, thread string, message slackui.Message) (string, error) {
	f.posts = append(f.posts, slackPost{channel: channel, thread: thread, message: message})
	return "1700.00" + string(rune('1'+len(f.posts)-1)), nil
}
func (f *fakeSlack) Update(context.Context, string, string, slackui.Message) error {
	return nil
}
func (f *fakeSlack) Pin(context.Context, string, string) error               { return nil }
func (f *fakeSlack) SetStatus(context.Context, string, string, string) error { return nil }
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

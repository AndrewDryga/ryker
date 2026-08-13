package service

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestWatchedStructuredReportPersistsEvidenceCoverageAndMemory(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		  "action":"reply",
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		  "reason":"The operator asked Responder for a health assessment.",
	  "message":"**Current assessment:** declared capacity is two instances; scheduler state remains unknown.",
	  "evidence":[{
	    "claim":"Expected production capacity is two instances",
	    "observation":"infra/main.tf sets target_size to 2",
	    "source_type":"repository",
	    "source_name":"infra/main.tf",
	    "source_url":"https://example.test/repo/blob/main/infra/main.tf?token=secret",
	    "target":"production-mig",
	    "confidence":"high"
	  }],
	  "coverage":[{
	    "layer":"scheduler",
	    "status":"unknown",
	    "detail":"No authorized Nomad observation was available"
	  }],
	  "memory":{
	    "goal":"Assess production health",
	    "topology":["Two declared production instances"],
	    "unresolved_questions":["Nomad allocation state"]
	  }
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-structured", EnvelopeID: "env-structured",
		EventID: "event-structured", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.900", UserID: "U123ABC",
		Text: "How healthy is production?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		strings.Contains(slackClient.posts[0].message.Markdown, "## Evidence") ||
		strings.Contains(slackClient.posts[0].message.Markdown, "## Coverage") ||
		len(slackClient.posts[0].message.Context) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Context[0], "finding") {
		t.Fatalf("structured response = %+v", slackClient.posts)
	}
	evidence, err := st.Intelligence.ListEvidence(ctx, "", input.ChannelID, 10)
	if err != nil || len(evidence) != 1 ||
		evidence[0].SourceURL != "https://example.test/repo/blob/main/infra/main.tf" {
		t.Fatalf("evidence = %+v, %v", evidence, err)
	}
	coverage, err := st.Intelligence.ListCoverage(ctx, "", input.ChannelID, 10)
	if err != nil || len(coverage) != 1 || coverage[0].Status != "unknown" {
		t.Fatalf("coverage = %+v, %v", coverage, err)
	}
	// The channel's memory keeps what describes the channel and drops the
	// goal, which belongs to the thread that pursues it rather than to the
	// room the thread is in.
	memory, err := st.Intelligence.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.TurnCount != 1 ||
		memory.State.Goal != "" ||
		len(memory.State.Topology) != 1 {
		t.Fatalf("memory = %+v, %v", memory, err)
	}
}

func TestWatchedShadowModeRecordsWithoutPosting(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.ShadowChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "reason":"A direct operational question was asked.",
	  "message":"Production is degraded.",
	  "evidence":[{
	    "claim":"One workload is unhealthy",
	    "observation":"The live status is failed",
	    "source_type":"emisar",
	    "source_name":"status",
	    "target":"job/api"
	  }],
	  "coverage":[
	    {"layer":"change","status":"unknown","detail":"No deployment source was available"},
	    {"layer":"host","status":"unknown","detail":"No host source was available"},
	    {"layer":"runtime","status":"unknown","detail":"No runtime source was available"},
	    {"layer":"workload","status":"unhealthy","source":"status","detail":"The API workload is failed"},
	    {"layer":"dependency","status":"unknown","detail":"No dependency source was available"},
	    {"layer":"application","status":"degraded","source":"status","detail":"The API workload cannot serve normally"},
	    {"layer":"slo","status":"unknown","detail":"No SLO source was available"}
	  ],
	  "completion":{"status":"blocked","summary":"Production is degraded but impact is not fully bounded.","material_gaps":["host, dependency, and SLO evidence"],"blocker_kind":"source_unavailable","attempts":["The configured live status source exposed the workload failure but no host, dependency, or SLO telemetry"],"next_action":"Connect an authoritative host and SLO telemetry source, then rerun the assessment"}
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-shadow", EnvelopeID: "env-shadow", EventID: "event-shadow",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.901", UserID: "U123ABC", Text: "Is production healthy?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("shadow mode posted: %+v", slackClient.posts)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" {
		t.Fatalf("shadow input = %+v, %v", stored, err)
	}
	evidence, err := st.Intelligence.ListEvidence(ctx, "", input.ChannelID, 10)
	if err != nil || len(evidence) != 1 {
		t.Fatalf("shadow evidence = %+v, %v", evidence, err)
	}
}

func TestWatchSessionRotatesAndCarriesDurableMemory(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.WatchSessionTurns = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.openAfterCreateKey = "responder:watch-session:CWATCH:2"
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, session, err := svc.ensureWatchSession(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceChannelMemory(ctx, "CWATCH", session.Revision+1, core.AgentMemory{
		Goal: "Track production health",
		Topology: []string{
			"Two declared instances",
		},
	}); err != nil {
		t.Fatal(err)
	}
	coopClient.session.State = "open"
	rotated, _, err := svc.ensureWatchSession(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if memory.Generation != 1 || rotated.Generation != 2 ||
		rotated.State.Goal != "Track production health" ||
		len(coopClient.createKeys) != 2 ||
		coopClient.createKeys[0] != "responder:watch-session:CWATCH" ||
		coopClient.createKeys[1] != "responder:watch-session:CWATCH:2" {
		t.Fatalf(
			"rotation = before=%+v after=%+v keys=%v",
			memory, rotated, coopClient.createKeys,
		)
	}
	cleanup, err := st.NextCleanup(ctx, time.Now().UTC())
	if err != nil || cleanup.SessionID != session.ID {
		t.Fatalf("rotated session was not immediately eligible for cleanup: %+v, %v", cleanup, err)
	}
}

func TestFailedWatchSessionCreateAdvancesIdempotencyGeneration(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.createErrors = []error{&coop.APIError{
		Status: 500, Code: "internal_error", Detail: "workspace creation failed",
	}}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if _, _, err := svc.ensureWatchSessionAtGeneration(
		ctx, "CWATCH", 1,
	); err == nil {
		t.Fatal("first watch session creation unexpectedly succeeded")
	}
	if _, _, err := svc.ensureWatchSessionAtGeneration(
		ctx, "CWATCH", 2,
	); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"responder:watch-session:CWATCH",
		"responder:watch-session:CWATCH:2",
	}
	if !slices.Equal(coopClient.createKeys, want) {
		t.Fatalf("watch session create keys = %v, want %v", coopClient.createKeys, want)
	}
}

func TestFailedSessionGenerationOnlyAdvancesForTerminalCoopCreate(t *testing.T) {
	if !advanceFailedSessionGeneration(&coop.APIError{
		Status: 500, Code: "internal_error",
	}) {
		t.Fatal("terminal Coop create failure did not advance generation")
	}
	if advanceFailedSessionGeneration(errors.New("connection reset")) ||
		advanceFailedSessionGeneration(&coop.APIError{
			Status: 409, Code: "operation_uncertain",
		}) {
		t.Fatal("uncertain create failure advanced generation")
	}
}

func TestWatchSessionRecoversLegacyGenerationOneIdempotencyRequest(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_legacy_watch"
	coopClient.createErrors = []error{
		&coop.APIError{
			Status: 409,
			Code:   "idempotency_conflict",
			Detail: "idempotency key is bound to another request",
		},
		nil,
	}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, session, err := svc.ensureWatchSession(ctx, "CWATCH")
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_legacy_watch" ||
		memory.SessionID != session.ID ||
		memory.Generation != 1 ||
		len(coopClient.createKeys) != 2 ||
		coopClient.createKeys[0] != "responder:watch-session:CWATCH" ||
		coopClient.createKeys[1] != "responder:watch-session:CWATCH" ||
		coopClient.createTasks[0] != "Slack operations channel CWATCH generation 1" ||
		coopClient.createTasks[1] != "Slack alert triage channel CWATCH" {
		t.Fatalf(
			"legacy recovery = memory=%+v session=%+v keys=%v tasks=%v",
			memory, session, coopClient.createKeys, coopClient.createTasks,
		)
	}
}

func TestWatchSessionSearchesPastHistoricalCollisionWindow(t *testing.T) {
	coopClient := newFakeCoop()
	for range 20 {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 409,
			Code:   "idempotency_conflict",
			Detail: "idempotency key is bound to a historical request",
		})
	}
	svc := &Service{cfg: serviceConfig(t), coop: coopClient}
	session, generation, err := svc.createWatchSession(
		context.Background(), "CHISTORY", "observe", 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID == "" || generation != 22 || len(coopClient.createKeys) != 21 {
		t.Fatalf(
			"historical collision recovery = session=%+v generation=%d keys=%d",
			session, generation, len(coopClient.createKeys),
		)
	}
	if got := coopClient.createKeys[len(coopClient.createKeys)-1]; got != "responder:watch-session:CHISTORY:22" {
		t.Fatalf("last create key = %q", got)
	}
}

func TestConversationSessionSearchesPastHistoricalCollisionWindow(t *testing.T) {
	coopClient := newFakeCoop()
	for range 20 {
		coopClient.createErrors = append(coopClient.createErrors, &coop.APIError{
			Status: 409,
			Code:   "idempotency_conflict",
			Detail: "idempotency key is bound to a historical request",
		})
	}
	svc := &Service{cfg: serviceConfig(t), coop: coopClient}
	session, generation, err := svc.createConversationSession(
		context.Background(), "CHISTORY", "conversation", 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID == "" || generation != 22 || len(coopClient.createKeys) != 21 {
		t.Fatalf(
			"historical collision recovery = session=%+v generation=%d keys=%d",
			session, generation, len(coopClient.createKeys),
		)
	}
}

// Opening an agent surface is acknowledged and costs nothing else.
//
// The prompts above the Messages tab are declared statically in
// deploy/slack-app-manifest.yaml under features.agent_view.suggested_prompts.
// Responder used to answer the same event by calling
// assistant.threads.setSuggestedPrompts with a near-identical list, which Slack
// refused with internal_error on every attempt either deployment ever made.
// Queueing work for these events is therefore not a smaller failure than
// failing at it — it is the whole defect, so the assertion is that no input is
// admitted at all.
func TestOpeningAnAgentSurfaceQueuesNoWorkAndTheHomeStillPublishes(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)

	for _, event := range []struct {
		name     string
		envelope string
		data     slackevents.EventsAPIInnerEvent
	}{
		{
			name:     "assistant thread",
			envelope: "env-assistant",
			data: slackevents.EventsAPIInnerEvent{Data: &slackevents.AssistantThreadStartedEvent{
				AssistantThread: slackevents.AssistantThread{
					UserID: "U123ABC", ChannelID: "D123ABC", ThreadTimeStamp: "1700.902",
				},
			}},
		},
		{
			name:     "agent messages tab",
			envelope: "env-messages",
			data: slackevents.EventsAPIInnerEvent{Data: &slackevents.AppHomeOpenedEvent{
				User: "U123ABC", Channel: "D123ABC", Tab: "messages",
			}},
		},
	} {
		payload, _ := json.Marshal(map[string]any{"event_id": event.envelope})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID: cfg.Slack.TeamID, InnerEvent: event.data,
			},
			Request: &socketmode.Request{EnvelopeID: event.envelope, Payload: payload},
		})
		// Acknowledged so Slack stops redelivering, and nothing queued: the
		// lane finds an empty queue rather than a surface repaint to attempt.
		if err := svc.processSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("%s queued a Slack input: %v", event.name, err)
		}
	}
	if socket.acks != 2 {
		t.Fatalf("acks = %d, want both surface opens acknowledged", socket.acks)
	}

	// The Home tab is the surface that does have host-owned content, and it is
	// unaffected.
	payload, _ := json.Marshal(map[string]any{"event_id": "EvHome"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.AppHomeOpenedEvent{User: "U123ABC", Tab: "home"},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-home", Payload: payload},
	})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.homes) != 1 ||
		slackClient.homes[0].thread != "U123ABC" ||
		slackClient.homes[0].message.Header != "Emisar" {
		t.Fatalf("operations home = %+v", slackClient.homes)
	}
}

func TestSlackShortcutAndDirectMessageBecomeExplicitReadOnlyRequests(t *testing.T) {
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
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	svc.admitInteraction(ctx, socketmode.Event{
		Type: socketmode.EventTypeInteractive,
		Data: slack.InteractionCallback{
			Type: slack.InteractionTypeMessageAction,
			Team: slack.Team{ID: cfg.Slack.TeamID},
			Channel: slack.Channel{
				GroupConversation: slack.GroupConversation{
					Conversation: slack.Conversation{ID: "CWATCH"},
				},
			},
			User:       slack.User{ID: "U123ABC"},
			CallbackID: "responder_investigate_message",
			Message: slack.Message{Msg: slack.Msg{
				User: "U456DEF", Text: "The API alert is firing.",
				Timestamp: "1700.903",
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-shortcut"},
	})
	shortcut, err := st.LeaseSlackInput(ctx)
	if err != nil || shortcut.Kind != "shortcut" ||
		shortcut.UserID != "U123ABC" || shortcut.ActionValue != "U456DEF" ||
		shortcut.ThreadTS != shortcut.MessageTS {
		t.Fatalf("shortcut = %+v, %v", shortcut, err)
	}
	contextMessage := WatchPromptMessage(shortcut, "U999BOT", true)
	if contextMessage.SenderID != "U456DEF" ||
		contextMessage.RequestedBy != "U123ABC" ||
		contextMessage.SenderType != "selected_message" {
		t.Fatalf("shortcut context = %+v", contextMessage)
	}
	if err := st.FinishSlackInput(ctx, shortcut.ID); err != nil {
		t.Fatal(err)
	}

	payload, _ := json.Marshal(map[string]any{"event_id": "EvDirect"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.MessageEvent{
					Channel: "D123ABC", User: "U123ABC",
					Text: "Assess production health.", TimeStamp: "1700.904",
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-direct", Payload: payload},
	})
	direct, err := st.LeaseSlackInput(ctx)
	if err != nil || direct.Kind != "direct" || direct.ChannelID != "D123ABC" {
		t.Fatalf("direct message = %+v, %v", direct, err)
	}
}

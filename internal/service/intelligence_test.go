package service

import (
	"context"
	"encoding/json"
	"errors"
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
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},
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
	evidence, err := st.ListEvidence(ctx, "", input.ChannelID, 10)
	if err != nil || len(evidence) != 1 ||
		evidence[0].SourceURL != "https://example.test/repo/blob/main/infra/main.tf" {
		t.Fatalf("evidence = %+v, %v", evidence, err)
	}
	coverage, err := st.ListCoverage(ctx, "", input.ChannelID, 10)
	if err != nil || len(coverage) != 1 || coverage[0].Status != "unknown" {
		t.Fatalf("coverage = %+v, %v", coverage, err)
	}
	memory, err := st.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.TurnCount != 1 ||
		memory.State.Goal != "Assess production health" ||
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
	  "completion":{"status":"blocked","summary":"Production is degraded but impact is not fully bounded.","material_gaps":["host, dependency, and SLO evidence"],"next_action":"Query the authoritative host and SLO sources"}
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
	evidence, err := st.ListEvidence(ctx, "", input.ChannelID, 10)
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

func TestTwoPersonActionApprovalQueuesOnlyConfiguredProposal(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.Operators = []string{"U123ABC", "U456DEF"}
	cfg.Actions = map[string]config.ActionPolicy{
		"restart_allocation": {
			Description: "Restart one failed scheduler allocation.",
			Authority:   "emisar", Risk: "medium", Approval: "two_person",
			ExpiresAfter: config.Duration{Duration: 15 * time.Minute},
		},
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-api", 1,
	); err != nil {
		t.Fatal(err)
	}
	proposals, err := st.CreateActionProposals(ctx, []core.ActionProposal{{
		IncidentID: incident.ID, ChannelID: incident.ChannelID, SourceInput: "turn_1",
		ActionName: "restart_allocation", Title: "Restart failed allocation",
		Summary: "The allocation is terminal and no replacement exists.",
		Target:  "alloc-123", Parameters: map[string]string{"allocation": "alloc-123"},
		BlastRadius: "One allocation", Rollback: "Restore the prior allocation version",
		Verification: "Replacement allocation reaches healthy",
		Authority:    "emisar", Risk: "medium", Required: 2,
		ExpiresAt: time.Now().UTC().Add(15 * time.Minute),
	}})
	if err != nil || len(proposals) != 1 {
		t.Fatalf("proposal = %+v, %v", proposals, err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	approve := func(id, user string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
			UserID: user, ActionID: slackui.ActionApproveProposal,
			ActionValue: proposals[0].ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
	}
	approve("approval-1", "U123ABC")
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "1 of 2") {
		t.Fatalf("first approval receipt = %+v", slackClient.ephemerals)
	}
	if _, err := st.GetAgentRunBySource(
		ctx, "proposal", proposals[0].ID,
	); err != store.ErrNotFound {
		t.Fatalf("proposal ran after one approval: %v", err)
	}
	approve("approval-2", "U456DEF")
	submission, err := st.GetAgentRunBySource(
		ctx, "proposal", proposals[0].ID,
	)
	if err != nil ||
		!strings.Contains(submission.Prompt, `configured action "restart_allocation"`) ||
		!strings.Contains(submission.Prompt, `target "alloc-123"`) ||
		!strings.Contains(submission.Prompt, "Emisar authorization") {
		t.Fatalf("queued governed action = %+v, %v", submission, err)
	}
	proposal, err := st.GetActionProposal(ctx, proposals[0].ID)
	if err != nil || proposal.Status != "executing" {
		t.Fatalf("proposal state = %+v, %v", proposal, err)
	}
}

func TestSlackAssistantPromptsAndOperationsHome(t *testing.T) {
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
	payload, _ := json.Marshal(map[string]any{"event_id": "EvAssistant"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.AssistantThreadStartedEvent{
					AssistantThread: slackevents.AssistantThread{
						UserID: "U123ABC", ChannelID: "D123ABC",
						ThreadTimeStamp: "1700.902",
					},
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-assistant", Payload: payload},
	})
	if socket.acks != 1 || len(slackClient.suggested) != 1 ||
		slackClient.suggested[0].channel != "D123ABC" ||
		slackClient.suggested[0].thread != "1700.902" {
		t.Fatalf(
			"assistant thread = acks=%d suggested=%+v",
			socket.acks, slackClient.suggested,
		)
	}
	if err := svc.publishOperationsHome(ctx, "U123ABC"); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.homes) != 1 ||
		slackClient.homes[0].thread != "U123ABC" ||
		slackClient.homes[0].message.Header != "Emisar" {
		t.Fatalf("operations home = %+v", slackClient.homes)
	}

	payload, _ = json.Marshal(map[string]any{"event_id": "EvMessages"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.AppHomeOpenedEvent{
					User: "U123ABC", Channel: "D123ABC", Tab: "messages",
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-messages", Payload: payload},
	})
	if socket.acks != 2 || len(slackClient.suggested) != 2 ||
		slackClient.suggested[1].channel != "D123ABC" ||
		slackClient.suggested[1].thread != "" {
		t.Fatalf(
			"agent messages tab = acks=%d suggested=%+v",
			socket.acks, slackClient.suggested,
		)
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
	contextMessage := watchPromptMessage(shortcut, "U999BOT", true)
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

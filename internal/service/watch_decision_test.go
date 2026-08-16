package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestSocketPersistsReactionsToResponderMessagesWithoutStartingAgentTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if created, enqueueErr := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "reaction-target", Kind: "watch_reply", ChannelID: "CWATCH",
		ThreadTS: "1700.100", Body: []byte(`{"text":"Production is healthy."}`),
	}); enqueueErr != nil || !created {
		t.Fatalf("enqueue reaction target = %v, %v", created, enqueueErr)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, delivery.ID, "1700.200", "sending"); err != nil {
		t.Fatal(err)
	}

	socket := &fakeSocket{events: make(chan socketmode.Event)}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	admitReaction := func(eventID, eventTS, kind string) {
		t.Helper()
		payload, _ := json.Marshal(map[string]any{"event_id": eventID})
		var event any
		item := slackevents.Item{
			Type: "message", Channel: "CWATCH", Timestamp: "1700.200",
		}
		if kind == "reaction_added" {
			event = &slackevents.ReactionAddedEvent{
				User: "U123ABC", Reaction: "thumbsup", ItemUser: "U999BOT",
				Item: item, EventTimestamp: eventTS,
			}
		} else {
			event = &slackevents.ReactionRemovedEvent{
				User: "U123ABC", Reaction: "thumbsup", ItemUser: "U999BOT",
				Item: item, EventTimestamp: eventTS,
			}
		}
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID:     cfg.Slack.TeamID,
				InnerEvent: slackevents.EventsAPIInnerEvent{Data: event},
			},
			Request: &socketmode.Request{EnvelopeID: "env-" + eventID, Payload: payload},
		})
	}

	admitReaction("EvReactionAdded", "1700.300", "reaction_added")
	if socket.acks != 1 {
		t.Fatalf("reaction acknowledgements = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if input.Kind != "reaction_added" || input.ThreadTS != "1700.100" ||
		input.MessageTS != "1700.300" || input.ActionID != "thumbsup" ||
		input.ActionValue != "1700.200" || input.UserID != "U123ABC" {
		t.Fatalf("added reaction input = %+v", input)
	}
	if err := st.RetrySlackInput(ctx, input.ID, "test release", time.Now(), false); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	admitReaction("EvReactionRemoved", "1700.400", "reaction_removed")
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	context, err := st.ListRecentWatchMessages(ctx, "CWATCH", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(context) != 2 || context[0].Kind != "reaction_added" ||
		context[1].Kind != "reaction_removed" {
		t.Fatalf("durable reaction context = %+v", context)
	}
	if len(coopClient.submitPrompts) != 0 {
		t.Fatalf("reactions started agent turns: %v", coopClient.submitPrompts)
	}

	message := WatchPromptMessage(context[1], "U999BOT", false)
	if message.SenderType != "human_reaction" || message.Text != "" ||
		len(message.Reactions) != 1 || message.Reactions[0].Change != "removed" ||
		message.Reactions[0].TargetMessageTS != "1700.200" {
		t.Fatalf("reaction prompt context = %+v", message)
	}
	current := WatchPromptMessage(core.SlackInput{
		Kind: "bot_message", UserID: "U999BOT", Text: "Production is healthy.",
		Reactions: []core.SlackReaction{{
			Name: "thumbsup", Count: 2, UserIDs: []string{"U123ABC", "U456DEF"},
		}},
	}, "U999BOT", false)
	if current.SenderType != "responder" || len(current.Reactions) != 1 ||
		current.Reactions[0].Count != 2 ||
		!slices.Equal(current.Reactions[0].UserIDs, []string{"U123ABC", "U456DEF"}) {
		t.Fatalf("current reaction state = %+v", current)
	}
}

func TestSocketIgnoresReactionsToOtherUsersMessages(t *testing.T) {
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
	payload, _ := json.Marshal(map[string]any{"event_id": "EvForeignReaction"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.ReactionAddedEvent{
					User: "U123ABC", Reaction: "eyes", ItemUser: "U456DEF",
					Item: slackevents.Item{
						Type: "message", Channel: "CWATCH", Timestamp: "1700.500",
					},
					EventTimestamp: "1700.600",
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-foreign-reaction", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("foreign reaction acknowledgements = %d", socket.acks)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("foreign reaction was admitted: %v", err)
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

	admitBotMessage := func(envelope, eventID, channel, botID, text string) {
		t.Helper()
		payload, _ := json.Marshal(map[string]any{"event_id": eventID})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID: cfg.Slack.TeamID,
				InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
					SubType: "bot_message", BotID: botID, Channel: channel,
					TimeStamp: "1700.4", Text: text,
				}},
			},
			Request: &socketmode.Request{EnvelopeID: envelope, Payload: payload},
		})
	}

	admitBotMessage("env-watch", "EvWatch", "CWATCH", "BEXTERNAL", "alert notification")
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "bot_message" || input.UserID != "BEXTERNAL" ||
		input.ChannelID != "CWATCH" {
		t.Fatalf("watched app message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}
	admitBotMessage(
		"env-planning", "EvPlanning", "CWATCH", "BTERRAFORM",
		"Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Planning",
	)
	input, err = st.LeaseSlackInput(ctx)
	if err != nil || input.EventID != "EvPlanning" {
		t.Fatalf("Terraform lifecycle message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}

	if err := st.SetSlackSetting(ctx, "global", "", proactiveSettingName, "on", "U123ABC"); err != nil {
		t.Fatal(err)
	}
	admitBotMessage("env-global", "EvGlobal", "CDYNAMIC", "BEXTERNAL", "alert notification")
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
	admitBotMessage("env-global-off", "EvGlobalOff", "CWATCH", "BEXTERNAL", "alert notification")
	admitBotMessage("env-other", "EvOther", "COTHER", "BEXTERNAL", "alert notification")
	admitBotMessage("env-self", "EvSelf", "CWATCH", "B999BOT", "alert notification")
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unwatched or self-authored app message was persisted: %v", err)
	}
	if socket.acks != 6 {
		t.Fatalf("acks = %d", socket.acks)
	}
}

func TestWatchedChannelDecisions(t *testing.T) {
	tests := []struct {
		name          string
		kind          string
		text          string
		decision      string
		alertPolicy   string
		wantState     string
		wantPosts     int
		wantIncidents int
		wantOffer     bool
		wantApproval  bool
		maxAttempts   int
	}{
		{
			name: "ignore", kind: "bot_message",
			decision: `{"action":"ignore"}`, wantState: "done",
		},
		{
			name: "reply", kind: "message",
			decision: `{"action":"reply","attention":{"addressee":"channel",` +
				`"urgency":1,"confidence":3,"novelty":2,"ownership":2,"contribution":"decision","material":true},` +
				`"operations":[{"id":"complete","type":"complete_episode","completion":{` +
				`"message":"The deploy recovered; checkout is serving normally again.",` +
				`"completion":{"status":"decision_ready","summary":"the deploy recovered"}}}]}`,
			wantState: "done", wantPosts: 1,
		},
		{
			name: "operator governed action awaits Emisar approval", kind: "message",
			text: "Enable origin certificate verification for this pull zone.",
			decision: `{"action":"reply","attention":{"addressee":"responder",` +
				`"urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},` +
				`"operations":[` +
				`{"id":"appr","type":"request_approval","approval":{"request_id":"apr_watch_1","run_id":"run_watch_1",` +
				`"operation_id":"op_watch_1","action_id":"bunny.pull_zone.update",` +
				`"pack_ref":"bunny@1.0.0#sha256:abc","runner_ref":"prod~abc",` +
				`"status":"pending_approval",` +
				`"approval_url":"https://emisar.dev/app/acme/approvals/apr_watch_1",` +
				`"expires_at":"2099-08-01T00:00:00Z"}},` +
				`{"id":"complete","type":"complete_episode","completion":{` +
				`"message":"Emisar accepted the exact request and paused it for approval.",` +
				`"completion":{"status":"decision_ready","summary":"approval is pending"}}}]}`,
			wantState: "done", wantPosts: 1, wantApproval: true,
		},
		{
			name: "incident", kind: "bot_message",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantIncidents: 1,
		},
		{
			name: "configured app alert offers incident", kind: "bot_message",
			alertPolicy: "offer",
			decision: `{"action":"reply","attention":{"addressee":"channel",` +
				`"urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},` +
				`"operations":[` +
				`{"id":"off-inc","type":"offer_task","task":{"kind":"incident","title":"Checkout error rate is elevated"}},` +
				`{"id":"complete","type":"complete_episode","completion":{` +
				`"message":"Checkout errors are elevated and need investigation.",` +
				`"completion":{"status":"decision_ready","summary":"checkout errors need investigation"}}}]}`,
			wantState: "done", wantPosts: 1, wantOffer: true,
		},
		{
			name: "configured app alert replies in place", kind: "bot_message",
			alertPolicy: "reply",
			decision: `{"action":"reply","attention":{"addressee":"channel",` +
				`"urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},` +
				`"operations":[{"id":"complete","type":"complete_episode","completion":{` +
				`"message":"Checkout errors are elevated and need investigation.",` +
				`"completion":{"status":"decision_ready","summary":"checkout errors need investigation"}}}]}`,
			wantState: "done", wantPosts: 1,
		},
		{
			name: "reply incident offer obeys automatic app policy", kind: "bot_message",
			alertPolicy: "automatic",
			decision: `{"action":"reply","attention":{"addressee":"channel",` +
				`"urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},` +
				`"operations":[` +
				`{"id":"off-inc","type":"offer_task","task":{"kind":"incident","title":"Checkout error rate is elevated"}},` +
				`{"id":"complete","type":"complete_episode","completion":{` +
				`"message":"The alert is credible.",` +
				`"completion":{"status":"decision_ready","summary":"the alert is credible"}}}]}`,
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
			wantState: "done", wantPosts: 0, maxAttempts: 1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			cfg.Slack.WatchChannels = []string{"CWATCH"}
			if test.maxAttempts > 0 {
				cfg.Limits.MaxAgentRunAttempts = test.maxAttempts
			}
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
			if test.alertPolicy != "" {
				if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
					ChannelID: "CWATCH", Participation: "proactive",
					Repository: "repo", AlertPolicy: test.alertPolicy,
					ActorID: "U123ABC",
				}); err != nil {
					t.Fatal(err)
				}
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
			finishQueuedAgentRun(t, ctx, svc)
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
				if slack.posts[0].thread != "" ||
					!strings.Contains(slack.posts[0].message.Text, "deploy recovered") {
					t.Fatalf("threaded watch reply = %+v", slack.posts[0])
				}
			}
			if test.wantApproval {
				message := slack.posts[0].message
				// Superseded: the header named the console, not the action, and
				// the promise to watch the request was a section between the
				// reply and the button. The header names the action id — a typed
				// identifier Emisar assigned — and the promise is a context line.
				if message.Header != "✋ Approval needed: bunny.pull_zone.update" ||
					message.Stripe != slackui.StripeNeedsYou ||
					len(message.Actions) != 1 ||
					message.Actions[0].ID != slackui.ActionOpenApproval ||
					message.Actions[0].URL != "https://emisar.dev/app/acme/approvals/apr_watch_1" ||
					!strings.Contains(strings.Join(message.Context, "\n"), "update this card automatically") ||
					strings.Contains(strings.Join(message.Sections, "\n"), "pinned card") {
					t.Fatalf("shared conversation approval card = %+v", message)
				}
				approval, err := st.Approvals.Get(ctx, "apr_watch_1")
				if err != nil || approval.IncidentID != "" ||
					approval.ChannelID != input.ChannelID || approval.SourceInput != input.ID ||
					approval.RequestedBy != input.UserID || approval.DeliveryID == "" ||
					approval.MessageTS == "" {
					t.Fatalf("shared conversation approval = %+v, %v", approval, err)
				}
				// The approval has no incident and must still name its owner.
				// source_input is a slack_inputs id and expires on the
				// operational horizon; the episode is what the completion path,
				// the remediation record and the trace page can still reach a
				// day later.
				run, runErr := st.GetAgentRunBySource(ctx, "watch", input.ID)
				if runErr != nil || run.EpisodeID == "" {
					t.Fatalf("watch run for the approval = %+v, %v", run, runErr)
				}
				if approval.EpisodeID != run.EpisodeID {
					t.Fatalf(
						"approval episode = %q, want the turn's episode %q",
						approval.EpisodeID, run.EpisodeID,
					)
				}
			}
			if test.name == "malformed" {
				run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
				if err != nil || run.State != core.AgentRunCompleted || run.LastError != "" {
					t.Fatalf("malformed result continuation = %+v, %v", run, err)
				}
				episode, episodeErr := st.GetWorkEpisode(ctx, run.EpisodeID)
				if episodeErr != nil || episode.State != core.EpisodeBlocked ||
					episode.NextAction == "" {
					t.Fatalf("malformed result episode = %+v, %v", episode, episodeErr)
				}
			}
			if test.wantOffer {
				message := slack.posts[0].message
				if len(message.Actions) != 1 ||
					message.Actions[0].ID != slackui.ActionOpenIncident ||
					message.Actions[0].Value != input.ID {
					t.Fatalf("human incident confirmation = %+v", message)
				}
				if strings.Contains(strings.ToLower(message.Text), "no incident") ||
					strings.Contains(strings.ToLower(message.Text), "channel is configured") {
					t.Fatalf("incident policy leaked into operator prose = %+v", message)
				}
				run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
				if err != nil {
					t.Fatal(err)
				}
				state, err := decodeWatchRunContext(run)
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
				!strings.Contains(coopClient.submitPrompts[0], "Active full workspace members may confirm") {
				t.Fatalf("watch Coop calls = keys=%v prompts=%v",
					coopClient.createKeys, coopClient.submitPrompts)
			}
		})
	}
}

func TestWatchedCorrectionExhaustionQueuesBlockedNotice(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 1
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
		EventID: "EvWatchFailure", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.700", UserID: "U123ABC",
		Text: "<@U999BOT> How is production health?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatalf("agent finalization should not depend on Slack: %v", err)
	}
	for range 4 {
		err := svc.processSlackDelivery(ctx, nil)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "done" {
		t.Fatalf("stored input = %+v", stored)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted || run.LastError != "" {
		t.Fatalf("durable blocked run = %+v, %v", run, err)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "couldn't finish this check safely yet") {
		t.Fatalf("blocked notice attempt = %+v", slack.posts)
	}
	if len(slack.statuses) == 0 {
		t.Fatal("targeted blocked continuation lost its pending status")
	}
}

func TestWatchStructuredCorrectionBudgetIsIndependentFromRunFailures(t *testing.T) {
	state := decisionpkg.WatchTurnState{}
	first := consumeWatchStructuredCorrection(&state, 1, 4)
	second := consumeWatchStructuredCorrection(&state, 1, 4)
	third := consumeWatchStructuredCorrection(&state, 1, 4)
	fourth := consumeWatchStructuredCorrection(&state, 1, 4)
	if first || second || third || !fourth ||
		state.StructuredCorrections != 4 {
		t.Fatalf("watch correction state = %+v", state)
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
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
	  "operations":[
	    {"id":"cov-change","type":"record_coverage","coverage":{"layer":"change","status":"unknown","detail":"The deployed revision was not available"}},
	    {"id":"cov-host","type":"record_coverage","coverage":{"layer":"host","status":"unhealthy","source":"Emisar","detail":"Two production runners are disconnected"}},
	    {"id":"cov-runtime","type":"record_coverage","coverage":{"layer":"runtime","status":"unknown","detail":"Disconnected runners cannot be queried"}},
	    {"id":"cov-workload","type":"record_coverage","coverage":{"layer":"workload","status":"unknown","detail":"Workload placement was not available"}},
	    {"id":"cov-dependency","type":"record_coverage","coverage":{"layer":"dependency","status":"unknown","detail":"Dependency health was not available"}},
	    {"id":"cov-application","type":"record_coverage","coverage":{"layer":"application","status":"unknown","detail":"Application probes were not available"}},
	    {"id":"cov-slo","type":"record_coverage","coverage":{"layer":"slo","status":"unknown","detail":"Customer impact was not available"}},
	    {"id":"off-inc","type":"offer_task","task":{"kind":"incident","title":"Two production runners disconnected"}},
	    {"id":"complete","type":"complete_episode","completion":{
	      "message":"Two production runners are disconnected.",
	      "completion":{"status":"blocked","summary":"Two runners are disconnected and the production impact cannot yet be bounded.","material_gaps":["workload placement and customer impact"],"blocker_kind":"source_unavailable","attempts":["Queried the configured live source; disconnected runners could not return workload or application evidence"],"next_action":"Restore runner connectivity or provide an authoritative workload and customer-impact source"}}}
	  ]
	}`
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
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].thread != "" ||
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
			MessageTS: "1700.001", UserID: userID,
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

	stale := core.SlackInput{
		ID: "incident-offer-stale", EnvelopeID: "env-incident-offer-stale",
		EventID: "event-incident-offer-stale", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
		MessageTS: "1700.999", UserID: "U123ABC",
		ActionID: slackui.ActionOpenIncident, ActionValue: source.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, stale); err != nil || !created {
		t.Fatalf("admit stale = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatalf("process stale: %v", err)
	}
	if len(slackClient.ephemerals) != 2 ||
		!strings.Contains(slackClient.ephemerals[1].message.Text, "stale") {
		t.Fatalf("stale offer response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("stale click created incident = %+v, %v", incidents, err)
	}

	click("incident-offer-authorized", "U123ABC")
	click("incident-offer-repeated", "U123ABC")
	drainSlackDeliveries(t, ctx, svc)
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("authorized offer incidents = %+v, %v", incidents, err)
	}
	if len(slackClient.posts) != 2 ||
		slackClient.posts[1].thread != "" ||
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

func TestWatchedScheduleAndRunbookRequestUsesEmisarAndOffersSchedule(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		dedupePosts: true,
		history: []slackui.HistoryMessage{
			{Timestamp: "1700.800", UserID: "U123ABC", Text: "Can you post a daily deep infrastructure health review around 9 am? Maybe make a reusable runbook for it too."},
			{Timestamp: "1700.850", ThreadTS: "1700.800", UserID: "U123ABC", Text: "Try again <@U999BOT>"},
		},
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},
		"reason":"the operator requested an Emisar runbook and recurring execution",
		"operations":[
			{"id":"ev-1","type":"record_evidence","evidence":{"claim_id":"task.requested_outcome","claim":"the runbook is published","observation":"Emisar published deep-infrastructure-health@1","source_type":"emisar","source_name":"publish_runbook"}},
			{"id":"off-sched","type":"offer_schedule","schedule_offer":{
				"title":"Daily deep infrastructure health review",
				"prompt":"Execute the exact published Emisar runbook deep-infrastructure-health@1 with fresh evidence and report the result.",
				"repository":"repo",
				"recurrence":"daily",
				"local_time":"09:00",
				"timezone":"UTC",
				"catch_up":"latest",
				"expires_in":"365d"
			}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"I created and published the reusable Emisar runbook deep-infrastructure-health@1. Confirm the daily schedule below.",
				"completion":{"status":"decision_ready","summary":"the runbook is published and the schedule awaits confirmation"}}}
		]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-schedule-runbook", EnvelopeID: "env-schedule-runbook",
		EventID: "event-schedule-runbook", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", ThreadTS: "1700.800", MessageTS: "1700.850", UserID: "U123ABC",
		Text: "Try again <@U999BOT>",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("compound offer posts = %+v", slackClient.posts)
	}
	message := slackClient.posts[0].message
	// Supersedes the flat-Actions/Sections form: the proposal is a row and its
	// confirmation is attached to it.
	offerText := strings.Join(message.Sections, "\n")
	for _, row := range message.Rows {
		offerText += "\n" + row.Text
	}
	if len(message.Rows) != 1 || len(message.Rows[0].Actions) != 1 ||
		message.Rows[0].Actions[0].ID != slackui.ActionRememberSchedule ||
		!strings.Contains(offerText, "Daily deep infrastructure health review") ||
		!strings.Contains(offerText, "deep-infrastructure-health@1") ||
		strings.Contains(offerText, "engineering task") {
		t.Fatalf("compound offer = %+v", message)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || state.OfferedTaskTitle != "" || state.OfferedTaskRepository != "" {
		t.Fatalf("runbook request became a repository task = %+v, %v", state, err)
	}
	if schedules, err := st.Schedules.ListScheduledTasksForChannel(ctx, source.ChannelID, 10); err != nil || len(schedules) != 0 {
		t.Fatalf("schedule was created before confirmation = %+v, %v", schedules, err)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("engineering task was created before confirmation = %+v, %v", incidents, err)
	}
}

func TestActivateItReconstructsAndUpdatesDailyScheduleWithoutAnotherConfirmation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	existing, err := st.Schedules.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", ThreadTS: "1700.800", DeliveryChannel: "CREPORTS",
		Repository: "repo", Title: "Daily report v3", Prompt: "Execute whole-platform-health-review-v3@3.",
		Recurrence: "daily", StartAt: now.Add(time.Hour), LocalTime: "09:00", Timezone: "America/Mexico_City",
		CatchUp: "latest", ActorID: cfg.Slack.Operators[0], SourceRef: "old-schedule",
		NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(90 * 24 * time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{
		dedupePosts: true,
		channel:     slackui.Channel{ID: "CREPORTS", Name: "reports", Member: true},
		history: []slackui.HistoryMessage{
			{Timestamp: "1700.800", UserID: "U123ABC", Text: "Published, use whole-platform-health-review-v5@5 for daily reports."},
			{Timestamp: "1700.820", ThreadTS: "1700.800", UserID: "U999BOT", BotID: "B999BOT", Text: "The runbook is ready; activating the recurring 09:00 delivery remains."},
			{Timestamp: "1700.850", ThreadTS: "1700.800", UserID: "U123ABC", Text: "activate it"},
		},
	}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{`{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		"reason":"the operator explicitly activated the established daily report",
		"operations":[
			{"id":"complete","type":"complete_episode","completion":{
				"message":"Activated. The daily report will run at 09:00.",
				"completion":{"status":"decision_ready","verdict":"completed","summary":"The daily report is active."}}}
		]
	}`, `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		"reason":"the operator explicitly activated the established daily report",
		"operations":[
			{"id":"off-sched","type":"offer_schedule","schedule_offer":{
				"prompt":"Execute whole-platform-health-review-v5@5 with fresh evidence and report actionable findings.",
				"repository":"repo",
				"recurrence":"daily",
				"local_time":"09:00",
				"catch_up":"latest"
			}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"The daily report is ready.",
				"completion":{"status":"decision_ready","summary":"the daily report schedule is ready"}}}
		]
	}`}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT"}
	input := core.SlackInput{
		ID: "slack-activate-daily", EnvelopeID: "env-activate-daily", EventID: "event-activate-daily",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", ThreadTS: "1700.800",
		MessageTS: "1700.850", UserID: "U123ABC", Text: "activate it <@U999BOT>",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit activation = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	// Failures stays 0: a correction round is not a failed attempt. The
	// LastError beside it is what proves the correction happened.
	if err != nil || run.State != core.AgentRunPending || run.Failures != 0 ||
		!strings.Contains(run.LastError, "typed schedule_offer") {
		t.Fatalf("plain activation claim was not corrected = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("false activation reached Slack: %+v", slackClient.posts)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("activation posts = %+v", slackClient.posts)
	}
	message := slackClient.posts[0].message
	for _, action := range message.Actions {
		if action.ID == slackui.ActionRememberSchedule {
			t.Fatalf("activation asked for another confirmation: %+v", message)
		}
	}
	if !strings.Contains(strings.ToLower(message.Text), "scheduled") {
		t.Fatalf("activation receipt = %+v", message)
	}
	schedules, err := st.Schedules.ListScheduledTasksForChannel(ctx, "CWATCH", 10)
	if err != nil || len(schedules) != 1 {
		t.Fatalf("daily schedules = %+v, err=%v", schedules, err)
	}
	if schedules[0].ID != existing.ID || !strings.Contains(schedules[0].Prompt, "v5@5") ||
		schedules[0].Title != existing.Title || schedules[0].DeliveryChannel != "CREPORTS" ||
		schedules[0].Timezone != "America/Mexico_City" {
		t.Fatalf("updated daily schedule = %+v", schedules[0])
	}
}

func TestWatchedCompoundRequestPostsOrderedMessagesInOneThread(t *testing.T) {
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
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},
		"reason":"the operator requested three independent read-only outcomes",
		"operations":[
			{"id":"ev-1","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"CI passed","observation":"All required jobs succeeded","relation":"supports","health_effect":"none","source_type":"other","source_name":"CI","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},
			{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","source":"CI","detail":"Current revision checks passed"}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"**CI:** all required checks passed for the current revision.",
				"followup_messages":[
					"**Deployments:** production is waiting for one approval; no failed rollout was observed.",
					"**Incidents:** two remain open, and the database-latency incident is the higher priority."
				],
				"completion":{"status":"decision_ready","summary":"CI, deployments and incidents are all reported"}}}
		]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-compound-read", EnvelopeID: "env-compound-read",
		EventID: "event-compound-read", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.860", UserID: "U123ABC",
		Text: "Check CI, tell me deployment status, and summarize the two active operational investigations.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 3 {
		t.Fatalf("compound reply posts = %+v", slackClient.posts)
	}
	for _, post := range slackClient.posts {
		if post.channel != source.ChannelID || post.thread != "" {
			t.Fatalf("compound reply changed destination = %+v", slackClient.posts)
		}
	}
	for index, expected := range []string{"CI", "Deployments", "Incidents"} {
		if !strings.Contains(slackClient.posts[index].message.Text, expected) {
			t.Fatalf("compound reply order = %+v", slackClient.posts)
		}
	}
	if strings.Contains(strings.Join(slackClient.posts[0].message.Context, "\n"), "Details saved") ||
		!strings.Contains(strings.Join(slackClient.posts[2].message.Context, "\n"), "Details saved") {
		t.Fatalf("evidence summary was not confined to final reply = %+v", slackClient.posts)
	}
}

func TestWatchedEngineeringRequestStaysInSourceThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	const screenshotURL = "https://files.slack.com/files-pri/T-F/task.png"
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive", Repository: cfg.Slack.DefaultRepository,
		AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{
		dedupePosts: true,
		files:       map[string][]byte{screenshotURL: testPNG},
		deniedUsers: map[string]bool{"UGUEST": true},
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
			"action":"reply",
			"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
			"operations":[
				{"id":"off-task","type":"offer_task","task":{"kind":"engineering","title":"Audit infrastructure packs"}},
				{"id":"complete","type":"complete_episode","completion":{
					"message":"I can audit and update infra/ in a dedicated isolated working copy.",
					"followup_messages":["I will keep unrelated application settings unchanged."]}}
			]
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
		Attachments: []core.SlackAttachment{{
			ID: "FTASK", Name: "task.png", MediaType: "image/png",
			Size: int64(len(testPNG)), URLPrivate: screenshotURL,
		}},
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].thread != "" ||
		len(slackClient.posts[0].message.Actions) != 1 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionStartTask ||
		slackClient.posts[0].message.Actions[0].Value != source.ID {
		t.Fatalf("engineering task offer = %+v", slackClient.posts)
	}
	offerText := slackClient.posts[0].message.Text + "\n" +
		strings.Join(slackClient.posts[0].message.Sections, "\n")
	if !strings.Contains(offerText, "audit and update infra/") ||
		!strings.Contains(offerText, "unrelated application settings") {
		t.Fatalf("multi-part engineering task offer was not consolidated = %+v", slackClient.posts[0].message)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
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
			MessageTS: "1700.001", UserID: userID,
			ActionID: slackui.ActionStartTask, ActionValue: source.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
	}
	click("engineering-task-guest", "UGUEST")
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "Only active full members") {
		t.Fatalf("ineligible engineering task response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("ineligible click created task = %+v, %v", incidents, err)
	}
	stale := core.SlackInput{
		ID: "engineering-task-stale", EnvelopeID: "env-engineering-task-stale",
		EventID: "event-engineering-task-stale", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
		MessageTS: "1700.999", UserID: "U123ABC",
		ActionID: slackui.ActionStartTask, ActionValue: source.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, stale); err != nil || !created {
		t.Fatalf("admit stale = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatalf("process stale: %v", err)
	}
	if len(slackClient.ephemerals) != 2 ||
		!strings.Contains(slackClient.ephemerals[1].message.Text, "stale") {
		t.Fatalf("stale task response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("stale click created task = %+v, %v", incidents, err)
	}
	click("engineering-task-member", "UOTHER")
	drainSlackDeliveries(t, ctx, svc)
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || !incidents[0].IsEngineeringTask() {
		t.Fatalf("engineering task = %+v, %v", incidents, err)
	}
	if !incidents[0].IsThreadScoped() ||
		incidents[0].OriginChannelID != source.ChannelID ||
		incidents[0].OriginThreadTS != source.MessageTS {
		t.Fatalf("engineering task scope = %+v", incidents[0])
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("engineering task added standalone acknowledgement = %+v", slackClient.posts)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Labels["work_kind"] != "engineering_task" ||
		signals[0].Summary != source.Text {
		t.Fatalf("engineering task source = %+v, %v", signals, err)
	}
	if slackClient.createChannelCalls != 0 {
		t.Fatalf("thread task created %d Slack channels", slackClient.createChannelCalls)
	}
	// The offer message is not the task card. Starting the task binds the
	// thread and posts the card as its own new reply, exactly as when a task
	// starts any other way; the message that carried the button is left alone.
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	incidents, err = st.ListIncidents(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	task := incidents[0]
	if task.ChannelID != source.ChannelID || task.RootTS == "" ||
		task.ConversationThreadTS() != source.MessageTS {
		t.Fatalf("bound thread task = %+v", task)
	}
	if task.RootTS == "1700.001" {
		t.Fatalf("task consumed the clicked offer message = %+v", task)
	}
	if len(slackClient.posts) != 2 || slackClient.posts[1].outboxID != "out_root_"+task.ID {
		t.Fatalf("task card was not posted as its own message = %+v", slackClient.posts)
	}
	taskCard := slackClient.posts[1]
	// The fallback leads with the state word rather than the work's category,
	// because a notification strips the stripe and the glyph and that word is
	// the only thing left carrying whose turn it is.
	if taskCard.channel != source.ChannelID || taskCard.thread != source.MessageTS ||
		!strings.HasPrefix(taskCard.message.Text, "Working — ") {
		t.Fatalf("thread task card = %+v", taskCard)
	}
	// The whole complaint: clicking the button used to rewrite the reply that
	// carried it, so the evidence the operator was reading was destroyed by
	// acting on it. Nothing may edit that message.
	for _, update := range slackClient.updates {
		if update.ts == "1700.001" {
			t.Fatalf("starting the task rewrote the offer message = %+v", update)
		}
	}
	// Clicking again is a no-op rather than a second task: the source event ID
	// already has a row, so the insert is ignored and no initial turn is
	// queued. Nothing has to neutralize the button for that to hold.
	click("engineering-task-second", "UOTHER")
	drainSlackDeliveries(t, ctx, svc)
	if again, err := st.ListIncidents(ctx, 10); err != nil || len(again) != 1 ||
		again[0].ID != task.ID || again[0].RootTS != task.RootTS {
		t.Fatalf("second click on the offer = %+v, %v", again, err)
	}
	if len(slackClient.posts) != 2 {
		t.Fatalf("second click posted again = %+v", slackClient.posts)
	}
	for _, update := range slackClient.updates {
		if update.ts == "1700.001" {
			t.Fatalf("second click rewrote the offer message = %+v", update)
		}
	}
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.createPolicies) == 0 ||
		coopClient.createPolicies[len(coopClient.createPolicies)-1] != "repo-contributor" {
		t.Fatalf("member task Coop policy = %v", coopClient.createPolicies)
	}
	for count := 0; count < 4; count++ {
		err := svc.processSlackDelivery(ctx, nil)
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
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	taskPrompt := coopClient.submitPrompts[len(coopClient.submitPrompts)-1]
	taskArtifacts := coopClient.submitArtifacts[len(coopClient.submitArtifacts)-1]
	if len(taskArtifacts) != 1 || taskArtifacts[0].Name != "task.png" ||
		string(taskArtifacts[0].Data) != string(testPNG) {
		t.Fatalf("engineering task lost source attachment = %+v", taskArtifacts)
	}
	for _, required := range []string{
		"Complete this workspace-member-confirmed engineering task",
		"Repository code and repository-owned configuration changes are allowed",
		"does not provide shared operational MCP tools or environment secrets",
		"Do not apply configuration, merge, push, deploy, sign, mutate live systems",
	} {
		if !strings.Contains(taskPrompt, required) {
			t.Fatalf("dedicated task prompt lacks %q:\n%s", required, taskPrompt)
		}
	}

	followup := core.SlackInput{
		ID: "task-thread-followup", EnvelopeID: "env-task-thread-followup",
		EventID: "event-task-thread-followup", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: source.ChannelID, ThreadTS: source.MessageTS, MessageTS: "1700.902",
		UserID: "UCOLLEAGUE", Text: "Also update the operations documentation.",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit task follow-up = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	queued, err := st.GetAgentRunBySource(ctx, "slack", followup.ID)
	if err != nil || queued.IncidentID != task.ID {
		t.Fatalf("thread follow-up routing = %+v, %v", queued, err)
	}
	if !strings.Contains(queued.Prompt, "active full workspace members") ||
		!strings.Contains(queued.Prompt, "authoritative for repository code") ||
		!strings.Contains(queued.Prompt, "Format every user-visible answer") ||
		strings.Contains(queued.Prompt, "allowlisted incident operator") {
		t.Fatalf("task teammate prompt = %q", queued.Prompt)
	}

	guestFollowup := core.SlackInput{
		ID: "task-thread-guest", EnvelopeID: "env-task-thread-guest",
		EventID: "event-task-thread-guest", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: source.ChannelID, ThreadTS: source.MessageTS, MessageTS: "1700.9025",
		UserID: "UGUEST", Text: "Push this through without review.",
	}
	if created, err := st.AdmitSlackInput(ctx, guestFollowup); err != nil || !created {
		t.Fatalf("admit guest task follow-up = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if queued, err := st.GetAgentRunBySource(ctx, "slack", guestFollowup.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("ineligible guest entered task session = %+v, %v", queued, err)
	}
	if len(slackClient.ephemerals) == 0 ||
		!strings.Contains(slackClient.ephemerals[len(slackClient.ephemerals)-1].message.Text, "Only active full members") {
		t.Fatalf("guest task follow-up refusal = %+v", slackClient.ephemerals)
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
	if queued, err := st.GetAgentRunBySource(ctx, "slack", unrelated.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unrelated message entered task session = %+v, %v", queued, err)
	}
}

func TestWatchedEngineeringOfferConditionsPrimaryReplyOnConfirmation(t *testing.T) {
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
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		"operations":[
			{"id":"off-task","type":"offer_task","task":{"kind":"engineering","title":"Reduce Cassandra disk-latency alert noise","repository":"repo"}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"Yes — I’ll prepare a PR to require a sustained latency condition before this warning fires. I’ll also review the device wording."}}
		]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID:         "slack-conditional-engineering-offer",
		EnvelopeID: "env-conditional-engineering-offer",
		EventID:    "event-conditional-engineering-offer",
		Kind:       "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.950", UserID: "U123ABC",
		Text: "Make a PR to reduce noise from brief latency spikes.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("engineering task offer posts = %+v", slackClient.posts)
	}
	offer := slackClient.posts[0].message
	for field, content := range map[string]string{
		"text": offer.Text, "markdown": offer.Markdown,
	} {
		if strings.Contains(content, "Confirm the engineering task below") ||
			!strings.Contains(content, "prepare a PR") {
			t.Errorf("engineering task offer %s repeats transition boilerplate: %q", field, content)
		}
	}
	if len(offer.Actions) != 1 ||
		!strings.Contains(offer.Actions[0].Confirm, "cannot merge or deploy") {
		t.Fatalf("engineering task confirmation boundary = %+v", offer.Actions)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("engineering task started before confirmation = %+v, %v", incidents, err)
	}
}

func TestDecisionReadyDiagnosisOffersIncidentAndPreparedFix(t *testing.T) {
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
	const taskPrompt = "Update the LoL rank decoder to treat unknown upstream rank values as unranked, add focused regression tests for WOOD and SALT, and verify the exact production error signature is absent after deployment."
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},
		"operations":[
			{"id":"ev-1","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"the decoder is strict","observation":"the repository decoder enumerates rank values","source_type":"repository","source_name":"lib/rank.ex"}},
			{"id":"cov-1","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"degraded","detail":"LoL requests fail on new rank values"}},
			{"id":"finding-1","type":"record_finding","finding":{"what":"LoL requests are failing on new upstream rank values","scope":"lol-api","status":"explained","cause_evidence":["ev-1"],"alternatives":[{"hypothesis":"the upstream API changed its response envelope","discriminated_by":"ev-1"}]}},
			{"id":"alert","type":"record_alert_assessment","alert_assessment":{
				"verdict":"confirmed_issue",
				"impact":"LoL requests fail continuously.",
				"cause_status":"identified",
				"cause":"The decoder rejects WOOD and SALT rank values.",
				"immediate_action":"Treat unknown values as unranked.",
				"verification":"Confirm the exact errors disappear after deployment.",
				"long_term_solution":"Use forward-compatible rank decoding with telemetry."
			}},
			{"id":"off-inc","type":"offer_task","task":{"kind":"incident","title":"Coordinate LoL request degradation"}},
			{"id":"off-task","type":"offer_task","task":{"kind":"engineering","title":"Make LoL rank decoding forward-compatible","repository":"repo","prompt":` + fmt.Sprintf("%q", taskPrompt) + `}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"LoL requests are failing because the rank decoder rejects new upstream values.",
				"completion":{"status":"decision_ready","summary":"The failure and fix boundary are established."}}}
		]
	}`
	if _, err := decisionpkg.ParseWatchDecision(coopClient.completeOnSubmit, testDecodeClock); err != nil {
		t.Fatalf("parse diagnosis decision: %v", err)
	}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-diagnosed-fix", EnvelopeID: "env-diagnosed-fix",
		EventID: "event-diagnosed-fix", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1701.100", UserID: "U123ABC",
		Text: "<@U999BOT> Why are LoL requests failing?",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 || len(slackClient.posts[0].message.Actions) != 2 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionOpenIncident ||
		slackClient.posts[0].message.Actions[1].ID != slackui.ActionStartTask ||
		slackClient.posts[0].message.Actions[1].Label != "Prepare code fix" {
		run, _ := st.GetAgentRunBySource(ctx, "watch", source.ID)
		t.Fatalf("diagnosis offers = %+v; run = %+v", slackClient.posts, run)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || state.OfferedTaskPrompt != taskPrompt ||
		state.OfferedIncidentTitle == "" || state.OfferedTaskTitle == "" {
		t.Fatalf("persisted diagnosis offers = %+v, %v", state, err)
	}
	click := core.SlackInput{
		ID: "prepare-diagnosed-fix", EnvelopeID: "env-prepare-diagnosed-fix",
		EventID: "event-prepare-diagnosed-fix", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
		MessageTS: "1700.001", UserID: "U123ABC",
		ActionID: slackui.ActionStartTask, ActionValue: source.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, click); err != nil || !created {
		t.Fatalf("admit click = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || !incidents[0].IsEngineeringTask() {
		t.Fatalf("prepared fix task = %+v, %v", incidents, err)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 || signals[0].Summary != taskPrompt {
		t.Fatalf("prepared fix objective = %+v, %v", signals, err)
	}
}

func TestDecisionReadyFactualAssessmentCanOfferSourceBackedFix(t *testing.T) {
	decision, err := decisionpkg.ParseWatchDecision(`{
		"action":"reply",
		"operations":[
			{"id":"evidence-source","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"The source fix is bounded.","observation":"Two optional jq regex calls have core-operation replacements.","relation":"supports","health_effect":"none","source_type":"repository","source_name":"packs/hcp-terraform","confidence":"high"}},
			{"id":"offer-fix","type":"offer_task","task":{"kind":"engineering","title":"Make HCP inspection portable","repository":"repo","prompt":"Replace the two regex-dependent jq expressions, preserve semantics, and add focused compatibility coverage."}},
			{"id":"complete","type":"complete_episode","completion":{"message":"The inspection fix is bounded; the failed apply remains unverified.","completion":{"status":"decision_ready","verdict":"not_confirmed","summary":"The source fix is known, but apply effects are not confirmed."}}}
		]
	}`, testDecodeClock)
	if err != nil {
		t.Fatalf("parse decision-ready source fix: %v", err)
	}
	if decision.TaskTitle != "Make HCP inspection portable" ||
		decision.TaskRepository != "repo" || decision.TaskPrompt == "" {
		t.Fatalf("decision-ready source fix = %+v", decision)
	}

	decision.Completion = &CompletionAssessment{
		Status: "blocked", BlockerKind: "source_unavailable",
	}
	if decisionpkg.ValidSuggestedEngineeringTaskBoundary(decision) {
		t.Fatal("source-unavailable blocker unexpectedly allowed a suggested code fix")
	}
}

func TestWatchOfferActionMatchesExactThreadedDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	source := core.SlackInput{
		ID: "threaded-offer-source", ChannelID: "CWATCH",
		ThreadTS: "1700.700", MessageTS: "1700.701",
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: source.ChannelID, ThreadTS: source.ThreadTS,
		ConversationKey: "channel:CWATCH:threaded-offer", SourceKind: "watch", SourceID: source.ID,
		IdempotencyKey: "run:threaded-offer:recovery_2",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + source.ID + "_exec_12345678", Kind: "notice",
		ChannelID: source.ChannelID, ThreadTS: source.ThreadTS,
		Body: []byte(`{"text":"offer"}`), SourceInputID: source.ID,
		AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey, ResponseRoot: true,
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(
		ctx,
		delivery.ID,
		"1700.702",
		"sending",
	); err != nil {
		t.Fatal(err)
	}
	matching := core.SlackInput{
		ChannelID: source.ChannelID,
		ThreadTS:  source.ThreadTS,
		MessageTS: "1700.702",
	}
	matches, err := svc.watchOfferActionMatchesDelivery(ctx, matching, source)
	if err != nil || !matches {
		t.Fatalf("matching threaded offer = %v, %v", matches, err)
	}
	for name, input := range map[string]core.SlackInput{
		"wrong channel": {
			ChannelID: "COTHER", ThreadTS: source.ThreadTS, MessageTS: "1700.702",
		},
		"wrong thread": {
			ChannelID: source.ChannelID, ThreadTS: "1700.799", MessageTS: "1700.702",
		},
		"wrong message": {
			ChannelID: source.ChannelID, ThreadTS: source.ThreadTS, MessageTS: "1700.799",
		},
	} {
		t.Run(name, func(t *testing.T) {
			matches, err := svc.watchOfferActionMatchesDelivery(ctx, input, source)
			if err != nil || matches {
				t.Fatalf("mismatched threaded offer = %v, %v", matches, err)
			}
		})
	}

	multipartSource := core.SlackInput{
		ID: "multipart-offer-source", ChannelID: "CWATCH",
		ThreadTS: "1700.800", MessageTS: "1700.801",
	}
	multipartRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: multipartSource.ChannelID, ThreadTS: multipartSource.ThreadTS,
		ConversationKey: "channel:CWATCH:multipart-offer", SourceKind: "watch", SourceID: multipartSource.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, part := range []struct {
		id        string
		messageTS string
	}{
		{id: "watch_reply_" + multipartSource.ID + "_part_001", messageTS: "1700.802"},
		{id: "watch_reply_" + multipartSource.ID + "_part_999", messageTS: "1700.803"},
	} {
		if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: part.id, Kind: "notice", ChannelID: multipartSource.ChannelID,
			ThreadTS: multipartSource.ThreadTS, Body: []byte(`{"text":"offer part"}`),
			SourceInputID: multipartSource.ID, AgentRunID: multipartRun.ID,
			AgentRunKey: multipartRun.IdempotencyKey, ResponseRoot: part.id == "watch_reply_"+multipartSource.ID+"_part_999",
		}); err != nil {
			t.Fatal(err)
		}
		delivery, err := st.LeaseSlackDelivery(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		if delivery.ID != part.id {
			t.Fatalf("leased multipart delivery = %q, want %q", delivery.ID, part.id)
		}
		if err := st.FinishSlackDelivery(
			ctx,
			delivery.ID,
			part.messageTS,
			"sending",
		); err != nil {
			t.Fatal(err)
		}
	}
	finalPart := core.SlackInput{
		ChannelID: multipartSource.ChannelID,
		ThreadTS:  multipartSource.ThreadTS,
		MessageTS: "1700.803",
	}
	matches, err = svc.watchOfferActionMatchesDelivery(ctx, finalPart, multipartSource)
	if err != nil || !matches {
		t.Fatalf("multipart final offer = %v, %v", matches, err)
	}
	earlierPart := finalPart
	earlierPart.MessageTS = "1700.802"
	matches, err = svc.watchOfferActionMatchesDelivery(ctx, earlierPart, multipartSource)
	if err != nil || matches {
		t.Fatalf("multipart earlier offer = %v, %v", matches, err)
	}

	visualSource := core.SlackInput{
		ID: "visual-offer-source", ChannelID: "CWATCH",
		ThreadTS: "1700.900", MessageTS: "1700.901",
	}
	visualRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: visualSource.ChannelID, ThreadTS: visualSource.ThreadTS,
		ConversationKey: "channel:CWATCH:visual-offer", SourceKind: "watch", SourceID: visualSource.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + visualSource.ID + "_visual_01", Operation: "file", Kind: "visual",
		ChannelID: visualSource.ChannelID, ThreadTS: visualSource.ThreadTS,
		Body: []byte(`{"title":"offer chart"}`), SourceInputID: visualSource.ID,
		AgentRunID: visualRun.ID, AgentRunKey: visualRun.IdempotencyKey, ResponseRoot: true,
	}); err != nil {
		t.Fatal(err)
	}
	visualDelivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, visualDelivery.ID, "1700.902", "sending"); err != nil {
		t.Fatal(err)
	}
	matches, err = svc.watchOfferActionMatchesDelivery(ctx, core.SlackInput{
		ChannelID: visualSource.ChannelID, ThreadTS: visualSource.ThreadTS, MessageTS: "1700.902",
	}, visualSource)
	if err != nil || !matches {
		t.Fatalf("visual offer = %v, %v", matches, err)
	}
}

// A shadow channel answers the person who said its name, and nobody else.
//
// Shadow covered only message and bot_message, so a channel an operator had set
// to observe-only still replied to anyone who typed the bot's name — including
// the operator writing "do not reply to any of the messages in this channel,
// you are here only to observe events", which drew a reply into the channel it
// was asking for quiet in. The setting says "without posting"; a mention is not
// an exception to that.
//
// It does not go silently dead either. Somebody who says the name is owed an
// answer, and gets it ephemerally, so the channel stays quiet and the asker is
// not waiting on a reply that is never coming.
func TestAShadowChannelAnswersAMentionPrivatelyAndPostsNothing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	mention := core.SlackInput{
		ID: "slack_shadow_mention", EnvelopeID: "env_shadow_mention",
		EventID: "ev_shadow_mention", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CSHADOW", MessageTS: "1700.001", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> do not reply to any of the messages in this channel",
	}
	if admitted, err := st.AdmitSlackInput(ctx, mention); err != nil || !admitted {
		t.Fatalf("admit mention = %t, %v", admitted, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.finishShadowedWatchDecision(
		ctx, mention, decisionpkg.WatchTurnState{}, decisionpkg.WatchDecision{Action: "reply"},
	); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("a shadow channel was posted to: %+v", slackClient.posts)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("the mention got no answer at all: %+v", slackClient.ephemerals)
	}
	if slackClient.ephemerals[0].user != cfg.Slack.Operators[0] {
		t.Errorf("the answer went to %q, not the person who asked",
			slackClient.ephemerals[0].user)
	}
	if !strings.Contains(slackClient.ephemerals[0].message.Text, "observe only") {
		t.Errorf("the answer does not say why it is quiet: %q",
			slackClient.ephemerals[0].message.Text)
	}

	// A recheck stays fully silent too. This is the kind that escaped the
	// allowlist after the mention did: the bot_message that started the
	// investigation was silenced correctly, its recheck fired half an hour
	// later, and the blocked notice posted into the channel anyway.
	slackClient.posts, slackClient.ephemerals = nil, nil
	recheck := mention
	recheck.ID, recheck.Kind, recheck.UserID = "slack_shadow_recheck", "recheck", "U123ABC"
	recheck.EnvelopeID, recheck.EventID = "env_shadow_recheck", "ev_shadow_recheck"
	if admitted, err := st.AdmitSlackInput(ctx, recheck); err != nil || !admitted {
		t.Fatalf("admit recheck = %t, %v", admitted, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.finishShadowedWatchDecision(
		ctx, recheck, decisionpkg.WatchTurnState{}, decisionpkg.WatchDecision{Action: "reply"},
	); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 || len(slackClient.ephemerals) != 0 {
		t.Fatalf("a shadowed recheck was answered: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}

	// A bot alert in the same channel stays fully silent: nobody asked, so
	// there is nobody to answer.
	slackClient.posts, slackClient.ephemerals = nil, nil
	alert := mention
	alert.ID, alert.Kind, alert.UserID = "slack_shadow_alert", "bot_message", "BEXTERNAL"
	alert.EnvelopeID, alert.EventID = "env_shadow_alert", "ev_shadow_alert"
	if admitted, err := st.AdmitSlackInput(ctx, alert); err != nil || !admitted {
		t.Fatalf("admit alert = %t, %v", admitted, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.finishShadowedWatchDecision(
		ctx, alert, decisionpkg.WatchTurnState{}, decisionpkg.WatchDecision{Action: "reply"},
	); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 || len(slackClient.ephemerals) != 0 {
		t.Fatalf("a shadowed alert was answered: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}
}

// The shadow gate names its exemption, never a list of kinds it covers.
//
// It was an allowlist — message and bot_message — and both holes were found in
// production by the same operator on the same day. A mention escaped it, so
// "do not reply to any of the messages in this channel" drew a reply. A recheck
// escaped it, so the investigation that had been correctly silenced posted its
// blocked notice half an hour later anyway. recheck, scheduled and the episode
// wakeups are all synthetic kinds invented after that list was written, which
// is the whole problem with writing one.
//
// A behavioural test cannot catch the next kind, because the next kind does not
// exist yet. Reading the gate can: if it ever grows a Kind comparison again,
// some kind is being let through, and that is the bug both times.
func TestTheShadowGateIsNotAnAllowlistOfInputKinds(t *testing.T) {
	source, err := os.ReadFile("watch.go")
	if err != nil {
		t.Fatal(err)
	}
	const marker = "shadow, err = s.shadowEnabled(ctx, input.ChannelID)"
	index := strings.Index(string(source), marker)
	if index < 0 {
		t.Fatal("the shadow gate has moved; this guard is reading nothing")
	}
	// The condition sits immediately above the call.
	head := string(source[:index])
	start := strings.LastIndex(head, "shadow := false")
	if start < 0 {
		t.Fatal("could not find the start of the shadow gate")
	}
	gate := head[start:]
	if strings.Contains(gate, "input.Kind") {
		t.Errorf(
			"the shadow gate compares input.Kind again:\n%s\n"+
				"Shadow means \"without posting\". Name what is exempt, not what is covered, "+
				"or the next synthetic kind posts into a channel that asked for silence.",
			strings.TrimSpace(gate),
		)
	}
}

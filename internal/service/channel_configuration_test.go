package service

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestChannelMembershipRunsConfirmedConversationalSetup(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel:     slackui.Channel{ID: "CNEW", Name: "new-operations", Member: true},
		channels:    []slackui.Channel{{ID: "CNEW", Name: "new-operations", Member: true}},
		dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
	}

	if err := svc.reconcileSlackChannelMemberships(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if session.Step != "participation" || session.ThreadTS == "" ||
		len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Markdown, "Nothing is saved") {
		t.Fatalf("initial setup = %+v, posts = %+v", session, slack.posts)
	}

	for index, answer := range []string{
		"Be proactive and participate like an SRE teammate.",
		"default",
		"offer an incident button",
		"include me",
	} {
		input := core.SlackInput{
			ID:         "setup-answer-" + string(rune('a'+index)),
			EnvelopeID: "setup-answer-env-" + string(rune('a'+index)),
			EventID:    "setup-answer-event-" + string(rune('a'+index)),
			Kind:       "message", TeamID: cfg.Slack.TeamID,
			ChannelID: "CNEW", ThreadTS: session.ThreadTS,
			MessageTS: "1700.2" + string(rune('0'+index)),
			UserID:    "U123ABC", Text: answer,
		}
		if _, err := st.AdmitSlackInput(ctx, input); err != nil {
			t.Fatal(err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process answer %q: %v", answer, err)
		}
		session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
		if err != nil {
			t.Fatal(err)
		}
	}
	if session.Status != "confirming" || session.Step != "confirm" ||
		session.Draft.Participation != "proactive" ||
		session.Draft.AlertPolicy != "offer" ||
		len(session.Draft.InviteUsers) != 1 ||
		session.Draft.InviteUsers[0] != "U123ABC" {
		t.Fatalf("configuration draft = %+v", session)
	}
	confirmation := slack.updates[len(slack.updates)-1].message
	if confirmation.Header != "Review channel behavior" ||
		len(confirmation.Actions) != 3 ||
		confirmation.Actions[0].ID != slackui.ActionSaveChannelConfig ||
		confirmation.Actions[0].Value != session.ID ||
		!strings.Contains(confirmation.Markdown, "does not authorize") {
		t.Fatalf("confirmation card = %+v", confirmation)
	}

	action := core.SlackInput{
		ID: "save-channel-config", EnvelopeID: "save-channel-config-env",
		EventID: "save-channel-config-event", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		ThreadTS: session.ThreadTS, MessageTS: session.CardTS,
		UserID: "U123ABC", ActionID: slackui.ActionSaveChannelConfig,
		ActionValue: session.ID,
	}
	if _, err := st.AdmitSlackInput(ctx, action); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	configuration, err := st.GetChannelConfiguration(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Repository != cfg.Slack.DefaultRepository ||
		configuration.Participation != "proactive" ||
		configuration.AlertPolicy != "offer" {
		t.Fatalf("saved configuration = %+v", configuration)
	}
	if enabled, err := svc.proactiveEnabled(ctx, "CNEW"); err != nil || !enabled {
		t.Fatalf("configured proactive = %v, %v", enabled, err)
	}
	if enabled, err := svc.shadowEnabled(ctx, "CNEW"); err != nil || enabled {
		t.Fatalf("configured shadow = %v, %v", enabled, err)
	}
	if _, err := st.GetActiveConfigurationSession(ctx, "CNEW"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("saved setup still active: %v", err)
	}
	// Four questions, a confirmation and a receipt, all on the one card the
	// opening question posted.
	if len(slack.posts) != 1 ||
		slack.updates[len(slack.updates)-1].message.Header != "Channel behavior saved" {
		t.Fatalf(
			"saved receipt = posts %+v updates %+v",
			slack.posts, slack.updates[len(slack.updates)-1],
		)
	}

	slack.channels[0].Member = false
	slack.channel.Member = false
	if err := svc.reconcileSlackChannelMemberships(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("remove membership reconciliation = %v", err)
	}
	slack.channels[0].Member = true
	slack.channel.Member = true
	if err := svc.reconcileSlackChannelMemberships(ctx); err != nil {
		t.Fatalf("rejoin membership reconciliation = %v", err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	reopened, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if reopened.ID == session.ID || reopened.Draft.Participation != "proactive" ||
		reopened.Draft.AlertPolicy != "offer" ||
		reopened.Draft.Repository != cfg.Slack.DefaultRepository {
		t.Fatalf("rejoined configuration draft = %+v", reopened)
	}
	if err := svc.reconcileSlackChannelMemberships(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unchanged membership queued duplicate onboarding: %v", err)
	}
	restarted := New(
		cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil,
	)
	restarted.identity = svc.identity
	if err := restarted.reconcileSlackChannelMemberships(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("restart queued duplicate onboarding: %v", err)
	}
	if err := restarted.processSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("restart left duplicate Slack input: %v", err)
	}
}

func TestChannelJoinCanUseProactiveDefaultsWithoutFullWizard(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		channel: slackui.Channel{
			ID: "CQUICK", Name: "infra", Member: true,
		},
		dedupePosts: true,
	}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	join := core.SlackInput{
		ID: "join-quick", EnvelopeID: "join-quick-env", EventID: "join-quick-event",
		Kind: "channel_joined", TeamID: cfg.Slack.TeamID, ChannelID: "CQUICK",
	}
	if _, err := st.AdmitSlackInput(ctx, join); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CQUICK")
	if err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].message.Actions[1].ID != slackui.ActionSetupQuickProactive {
		t.Fatalf("quick start card = %+v", slackClient.posts)
	}
	action := core.SlackInput{
		ID: "quick-proactive", EnvelopeID: "quick-proactive-env",
		EventID: "quick-proactive-event", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: "CQUICK",
		UserID: "U123ABC", ActionID: slackui.ActionSetupQuickProactive,
		ActionValue: session.ID,
	}
	if _, err := st.AdmitSlackInput(ctx, action); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	configuration, err := st.GetChannelConfiguration(ctx, "CQUICK")
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Participation != "proactive" ||
		configuration.Repository != cfg.Slack.DefaultRepository ||
		configuration.AlertPolicy != "reply" ||
		len(configuration.InviteUsers) != 0 ||
		len(configuration.InviteUserGroups) != 0 {
		t.Fatalf("quick configuration = %+v", configuration)
	}
	if _, err := st.GetActiveConfigurationSession(
		ctx,
		"CQUICK",
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("quick configuration remains active: %v", err)
	}
	if len(slackClient.posts) != 1 || len(slackClient.updates) != 1 ||
		slackClient.updates[0].message.Header != "Channel behavior saved" {
		t.Fatalf(
			"quick setup receipt = posts %+v updates %+v",
			slackClient.posts, slackClient.updates,
		)
	}
}

func TestConfigurationAnswersRequireOperatorAndConversationCommandsUseSharedHandlers(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel:     slackui.Channel{ID: "CNEW", Name: "new-operations", Member: true},
		dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	join := core.SlackInput{
		ID: "join-new", EnvelopeID: "join-new-env", EventID: "join-new-event",
		Kind: "channel_joined", TeamID: cfg.Slack.TeamID,
		ChannelID: "CNEW", UserID: "U123ABC",
	}
	if _, err := st.AdmitSlackInput(ctx, join); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := core.SlackInput{
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		ThreadTS: session.ThreadTS, MessageTS: "1700.2",
		UserID: "UNAUTHORIZED", Text: "proactive",
	}
	if admit, err := svc.shouldAdmitConfigurationMessage(
		ctx, unauthorized,
	); err != nil || admit {
		t.Fatalf("unauthorized setup answer admitted = %v, %v", admit, err)
	}

	if err := st.FinishConfigurationSession(
		ctx, session.ID, session.Revision, "cancelled",
	); err != nil {
		t.Fatal(err)
	}
	command := core.SlackInput{
		ID: "conversation-status", EnvelopeID: "conversation-status-env",
		EventID: "conversation-status-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		MessageTS: "1700.3", UserID: "U123ABC",
		Text: "<@U999BOT> how are you configured here?",
	}
	if _, err := st.AdmitSlackInput(ctx, command); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	last := slack.posts[len(slack.posts)-1]
	if last.thread != "" ||
		last.message.Header != "Responder is passive in this channel" {
		t.Fatalf("conversational status = %+v", last)
	}
	if len(slack.ephemerals) != 0 {
		t.Fatalf("conversational command was ephemeral = %+v", slack.ephemerals)
	}
}

func TestChannelSetupButtonsFollowOperatorBetweenChannelAndThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel: slackui.Channel{ID: "CNEW", Name: "infra", Member: true},
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	join := core.SlackInput{
		ID: "join-buttons", EnvelopeID: "join-buttons-env", EventID: "join-buttons-event",
		Kind: "channel_joined", TeamID: cfg.Slack.TeamID,
		ChannelID: "CNEW", UserID: "U123ABC",
	}
	if _, err := st.AdmitSlackInput(ctx, join); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 || len(slack.posts[0].message.Actions) != 3 {
		t.Fatalf("initial button question = %+v", slack.posts)
	}

	choose := core.SlackInput{
		ID: "choose-proactive", EnvelopeID: "choose-proactive-env",
		EventID: "choose-proactive-event", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		MessageTS: session.ThreadTS, UserID: "U123ABC",
		ActionID: slackui.ActionSetupProactive, ActionValue: session.ID,
	}
	if _, err := st.AdmitSlackInput(ctx, choose); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if session.Step != "repository" || session.Draft.Participation != "proactive" ||
		slack.posts[len(slack.posts)-1].thread != "" {
		t.Fatalf("channel button advance = %+v, post = %+v", session, slack.posts[len(slack.posts)-1])
	}
	repositoryQuestionTS := session.ThreadRoots[len(session.ThreadRoots)-1]

	repositoryReply := core.SlackInput{
		ID: "repository-in-thread", EnvelopeID: "repository-in-thread-env",
		EventID: "repository-in-thread-event", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		ThreadTS: repositoryQuestionTS, MessageTS: "1700.100",
		UserID: "U123ABC", Text: "default",
	}
	if _, err := st.AdmitSlackInput(ctx, repositoryReply); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	// Answering in a thread under the card is not a move. The card is the first
	// message of that thread, so the next question replaces it in place and the
	// operator reads it directly above their own reply.
	if session.Step != "alerts" || len(slack.posts) != 1 ||
		slack.updates[len(slack.updates)-1].ts != repositoryQuestionTS {
		t.Fatalf(
			"thread reply advance = %+v, posts = %+v, updates = %+v",
			session, slack.posts, slack.updates,
		)
	}

	moveToChannel := core.SlackInput{
		ID: "move-setup-channel", EnvelopeID: "move-setup-channel-env",
		EventID: "move-setup-channel-event", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		ThreadTS: repositoryQuestionTS, MessageTS: "1700.101",
		UserID: "U123ABC", Text: "let's switch to the channel",
	}
	if _, err := st.AdmitSlackInput(ctx, moveToChannel); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	// The card is already in the channel, so asking to continue there moves
	// nothing and costs no message.
	if session.Step != "alerts" || len(slack.posts) != 1 ||
		slack.updates[len(slack.updates)-1].ts != "1700.001" ||
		len(slack.updates[len(slack.updates)-1].message.Actions) != 3 {
		t.Fatalf(
			"move setup to channel = %+v, posts = %+v, updates = %+v",
			session, slack.posts, slack.updates,
		)
	}

	alertChoice := core.SlackInput{
		ID: "choose-alert", EnvelopeID: "choose-alert-env", EventID: "choose-alert-event",
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		MessageTS: session.ThreadRoots[len(session.ThreadRoots)-1],
		UserID:    "U123ABC", ActionID: slackui.ActionSetupAlertOffer,
		ActionValue: session.ID,
	}
	if _, err := st.AdmitSlackInput(ctx, alertChoice); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if session.Step != "audience" {
		t.Fatalf("alert button advance = %+v", session)
	}

	moveToThread := core.SlackInput{
		ID: "move-setup-thread", EnvelopeID: "move-setup-thread-env",
		EventID: "move-setup-thread-event", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		MessageTS: "1700.102", UserID: "U123ABC",
		Text: "let's switch to a thread not to pollute the channel",
	}
	if _, err := st.AdmitSlackInput(ctx, moveToThread); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	// Moving between the channel and a thread is the one thing an edit cannot
	// do, so the setup posts a second card and the first one stops being a
	// question that answers anything.
	if session.Step != "audience" || len(slack.posts) != 2 ||
		slack.posts[len(slack.posts)-1].thread != moveToThread.MessageTS ||
		!slices.Contains(session.ThreadRoots, moveToThread.MessageTS) {
		t.Fatalf("move setup to thread = %+v, posts = %+v", session, slack.posts)
	}
	retired := slack.updates[len(slack.updates)-1]
	if retired.ts != "1700.001" || len(retired.message.Actions) != 0 {
		t.Fatalf("the card left in the channel still answers = %+v", retired)
	}

	audienceReply := core.SlackInput{
		ID: "audience-thread", EnvelopeID: "audience-thread-env",
		EventID: "audience-thread-event", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		ThreadTS: moveToThread.MessageTS, MessageTS: "1700.103",
		UserID: "U123ABC", Text: "include me",
	}
	if _, err := st.AdmitSlackInput(ctx, audienceReply); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if session.Step != "confirm" || session.Status != "confirming" ||
		len(slack.posts) != 2 || session.CardTS != "1700.002" ||
		slack.updates[len(slack.updates)-1].ts != session.CardTS {
		t.Fatalf("thread confirmation = %+v, updates = %+v", session, slack.updates)
	}
}

func TestMembershipReconciliationDoesNotConfigureIncidentRooms(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, created, err := st.CreateManualIncident(
		ctx, cfg.Slack.DefaultRepository, "EvIncidentRoom", "Production issue",
		"Investigate", "U123ABC", "CORIGIN", "1700.1", 100,
	)
	if err != nil || !created {
		t.Fatalf("create incident = %+v, %v, %v", incident, created, err)
	}
	if err := st.SetChannel(ctx, incident.ID, "CINCIDENT", "ems-production-issue"); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{
		channels: []slackui.Channel{{
			ID: "CINCIDENT", Name: "ems-production-issue", Private: true, Member: true,
		}},
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileSlackChannelMemberships(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("incident room queued channel configuration input: %v", err)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("incident room received setup posts: %+v", slack.posts)
	}
}

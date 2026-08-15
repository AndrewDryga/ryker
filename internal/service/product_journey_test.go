package service

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestProductJourneyChannelSetupCanMoveRestartAndCancelWithoutPartialSave(
	t *testing.T,
) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{channel: slackui.Channel{
		ID: "CTEST", Name: "test", Member: true,
	}}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)

	joined := core.SlackInput{
		ID: "setup_joined", EnvelopeID: "env_setup_joined",
		EventID: "event_setup_joined", Kind: "channel_joined",
		TeamID: cfg.Slack.TeamID, ChannelID: "CTEST",
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, joined); err != nil || !admitted {
		t.Fatalf("admit joined = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CTEST")
	if err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		findMessageAction(
			slackClient.posts[0].message,
			slackui.ActionSetupCustomize,
		).ID == "" {
		t.Fatalf("initial setup card = %+v", slackClient.posts)
	}

	click := func(label, actionID, threadTS string) core.ConfigurationSession {
		t.Helper()
		input := core.SlackInput{
			ID: "setup_" + label, EnvelopeID: "env_setup_" + label,
			EventID: "event_setup_" + label, Kind: "action",
			TeamID: cfg.Slack.TeamID, ChannelID: "CTEST",
			MessageTS: "1700." + label, ThreadTS: threadTS,
			UserID:   cfg.Slack.Operators[0],
			ActionID: actionID, ActionValue: session.ID,
			ReceivedAt: time.Now().UTC(),
		}
		if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
			t.Fatalf("admit %s = %t, %v", label, admitted, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", label, err)
		}
		updated, err := st.GetConfigurationSession(ctx, session.ID)
		if err != nil {
			t.Fatalf("load %s session: %v", label, err)
		}
		session = updated
		return updated
	}

	if got := click("customize", slackui.ActionSetupCustomize, "1700.root"); got.Step != "participation" || got.Draft.ActorID != cfg.Slack.Operators[0] {
		t.Fatalf("customize session = %+v", got)
	}
	if got := click("proactive", slackui.ActionSetupProactive, "1700.thread"); got.Step != "repository" || got.ResponseThreadTS != "1700.thread" {
		t.Fatalf("proactive session = %+v", got)
	}
	if got := click("repository", slackui.ActionSetupDefaultRepo, ""); got.Step != "alerts" || got.ResponseThreadTS != "" {
		t.Fatalf("repository session did not follow the operator to channel: %+v", got)
	}
	if got := click("alerts", slackui.ActionSetupAlertOffer, "1700.thread2"); got.Step != "audience" || got.ResponseThreadTS != "1700.thread2" {
		t.Fatalf("alert session did not follow the operator to thread: %+v", got)
	}
	if got := click("audience", slackui.ActionSetupIncludeMe, "1700.thread2"); got.Step != "confirm" || got.Status != "confirming" ||
		len(got.Draft.InviteUsers) != 1 ||
		got.Draft.InviteUsers[0] != cfg.Slack.Operators[0] {
		t.Fatalf("audience session = %+v", got)
	}

	if got := click("restart", slackui.ActionRestartChannelSetup, ""); got.Step != "participation" || got.Status != "asking" ||
		got.Draft.Participation != "mentions" ||
		len(got.Draft.InviteUsers) != 0 {
		t.Fatalf("restarted session retained draft state: %+v", got)
	}
	if got := click("cancel", slackui.ActionCancelChannelSetup, "1700.final"); got.Status != "cancelled" {
		t.Fatalf("cancelled session = %+v", got)
	}
	if _, err := st.GetChannelConfiguration(ctx, "CTEST"); !errors.Is(
		err,
		store.ErrNotFound,
	) {
		t.Fatalf("cancelled setup partially saved configuration: %v", err)
	}
	last := slackClient.posts[len(slackClient.posts)-1]
	if last.thread != "1700.final" ||
		!strings.Contains(renderedSlackMessage(last.message), "No channel settings were changed") {
		t.Fatalf("cancel response = %+v", last)
	}
}

func TestProductJourneyClosedTaskCanDiscardRetainedWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx,
		"repo",
		"source_discard",
		"Discard acceptance task",
		"Make a temporary isolated change.",
		cfg.Slack.Operators[0],
		"CTASK",
		"1700.100",
		cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_1", "retained-task", 1); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	slackClient := &fakeSlack{}
	svc := New(
		cfg,
		st,
		coopClient,
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	input := core.SlackInput{
		ID: "discard_retained", EnvelopeID: "env_discard_retained",
		EventID: "event_discard_retained", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: task.ChannelID,
		MessageTS: task.RootTS, ThreadTS: task.ConversationThreadTS(),
		UserID:   cfg.Slack.Operators[0],
		ActionID: slackui.ActionDiscardWork, ActionValue: task.ID,
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
		t.Fatalf("admit discard = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf(
			"retained task discard = calls %d state %s",
			coopClient.discardCalls,
			coopClient.session.State,
		)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(
			renderedSlackMessage(slackClient.posts[0].message),
			"Retained task work discarded",
		) {
		t.Fatalf("discard confirmation = %+v", slackClient.posts)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.CleanupPending != 0 || metrics.CleanupBlocked != 0 {
		t.Fatalf("discard left cleanup work behind: %+v", metrics)
	}
}

func TestProductJourneyIncidentDirectoryButtonsPageBothDirections(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxOpenIncidents = 50
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for index := range incidentPageSize + 3 {
		_, _, err := st.CreateManualIncident(
			ctx,
			"repo",
			fmt.Sprintf("incident_%02d", index),
			fmt.Sprintf("Test incident %02d", index),
			"Acceptance paging",
			cfg.Slack.Operators[0],
			"CTEST",
			fmt.Sprintf("1700.%03d", index),
			cfg.Limits.MaxOpenIncidents,
		)
		if err != nil {
			t.Fatal(err)
		}
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)

	run := func(id, kind, actionID, actionValue, text string) slackui.Message {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env_" + id, EventID: "event_" + id,
			Kind: kind, TeamID: cfg.Slack.TeamID, ChannelID: "CTEST",
			UserID: cfg.Slack.Operators[0], ActionID: actionID,
			ActionValue: actionValue, Text: text,
			ReceivedAt: time.Now().UTC(),
		}
		if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
			t.Fatalf("admit %s = %t, %v", id, admitted, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		return slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	}

	first := run(
		"incidents_first",
		"slash",
		"/responder",
		"",
		"incidents open",
	)
	next := findMessageAction(first, slackui.ActionCommandNextIncidents)
	if next.ID == "" || next.Value != "open:2" ||
		findMessageAction(first, slackui.ActionCommandPreviousIncidents).ID != "" {
		t.Fatalf("first incident page controls = %+v", first.Actions)
	}
	second := run(
		"incidents_second",
		"action",
		next.ID,
		next.Value,
		"",
	)
	previous := findMessageAction(second, slackui.ActionCommandPreviousIncidents)
	if previous.ID == "" || previous.Value != "open:1" ||
		findMessageAction(second, slackui.ActionCommandNextIncidents).ID != "" {
		t.Fatalf("second incident page controls = %+v", second.Actions)
	}
	if !strings.Contains(renderedSlackMessage(second), "page 2 of 2") {
		t.Fatalf("second incident page copy = %+v", second)
	}
	back := run(
		"incidents_back",
		"action",
		previous.ID,
		previous.Value,
		"",
	)
	if !strings.Contains(renderedSlackMessage(back), "page 1 of 2") {
		t.Fatalf("previous incident page copy = %+v", back)
	}
}

func TestProductJourneyTextControlsExplainHelpAndAutomaticCapacity(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateManualIncident(
		ctx,
		"repo",
		"source_controls",
		"Acceptance control help",
		"Verify text controls.",
		cfg.Slack.Operators[0],
		"CCONTROLS",
		"1700.200",
		cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetChannel(
		ctx,
		incident.ID,
		"CCONTROLS",
		"ems-acceptance-controls",
	); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.201"); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)

	run := func(label, command string) slackui.Message {
		t.Helper()
		input := core.SlackInput{
			ID: "control_" + label, EnvelopeID: "env_control_" + label,
			EventID: "event_control_" + label, Kind: "message",
			TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
			MessageTS: "1700." + label, ThreadTS: incident.ConversationThreadTS(),
			UserID: cfg.Slack.Operators[0], Text: command,
			ReceivedAt: time.Now().UTC(),
		}
		if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
			t.Fatalf("admit %s = %t, %v", label, admitted, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", label, err)
		}
		drainSlackDeliveries(t, ctx, svc)
		return slackClient.posts[len(slackClient.posts)-1].message
	}

	// `!respond help` still answers. The legacy spellings keep working; help
	// simply stopped advertising them, along with the five other sections it
	// used to open with.
	help := renderedSlackMessage(run("help", "!respond help"))
	for _, expected := range []string{
		"Just reply in this channel",
		"/responder update",
		"/responder changes",
		"never merge, sign, or deploy",
	} {
		if !strings.Contains(help, expected) {
			t.Fatalf("help does not explain %q: %s", expected, help)
		}
	}
	if strings.Contains(help, "Lifecycle controls") || strings.Contains(help, "!respond") {
		t.Fatalf("help is a wall again: %s", help)
	}
	// "!respond help" is a question asked in the open and keeps its channel
	// answer. "!respond extend" allocates nothing — the explanation belongs to
	// the one person who typed a control that no longer does anything.
	posted := len(slackClient.posts)
	run("extend", "!respond extend")
	if len(slackClient.posts) != posted {
		t.Fatalf("the capacity explanation was posted to the room = %+v", slackClient.posts[posted:])
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("automatic capacity explanation = %+v", slackClient.ephemerals)
	}
	capacity := renderedSlackMessage(slackClient.ephemerals[0].message)
	if !strings.Contains(capacity, "Manual turn allocation is no longer required") ||
		!strings.Contains(capacity, "/responder turn-limit") {
		t.Fatalf("automatic capacity explanation = %s", capacity)
	}
}

// A mistyped setup answer is between Responder and the person who typed it.
//
// The refusal used to be a channel post, so one operator fumbling an answer put
// "I could not map that answer to a safe typed setting" in front of the whole
// room, once per attempt. It has exactly one useful reader, nobody else can act
// on it, and a channel that learns Responder posts its errors there is a
// channel that starts tuning Responder out.
func TestAMistypedSetupAnswerIsNotPostedToTheChannel(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{channel: slackui.Channel{
		ID: "CTEST", Name: "test", Member: true,
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	joined := core.SlackInput{
		ID: "setup_joined", EnvelopeID: "env_setup_joined",
		EventID: "event_setup_joined", Kind: "channel_joined",
		TeamID: cfg.Slack.TeamID, ChannelID: "CTEST",
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, joined); err != nil || !admitted {
		t.Fatalf("admit joined = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CTEST")
	if err != nil {
		t.Fatal(err)
	}
	customize := core.SlackInput{
		ID: "setup_customize", EnvelopeID: "env_setup_customize",
		EventID: "event_setup_customize", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: "CTEST", MessageTS: "1700.001",
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionSetupCustomize,
		ActionValue: session.ID, ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, customize); err != nil || !admitted {
		t.Fatalf("admit customize = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	postsBefore := len(slackClient.posts)
	answer := core.SlackInput{
		ID: "setup_gibberish", EnvelopeID: "env_setup_gibberish",
		EventID: "event_setup_gibberish", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "CTEST", MessageTS: "1700.900",
		ThreadTS: "1700.001", UserID: cfg.Slack.Operators[0],
		Text:       "invite marketing and also probably legal maybe",
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, answer); err != nil || !admitted {
		t.Fatalf("admit answer = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	for _, post := range slackClient.posts[postsBefore:] {
		if strings.Contains(post.message.Text, "could not map that answer") {
			t.Fatalf("a setup refusal was posted to the channel: %q", post.message.Text)
		}
	}
	refused := false
	for _, ephemeral := range slackClient.ephemerals {
		if strings.Contains(ephemeral.message.Text, "could not map that answer") {
			refused = true
			if ephemeral.user != cfg.Slack.Operators[0] {
				t.Errorf("refusal went to %q, not the operator who typed it", ephemeral.user)
			}
		}
	}
	if !refused {
		t.Fatalf("the refusal reached nobody: posts=%+v ephemerals=%+v",
			slackClient.posts[postsBefore:], slackClient.ephemerals)
	}
}

// Being refused is between Responder and the person refused.
//
// Both denials name one Slack account and nothing else: this person is not a
// configured operator, or this person is a guest. Nobody else in the incident
// room can grant either, so nobody else can act on reading it. It was a channel
// post, so a colleague who typed one sentence in an incident room was turned
// away in public, once per message they sent, in front of everyone working the
// incident.
func TestANonOperatorIsRefusedPrivatelyNotInTheIncidentRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, created, err := st.CreateManualIncident(
		ctx, cfg.Slack.DefaultRepository, "EvDenied", "Production issue",
		"Investigate", cfg.Slack.Operators[0], "CORIGIN", "1700.1", 100,
	)
	if err != nil || !created {
		t.Fatalf("create incident = %+v, %v, %v", incident, created, err)
	}
	if err := st.SetChannel(ctx, incident.ID, "CINCIDENT", "ems-production-issue"); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{channel: slackui.Channel{
		ID: "CINCIDENT", Name: "ems-production-issue", Member: true,
	}}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	bystander := core.SlackInput{
		ID: "denied_message", EnvelopeID: "env_denied", EventID: "event_denied",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CINCIDENT",
		MessageTS: "1700.500", ThreadTS: "1700.500", UserID: "UBYSTANDER",
		Text: "is anyone looking at the checkout errors?", ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, bystander); err != nil || !admitted {
		t.Fatalf("admit bystander = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	const refusal = "restricted to configured incident operators"
	for _, post := range slackClient.posts {
		if strings.Contains(post.message.Text, refusal) {
			t.Fatalf("a refusal was posted to the incident room: %q", post.message.Text)
		}
	}
	refused := false
	for _, ephemeral := range slackClient.ephemerals {
		if !strings.Contains(ephemeral.message.Text, refusal) {
			continue
		}
		refused = true
		if ephemeral.user != "UBYSTANDER" {
			t.Errorf("refusal went to %q, not the person refused", ephemeral.user)
		}
		if ephemeral.channel != "CINCIDENT" {
			t.Errorf("refusal landed in %q, not where they typed", ephemeral.channel)
		}
	}
	if !refused {
		t.Fatalf("the refusal reached nobody: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}
	// The refusal stays findable whether or not Slack accepted the ephemeral.
	trail := auditOutcomes(t, cfg, "slack.input", bystander.ID)
	if len(trail) != 1 || !strings.HasPrefix(trail[0], "denied: ") {
		t.Fatalf("the refusal left no audit trail: %+v", trail)
	}
}

// A sentence is a sentence, whichever words are in it.
//
// Two refusals used to be posted at whole channels, because a keyword table
// turned free text into slash subcommands. "@Emisar show settings" from
// somebody not in slack.operators printed "your account is not listed, an
// administrator must add you" in front of the room, once per attempt. "@Emisar
// stop" in a channel with no incident printed five sentences about which
// commands operate on an attached incident. Both were made private, which
// fixed who read them; deleting the router is what stops them being produced.
// Neither sentence is a command now, so neither has anything to refuse — they
// are questions, and questions go to the conversation.
func TestAnAddressedSentenceIsNeverRoutedToACommand(t *testing.T) {
	for _, probe := range []struct {
		name    string
		id      string
		user    string
		text    string
		refusal string
	}{
		{
			name: "a settings question from somebody who is not an operator",
			id:   "ops_show_settings", user: "UBYSTANDER",
			text:    "<@U999BOT> show settings",
			refusal: "not listed in `slack.operators`",
		},
		{
			name: "a control word with no incident behind it",
			id:   "ops_stop_nothing", user: "U123ABC",
			text:    "<@U999BOT> stop",
			refusal: "no incident to control in this channel",
		},
	} {
		t.Run(probe.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			slackClient := &fakeSlack{channel: slackui.Channel{
				ID: "COPS", Name: "backend-ops", Member: true,
			}}
			svc := New(
				cfg, st, newFakeCoop(), slackClient, nil,
				slackui.NewSanitizer(12000), nil,
			)
			svc.identity = slackui.Identity{
				TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
			}

			asked := core.SlackInput{
				ID: probe.id, EnvelopeID: "env_" + probe.id,
				EventID: "event_" + probe.id, Kind: "mention",
				TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
				MessageTS: "1700.700", UserID: probe.user, Text: probe.text,
				ReceivedAt: time.Now().UTC(),
			}
			if admitted, err := st.AdmitSlackInput(ctx, asked); err != nil || !admitted {
				t.Fatalf("admit question = %t, %v", admitted, err)
			}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			drainSlackDeliveries(t, ctx, svc)

			for _, sent := range append(
				append([]slackPost{}, slackClient.posts...),
				slackClient.ephemerals...,
			) {
				if strings.Contains(renderedSlackMessage(sent.message), probe.refusal) {
					t.Fatalf(
						"a sentence was refused as a command: %q",
						renderedSlackMessage(sent.message),
					)
				}
			}
			if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("the question was not completed: %v", err)
			}
		})
	}
}

// A request that Responder gave up on is news to the person who made it.
//
// "Responder could not complete that request after retrying", the raw error
// Slack or Coop returned, and an invitation to run the command again: only the
// person who pressed the button can do that. To everyone else it is a stack
// trace addressed to nobody, arriving in their room after up to twelve silent
// attempts they never knew about. It went to the whole thread.
func TestAnAbandonedRequestTellsTheOperatorNotTheRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", "source_abandoned", "Abandoned control task",
		"Make a temporary isolated change.", cfg.Slack.Operators[0],
		"CTASK", "1700.100", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_1", "review-task", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.changes = coop.Changes{
		BaseCommit: "base", ForkHead: "proposed",
		Committed: []coop.Change{{Path: "checkout.go", Status: "M"}},
	}
	// A refusal Coop will repeat forever, so the input gives up on the first
	// attempt instead of the test having to burn all twelve.
	coopClient.getSessionErr = &coop.APIError{
		Status: http.StatusForbidden, Code: "forbidden",
		Detail: "this token may not read that session",
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)

	press := core.SlackInput{
		ID: "abandoned_review", EnvelopeID: "env_abandoned_review",
		EventID: "event_abandoned_review", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: task.ChannelID,
		MessageTS: task.RootTS, ThreadTS: task.ConversationThreadTS(),
		UserID:   cfg.Slack.Operators[0],
		ActionID: slackui.ActionReview, ActionValue: task.ID,
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, press); err != nil || !admitted {
		t.Fatalf("admit press = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	stored, err := st.GetSlackInput(ctx, press.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "failed" {
		t.Fatalf("state = %q, want failed; Coop's refusal is final", stored.State)
	}
	const abandoned = "could not complete that request after retrying"
	for _, post := range slackClient.posts {
		if strings.Contains(renderedSlackMessage(post.message), abandoned) {
			t.Fatalf("a give-up notice was posted to the room: %q", post.message.Text)
		}
	}
	told := false
	for _, ephemeral := range slackClient.ephemerals {
		if !strings.Contains(renderedSlackMessage(ephemeral.message), abandoned) {
			continue
		}
		told = true
		if ephemeral.user != cfg.Slack.Operators[0] {
			t.Errorf("give-up notice went to %q, not the operator who pressed", ephemeral.user)
		}
		if !strings.Contains(renderedSlackMessage(ephemeral.message), "forbidden") {
			t.Errorf("the reason was dropped: %q", ephemeral.message.Text)
		}
	}
	if !told {
		t.Fatalf("nobody was told the request was abandoned: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}
	// Whether or not Slack accepts an ephemeral, giving up stays findable.
	trail := auditOutcomes(t, cfg, "slack.input", press.ID)
	if len(trail) != 1 || !strings.HasPrefix(trail[0], "abandoned: ") {
		t.Fatalf("giving up left no audit trail: %+v", trail)
	}
}

// A control that changed nothing answers the person who pressed it.
//
// "Nothing was stopped. No agent turn is currently running." went to the whole
// incident room. It has exactly one reader — the operator who pressed Stop and
// is waiting to hear whether it worked — and it reports a no-op, so everyone
// else was told that a button somebody else pressed did nothing.
func TestAControlThatStoppedNothingTellsThePresserNotTheRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	press := core.SlackInput{
		ID: "stop_idle", EnvelopeID: "env_stop_idle", EventID: "event_stop_idle",
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		MessageTS: incident.RootTS, ThreadTS: incident.ConversationThreadTS(),
		UserID:   cfg.Slack.Operators[0],
		ActionID: slackui.ActionStop, ActionValue: incident.ID,
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, press); err != nil || !admitted {
		t.Fatalf("admit stop = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	const refusal = "Nothing was stopped"
	for _, post := range slackClient.posts {
		if strings.Contains(renderedSlackMessage(post.message), refusal) {
			t.Fatalf("a no-op control notice was posted to the room: %q", post.message.Text)
		}
	}
	told := false
	for _, ephemeral := range slackClient.ephemerals {
		if !strings.Contains(renderedSlackMessage(ephemeral.message), refusal) {
			continue
		}
		told = true
		if ephemeral.user != cfg.Slack.Operators[0] {
			t.Errorf("the answer went to %q, not the operator who pressed", ephemeral.user)
		}
		if ephemeral.channel != incident.ChannelID {
			t.Errorf("the answer landed in %q, not where they pressed", ephemeral.channel)
		}
	}
	if !told {
		t.Fatalf("the operator was told nothing: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}
	// A refused control stays findable whether or not Slack took the ephemeral.
	trail := auditOutcomes(t, cfg, "slack.control", press.ID)
	if len(trail) != 1 || !strings.HasPrefix(trail[0], "refused: ") {
		t.Fatalf("the refusal left no audit trail: %+v", trail)
	}
}

// Refusing a command and then reporting it as submitted is two answers, and
// the second one is wrong.
//
// "/responder stop" appends a receipt to whatever the control did: "this
// command will cancel the active agent turn". Run against an idle incident it
// arrived directly beneath "Nothing was stopped", describing work that had just
// been declined.
func TestARefusedSlashControlIsNotAlsoReportedAsSubmitted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	typed := core.SlackInput{
		ID: "slash_stop_idle", EnvelopeID: "env_slash_stop_idle",
		EventID: "event_slash_stop_idle", Kind: "slash",
		TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		UserID: cfg.Slack.Operators[0], Text: "stop",
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, typed); err != nil || !admitted {
		t.Fatalf("admit slash stop = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	refused := false
	sent := append(append([]slackPost{}, slackClient.posts...), slackClient.ephemerals...)
	for _, message := range sent {
		rendered := renderedSlackMessage(message.message)
		if strings.Contains(rendered, "Request submitted for incident") {
			t.Fatalf("a refused control was reported as submitted: %q", rendered)
		}
		if strings.Contains(rendered, "Nothing was stopped") {
			refused = true
		}
	}
	if !refused {
		t.Fatalf("the operator was told nothing: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}
}

// A dashboard control that cannot happen must refuse to the dashboard.
//
// These handlers answered a refusal by enqueuing a Slack notice and returning
// nil, so clearing workspaces from the control plane did two wrong things at
// once: the browser reported success for a discard that never ran, and an
// incident room nobody was looking at was told why. Six of those went out in
// two minutes.
//
// Nothing in Slack; an error on the page the operator is already looking at.
func TestADashboardRefusalReachesTheDashboardAndNotTheRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", "source_dirty_discard", "Dirty discard task",
		"Make a temporary isolated change.", cfg.Slack.Operators[0],
		"CTASK", "1700.100", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_1", "retained-task", 1); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	// Uncommitted work: nothing deletes it, so the discard stops here.
	coopClient.discardPlan.OperationID = "op_discard_plan"
	coopClient.discardPlan.Plan.Workspace.Dirty = true
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)

	err = svc.ControlPlaneAct(ctx, "discard", task.ID, "control-plane@localhost")
	if err == nil {
		t.Fatal("the dashboard was told a refused discard had succeeded")
	}
	if !strings.Contains(err.Error(), "uncommitted changes") {
		t.Fatalf("the dashboard was given no reason: %v", err)
	}
	if coopClient.discardCalls != 0 {
		t.Fatalf("a dirty workspace was discarded %d times", coopClient.discardCalls)
	}
	if len(slackClient.posts) != 0 || len(slackClient.ephemerals) != 0 {
		t.Fatalf("a dashboard action spoke in Slack: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
	}
	// Nobody in Slack asked, so the audit row is the whole record.
	trail := auditOutcomes(t, cfg, "slack.control", "")
	if len(trail) != 1 || !strings.HasPrefix(trail[0], "refused: ") {
		t.Fatalf("the refusal left no audit trail: %+v", trail)
	}
}

// The dashboard's Close button has to work on a real Coop session.
//
// Closing freezes the session and revision onto the stored Slack input so a
// redelivered Slack event acts on the turn it first resolved. The dashboard's
// input is synthetic — never admitted to slack_inputs, never redelivered — so
// the SELECT behind that freeze matched nothing and the whole action failed
// with a bare "sql: no rows in result set". The button was offered on every
// incident holding a session, and could not work on any of them.
func TestTheDashboardCanCloseAnIncidentHoldingACoopSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", "source_cp_close", "Closeable task",
		"Make a temporary isolated change.", cfg.Slack.Operators[0],
		"CTASK", "1700.200", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.201"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_close", "closeable", 1); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	if err := svc.ControlPlaneAct(ctx, "close", task.ID, "control-plane@localhost"); err != nil {
		t.Fatalf("the dashboard could not close a session-holding incident: %v", err)
	}
	closed, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if closed.Status != core.IncidentClosed {
		t.Fatalf("the incident is still %q", closed.Status)
	}
}

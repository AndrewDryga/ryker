package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

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

	help := renderedSlackMessage(run("help", "!respond help"))
	for _, expected := range []string{
		"/responder update",
		"/responder changes",
		"/responder close",
	} {
		if !strings.Contains(help, expected) {
			t.Fatalf("help does not explain %q: %s", expected, help)
		}
	}
	capacity := renderedSlackMessage(run("extend", "!respond extend"))
	if !strings.Contains(capacity, "Manual turn allocation is no longer required") ||
		!strings.Contains(capacity, "/responder turn-limit") {
		t.Fatalf("automatic capacity explanation = %s", capacity)
	}
}

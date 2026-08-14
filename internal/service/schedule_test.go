package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	schedulepkg "github.com/AndrewDryga/responder/internal/schedule"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/schedulestore"
)

type scheduleSlack struct {
	fakeSlack
	t        *testing.T
	wantUser string
	wantTeam string
}

func (f *scheduleSlack) UserAllowed(_ context.Context, userID, teamID string) (bool, error) {
	f.t.Helper()
	if userID != f.wantUser || teamID != f.wantTeam {
		f.t.Fatalf("UserAllowed(%q, %q), want (%q, %q)", userID, teamID, f.wantUser, f.wantTeam)
	}
	return true, nil
}

func TestScheduleOfferRequiresOperatorIntentAndNormalizesTypedCalendar(t *testing.T) {
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	s := &Service{cfg: cfg, slack: &fakeSlack{channel: slackui.Channel{
		ID: "CREPORT", Name: "health-reports", Member: true,
	}}, store: st}
	start := time.Now().UTC().Add(2 * time.Hour).Truncate(time.Second)
	input := core.SlackInput{ID: "slack_schedule", EventID: "EvSchedule", TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1", UserID: cfg.Slack.Operators[0], Text: "Every Monday at 09:00 schedule a deep production health report."}
	offer := &core.ScheduleOffer{Title: "Weekly production health", Prompt: "Run a deep production health check and report material changes.", Repository: "repo", DeliveryChannel: "CREPORT", Recurrence: "weekly", StartAt: start.Format(time.RFC3339), Weekdays: []string{"monday"}, LocalTime: "09:00", Timezone: "UTC", CatchUp: "latest", ExpiresIn: "90d"}
	value, task, when, ok := s.prepareScheduleOfferAction(context.Background(), input, offer)
	if !ok || !strings.Contains(value, `"version":2`) || strings.Contains(value, offer.Prompt) || task.ChannelID != "COPS" || task.DeliveryChannel != "CREPORT" || task.ThreadTS != "100.1" || task.Recurrence != "weekly" || !strings.Contains(when, "monday") {
		t.Fatalf("schedule offer = ok=%t value=%q task=%+v when=%q", ok, value, task, when)
	}
	var payload scheduleActionPayload
	if err := decisionpkg.DecodeStrictJSON([]byte(value), &payload); err != nil {
		t.Fatal(err)
	}
	proposal, err := st.Schedules.Get(context.Background(), payload.ProposalID)
	if err != nil {
		t.Fatal(err)
	}
	if proposal.Task.Prompt != offer.Prompt || proposal.Task.Recurrence != "weekly" {
		t.Fatalf("stored schedule proposal = %+v", proposal)
	}
	input.Text = "Run a deep production health report."
	if _, _, _, ok := s.prepareScheduleOfferAction(context.Background(), input, offer); ok {
		t.Fatal("schedule offer accepted without explicit scheduling intent")
	}
}

func TestSeveralScheduleOffersBecomeOneAtomicConfirmation(t *testing.T) {
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	s := &Service{cfg: cfg, store: st, slack: &fakeSlack{channel: slackui.Channel{
		ID: "COPS", Name: "operations", Member: true,
	}}}
	now := time.Now().UTC().Truncate(time.Second)
	input := core.SlackInput{
		ID: "slack_zot_followups", EventID: "EvZotFollowups", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "100.1", UserID: cfg.Slack.Operators[0],
		Text: "Check tomorrow and in three days that Zot authentication failures are gone.",
	}
	offers := []*core.ScheduleOffer{
		{Title: "Check Zot tomorrow", Prompt: "Check Zot logs for recurring authentication failures and report here.", Repository: "repo", Recurrence: "once", StartAt: now.Add(24 * time.Hour).Format(time.RFC3339), Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d"},
		{Title: "Check Zot in three days", Prompt: "Check Zot logs for recurring authentication failures and report here.", Repository: "repo", Recurrence: "once", StartAt: now.Add(72 * time.Hour).Format(time.RFC3339), Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d"},
	}
	value, tasks, whens, ok := s.prepareScheduleOffersAction(context.Background(), input, offers)
	if !ok || len(tasks) != 2 || len(whens) != 2 {
		t.Fatalf("schedule batch = ok=%t tasks=%+v whens=%v", ok, tasks, whens)
	}
	var payload scheduleActionPayload
	if err := decisionpkg.DecodeStrictJSON([]byte(value), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Version != 3 || len(payload.ProposalIDs) != 2 {
		t.Fatalf("schedule batch payload = %+v", payload)
	}
	for index, id := range payload.ProposalIDs {
		proposal, getErr := st.Schedules.Get(context.Background(), id)
		if getErr != nil {
			t.Fatalf("get proposal %d: %v", index, getErr)
		}
		if proposal.Task.ThreadTS != input.ThreadTS || proposal.Task.Prompt != offers[index].Prompt {
			t.Fatalf("proposal %d = %+v", index, proposal)
		}
	}
}

func TestScheduleConfirmationUpdatesProposalCardInPlace(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC().Truncate(time.Second)
	source := core.SlackInput{
		ID: "slack_zot_schedule_source", EventID: "EvZotScheduleSource",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1",
		UserID: cfg.Slack.Operators[0],
		Text:   "Check tomorrow that Zot authentication failures are gone.",
	}
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	actionValue, _, _, ok := svc.prepareScheduleOfferAction(ctx, source, &core.ScheduleOffer{
		Title:      "Verify Zot authentication tomorrow",
		Prompt:     "Check Zot logs for recurring authentication failures and report here.",
		Repository: "repo", Recurrence: "once",
		StartAt:  now.Add(24 * time.Hour).Format(time.RFC3339),
		Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d",
	})
	if !ok {
		t.Fatal("schedule proposal was not prepared")
	}

	action := core.SlackInput{
		ID: "slack_zot_schedule_confirm", EnvelopeID: "env_zot_schedule_confirm",
		EventID: "EvZotScheduleConfirm", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID, ThreadTS: source.ThreadTS,
		MessageTS: "1700.777", UserID: source.UserID,
		ActionID: slackui.ActionRememberSchedule, ActionValue: actionValue,
		ReceivedAt: now,
	}
	if admitted, admitErr := st.AdmitSlackInput(ctx, action); admitErr != nil || !admitted {
		t.Fatalf("admit schedule confirmation = %t, %v", admitted, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	delivery, err := st.GetSlackDelivery(ctx, "behavior_receipt_"+action.ID)
	if err != nil {
		t.Fatal(err)
	}
	if delivery.Operation != "update" || delivery.ChannelID != action.ChannelID ||
		delivery.MessageTS != action.MessageTS {
		t.Fatalf("schedule receipt delivery = %+v", delivery)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("schedule confirmation posted a second message: %+v", slackClient.posts)
	}
	if len(slackClient.updates) != 1 {
		t.Fatalf("schedule confirmation updates = %+v", slackClient.updates)
	}
	update := slackClient.updates[0]
	// Supersedes the "Scheduled task created" header and the four management
	// buttons: a receipt states the outcome once and offers the way back out,
	// not a control panel five seconds after a confirmation.
	if update.channel != action.ChannelID || update.ts != action.MessageTS ||
		!strings.HasPrefix(update.message.Text, "Scheduled Verify Zot authentication tomorrow.") {
		t.Fatalf("schedule proposal update = %+v", update)
	}
	for _, control := range update.message.Actions {
		if control.ID == slackui.ActionRememberSchedule {
			t.Fatalf("confirmed schedule kept proposal action: %+v", update.message.Actions)
		}
	}
	if len(update.message.Actions) != 1 ||
		update.message.Actions[0].ID != slackui.ActionDeleteSchedule ||
		update.message.Actions[0].Label != "Undo" ||
		update.message.Actions[0].Style == "danger" {
		t.Fatalf("confirmed schedule controls = %+v", update.message.Actions)
	}
	tasks, err := st.Schedules.ListScheduledTasksForChannel(ctx, action.ChannelID, 10)
	if err != nil || len(tasks) != 1 || tasks[0].Title != "Verify Zot authentication tomorrow" {
		t.Fatalf("saved schedules = %+v, err=%v", tasks, err)
	}
}

func TestBatchScheduleConfirmationUpdatesProposalCardInPlace(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC().Truncate(time.Second)
	source := core.SlackInput{
		ID: "slack_zot_batch_source", EventID: "EvZotBatchSource",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1",
		UserID: cfg.Slack.Operators[0],
		Text:   "Check tomorrow and in three days that Zot authentication failures are gone.",
	}
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	actionValue, _, _, ok := svc.prepareScheduleOffersAction(ctx, source, []*core.ScheduleOffer{
		{
			Title: "Verify Zot authentication tomorrow", Prompt: "Check Zot logs and report here.",
			Repository: "repo", Recurrence: "once", StartAt: now.Add(24 * time.Hour).Format(time.RFC3339),
			Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d",
		},
		{
			Title: "Verify Zot authentication in three days", Prompt: "Check Zot logs and report here.",
			Repository: "repo", Recurrence: "once", StartAt: now.Add(72 * time.Hour).Format(time.RFC3339),
			Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d",
		},
	})
	if !ok {
		t.Fatal("schedule batch was not prepared")
	}

	action := core.SlackInput{
		ID: "slack_zot_batch_confirm", EnvelopeID: "env_zot_batch_confirm",
		EventID: "EvZotBatchConfirm", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID, ThreadTS: source.ThreadTS,
		MessageTS: "1700.888", UserID: source.UserID,
		ActionID: slackui.ActionRememberSchedule, ActionValue: actionValue,
		ReceivedAt: now,
	}
	if admitted, admitErr := st.AdmitSlackInput(ctx, action); admitErr != nil || !admitted {
		t.Fatalf("admit schedule confirmation = %t, %v", admitted, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("batch confirmation posted a second message: %+v", slackClient.posts)
	}
	if len(slackClient.updates) != 1 {
		t.Fatalf("batch confirmation updates = %+v", slackClient.updates)
	}
	update := slackClient.updates[0]
	// Supersedes the "%d follow-up checks scheduled" header; the batch receipt
	// leads with the verb and lists what it created as rows.
	if update.channel != action.ChannelID || update.ts != action.MessageTS ||
		update.message.Text != "Scheduled 2 follow-up checks." ||
		len(update.message.Rows) != 2 {
		t.Fatalf("batch proposal update = %+v", update)
	}
	for _, control := range update.message.Actions {
		if control.ID == slackui.ActionRememberSchedule {
			t.Fatalf("confirmed batch kept proposal action: %+v", update.message.Actions)
		}
	}
	tasks, err := st.Schedules.ListScheduledTasksForChannel(ctx, action.ChannelID, 10)
	if err != nil || len(tasks) != 2 {
		t.Fatalf("saved schedules = %+v, err=%v", tasks, err)
	}
}

func TestSeveralScheduleOffersCannotReplaceTheSameExistingSchedule(t *testing.T) {
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	_, err = st.Schedules.CreateScheduledTask(context.Background(), core.ScheduledTask{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1", DeliveryChannel: "COPS",
		Repository: "repo", Title: "Existing Zot check", Prompt: "Check Zot logs.",
		Recurrence: "once", StartAt: now.Add(12 * time.Hour), NextRunAt: now.Add(12 * time.Hour),
		Timezone: "UTC", CatchUp: "latest", ActorID: cfg.Slack.Operators[0], SourceRef: "existing-zot",
		ExpiresAt: now.Add(7 * 24 * time.Hour),
	}, cfg.Limits.MaxScheduledTasks, cfg.Limits.MaxSchedulesPerChannel)
	if err != nil {
		t.Fatal(err)
	}
	s := &Service{cfg: cfg, store: st, slack: &fakeSlack{channel: slackui.Channel{
		ID: "COPS", Name: "operations", Member: true,
	}}}
	input := core.SlackInput{
		ID: "slack_zot_followups", EventID: "EvZotFollowups", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "100.1", UserID: cfg.Slack.Operators[0],
		Text: "Check tomorrow and in three days that Zot authentication failures are gone.",
	}
	offers := []*core.ScheduleOffer{
		{Title: "Check Zot tomorrow", Prompt: "Check Zot logs.", Repository: "repo", Recurrence: "once", StartAt: now.Add(24 * time.Hour).Format(time.RFC3339), Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d"},
		{Title: "Check Zot in three days", Prompt: "Check Zot logs.", Repository: "repo", Recurrence: "once", StartAt: now.Add(72 * time.Hour).Format(time.RFC3339), Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d"},
	}

	if _, _, _, ok := s.prepareScheduleOffersAction(context.Background(), input, offers); ok {
		t.Fatal("ambiguous batch replacing one schedule was accepted")
	}
	if _, err := st.Schedules.GetPendingForConversation(
		context.Background(), cfg.Slack.TeamID, input.ChannelID, input.ThreadTS, input.UserID,
	); !errors.Is(err, schedulestore.ErrNotFound) {
		t.Fatalf("ambiguous batch left a pending proposal: %v", err)
	}
}

func TestScheduleOfferKeepsLongPromptOutOfSlackActionValue(t *testing.T) {
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	s := &Service{cfg: cfg, store: st, slack: &fakeSlack{channel: slackui.Channel{
		ID: "COPS", Name: "operations", Member: true,
	}}}
	prompt := strings.Repeat("Collect fresh evidence, reconcile contradictions, and report only actionable findings. ", 13)
	input := core.SlackInput{
		ID: "slack_long_schedule", EventID: "EvLongSchedule", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "100.1", UserID: cfg.Slack.Operators[0],
		Text: "Post this comprehensive report daily at 09:00.",
	}
	value, _, _, ok := s.prepareScheduleOfferAction(context.Background(), input, &core.ScheduleOffer{
		Title: "Daily comprehensive report", Prompt: prompt, Repository: "repo",
		Recurrence: "daily", LocalTime: "09:00", Timezone: "UTC", CatchUp: "latest", ExpiresIn: "90d",
	})
	if !ok {
		t.Fatal("long schedule offer was discarded")
	}
	if len(value) >= 200 || strings.Contains(value, prompt[:80]) {
		t.Fatalf("Slack action value contains schedule data: len=%d value=%q", len(value), value)
	}
	var payload scheduleActionPayload
	if err := decisionpkg.DecodeStrictJSON([]byte(value), &payload); err != nil {
		t.Fatal(err)
	}
	proposal, err := st.Schedules.Get(context.Background(), payload.ProposalID)
	if err != nil || proposal.Task.Prompt != strings.TrimSpace(prompt) {
		t.Fatalf("durable long prompt = %q, err=%v", proposal.Task.Prompt, err)
	}
}

func TestScheduleIntentHandlesNaturalRelativeDurations(t *testing.T) {
	for _, text := range []string{
		"check this in 12 hours", "do this every Thursday", "run it weekly", "remind me tomorrow",
		"check this every 6 hours", "prepare this once a month",
	} {
		if !schedulepkg.ExplicitScheduleRequest(text) {
			t.Fatalf("schedule intent not recognized: %q", text)
		}
	}
	if schedulepkg.ExplicitScheduleRequest("check production health now") {
		t.Fatal("one-time immediate request was treated as a schedule")
	}
}

func TestScheduleRetryInheritsExplicitIntentFromSameOperatorThread(t *testing.T) {
	input := core.SlackInput{
		UserID: "UOPERATOR", ThreadTS: "1700.100", Text: "Try again <@UEMISAR>",
	}
	recent := []decisionpkg.WatchContextMessage{
		{MessageTS: "1699.900", SenderID: "UOTHER", SenderType: "human", Text: "Run this weekly."},
		{MessageTS: "1700.100", SenderID: "UOPERATOR", SenderType: "human", Text: "Post a deep review daily around 9 am."},
		{MessageTS: "1700.200", ThreadTS: "1700.100", SenderID: "UOPERATOR", SenderType: "human", Text: "Try again", Target: true},
	}
	resolved := schedulepkg.ScheduleInputWithConversationIntent(input, recent)
	if resolved.Text != recent[1].Text || !schedulepkg.ExplicitScheduleRequest(resolved.Text) {
		t.Fatalf("resolved schedule intent = %q", resolved.Text)
	}

	input.Text = "Do not schedule it."
	if resolved := schedulepkg.ScheduleInputWithConversationIntent(input, recent); resolved.Text != input.Text {
		t.Fatalf("non-continuation inherited stale intent = %q", resolved.Text)
	}

	input.Text = "activate it"
	if resolved := schedulepkg.ScheduleInputWithConversationIntent(input, recent); resolved.Text != recent[1].Text {
		t.Fatalf("activation did not inherit the existing schedule = %q", resolved.Text)
	}
	if !schedulepkg.ExplicitScheduleConfirmation(input.Text) {
		t.Fatal("activation was not recognized as an explicit schedule confirmation")
	}
}

func TestActivateItAcceptsPendingScheduleWithoutAnotherModelRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	proposal, err := st.Schedules.Create(ctx, core.ScheduleProposal{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1",
		ActorID: cfg.Slack.Operators[0], SourceRef: "schedule-offer", ExpiresAt: now.Add(time.Hour),
		Task: core.ScheduledTask{
			TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1", DeliveryChannel: "COPS",
			Repository: "repo", Title: "Daily report", Prompt: "Use the published runbook with fresh evidence.",
			Recurrence: "daily", StartAt: now.Add(time.Hour), LocalTime: "09:00", Timezone: "UTC",
			CatchUp: "latest", ActorID: cfg.Slack.Operators[0], SourceRef: "schedule-offer",
			NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(90 * 24 * time.Hour),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(cfg, st, nil, slackClient, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "activate-schedule", EventID: "EvActivateSchedule", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1", MessageTS: "100.2",
		UserID: cfg.Slack.Operators[0], Text: "activate it",
	}
	if admitted, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !admitted {
		t.Fatalf("admit activation = %t, %v", admitted, admitErr)
	}
	input, err = st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	handled, err := svc.confirmPendingScheduleReply(ctx, input)
	if err != nil || !handled {
		t.Fatalf("confirm pending schedule = %t, %v", handled, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	accepted, err := st.Schedules.Get(ctx, proposal.ID)
	if err != nil {
		t.Fatal(err)
	}
	task, err := st.Schedules.GetScheduledTask(ctx, accepted.AcceptedTaskID)
	if err != nil || task.Title != "Daily report" {
		t.Fatalf("activated schedule = %+v, err=%v", task, err)
	}
	if len(slackClient.posts) != 1 || !strings.Contains(strings.ToLower(slackClient.posts[0].message.Text), "scheduled") {
		t.Fatalf("activation receipt = %+v", slackClient.posts)
	}
}

func TestCalendarScheduleComputesNextRunWithoutModelDateArithmetic(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	now := time.Date(2026, time.August, 1, 14, 0, 0, 0, time.UTC)
	task, err := s.scheduledTaskFromOffer(context.Background(), core.SlackInput{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", UserID: cfg.Slack.Operators[0],
	}, core.ScheduleOffer{
		Title: "Morning report", Prompt: "Summarize production health.", Repository: "repo",
		Recurrence: "daily", LocalTime: "09:00", Timezone: "America/New_York",
		CatchUp: "latest", ExpiresIn: "90d",
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	local := task.NextRunAt.In(schedulepkg.MustLocation(task.Timezone))
	if !task.StartAt.Equal(task.NextRunAt) || local.Hour() != 9 || !task.NextRunAt.After(now) {
		t.Fatalf("computed next run = %s (%s)", task.NextRunAt, local)
	}
}

func TestScheduleOfferRejectsInvalidTimezoneAndExpiryBeforeFirstRun(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	now := time.Date(2026, time.August, 1, 14, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", UserID: cfg.Slack.Operators[0],
	}
	base := core.ScheduleOffer{
		Title: "Health report", Prompt: "Report production health.", Repository: "repo",
		Recurrence: "once", StartAt: now.Add(2 * time.Hour).Format(time.RFC3339),
		Timezone: "UTC", CatchUp: "latest", ExpiresIn: "90d",
	}
	invalidZone := base
	invalidZone.Timezone = "Mars/Olympus"
	if _, err := s.scheduledTaskFromOffer(context.Background(), input, invalidZone, now); err == nil {
		t.Fatal("invalid timezone was accepted")
	}
	expiresFirst := base
	expiresFirst.StartAt = now.Add(48 * time.Hour).Format(time.RFC3339)
	expiresFirst.ExpiresIn = "1d"
	if _, err := s.scheduledTaskFromOffer(context.Background(), input, expiresFirst, now); err == nil {
		t.Fatal("schedule expiring before its first run was accepted")
	}
}

func TestNextScheduledOccurrencePreservesCalendarAndSkipsMissingMonthDay(t *testing.T) {
	task := core.ScheduledTask{Recurrence: "monthly", DayOfMonth: 31, LocalTime: "09:30", Timezone: "America/New_York"}
	after := time.Date(2026, time.April, 1, 0, 0, 0, 0, time.UTC)
	next := schedulepkg.NextScheduledOccurrence(task, after).In(schedulepkg.MustLocation(task.Timezone))
	if next.Month() != time.May || next.Day() != 31 || next.Hour() != 9 || next.Minute() != 30 {
		t.Fatalf("next monthly occurrence = %s", next)
	}

	interval := core.ScheduledTask{Recurrence: "interval", StartAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), IntervalSeconds: 3600}
	got := schedulepkg.NextScheduledOccurrence(interval, time.Date(2026, 1, 1, 5, 20, 0, 0, time.UTC))
	want := time.Date(2026, 1, 1, 6, 0, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("next interval = %s, want %s", got, want)
	}
}

func TestNextScheduledOccurrenceSkipsNonexistentDSTWallTime(t *testing.T) {
	location := schedulepkg.MustLocation("America/New_York")
	task := core.ScheduledTask{Recurrence: "daily", LocalTime: "02:30", Timezone: "America/New_York"}
	after := time.Date(2026, time.March, 8, 0, 0, 0, 0, location)
	next := schedulepkg.NextScheduledOccurrence(task, after).In(location)
	if next.Day() != 9 || next.Hour() != 2 || next.Minute() != 30 {
		t.Fatalf("next DST occurrence = %s, want Mar 9 at 02:30", next)
	}
}

func TestDueScheduleQueuesOneNormalAgentRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = false
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	task, err := st.Schedules.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1",
		DeliveryChannel: "CREPORT",
		Repository:      "repo", Title: "Production health", Prompt: "Check production health.",
		Recurrence: "once", StartAt: now, NextRunAt: now, Timezone: "UTC",
		CatchUp: "latest", ActorID: cfg.Slack.Operators[0], SourceRef: "EvSchedule",
		ExpiresAt: now.Add(7 * 24 * time.Hour),
	}, cfg.Limits.MaxScheduledTasks, cfg.Limits.MaxSchedulesPerChannel)
	if err != nil {
		t.Fatal(err)
	}
	slack := &scheduleSlack{t: t, wantUser: task.ActorID, wantTeam: task.TeamID}
	slack.channel = slackui.Channel{ID: "CREPORT", Name: "health-reports", Member: true}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processScheduledTasks(ctx); err != nil {
		t.Fatal(err)
	}
	runs, err := st.Schedules.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 1 || runs[0].TaskID != task.ID || runs[0].AgentRunID == "" {
		t.Fatalf("scheduled runs = %+v, err=%v", runs, err)
	}
	agent, err := st.GetAgentRun(ctx, runs[0].AgentRunID)
	if err != nil || agent.SourceKind != "watch" || agent.SourceID != runs[0].SourceInput || agent.ChannelID != task.DeliveryChannel {
		t.Fatalf("agent run = %+v, err=%v", agent, err)
	}
	input, err := st.GetSlackInput(ctx, runs[0].SourceInput)
	if err != nil || input.Kind != "scheduled" || input.Text != task.Prompt || input.ChannelID != task.DeliveryChannel || input.ThreadTS != "" {
		t.Fatalf("synthetic input = %+v, err=%v", input, err)
	}
	var state decisionpkg.WatchTurnState
	if err := json.Unmarshal(input.Frozen, &state); err != nil ||
		!state.RepositoryPinned || state.Repository != task.Repository ||
		state.SessionChannelID != "scheduled:"+runs[0].SourceInput ||
		state.ResponseThreadTS != "" {
		t.Fatalf("scheduled state = %+v, err=%v", state, err)
	}
	deliveryMemory, err := st.Intelligence.GetChannelMemory(ctx, task.DeliveryChannel)
	if err != nil || deliveryMemory.Repository != cfg.Slack.DefaultRepository {
		t.Fatalf("delivery channel memory = %+v, err=%v", deliveryMemory, err)
	}
	if err := svc.processScheduledTasks(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("second scheduler pass = %v, want no due work", err)
	}
	runs, err = st.Schedules.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 1 {
		t.Fatalf("duplicate scheduled runs = %+v, err=%v", runs, err)
	}
}

func TestScheduledExecutionRepairsLegacyInputWithoutFrozenState(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC().Truncate(time.Second)
	task, err := st.Schedules.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", DeliveryChannel: "CREPORT",
		Repository: "repo", Title: "Production health", Prompt: "Check production health.",
		Recurrence: "once", StartAt: now, NextRunAt: now, Timezone: "UTC",
		CatchUp: "latest", ActorID: cfg.Slack.Operators[0], SourceRef: "EvLegacySchedule",
		ExpiresAt: now.Add(24 * time.Hour),
	}, cfg.Limits.MaxScheduledTasks, cfg.Limits.MaxSchedulesPerChannel)
	if err != nil {
		t.Fatal(err)
	}
	sourceInput := schedulepkg.ScheduledSourceInputID(task.ID, now)
	occurrence, execute, err := st.Schedules.ClaimScheduledTaskRun(
		ctx, task, now, time.Time{}, sourceInput, false, true, "",
	)
	if err != nil || !execute {
		t.Fatalf("claim occurrence: execute=%v err=%v", execute, err)
	}
	created, err := st.AdmitSyntheticSlackInput(ctx, core.SlackInput{
		ID: sourceInput, EnvelopeID: sourceInput, EventID: sourceInput,
		Kind: "scheduled", TeamID: task.TeamID, ChannelID: task.DeliveryChannel,
		UserID: task.ActorID, Text: task.Prompt, ReceivedAt: now,
	})
	if err != nil || !created {
		t.Fatalf("admit legacy input: created=%v err=%v", created, err)
	}

	slack := &scheduleSlack{t: t, wantUser: task.ActorID, wantTeam: task.TeamID}
	slack.channel = slackui.Channel{ID: "CREPORT", Name: "health-reports", Member: true}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.ensureScheduledTaskExecution(ctx, task, occurrence); err != nil {
		t.Fatal(err)
	}

	input, err := st.GetSlackInput(ctx, sourceInput)
	if err != nil {
		t.Fatal(err)
	}
	var state decisionpkg.WatchTurnState
	if err := json.Unmarshal(input.Frozen, &state); err != nil ||
		state.Repository != task.Repository || !state.RepositoryPinned ||
		state.SessionChannelID != "scheduled:"+sourceInput {
		t.Fatalf("repaired scheduled state = %+v, err=%v", state, err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", sourceInput)
	if err != nil || len(run.Context) == 0 {
		t.Fatalf("scheduled run = %+v, err=%v", run, err)
	}
	var runState decisionpkg.WatchTurnState
	if err := json.Unmarshal(run.Context, &runState); err != nil ||
		runState.Repository != task.Repository || !runState.RepositoryPinned ||
		runState.SessionChannelID != "scheduled:"+sourceInput {
		t.Fatalf("scheduled run state = %+v, err=%v", runState, err)
	}
}

func TestDueScheduleCreatesRecoverableNativeStatusAnchor(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	task, err := st.Schedules.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", DeliveryChannel: "CREPORT",
		Repository: "repo", Title: "Production health", Prompt: "Check production health.",
		Recurrence: "once", StartAt: now, NextRunAt: now, Timezone: "UTC",
		CatchUp: "latest", ActorID: cfg.Slack.Operators[0], SourceRef: "EvNativeSchedule",
		ExpiresAt: now.Add(24 * time.Hour),
	}, cfg.Limits.MaxScheduledTasks, cfg.Limits.MaxSchedulesPerChannel)
	if err != nil {
		t.Fatal(err)
	}
	slack := &scheduleSlack{t: t, wantUser: task.ActorID, wantTeam: task.TeamID}
	slack.channel = slackui.Channel{ID: "CREPORT", Name: "health-reports", Member: true}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processScheduledTasks(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	if len(slack.posts) != 0 {
		t.Fatalf("scheduled anchor bypassed durable outbox: %+v", slack.posts)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.processScheduledTasks(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 || slack.posts[0].thread != "" ||
		!strings.Contains(slack.posts[0].message.Text, "Production health") {
		t.Fatalf("scheduled anchor = %+v", slack.posts)
	}
	runs, err := st.Schedules.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 1 {
		t.Fatalf("scheduled runs = %+v, err=%v", runs, err)
	}
	input, err := st.GetSlackInput(ctx, runs[0].SourceInput)
	if err != nil || input.ThreadTS == "" || !watchInputWantsPendingStatus(input, decisionpkg.WatchTurnState{ConversationFollowup: true}) {
		t.Fatalf("scheduled input = %+v, err=%v", input, err)
	}
	var state decisionpkg.WatchTurnState
	if err := json.Unmarshal(input.Frozen, &state); err != nil || state.ResponseThreadTS != input.ThreadTS {
		t.Fatalf("scheduled route = %+v, err=%v", state, err)
	}
	if _, err := svc.ensureScheduledRunAnchor(ctx, task, runs[0], "CREPORT"); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 {
		t.Fatalf("anchor replay posted %d messages", len(slack.posts))
	}
}

func TestDueScheduleStopsWhenCreatorIsNoLongerAnOperator(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	task, err := st.Schedules.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", Repository: "repo",
		Title: "Production health", Prompt: "Check production health.",
		Recurrence: "daily", StartAt: now, NextRunAt: now, LocalTime: "09:00",
		Timezone: "UTC", CatchUp: "latest", ActorID: "UREMOVED", SourceRef: "EvRemoved",
		ExpiresAt: now.Add(7 * 24 * time.Hour),
	}, cfg.Limits.MaxScheduledTasks, cfg.Limits.MaxSchedulesPerChannel)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processScheduledTasks(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.Schedules.GetScheduledTask(ctx, task.ID)
	if err != nil || stored.Enabled || stored.LastOutcome != "skipped_unauthorized" || !stored.NextRunAt.IsZero() {
		t.Fatalf("disabled schedule = %+v, err=%v", stored, err)
	}
	runs, err := st.Schedules.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 0 {
		t.Fatalf("unauthorized active runs = %+v, err=%v", runs, err)
	}
}

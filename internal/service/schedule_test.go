package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
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
	s := &Service{cfg: cfg, slack: &fakeSlack{channel: slackui.Channel{
		ID: "CREPORT", Name: "health-reports", Member: true,
	}}}
	start := time.Now().UTC().Add(2 * time.Hour).Truncate(time.Second)
	input := core.SlackInput{ID: "slack_schedule", EventID: "EvSchedule", TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "100.1", UserID: cfg.Slack.Operators[0], Text: "Every Monday at 09:00 schedule a deep production health report."}
	offer := &core.ScheduleOffer{Title: "Weekly production health", Prompt: "Run a deep production health check and report material changes.", Repository: "repo", DeliveryChannel: "CREPORT", Recurrence: "weekly", StartAt: start.Format(time.RFC3339), Weekdays: []string{"monday"}, LocalTime: "09:00", Timezone: "UTC", CatchUp: "latest", ExpiresIn: "90d"}
	value, task, when, ok := s.prepareScheduleOfferAction(context.Background(), input, offer)
	if !ok || !strings.Contains(value, `"version":1`) || !strings.Contains(value, `"expires_in":"90d"`) || task.ChannelID != "COPS" || task.DeliveryChannel != "CREPORT" || task.ThreadTS != "100.1" || task.Recurrence != "weekly" || !strings.Contains(when, "monday") {
		t.Fatalf("schedule offer = ok=%t value=%q task=%+v when=%q", ok, value, task, when)
	}
	var payload scheduleActionPayload
	if err := decodeStrictJSON([]byte(value), &payload); err != nil {
		t.Fatal(err)
	}
	if _, err := s.scheduledTaskFromOffer(context.Background(), input, payload.Offer, time.Now().UTC()); err != nil {
		t.Fatalf("confirmed schedule payload did not round-trip: %v", err)
	}
	input.Text = "Run a deep production health report."
	if _, _, _, ok := s.prepareScheduleOfferAction(context.Background(), input, offer); ok {
		t.Fatal("schedule offer accepted without explicit scheduling intent")
	}
}

func TestScheduleIntentHandlesNaturalRelativeDurations(t *testing.T) {
	for _, text := range []string{
		"check this in 12 hours", "do this every Thursday", "run it weekly", "remind me tomorrow",
		"check this every 6 hours", "prepare this once a month",
	} {
		if !explicitScheduleRequest(text) {
			t.Fatalf("schedule intent not recognized: %q", text)
		}
	}
	if explicitScheduleRequest("check production health now") {
		t.Fatal("one-time immediate request was treated as a schedule")
	}
}

func TestScheduleRetryInheritsExplicitIntentFromSameOperatorThread(t *testing.T) {
	input := core.SlackInput{
		UserID: "UOPERATOR", ThreadTS: "1700.100", Text: "Try again <@UEMISAR>",
	}
	recent := []watchContextMessage{
		{MessageTS: "1699.900", SenderID: "UOTHER", SenderType: "human", Text: "Run this weekly."},
		{MessageTS: "1700.100", SenderID: "UOPERATOR", SenderType: "human", Text: "Post a deep review daily around 9 am."},
		{MessageTS: "1700.200", ThreadTS: "1700.100", SenderID: "UOPERATOR", SenderType: "human", Text: "Try again", Target: true},
	}
	resolved := scheduleInputWithConversationIntent(input, recent)
	if resolved.Text != recent[1].Text || !explicitScheduleRequest(resolved.Text) {
		t.Fatalf("resolved schedule intent = %q", resolved.Text)
	}

	input.Text = "Do not schedule it."
	if resolved := scheduleInputWithConversationIntent(input, recent); resolved.Text != input.Text {
		t.Fatalf("non-continuation inherited stale intent = %q", resolved.Text)
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
	local := task.NextRunAt.In(mustLocation(task.Timezone))
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
	next := nextScheduledOccurrence(task, after).In(mustLocation(task.Timezone))
	if next.Month() != time.May || next.Day() != 31 || next.Hour() != 9 || next.Minute() != 30 {
		t.Fatalf("next monthly occurrence = %s", next)
	}

	interval := core.ScheduledTask{Recurrence: "interval", StartAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), IntervalSeconds: 3600}
	got := nextScheduledOccurrence(interval, time.Date(2026, 1, 1, 5, 20, 0, 0, time.UTC))
	want := time.Date(2026, 1, 1, 6, 0, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("next interval = %s, want %s", got, want)
	}
}

func TestNextScheduledOccurrenceSkipsNonexistentDSTWallTime(t *testing.T) {
	location := mustLocation("America/New_York")
	task := core.ScheduledTask{Recurrence: "daily", LocalTime: "02:30", Timezone: "America/New_York"}
	after := time.Date(2026, time.March, 8, 0, 0, 0, 0, location)
	next := nextScheduledOccurrence(task, after).In(location)
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
	task, err := st.CreateScheduledTask(ctx, core.ScheduledTask{
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
	runs, err := st.ListActiveScheduledTaskRuns(ctx, 10)
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
	var state watchTurnState
	if err := json.Unmarshal(input.Frozen, &state); err != nil ||
		!state.RepositoryPinned || state.Repository != task.Repository ||
		state.SessionChannelID != "scheduled:"+task.ID ||
		state.ResponseThreadTS != "" {
		t.Fatalf("scheduled state = %+v, err=%v", state, err)
	}
	deliveryMemory, err := st.GetChannelMemory(ctx, task.DeliveryChannel)
	if err != nil || deliveryMemory.Repository != cfg.Slack.DefaultRepository {
		t.Fatalf("delivery channel memory = %+v, err=%v", deliveryMemory, err)
	}
	if err := svc.processScheduledTasks(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("second scheduler pass = %v, want no due work", err)
	}
	runs, err = st.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 1 {
		t.Fatalf("duplicate scheduled runs = %+v, err=%v", runs, err)
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
	task, err := st.CreateScheduledTask(ctx, core.ScheduledTask{
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
	stored, err := st.GetScheduledTask(ctx, task.ID)
	if err != nil || stored.Enabled || stored.LastOutcome != "skipped_unauthorized" || !stored.NextRunAt.IsZero() {
		t.Fatalf("disabled schedule = %+v, err=%v", stored, err)
	}
	runs, err := st.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 0 {
		t.Fatalf("unauthorized active runs = %+v, err=%v", runs, err)
	}
}

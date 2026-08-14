package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// selfReportConfig switches the digest on for Monday 09:00 UTC.
func selfReportConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := serviceConfig(t)
	cfg.Report.WeeklySelfReport = config.WeeklySelfReportConfig{
		Enabled: true, Channel: "C0REPORT",
		Weekday: "monday", LocalTime: "09:00", Timezone: "UTC",
	}
	return cfg
}

func selfReportService(
	t *testing.T,
	cfg config.Config,
	slackClient *fakeSlack,
) (*Service, *store.Store) {
	t.Helper()
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil), st
}

// Absent configuration means absent behaviour. A reporting job that posts, logs
// or writes state on a deployment that never asked for it is a job an operator
// discovers by being interrupted by it.
func TestTheWeeklyDigestDoesNothingWhenItIsNotConfigured(t *testing.T) {
	ctx := context.Background()
	slackClient := &fakeSlack{}
	svc, st := selfReportService(t, serviceConfig(t), slackClient)
	for offset := range 8 {
		at := time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC).AddDate(0, 0, offset)
		if err := svc.postWeeklySelfReport(ctx, at); err != nil {
			t.Fatal(err)
		}
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("an unconfigured digest posted %d messages", len(slackClient.posts))
	}
	sent, err := st.SelfReport.LastSent(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !sent.IsZero() {
		t.Fatalf("an unconfigured digest recorded a send at %s", sent)
	}
}

// Restarts are ordinary: the maintenance lane runs this every sweep and a crash
// loop runs it many times a minute. The digest is a message a channel sees, so
// one per week has to mean one — which is why the guard is a state row rather
// than a field on the process that just died.
func TestTheWeeklyDigestPostsOncePerWeekAcrossRestarts(t *testing.T) {
	ctx := context.Background()
	cfg := selfReportConfig(t)
	slackClient := &fakeSlack{}
	svc, st := selfReportService(t, cfg, slackClient)

	// Switched on mid-week. The first sweep must not post the moment the
	// feature deploys, or turning it on is itself an unprompted message.
	wednesday := time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC)
	if err := svc.postWeeklySelfReport(ctx, wednesday); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("the digest posted on the sweep that switched it on: %+v", slackClient.posts)
	}

	// Monday 09:00 arrives. One post, in the configured channel, carrying the
	// digest rather than a bare notification.
	monday := time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC)
	if err := svc.postWeeklySelfReport(ctx, monday); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("the scheduled send posted %d messages", len(slackClient.posts))
	}
	if slackClient.posts[0].channel != "C0REPORT" || slackClient.posts[0].thread != "" {
		t.Fatalf("the digest went to %+v", slackClient.posts[0])
	}
	for _, want := range []string{"Feedback:", "Learned:", "Open loops:", "Worst answer:"} {
		if !strings.Contains(slackClient.posts[0].message.Markdown, want) {
			t.Fatalf("posted message is missing %q: %q",
				want, slackClient.posts[0].message.Markdown)
		}
	}

	// Every later sweep in the same week must stay quiet, including one from a
	// process that just restarted and remembers nothing.
	for _, later := range []time.Time{
		monday.Add(time.Second), monday.Add(time.Hour), monday.AddDate(0, 0, 3),
		monday.AddDate(0, 0, 6),
	} {
		restarted, _ := selfReportService(t, cfg, slackClient)
		if err := restarted.postWeeklySelfReport(ctx, later); err != nil {
			t.Fatal(err)
		}
		if len(slackClient.posts) != 1 {
			t.Fatalf("a sweep at %s posted again: %d messages in total",
				later, len(slackClient.posts))
		}
	}

	// The next Monday is a new week and gets its own digest.
	if err := svc.postWeeklySelfReport(ctx, monday.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 2 {
		t.Fatalf("the following week brought the total to %d", len(slackClient.posts))
	}
	sent, err := st.SelfReport.LastSent(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !sent.Equal(monday.AddDate(0, 0, 7)) {
		t.Fatalf("recorded send = %s, want the occurrence it satisfied", sent)
	}
}

// A missed week must be missed once. A deployment that was down for a fortnight
// comes back to one digest, not one per skipped Monday, because the state row
// records the occurrence rather than counting them.
func TestALongOutageProducesOneDigestRatherThanOnePerMissedWeek(t *testing.T) {
	ctx := context.Background()
	slackClient := &fakeSlack{}
	svc, st := selfReportService(t, selfReportConfig(t), slackClient)
	if err := st.SelfReport.MarkSent(
		ctx, time.Date(2026, 7, 13, 9, 0, 0, 0, time.UTC),
	); err != nil {
		t.Fatal(err)
	}
	back := time.Date(2026, 8, 10, 11, 0, 0, 0, time.UTC)
	if err := svc.postWeeklySelfReport(ctx, back); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("coming back from a four-week outage posted %d digests", len(slackClient.posts))
	}
}

// A Slack failure must not consume the week. Recording the send before the post
// succeeds turns one transient rate limit into a silently missing week that
// nothing retries and nothing reports.
func TestAFailedPostLeavesTheWeekUnsent(t *testing.T) {
	ctx := context.Background()
	slackClient := &fakeSlack{postErr: errors.New("slack: rate limited")}
	svc, st := selfReportService(t, selfReportConfig(t), slackClient)
	monday := time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC)
	if err := st.SelfReport.MarkSent(ctx, monday.AddDate(0, 0, -7)); err != nil {
		t.Fatal(err)
	}
	if err := svc.postWeeklySelfReport(ctx, monday); err == nil {
		t.Fatal("a failed Slack post was reported as a successful send")
	}
	sent, err := st.SelfReport.LastSent(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !sent.Before(monday) {
		t.Fatalf("a failed post recorded the send anyway: %s", sent)
	}
	slackClient.postErr = nil
	if err := svc.postWeeklySelfReport(ctx, monday.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if sent, _ = st.SelfReport.LastSent(ctx); !sent.Equal(monday) {
		t.Fatalf("the retry recorded %s rather than the occurrence it satisfied", sent)
	}
}

// The send time is local, so it has to survive the two days a year when a local
// hour does not exist or happens twice. Chicago springs forward on 8 March 2026.
func TestTheSendTimeHoldsAcrossADaylightSavingTransition(t *testing.T) {
	ctx := context.Background()
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Skip("no timezone database")
	}
	cfg := selfReportConfig(t)
	cfg.Report.WeeklySelfReport.Weekday = "sunday"
	cfg.Report.WeeklySelfReport.LocalTime = "09:00"
	cfg.Report.WeeklySelfReport.Timezone = "America/Chicago"
	slackClient := &fakeSlack{}
	svc, st := selfReportService(t, cfg, slackClient)
	if err := st.SelfReport.MarkSent(
		ctx, time.Date(2026, 3, 1, 9, 0, 0, 0, chicago),
	); err != nil {
		t.Fatal(err)
	}
	// 09:00 local on the day the clocks moved is 14:00 UTC, not 15:00.
	if err := svc.postWeeklySelfReport(
		ctx, time.Date(2026, 3, 8, 14, 30, 0, 0, time.UTC),
	); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("the digest posted %d messages across the transition", len(slackClient.posts))
	}
	sent, err := st.SelfReport.LastSent(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if want := time.Date(2026, 3, 8, 9, 0, 0, 0, chicago); !sent.Equal(want) {
		t.Fatalf("recorded send = %s, want %s", sent.In(chicago), want)
	}
}

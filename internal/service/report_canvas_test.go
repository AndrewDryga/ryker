package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// reportFixture is a closed incident with an alert behind it and one recorded
// observation, which is the least durable record that gives all four reports
// something to say, plus a service whose Slack can hold canvases.
//
// The logger is a parameter because one of these tests is about what Responder
// says to its operator when Slack refuses, and a warning nobody can read is the
// same as no warning at all.
func reportFixture(
	t *testing.T,
	ctx context.Context,
	logger *slog.Logger,
) (*store.Store, *Service, *fakeSlack, core.Incident) {
	t.Helper()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incidents, err := st.ApplySignals(ctx, core.WebhookEvent{
		Route: "grafana", DedupeKey: "report-canvas", BodyDigest: "digest",
		Signals: []core.Signal{{
			Route: "grafana", SourceID: "alert-report", EventID: "alert-report-event",
			Repository: "repo", CorrelationKey: "api", Status: core.SignalFiring,
			Title: "API errors", Severity: "high", ReceivedAt: time.Now().UTC(),
		}},
	}, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CREPORT", "ems-api"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CREPORT", SourceInput: "run_1",
		Claim: "API recovered", Observation: "Probe returned HTTP 200",
		SourceType: "emisar", SourceName: "http probe", Target: "api",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	if incident, err = st.GetIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), logger,
	)
	return st, svc, slackClient, incident
}

// askForReport presses one of the card's four record controls and drives it
// through the durable input lane, which is the only way these reports are ever
// reached. They were `/responder timeline|evidence|handoff|postmortem` until
// 2026-08-15; the renderers did not change, the way in did.
func askForReport(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	svc *Service,
	incident core.Incident,
	command string,
) {
	t.Helper()
	actionID := map[string]string{
		"timeline":   slackui.ActionRecordTimeline,
		"evidence":   slackui.ActionRecordEvidence,
		"handoff":    slackui.ActionRecordHandoff,
		"postmortem": slackui.ActionRecordPostmortem,
	}[command]
	if actionID == "" {
		t.Fatalf("no record control renders %q", command)
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "record-" + command, EnvelopeID: "env-record-" + command,
		EventID: "event-record-" + command, Kind: "action",
		TeamID: svc.cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		UserID: "U123ABC", ActionID: actionID, ActionValue: incident.ID,
	}); err != nil || !created {
		t.Fatalf("admit %s = %v, %v", command, created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
}

func addOversizedTimeline(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	incident core.Incident,
) {
	t.Helper()
	for index := range 30 {
		if err := st.Intelligence.RecordTimeline(ctx, core.TimelineEvent{
			ID: fmt.Sprintf("long-event-%02d", index), IncidentID: incident.ID,
			Kind:      "test.verification",
			Title:     fmt.Sprintf("Detailed verification %02d", index),
			Detail:    strings.Repeat(fmt.Sprintf("measurement-%02d ", index), 25),
			CreatedAt: time.Now().UTC().Add(time.Duration(index) * time.Second),
		}); err != nil {
			t.Fatal(err)
		}
	}
}

// A short record belongs in the private answer itself. Moving four events into
// a Canvas and leaving only their count makes the operator click merely to
// discover whether the record contains anything useful.
func TestAShortTimelineIsAnsweredInlineWithItsRecordedEvents(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, incident := reportFixture(t, ctx, nil)
	slackClient.canvasURL = "https://example.slack.com/docs/T123ABC/F0TIMELINE"
	askForReport(t, ctx, st, svc, incident, "timeline")

	if len(slackClient.canvases) != 0 {
		t.Fatalf("short timeline was needlessly moved to Canvas: %+v", slackClient.canvases)
	}

	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("timeline replies = %+v, want exactly one", slackClient.ephemerals)
	}
	message := slackClient.ephemerals[0].message
	// Grey and with no primary: a document holds custody of nothing, and
	// nobody is being asked for anything by a report they can choose to read.
	if message.Stripe != slackui.StripeIdle {
		t.Fatalf("report card stripe = %q, want %q", message.Stripe, slackui.StripeIdle)
	}
	if !strings.Contains(message.Markdown, "Remediation timeline") ||
		!strings.Contains(message.Markdown, "Alert fired: API errors") {
		t.Fatalf("short timeline omitted its actual events: %+v", message)
	}
	for _, action := range message.Actions {
		if action.ID == slackui.ActionOpenCanvas {
			t.Fatalf("short timeline still offers a Canvas: %+v", message.Actions)
		}
	}
}

// A workspace whose token cannot make canvases keeps exactly the report it has
// always had. The attempt is the feature detection — there is no setting to
// consult, because a setting would be a second answer to a question the
// installed grant already answers — so the ask happens, Slack refuses, and the
// long-form message goes out instead.
//
// Never twice. A canvas that could not be made a moment ago will not be made by
// asking again, and the person waiting on the report should not pay a second
// round trip to arrive at the message they were always going to get.
//
// And the refusal is logged, because "the reports stopped being canvases" is
// otherwise invisible: every report still arrives, in the older form, and
// nothing on the surface says why.
func TestAReportSlackWillNotHoldAsACanvasIsPostedAsItsMessage(t *testing.T) {
	ctx := context.Background()
	logs := &bytes.Buffer{}
	st, svc, slackClient, incident := reportFixture(t, ctx, slog.New(
		slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelWarn}),
	))
	slackClient.canvasErr = errors.New("missing_scope")
	addOversizedTimeline(t, ctx, st, incident)
	askForReport(t, ctx, st, svc, incident, "timeline")

	if len(slackClient.canvases) != 1 {
		t.Fatalf("canvas attempts = %d, want one ask and no retry", len(slackClient.canvases))
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("timeline replies = %+v, want exactly one", slackClient.ephemerals)
	}
	message := slackClient.ephemerals[0].message
	if !strings.Contains(message.Markdown, "Remediation timeline") ||
		!strings.Contains(message.Markdown, "Alert fired: API errors") {
		t.Fatalf("the fallback reply dropped the report: %+v", message)
	}
	for _, action := range message.Actions {
		if action.ID == slackui.ActionOpenCanvas {
			t.Fatalf("the reply offers a canvas that was never made: %+v", message.Actions)
		}
	}
	logged := logs.String()
	if !strings.Contains(logged, "could not publish a report as a canvas") {
		t.Fatalf("nothing warned that canvases stopped working: %q", logged)
	}
	// Exactly once, for the same reason there is exactly one attempt: a second
	// line here would mean a retry nobody asked for.
	if count := strings.Count(logged, "missing_scope"); count != 1 {
		t.Fatalf("Slack's own words were logged %d times, want once: %q", count, logged)
	}
}

// All four reports are documents, and they escalate together. Postmortem was
// the one this was built for, but a timeline of forty events, an evidence
// directory and a shift handoff are the same shape of thing — so a change that
// escalates one of them and leaves another pasting itself into the room is a
// regression the postmortem test alone would not catch.
func TestEveryShortRecordViewAnswersWithItsActualContent(t *testing.T) {
	ctx := context.Background()
	for _, command := range []string{"timeline", "postmortem", "evidence", "handoff"} {
		t.Run(command, func(t *testing.T) {
			// A fresh service and store per report, so "exactly one canvas" is
			// a statement about this command rather than about the loop.
			st, svc, slackClient, incident := reportFixture(t, ctx, nil)
			askForReport(t, ctx, st, svc, incident, command)

			if len(slackClient.canvases) != 0 {
				t.Fatalf("the short %s control needlessly canvased = %+v",
					command, slackClient.canvases)
			}
			if len(slackClient.ephemerals) != 1 {
				t.Fatalf("the %s control replies = %+v", command, slackClient.ephemerals)
			}
			message := slackClient.ephemerals[0].message
			if strings.TrimSpace(message.Markdown) == "" {
				t.Fatalf("the %s control returned a summary without record detail: %+v",
					command, message)
			}
		})
	}
}

// An oversized record still belongs in a Canvas, but the Slack answer must
// preview real entries rather than state only a count and date range.
func TestAnOversizedTimelineUsesCanvasAndKeepsAUsefulPreview(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, incident := reportFixture(t, ctx, nil)
	slackClient.canvasURL = "https://example.slack.com/docs/T123ABC/F0LONG"
	addOversizedTimeline(t, ctx, st, incident)
	askForReport(t, ctx, st, svc, incident, "timeline")

	if len(slackClient.canvases) != 1 {
		t.Fatalf("oversized timeline canvases = %+v", slackClient.canvases)
	}
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Markdown, "Detailed verification") {
		t.Fatalf("oversized timeline has no useful Slack preview: %+v", slackClient.ephemerals)
	}
}

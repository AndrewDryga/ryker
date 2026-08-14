package service

import (
	"bytes"
	"context"
	"errors"
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

// askForReport runs one `/responder <report>` through the durable input lane,
// which is the only way these four commands are ever reached.
func askForReport(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	svc *Service,
	incident core.Incident,
	command string,
) {
	t.Helper()
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slash-" + command, EnvelopeID: "env-slash-" + command,
		EventID: "event-slash-" + command, Kind: "slash",
		TeamID: svc.cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		UserID: "U123ABC", Text: command, ActionID: "/responder",
	}); err != nil || !created {
		t.Fatalf("admit /responder %s = %v, %v", command, created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
}

// The document goes to the canvas and the summary stays in the room, and the
// two halves have to stay apart.
//
// A forty-event timeline pasted into a channel pushes every other message off
// the screen and is unfindable a day later. What replaces it is a card carrying
// the one judgement a reader needs — so a card that also carried the body would
// be the wall of text it replaced with a link stapled to it, and a canvas
// holding only the summary would have thrown the report away.
func TestATimelineIsPublishedAsACanvasAndAnsweredWithASummaryCard(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, incident := reportFixture(t, ctx, nil)
	slackClient.canvasURL = "https://example.slack.com/docs/T123ABC/F0TIMELINE"
	askForReport(t, ctx, st, svc, incident, "timeline")

	if len(slackClient.canvases) != 1 {
		t.Fatalf("timeline canvases = %+v, want exactly one", slackClient.canvases)
	}
	canvas := slackClient.canvases[0]
	if canvas.channel != incident.ChannelID {
		t.Fatalf("canvas channel = %q, want the room the report was asked for, %q",
			canvas.channel, incident.ChannelID)
	}
	// The body the message form would have carried, verbatim: the heading the
	// report opens with, and an event that only exists because this fixture
	// recorded it.
	if !strings.Contains(canvas.markdown, "Remediation timeline") ||
		!strings.Contains(canvas.markdown, "Alert fired: API errors") {
		t.Fatalf("canvas body = %q, want the whole long-form report", canvas.markdown)
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
	// One control, and it is the way in. A "post it here instead" button would
	// need a handler that could rebuild the report at click time, and a button
	// that cannot do what its label says is worse than no button.
	if len(message.Actions) != 1 {
		t.Fatalf("report card actions = %+v, want only the way into the canvas",
			message.Actions)
	}
	action := message.Actions[0]
	if action.ID != slackui.ActionOpenCanvas || action.URL != slackClient.canvasURL {
		t.Fatalf("report card action = %+v, want %q pointing at %q",
			action, slackui.ActionOpenCanvas, slackClient.canvasURL)
	}
	if message.Markdown != "" {
		t.Fatalf("the summary card is still carrying the document: %q", message.Markdown)
	}
	if rendered := renderedSlackMessage(message); strings.Contains(
		rendered, "Alert fired: API errors",
	) {
		t.Fatalf("the summary card repeated the canvas body: %q", rendered)
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
func TestEveryLongFormReportEscalatesToACanvas(t *testing.T) {
	ctx := context.Background()
	for _, command := range []string{"timeline", "postmortem", "evidence", "handoff"} {
		t.Run(command, func(t *testing.T) {
			// A fresh service and store per report, so "exactly one canvas" is
			// a statement about this command rather than about the loop.
			st, svc, slackClient, incident := reportFixture(t, ctx, nil)
			askForReport(t, ctx, st, svc, incident, command)

			if len(slackClient.canvases) != 1 {
				t.Fatalf("/responder %s canvases = %+v, want exactly one",
					command, slackClient.canvases)
			}
			canvas := slackClient.canvases[0]
			if strings.TrimSpace(canvas.title) == "" {
				t.Fatalf("/responder %s made an untitled canvas: %+v", command, canvas)
			}
			if strings.TrimSpace(canvas.markdown) == "" {
				t.Fatalf("/responder %s made an empty canvas: %+v", command, canvas)
			}
			if len(slackClient.ephemerals) != 1 {
				t.Fatalf("/responder %s replies = %+v", command, slackClient.ephemerals)
			}
			message := slackClient.ephemerals[0].message
			opened := false
			for _, action := range message.Actions {
				if action.ID == slackui.ActionOpenCanvas && action.URL != "" {
					opened = true
				}
			}
			if !opened {
				t.Fatalf("/responder %s card has no way into its canvas: %+v",
					command, message.Actions)
			}
		})
	}
}

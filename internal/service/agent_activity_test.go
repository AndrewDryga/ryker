package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// activityRunFixture drives one incident run up to the point where it is
// running against Coop and the poll loop is what advances it.
func activityRunFixture(t *testing.T) (
	context.Context, *store.Store, *Service, *fakeCoop, core.AgentRun,
) {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-activity", 1); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	run, created, err := svc.queueIncidentAgentRun(
		ctx, incident, "initial", incident.ID, "", "Investigate the alert.",
	)
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	running, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	return ctx, st, svc, coopClient, running
}

func activityEvent(sequence int64, turnID, eventType, payload string) coop.Event {
	return coop.Event{
		ID: "evt_" + eventType, SessionID: "ses_1", Sequence: sequence,
		TurnID: turnID, Type: eventType, Payload: []byte(payload),
	}
}

// The narration of a turn has to survive the poll that also finishes it. Coop
// sequences activity below the terminal event precisely so that one page can
// carry both; the loop returns on the terminal event, so anything recorded
// after that branch would be lost the moment a fast turn arrived whole.
func TestPollRecordsActivityDeliveredAlongsideTheTerminalEvent(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	coopClient.events = append(coopClient.events,
		activityEvent(1, run.CoopTurnID, "model.thought",
			`{"text":"Check whether the rollout finished."}`),
		activityEvent(2, run.CoopTurnID, "tool.started",
			`{"tool_call_id":"t1","title":"Emisar nomad.job_status","kind":"execute",`+
				`"input":{"job":"website"}}`),
		activityEvent(3, run.CoopTurnID, "tool.completed",
			`{"tool_call_id":"t1","title":"Emisar nomad.job_status","kind":"execute","status":"completed"}`),
		activityEvent(4, run.CoopTurnID, "turn.completed", `{"stop_reason":"end_turn"}`),
	)
	svc.pollAgentRuns(ctx)

	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	moments, err := st.Activity.ListForEpisode(ctx, episode.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 3 {
		t.Fatalf("want the three narrated moments, got %d: %+v", len(moments), moments)
	}
	if moments[0].Kind != "model.thought" || moments[1].Kind != "tool.started" ||
		moments[2].Kind != "tool.completed" {
		t.Fatalf("moments arrived out of order: %+v", moments)
	}
	started := moments[1]
	if started.Title != "Emisar nomad.job_status" || started.ToolKind != "execute" ||
		started.ToolCallID != "t1" {
		t.Fatalf("the call lost its identity: %+v", started)
	}
	if string(started.Detail) != `{"input":{"job":"website"}}` {
		t.Fatalf("arguments were not kept: %s", started.Detail)
	}
	if moments[2].Status != "completed" {
		t.Fatalf("the completion lost its status: %+v", moments[2])
	}
}

// Coop's cursor is rewound to zero whenever it outruns the session, so the
// same narration is delivered again by design.
func TestPollDoesNotTellTheSameStoryTwice(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	coopClient.events = append(coopClient.events,
		activityEvent(1, run.CoopTurnID, "tool.started",
			`{"tool_call_id":"t1","title":"Read apps_cms.tf","kind":"read"}`),
	)
	svc.pollAgentRuns(ctx)
	// A second poll of the same session, with the cursor wound back.
	if err := st.AdvanceAgentRunEvents(ctx, run.ID, 0); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)

	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	moments, err := st.Activity.ListForEpisode(ctx, episode.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 1 {
		t.Fatalf("a replay duplicated the story: %+v", moments)
	}
}

// An older Coop sends no payload. The moment still happened, and recording its
// kind is a truer trace than dropping it.
func TestPollKeepsAnUnreadableMoment(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	coopClient.events = append(coopClient.events,
		activityEvent(1, run.CoopTurnID, "tool.started", ""),
	)
	svc.pollAgentRuns(ctx)

	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	moments, err := st.Activity.ListForEpisode(ctx, episode.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 1 || moments[0].Kind != "tool.started" {
		t.Fatalf("a payload-less moment was dropped: %+v", moments)
	}
}

// Activity belonging to another turn on the same session is not this run's.
func TestPollIgnoresActivityFromAnotherTurn(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	coopClient.events = append(coopClient.events,
		activityEvent(1, "some_other_turn", "tool.started",
			`{"tool_call_id":"t9","title":"Not ours","kind":"read"}`),
	)
	svc.pollAgentRuns(ctx)

	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	moments, err := st.Activity.ListForEpisode(ctx, episode.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 0 {
		t.Fatalf("another turn's work was attributed to this run: %+v", moments)
	}
}

// The poll stamps the episode with when the turn last did something.
//
// last_progress_at answers a different question — when the model last wrote
// prose about itself — and the run this design was built from is why the two
// have to be separate columns: it worked for 57 minutes, made 119 tool calls,
// and reported "Still working" twice, byte for byte. A watchdog reading only
// the prose accused a turn that had never stopped. This column is what it will
// read instead.
func TestPollStampsTheEpisodeWithItsLastNarratedMoment(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !episode.LastActivityAt.IsZero() {
		t.Fatalf("an episode that has narrated nothing claims a last activity: %v",
			episode.LastActivityAt)
	}
	moment := time.Date(2026, 8, 13, 19, 42, 0, 0, time.UTC)
	event := activityEvent(1, run.CoopTurnID, "tool.started",
		`{"tool_call_id":"t1","title":"Read traefik.nomad.hcl","kind":"read"}`)
	event.OccurredAt = moment
	coopClient.events = append(coopClient.events, event)
	svc.pollAgentRuns(ctx)

	episode, err = st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !episode.LastActivityAt.Equal(moment) {
		t.Fatalf("last activity = %v, want the moment Coop narrated: %v",
			episode.LastActivityAt, moment)
	}

	// A rewound cursor redelivers moments from earlier in the same turn. The
	// stamp must not follow them backwards, or a working turn reads as stalled.
	if err := st.AdvanceAgentRunEvents(ctx, run.ID, 0); err != nil {
		t.Fatal(err)
	}
	earlier := activityEvent(2, run.CoopTurnID, "model.thought", `{"text":"Earlier."}`)
	earlier.OccurredAt = moment.Add(-10 * time.Minute)
	coopClient.events = append(coopClient.events, earlier)
	svc.pollAgentRuns(ctx)

	episode, err = st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !episode.LastActivityAt.Equal(moment) {
		t.Fatalf("a replayed earlier moment moved freshness backwards: %v",
			episode.LastActivityAt)
	}
}

// A rate limit is a moment in the episode, not a gap in it.
//
// On 2026-08-15 a turn spent hours inside provider 429 backoff and the episode
// timeline showed nothing at all between its last tool call and its terminal —
// an operator reading that page could not tell a throttled turn from a wedged
// one, and neither could the deadline that cancel-replayed them, which is why
// it was widened to 45m. Coop narrates both halves now; this asserts the host
// files them like any other narrated moment, with the label the timeline shows.
func TestAThrottledTurnIsFiledAsNarrationRatherThanSilence(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	coopClient.events = append(coopClient.events,
		activityEvent(1, run.CoopTurnID, "provider.backoff",
			`{"attempt":2,"target":"codex@work","next_target":"claude@oncall",`+
				`"retry_after_seconds":3600,"reset_at":"2026-08-15T04:00:00Z"}`),
		activityEvent(2, run.CoopTurnID, "provider.alive", `{"frames":41,"bytes":8192}`),
		activityEvent(3, run.CoopTurnID, "turn.completed", `{"stop_reason":"end_turn"}`),
	)
	svc.pollAgentRuns(ctx)

	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	moments, err := st.Activity.ListForEpisode(ctx, episode.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(moments) != 2 {
		t.Fatalf("want both provider moments stored, got %d: %+v", len(moments), moments)
	}
	if moments[0].Kind != "provider.backoff" || moments[1].Kind != "provider.alive" {
		t.Fatalf("provider narration was not filed: %+v", moments)
	}
	if moments[0].Title != "rate limited on codex@work, retrying in 3600s (attempt 2)" {
		t.Fatalf("the backoff row does not name the weather: %q", moments[0].Title)
	}
	if moments[1].Title != "provider streaming, 41 frames" {
		t.Fatalf("the pulse row does not name the transport: %q", moments[1].Title)
	}
	if !strings.Contains(string(moments[0].Detail), "claude@oncall") {
		t.Fatalf("the backoff row does not say where the ladder went: %s", moments[0].Detail)
	}
}

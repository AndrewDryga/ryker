package service

import (
	"context"
	"testing"

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

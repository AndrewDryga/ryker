package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The thread status names this turn's kind of progress once it has narrated
// any, while the exact call remains in the task card and work record.
//
// The general sentence stays for a turn that has not: "is investigating..."
// about a run that has made no call is a placeholder, and "is running" about a
// call that has not happened would be a lie. So the fallback is tested beside
// the derivation, in the same run, before and after the first moment lands.
func TestThreadStatusNamesProgressWithoutRelayingTheCall(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	run := seedWorkingRun(t, ctx, st)

	if status := svc.agentRunNativeStatus(ctx, run); status != "is investigating..." {
		t.Fatalf("a turn with nothing recorded = %q, want the static status", status)
	}

	recordMoments(t, ctx, st, run, []core.AgentActivity{{
		Kind: "tool.started", ToolKind: "mcp", Title: "mcp.emisar.run_action",
		Detail: json.RawMessage(
			`{"input":{"server":"emisar","tool":"run_action","arguments":{"action_id":"vl.query"}}}`,
		),
	}})
	if status := svc.agentRunNativeStatus(ctx, run); status != "is checking evidence..." {
		t.Fatalf("status = %q", status)
	}

	// And it follows the work rather than freezing on the first call.
	recordMoments(t, ctx, st, run, []core.AgentActivity{{
		Kind: "tool.started", ToolKind: "read",
		Title: "Read file '/coop/repositories/infra/terraform/apps_cms.tf'",
	}})
	if status := svc.agentRunNativeStatus(ctx, run); status != "is inspecting the workspace..." {
		t.Fatalf("status did not follow the turn: %q", status)
	}
}

// Deriving the status changed what it says, not how often it is written.
//
// This is the whole risk of the change. The status is a Slack write on a
// per-channel budget shared with every reply queued behind it, and a status
// derived from a stream that produces hundreds of moments per turn is one
// `assistant.threads.setStatus` per tool call if anything in the narration path
// sets it. Nothing in that path does: recording a moment marks the card stale
// and stops. The count below is the assertion — 40 narrated moments, zero
// status writes — and it fails the moment somebody wires the obvious shortcut.
func TestNarrationNeverSpendsAStatusWrite(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	run := seedWorkingRun(t, ctx, st)

	moments := make([]core.AgentActivity, 0, 40)
	for index := range 40 {
		moments = append(moments, core.AgentActivity{
			Kind: "tool.started", ToolKind: "execute", Title: "Terminal",
			Detail: json.RawMessage(
				`{"input":{"command":"go test ./internal/service -run ` +
					string(rune('a'+index%26)) + `"}}`,
			),
		})
	}
	recordMoments(t, ctx, st, run, moments)
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 0 {
		t.Fatalf("narration wrote %d thread statuses: %+v", len(slack.statuses), slack.statuses)
	}

	// The one driver that does write on a timer still writes exactly once per
	// interval, whatever the stream underneath it did. Two checkins are
	// attempted back to back; the second is inside the window and is refused.
	if err := svc.refreshWorkEpisodeProgress(ctx, run); err != nil {
		t.Fatal(err)
	}
	if err := svc.refreshWorkEpisodeProgress(ctx, run); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) > 1 {
		t.Fatalf(
			"the progress checkin wrote %d statuses in one interval: %+v",
			len(slack.statuses), slack.statuses,
		)
	}
}

// The host's own checkin row says what the turn did, when the turn did
// anything.
//
// "Still working; completing the requested checks" is the row this replaces. It
// was written every two minutes, byte for byte identical each time, so two rows
// an hour apart could not tell a reader whether anything had happened between
// them — which is the exact question a checkin row exists to answer.
func TestCheckinRowSaysWhatTheTurnHasActuallyDone(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.EpisodeProgressInterval.Duration = 30 * time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	run := seedWorkingRun(t, ctx, st)

	// Nothing narrated yet: the effort's own sentence, exactly as before.
	if err := svc.refreshWorkEpisodeProgress(ctx, run); err != nil {
		t.Fatal(err)
	}
	first := latestProgressSummary(t, ctx, st, run.ID)
	if first != "Still investigating; verifying impact and the safest response" {
		t.Fatalf("silent-turn checkin = %q", first)
	}

	recordMoments(t, ctx, st, run, []core.AgentActivity{{
		Kind: "tool.started", ToolKind: "mcp", Title: "mcp.emisar.run_action",
		Detail: json.RawMessage(
			`{"input":{"server":"emisar","tool":"run_action","arguments":{"action_id":"vl.query"}}}`,
		),
	}})
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "investigating", "Checking impact",
		"Finish the evidence plan", time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.refreshWorkEpisodeProgress(ctx, run); err != nil {
		t.Fatal(err)
	}
	second := latestProgressSummary(t, ctx, st, run.ID)
	if !strings.HasPrefix(second, "Still investigating — last: emisar vl.query") {
		t.Fatalf("narrated-turn checkin = %q", second)
	}
	if !strings.Contains(second, "1 tool calls") {
		t.Fatalf("the checkin lost its totals: %q", second)
	}
	if second == first {
		t.Fatal("two checkins on a turn that did work said the same thing")
	}
	if len(second) > 200 {
		t.Fatalf("checkin row is %d bytes: %q", len(second), second)
	}
}

func seedWorkingRun(t *testing.T, ctx context.Context, st *store.Store) core.AgentRun {
	t.Helper()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_status", "incident-status", 1); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "signal", SourceID: "sig_status",
		SessionID: "ses_status",
		Episode: &core.WorkEpisode{
			Effort: core.EffortIncidentInvestigation, Authority: core.AuthorityReadOnly,
		},
	})
	if err != nil || !created {
		t.Fatalf("seed a working run = %+v, %t, %v", run, created, err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "investigating", "Checking impact",
		"Finish the evidence plan", time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	return run
}

func recordMoments(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	run core.AgentRun,
	moments []core.AgentActivity,
) {
	t.Helper()
	existing, err := st.Activity.TailForEpisode(ctx, run.EpisodeID, 1)
	if err != nil {
		t.Fatal(err)
	}
	base := int64(existing.Recorded)
	for index, moment := range moments {
		moment.EpisodeID = run.EpisodeID
		moment.AgentRunID = run.ID
		moment.SessionID = run.SessionID
		moment.TurnID = "coop_turn_status"
		moment.Sequence = base + int64(index) + 1
		moment.OccurredAt = time.Now().UTC().Add(time.Duration(index) * time.Second)
		stored, recordErr := st.Activity.Record(ctx, moment)
		if recordErr != nil || !stored {
			t.Fatalf("record moment %d = %t, %v", index, stored, recordErr)
		}
	}
}

func latestProgressSummary(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	runID string,
) string {
	t.Helper()
	progress, err := st.ListWorkEpisodeProgress(ctx, runID, 20)
	if err != nil || len(progress) == 0 {
		t.Fatalf("progress = %+v, %v", progress, err)
	}
	return progress[0].Summary
}

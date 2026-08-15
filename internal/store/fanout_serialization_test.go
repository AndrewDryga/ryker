package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/fanout"
)

// Two layers serialize on the conversation key, and neither one is visible from
// the code that queues the work. The agent-run lease refuses any run whose
// conversation key is already preparing, running, applying or finalizing
// (agent_run.go, the NOT EXISTS over active runs); the scheduled work lane
// refuses any item whose conversation key already holds a live lease (work.go,
// the NOT EXISTS over running items).
//
// A parallel investigation whose branches inherited the episode's conversation
// key would be queued in parallel, counted as parallel, rendered as parallel
// lanes on the trace page — and executed strictly one after another. That is
// the failure mode that looks exactly like success, and it is why the key is
// minted by one function instead of being suffixed at each of the two sites.
//
// This test is the check on that claim, in both directions: the shared key
// still serializes (which is what protects a single conversation), and the
// goal-scoped keys do not.
// Restart is where a fan-out is most exposed: the branches are ordinary
// agent_runs, so the generic "preparing goes back to pending" sweep already
// resumes them, and the sweep immediately before it hands every unbound
// incident run the incident's own Coop session. That session is the lead's.
// A branch given it would take its next turn inside the lead's fork —
// serialized against the lead by the very column this feature just stopped
// serializing on, writing into a session it does not own, and with no trace
// saying which turn belonged to which goal.
//
// The branch's session is bound at prepare time from its own fork, so the
// correct recovery for an interrupted branch is to leave the field empty and
// let it re-prepare.
func TestRestartResumesBranchesWithoutHandingThemTheLeadSession(t *testing.T) {
	ctx := context.Background()
	st, incident := incidentWithSession(t)

	goals := []string{"goal-host", "goal-dependency"}
	for _, goalID := range goals {
		if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunIncident, IncidentID: incident.ID,
			ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
			ConversationKey: fanout.BranchConversationKey("incident:"+incident.ID, goalID),
			SourceKind:      "fanout", SourceID: "branch_" + goalID,
		}); err != nil {
			t.Fatal(err)
		}
	}
	// Both leased and interrupted mid-preparation, which is the crash this
	// recovers from.
	interrupted := map[string]string{}
	for range goals {
		leased, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatal(err)
		}
		goalID, _ := fanout.GoalOf(leased.ConversationKey)
		interrupted[goalID] = leased.ID
	}
	if len(interrupted) != len(goals) {
		t.Fatalf("leased %d distinct branches, want %d", len(interrupted), len(goals))
	}

	if err := st.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}

	for goalID, runID := range interrupted {
		run, err := st.GetAgentRun(ctx, runID)
		if err != nil {
			t.Fatal(err)
		}
		if run.SessionID != "" {
			t.Fatalf("branch %s was recovered onto session %q; the lead owns "+
				"the incident's session and a branch must re-prepare its own fork",
				goalID, run.SessionID)
		}
		if run.State != core.AgentRunPending {
			t.Fatalf("branch %s recovered in state %q, want pending so its child "+
				"episode resumes", goalID, run.State)
		}
	}

	// Resumed, not duplicated: the same two branches lease again, and the
	// fan-out is still two goals wide.
	resumed := map[string]bool{}
	for range goals {
		leased, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatalf("a recovered branch did not lease again: %v", err)
		}
		goalID, _ := fanout.GoalOf(leased.ConversationKey)
		if resumed[goalID] {
			t.Fatalf("goal %q resumed twice", goalID)
		}
		resumed[goalID] = true
	}
	if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("recovery left a third runnable branch behind (err = %v)", err)
	}
}

// incidentWithSession is an incident far enough along to lease runs against:
// channelled, rooted, and holding the one Coop session the lead investigates in.
func incidentWithSession(t *testing.T) (*Store, core.Incident) {
	t.Helper()
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incidents = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_lead", "fork-lead", 1); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	return st, incident
}

func TestBranchConversationsLeaseTogetherWhileOneConversationStillSerializes(t *testing.T) {
	ctx := context.Background()

	t.Run("agent runs", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()

		// The trap, stated as a control: two runs sharing the episode's
		// conversation are the naive branch implementation, and only one of them
		// ever starts.
		shared := "incident:inc_shared"
		for _, source := range []string{"input_shared_a", "input_shared_b"} {
			if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
				Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
				ConversationKey: shared, SourceKind: "watch", SourceID: source,
			}); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := st.LeaseAgentRun(ctx); err != nil {
			t.Fatalf("the first run of a shared conversation did not lease: %v", err)
		}
		if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, ErrNotFound) {
			t.Fatalf("two runs on one conversation both leased (err = %v); "+
				"the per-conversation mutex is gone and this test's premise with it", err)
		}

		// The fix: a branch conversation per goal, and both start.
		base := "incident:inc_branching"
		for _, goalID := range []string{"goal-host", "goal-dependency"} {
			if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
				Mode: core.AgentRunTriage, ChannelID: "C2", ThreadTS: "200.1",
				ConversationKey: fanout.BranchConversationKey(base, goalID),
				SourceKind:      "watch", SourceID: "input_" + goalID,
			}); err != nil {
				t.Fatal(err)
			}
		}
		first, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatalf("the first branch did not lease: %v", err)
		}
		second, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatalf("the second branch was serialized behind the first: %v", err)
		}
		firstGoal, ok := fanout.GoalOf(first.ConversationKey)
		if !ok {
			t.Fatalf("the leased run %q is not identifiable as a branch", first.ConversationKey)
		}
		secondGoal, ok := fanout.GoalOf(second.ConversationKey)
		if !ok {
			t.Fatalf("the leased run %q is not identifiable as a branch", second.ConversationKey)
		}
		if firstGoal == secondGoal {
			t.Fatalf("both leases went to goal %q", firstGoal)
		}
	})

	t.Run("the incident's own active turn", func(t *testing.T) {
		st, incident := incidentWithSession(t)

		// Both branches are admitted before either runs, which is what a
		// fan-out actually queues.
		for _, goalID := range []string{"goal-host", "goal-dependency"} {
			if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
				Mode: core.AgentRunIncident, IncidentID: incident.ID,
				ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
				ConversationKey: fanout.BranchConversationKey("incident:"+incident.ID, goalID),
				SourceKind:      "fanout", SourceID: "branch_" + goalID,
			}); err != nil {
				t.Fatal(err)
			}
		}
		first, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatalf("the first branch did not lease: %v", err)
		}
		// Submitting is what sets incidents.active_turn_id, and the incident is
		// shared by every branch under it. This is the fourth serializer: the
		// first branch to reach Coop would otherwise hold the whole incident.
		if err := st.BindAgentRunSession(
			ctx, first.ID, "ses_branch_1", 0, incident.Repository, 0, first.Context,
		); err != nil {
			t.Fatal(err)
		}
		if err := st.MarkAgentRunSubmitted(ctx, first.ID, "coop_turn_branch_1", 2, 0); err != nil {
			t.Fatal(err)
		}
		second, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatalf("the second branch was serialized behind the first branch's "+
				"turn on the shared incident: %v; branches run on their own Coop "+
				"sessions and must not queue behind the incident's active turn", err)
		}
		firstGoal, _ := fanout.GoalOf(first.ConversationKey)
		secondGoal, _ := fanout.GoalOf(second.ConversationKey)
		if firstGoal == "" || secondGoal == "" || firstGoal == secondGoal {
			t.Fatalf("leases went to goals %q and %q, want two distinct branches",
				firstGoal, secondGoal)
		}

		// The control, and the reason this is a per-session exemption rather
		// than a deletion: the lead shares the incident's one session, so a
		// lead run still waits for the incident's turn to clear.
		if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunIncident, IncidentID: incident.ID,
			ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
			ConversationKey: "incident:" + incident.ID,
			SourceKind:      "watch", SourceID: "lead_second_sweep",
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, ErrNotFound) {
			t.Fatalf("a lead run leased while the incident held an active turn "+
				"(err = %v); the per-incident gate is gone, not narrowed", err)
		}
	})

	t.Run("scheduled work", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()

		shared := "incident:inc_shared"
		for _, subject := range []string{"branch-a", "branch-b"} {
			if err := st.EnqueueWork(ctx, WorkItem{
				Kind: "episode_attempt", SubjectID: subject,
				Lane: WorkLaneControl, ConversationKey: shared, Priority: 20,
			}); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute); err != nil {
			t.Fatalf("the first item of a shared conversation did not lease: %v", err)
		}
		if _, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute); !errors.Is(err, ErrNotFound) {
			t.Fatalf("two items on one conversation both leased (err = %v); "+
				"the work lane's per-conversation mutex is gone", err)
		}

		base := "incident:inc_branching"
		for _, goalID := range []string{"goal-host", "goal-dependency"} {
			if err := st.EnqueueWork(ctx, WorkItem{
				Kind: "episode_attempt", SubjectID: "branch-" + goalID,
				Lane: WorkLaneControl, Priority: 20,
				ConversationKey: fanout.BranchConversationKey(base, goalID),
			}); err != nil {
				t.Fatal(err)
			}
		}
		leased := map[string]bool{}
		for range 2 {
			item, err := st.LeaseWork(ctx, WorkLaneControl, time.Minute)
			if err != nil {
				t.Fatalf("a branch work item was serialized behind another: %v", err)
			}
			goalID, ok := fanout.GoalOf(item.ConversationKey)
			if !ok {
				continue
			}
			if leased[goalID] {
				t.Fatalf("goal %q was leased twice", goalID)
			}
			leased[goalID] = true
		}
		if len(leased) != 2 {
			t.Fatalf("leased %d distinct branch goals, want 2", len(leased))
		}
	})
}

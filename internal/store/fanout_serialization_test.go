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

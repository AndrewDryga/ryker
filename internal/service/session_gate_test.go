package service

import (
	"context"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The Coop session every tool use needs used to be bound only after a room's
// root card landed — store.SetCoopSession refused a row whose root_ts was empty in its WHERE
// clause and ListSessionWork carried it in its seed. That is the bridge §25
// phase 5 exists to break, and it was measurably load-bearing: the incident
// root carries four proven capabilities at once.
//
// For thread-scoped work it was never true in substance. An engineering task
// speaks in the operator's own thread, which is bound before the card is even
// enqueued; root_ts is where the CARD landed, which is presentation. Sequencing
// the session behind it meant a card that could not post — channel archived
// between the bind and the delivery, an enqueue that failed permanently — left
// every turn of that task pending forever. LeaseAgentRun requires a bound
// session, ListSessionWork required a root, and nothing anywhere timed out, so
// the work was not blocked or parked or reported. It was silently dead.
func TestAThreadScopedTaskStartsItsSessionBeforeItsCardLands(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	task, created, err := st.CreateEngineeringTask(
		ctx, cfg.Slack.DefaultRepository, "session-gate", "Raise the timeout",
		"summary", cfg.Slack.Operators[0], "CWATCH", "1700.100", 100,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if !task.IsThreadScoped() {
		t.Fatalf("engineering task is not thread scoped: %+v", task)
	}

	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	// One pass binds the thread and enqueues the card. Nothing delivers it:
	// this is the channel that went away, or the post that will never succeed.
	if err := svc.processChannelIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	bound, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if bound.RootTS != "" {
		t.Fatalf("the card landed after all; this test proves nothing: %+v", bound)
	}
	if bound.ConversationThreadTS() != "1700.100" {
		t.Fatalf("thread-scoped work lost its conversation: %+v", bound)
	}

	// The decision first: the scheduler's own seed offers this work for a
	// session, without a root card anywhere.
	seeded, err := st.ListSessionWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, item := range seeded {
		if item.ID == task.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf(
			"thread-scoped work with a bound conversation was not offered a session; "+
				"every turn of it would sit pending forever, unblocked and unreported "+
				"(seeded=%d)", len(seeded),
		)
	}

	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	live, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if live.CoopSessionID == "" {
		t.Fatalf("no Coop session was bound without a root card: %+v", live)
	}
	if live.RootTS != "" {
		t.Fatalf("the session bound only because a root card appeared: %+v", live)
	}

	// And the card landing afterwards must not walk the workflow back over the
	// session that started while it was in flight.
	if live.Workflow != core.WorkflowInvestigating {
		t.Fatalf("bound work is not investigating: %+v", live)
	}
	drainSlackDeliveries(t, ctx, svc)
	settled, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if settled.RootTS == "" {
		t.Fatalf("the card never posted at all: %+v", settled)
	}
	if settled.Workflow != core.WorkflowInvestigating {
		t.Fatalf(
			"the card landing moved live work back to %q; the session it would ask "+
				"to be provisioned is already running",
			settled.Workflow,
		)
	}
}

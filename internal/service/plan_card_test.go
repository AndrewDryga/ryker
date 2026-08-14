package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The whole loop, through the paths production uses and no others.
//
// A model plans with plan_goal, the card shows the plan as checks under the
// step doing them, the next turn closes one with update_goal, and the card
// shows the tick. Each half of that has its own unit test; this exists because
// the halves have been correct and disconnected before — the goal operations
// have been applyable since the contract was written and episode_goals has
// never held a row, so "the store method works" and "the operator sees a
// checklist" are not the same claim and only the second one was asked for.
//
// The operations go through recordResultOperationEvents rather than through
// CreateEpisodeGoal directly. That is the point: it is the only path a model
// can reach, and a test that seeded the table itself would pass just as well
// with the operation handler deleted.
func TestPlannedGoalsReachTheCardAndAreCheckedOffThere(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "task:plan-card", "Add the retry", "summary",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetChannel(ctx, task.ID, "CTASK", "task-retry"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.100"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_plan", "task-plan", 1); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: "CTASK", ThreadTS: "1700.100",
		ConversationKey: "incident:" + task.ID,
		SourceKind:      "slack", SourceID: "input_plan", SessionID: "ses_plan",
		Episode: &core.WorkEpisode{
			Effort: core.EffortEngineeringTask, Authority: core.AuthorityRepositoryWrite,
		},
	})
	if err != nil || !created {
		t.Fatalf("queue the task run = %+v, %t, %v", run, created, err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "investigating", "Implementing the retry",
		"Finish the change", time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	// The window has to have something in it for the card to read the turn's
	// interior at all, which is the same read the plan arrives on.
	recordMoments(t, ctx, st, run, []core.AgentActivity{{
		Kind: "tool.started", ToolKind: "edit", Title: "Edit 'internal/http/retry.go'",
	}})

	// Before any plan: today's card exactly, with no checks under anything.
	if children := planChildrenOnCard(t, ctx, svc, task.ID); len(children) != 0 {
		t.Fatalf("an unplanned task grew a checklist: %+v", children)
	}

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		planGoal("goal-1", "Reproduce the timeout"),
		planGoal("goal-2", "Add the retry with backoff"),
		planGoal("goal-3", "Prove it under the failing test"),
	}); err != nil {
		t.Fatalf("apply the model's plan: %v", err)
	}

	children := planChildrenOnCard(t, ctx, svc, task.ID)
	if len(children) != 3 {
		t.Fatalf("planned checks on the card = %d: %+v", len(children), children)
	}
	for index, want := range []string{
		"Reproduce the timeout", "Add the retry with backoff", "Prove it under the failing test",
	} {
		if children[index].Label != want {
			t.Fatalf("check %d = %q, want %q", index, children[index].Label, want)
		}
		if children[index].Glyph != "·" {
			t.Fatalf("a freshly planned goal is not pending: %q", children[index].Glyph)
		}
	}

	// The next turn closes one and starts the next.
	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		updateGoal("goal-1", core.GoalCompleted),
		updateGoal("goal-2", core.GoalWorking),
	}); err != nil {
		t.Fatalf("apply the goal updates: %v", err)
	}

	checked := planChildrenOnCard(t, ctx, svc, task.ID)
	if len(checked) != 3 {
		t.Fatalf("checks after the update = %d: %+v", len(checked), checked)
	}
	for index, want := range []string{"✓", "▸", "·"} {
		if checked[index].Glyph != want {
			t.Fatalf(
				"check %d glyph = %q, want %q (whole strip %+v)",
				index, checked[index].Glyph, want, checked,
			)
		}
	}
	// Planning order, not state order: a checklist that re-sorted itself as the
	// work progressed would be a different list on every refresh.
	if checked[0].Label != "Reproduce the timeout" {
		t.Fatalf("the plan reordered itself: %+v", checked)
	}

	// And the whole loop is measurable: two results planned or updated goals,
	// and both said so where an operator counting adoption can find it.
	outcomes := auditOutcomes(t, cfg, "result.plan_goals", run.ID)
	if len(outcomes) != 2 ||
		!strings.HasPrefix(outcomes[0], "planned") ||
		!strings.HasPrefix(outcomes[1], "updated") {
		t.Fatalf("plan adoption audit = %v, want [planned…, updated…]", outcomes)
	}
	// The counts are what makes it a meter rather than a flag: "did any turn
	// plan" is answerable from the kind alone, and "how much" is not.
	if !strings.Contains(outcomes[0], "planned 3") ||
		!strings.Contains(outcomes[1], "updated 2") {
		t.Fatalf("the adoption rows do not carry their counts: %v", outcomes)
	}
}

// A goal the model never planned must not take the result down with it.
//
// This is the 2026-08 failure in its original form: an engineering task
// finished, committed, then closed a goal it had never opened, the not-found
// failed the whole result, and because operations apply in order the
// complete_episode behind it never ran. The card read "Investigating" for
// seventy-nine minutes on work that was done. Now that the contract actually
// asks models to plan, dangling closes stop being hypothetical.
func TestAGoalThatWasNeverPlannedDoesNotFailTheResultAroundIt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	run := seedWorkingRun(t, ctx, st)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		updateGoal("goal-never-opened", core.GoalCompleted),
		planGoal("goal-real", "Bound the blast radius"),
	}); err != nil {
		t.Fatalf("a dangling goal close failed the whole result: %v", err)
	}
	goals, err := st.Goals.ListForEpisode(ctx, run.EpisodeID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(goals) != 1 || goals[0].RequestedOutcome != "Bound the blast radius" {
		t.Fatalf("the operation behind the drop never applied: %+v", goals)
	}
}

// planChildrenOnCard composes the real card and returns the checks nested under
// whichever step the run has reached.
func planChildrenOnCard(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	incidentID string,
) []slackui.LedgerStep {
	t.Helper()
	incident, err := svc.store.GetIncident(ctx, incidentID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := svc.incidentCard(ctx, incident)
	if err != nil {
		t.Fatal(err)
	}
	var children []slackui.LedgerStep
	for _, step := range card.Ledger {
		children = append(children, step.Children...)
	}
	return children
}

func planGoal(id, outcome string) investigation.ResultOperation {
	return investigation.ResultOperation{
		ID: "op-" + id, Type: "plan_goal",
		Goal: &investigation.GoalOperation{
			ID: id, Kind: "engineering", RequestedOutcome: outcome,
			CompletionContract: "the change is in place and proven",
			Required:           true, Authority: core.AuthorityRepositoryWrite,
		},
	}
}

func updateGoal(id string, state core.EpisodeGoalState) investigation.ResultOperation {
	return investigation.ResultOperation{
		ID: "op-state-" + id + "-" + string(state), Type: "update_goal",
		GoalState: &investigation.GoalStateOperation{GoalID: id, State: state},
	}
}

package service

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

func TestPermanentChannelPreparationFailureNeedsOperatorAction(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incident, created, err := st.CreateManualIncident(
		ctx, "repo", "missing-scope", "Create the incident room", "summary",
		"U123ABC", "CSOURCE", "1700.1", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create incident = %+v, %t, %v", incident, created, err)
	}
	slackClient := &fakeSlack{createChannelErr: errors.New("missing_scope")}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processChannelIncident(ctx, incident.ID); err == nil {
		t.Fatal("permanent Slack refusal was hidden")
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.Workflow != core.WorkflowBlocked {
		t.Fatalf("permanent channel preparation remained automatic: %+v", incident)
	}
	card, err := svc.incidentCard(ctx, incident)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := slackui.Encode(card)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rendered), "Action needed") ||
		strings.Contains(string(rendered), "nothing needed from you") {
		t.Fatalf("permanent Slack refusal custody = %s", rendered)
	}
}

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

	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

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

// One production task retried a terminal Coop create operation for four hours.
// Idempotency correctly replayed the same failure every time, which made the
// workspace unrecoverable after the repository-fetch fix was deployed. A
// terminal refusal needs one new generation; an operation still running does
// not, because rotating that key could create a duplicate session.
func TestTerminalTaskSessionFailureGetsOneFreshIdempotencyGeneration(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories[cfg.Slack.DefaultRepository]
	repository.DisplayName = "blitz-core"
	cfg.Repositories[cfg.Slack.DefaultRepository] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx, cfg.Slack.DefaultRepository, "session-generation", "Fix delta builder",
		"Remove the synchronous event-loop block.", cfg.Slack.Operators[0],
		"CWATCH", "1700.100", 100,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.createErrors = []error{&coop.APIError{
		Status: 503, Code: "repository_unavailable", OperationID: "op_failed",
		Detail: "workspace preparation could not refresh blitz-core; no model session was created",
	}}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processChannelIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSessionIncident(ctx, task.ID); err == nil {
		t.Fatal("terminal workspace preparation failure unexpectedly succeeded")
	}
	waiting, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Investigation queued", "blitz-core", "No model turn has started", "Ryker will retry"} {
		if !strings.Contains(waiting.LastError, want) {
			t.Fatalf("visible preparation status lacks %q: %q", want, waiting.LastError)
		}
	}
	if strings.Contains(waiting.LastError, "Coop API") || strings.Contains(waiting.LastError, "operation=") {
		t.Fatalf("preparation status leaked transport plumbing: %q", waiting.LastError)
	}
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"ryker:session:" + task.ID,
		"ryker:session:" + task.ID + ":2",
	}
	if !slices.Equal(coopClient.createKeys, want) {
		t.Fatalf("task session keys = %v, want %v", coopClient.createKeys, want)
	}
}

func TestPendingTaskSessionKeepsItsIdempotencyGeneration(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx, cfg.Slack.DefaultRepository, "pending-session-generation", "Fix delta builder",
		"Remove the synchronous event-loop block.", cfg.Slack.Operators[0],
		"CWATCH", "1700.100", 100,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.createErrors = []error{&coop.OperationPendingError{
		ID: "op_running", Method: "CreateRemoteSession",
	}}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processChannelIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSessionIncident(ctx, task.ID); err == nil {
		t.Fatal("pending workspace preparation unexpectedly succeeded")
	}
	waiting, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Investigation queued", "still preparing", "No model turn has started"} {
		if !strings.Contains(waiting.LastError, want) {
			t.Fatalf("visible pending preparation status lacks %q: %q", want, waiting.LastError)
		}
	}
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	want := []string{"ryker:session:" + task.ID, "ryker:session:" + task.ID}
	if !slices.Equal(coopClient.createKeys, want) {
		t.Fatalf("pending task session keys = %v, want %v", coopClient.createKeys, want)
	}
}

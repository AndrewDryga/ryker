package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// Thirty focused tests passed in the live Rivals task, but the feedback turn
// left two intended files uncommitted and Responder still accepted completion.
// Coop then refused the PR review, so the selected decision never reached the
// existing pull request.
func TestEngineeringTurnCannotFinishWithItsIntendedChangesUncommitted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", "dirty-feedback-task", "Update failure aggregation",
		"Apply the selected aggregation policy.", cfg.Slack.Operators[0],
		"COPS", "1700.100", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_dirty_feedback", "task-feedback", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.ConversationThreadTS(),
		ConversationKey: "incident:" + task.ID, SourceKind: "initial",
		SourceID: task.ID, UserID: cfg.Slack.Operators[0], Repository: task.Repository,
		Prompt:    "Use five-minute aggregation and commit the intended change.",
		SessionID: "ses_dirty_feedback", CommitmentTitle: task.Title,
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}

	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_dirty_feedback"
	coopClient.session.ForkName = "task-feedback"
	coopClient.session.Revision = 1
	coopClient.session.RepositoryReadOnly = false
	coopClient.changes = coop.Changes{
		BaseCommit: "base", ForkHead: "before", ForkTree: "tree-before",
	}
	coopClient.completeOnSubmit = `{
	  "operations":[{"id":"complete","type":"complete_episode","completion":{
	    "message":"Implemented five-minute aggregation. All 30 focused tests pass.",
	    "completion":{"status":"decision_ready","verdict":"completed","summary":"The requested feedback is implemented and tested."}
	  }}]
	}`
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	// The model changed the tree but did not commit it. This is the exact state
	// Coop's review endpoint rejected in production.
	coopClient.changes = coop.Changes{
		BaseCommit: "base", ForkHead: "before", ForkTree: "tree-before",
		Unstaged: []coop.Change{{Path: "src/scraper_app.py", Status: "modified"}},
	}
	svc.pollAgentRuns(ctx)

	got, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != core.AgentRunPending || got.Failures != 0 ||
		!strings.Contains(strings.ToLower(got.LastError), "commit") {
		t.Fatalf("dirty completion was accepted instead of corrected: %+v", got)
	}
}

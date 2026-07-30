package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestAgentRunsProjectDurableOperatorCommitments(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CINFRA", ThreadTS: "1700.001",
		ConversationKey: "channel:CINFRA", SourceKind: "watch", SourceID: "input_1",
		UserID: "UOPERATOR", Repository: "emisar",
		CommitmentTitle: "Check production health",
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %v, %v", run, created, err)
	}
	commitment, err := st.GetCommitmentByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if commitment.Title != "Check production health" ||
		commitment.State != core.CommitmentQueued ||
		commitment.NextAction != "Start the investigation" {
		t.Fatalf("queued commitment = %+v", commitment)
	}

	if _, err := st.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'running', started_at = ?, updated_at = ?
		WHERE id = ?`,
		nowText(), nowText(), run.ID,
	); err != nil {
		t.Fatal(err)
	}
	commitment, err = st.GetCommitmentByRun(ctx, run.ID)
	if err != nil || commitment.State != core.CommitmentWorking ||
		commitment.Status != "Investigating" {
		t.Fatalf("working commitment = %+v, %v", commitment, err)
	}

	if _, err := st.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'failed', last_error = 'provider unavailable',
		    completed_at = ?, updated_at = ?
		WHERE id = ?`,
		nowText(), nowText(), run.ID,
	); err != nil {
		t.Fatal(err)
	}
	commitment, err = st.GetCommitmentByRun(ctx, run.ID)
	if err != nil || commitment.State != core.CommitmentBlocked ||
		commitment.Status != "provider unavailable" {
		t.Fatalf("blocked commitment = %+v, %v", commitment, err)
	}
	active, err := st.ListActiveCommitments(ctx, 10)
	if err != nil || len(active) != 1 || active[0].AgentRunID != run.ID {
		t.Fatalf("active commitments = %+v, %v", active, err)
	}
	count, err := st.CountActiveCommitments(ctx)
	if err != nil || count != 1 {
		t.Fatalf("active count = %d, %v", count, err)
	}

	if _, err := st.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'completed', last_error = '', completed_at = ?, updated_at = ?
		WHERE id = ?`,
		time.Now().UTC().Format(timestampFormat),
		nowText(),
		run.ID,
	); err != nil {
		t.Fatal(err)
	}
	active, err = st.ListActiveCommitments(ctx, 10)
	if err != nil || len(active) != 0 {
		t.Fatalf("completed commitment remains active = %+v, %v", active, err)
	}
}

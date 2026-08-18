package store

import (
	"context"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// A successful Coop submission and its recovery intent were once two commits.
// A crash or database failure between them left the run working while Slack
// permanently said repository preparation was blocked.
func TestModelSubmissionAndPreparationRecoveryCommitAtomically(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "1700.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_atomic_recovery",
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(ctx, run.ID, "session_1", 1, "repo", 0, run.Context); err != nil {
		t.Fatal(err)
	}
	prefix := "watch_preparation_blocked_" + run.EpisodeID + "_"
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: prefix + "epoch_001", EpisodeID: run.EpisodeID, AgentRunID: run.ID,
		SourceInputID: run.SourceID, Operation: "post", Kind: "notice",
		ChannelID: "C1", ThreadTS: "1700.1", Body: []byte(`{"text":"blocked"}`),
		CoalesceKey: prefix,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(`
		CREATE TRIGGER fail_preparation_retirement
		BEFORE INSERT ON slack_deliveries
		WHEN NEW.kind = 'notice_retirement'
		BEGIN SELECT RAISE(FAIL, 'injected retirement failure'); END;`); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkTriageAgentRunSubmitted(
		ctx, run.ID, "turn_1", 2, 0, "watch", prefix,
	); err == nil {
		t.Fatal("submission committed without its preparation retirement")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunPreparing || stored.CoopTurnID != "" {
		t.Fatalf("failed atomic submission changed run = %+v, %v", stored, err)
	}
	if _, err := st.db.Exec(`DROP TRIGGER fail_preparation_retirement`); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkTriageAgentRunSubmitted(
		ctx, run.ID, "turn_1", 2, 0, "watch", prefix,
	); err != nil {
		t.Fatal(err)
	}
	stored, err = st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunRunning || stored.CoopTurnID != "turn_1" {
		t.Fatalf("retried atomic submission = %+v, %v", stored, err)
	}
	deliveries, err := st.ListSlackDeliveriesByPrefix(ctx, prefix)
	if err != nil || len(deliveries) != 2 || deliveries[0].State != "superseded" ||
		deliveries[1].Operation != "delete" || deliveries[1].State != "pending" {
		t.Fatalf("durable recovery deliveries = %+v, %v", deliveries, err)
	}
}

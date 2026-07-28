package store

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestSchemaV3MigratesIntelligenceState(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(schemaV1 + schemaV2 + schemaV3); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (3)`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, table := range []string{
		"channel_memories",
		"evidence",
		"coverage",
		"timeline_events",
		"action_proposals",
		"proposal_approvals",
		"evaluation_decisions",
	} {
		var count int
		if err := st.db.QueryRow(`
			SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?`,
			table,
		).Scan(&count); err != nil || count != 1 {
			t.Fatalf("table %s = %d, %v", table, count, err)
		}
	}
}

func TestIntelligenceEvidenceCoverageTimelineAndMemory(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	started := time.Now().UTC().Add(-time.Minute)
	if err := st.BindChannelSession(
		ctx, "COPS", "emisar", "ses_1", 7, 1, started,
	); err != nil {
		t.Fatal(err)
	}
	state := core.AgentMemory{
		Goal: "Assess production health",
		Topology: []string{
			"Two declared production instances",
		},
		UnresolvedQuestions: []string{"Nomad allocation state"},
	}
	if err := st.AdvanceChannelMemory(ctx, "COPS", 8, state); err != nil {
		t.Fatal(err)
	}
	memory, err := st.GetChannelMemory(ctx, "COPS")
	if err != nil {
		t.Fatal(err)
	}
	if memory.SessionID != "ses_1" || memory.SessionRevision != 8 ||
		memory.Generation != 1 || memory.TurnCount != 1 ||
		memory.State.Goal != state.Goal {
		t.Fatalf("memory = %+v", memory)
	}
	decision := core.EvaluationDecision{
		ChannelID: "COPS", SourceInput: "slack_once", Mode: "live",
		Action: "reply", Reason: "explicit question",
	}
	applied, err := st.ApplyWatchDecision(ctx, decision, 9, core.AgentMemory{
		Goal: "Answer the explicit question",
	})
	if err != nil || !applied {
		t.Fatalf("apply watch decision = %t, %v", applied, err)
	}
	applied, err = st.ApplyWatchDecision(ctx, decision, 10, core.AgentMemory{
		Goal: "duplicate must not replace memory",
	})
	if err != nil || applied {
		t.Fatalf("replay watch decision = %t, %v", applied, err)
	}
	memory, err = st.GetChannelMemory(ctx, "COPS")
	if err != nil {
		t.Fatal(err)
	}
	if memory.TurnCount != 2 || memory.SessionRevision != 9 ||
		memory.State.Goal != "Answer the explicit question" {
		t.Fatalf("idempotent watch memory = %+v", memory)
	}

	observed := time.Now().UTC().Add(-30 * time.Second)
	items, err := st.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: "inc_1", ChannelID: "COPS", SourceInput: "slack_1",
		Claim:       "Expected production capacity is two instances",
		Observation: "infra/main.tf sets target_size to 2",
		SourceType:  "repository", SourceName: "infra/main.tf",
		SourceURL: "https://example.test/repo/blob/main/infra/main.tf",
		Target:    "production-mig", ObservedAt: observed,
		Metadata: map[string]string{"revision": "abc123"},
	}})
	if err != nil || len(items) != 1 || items[0].ID == "" {
		t.Fatalf("record evidence = %+v, %v", items, err)
	}
	replayed, err := st.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: "inc_1", ChannelID: "COPS", SourceInput: "slack_1",
		Claim:       "Expected production capacity is two instances",
		Observation: "infra/main.tf sets target_size to 2",
		SourceType:  "repository", SourceName: "infra/main.tf",
		Target: "production-mig",
	}})
	if err != nil || len(replayed) != 1 || replayed[0].ID != items[0].ID {
		t.Fatalf("replayed evidence = %+v, %v", replayed, err)
	}
	evidence, err := st.ListEvidence(ctx, "inc_1", "", 10)
	if err != nil || len(evidence) != 1 ||
		evidence[0].Metadata["revision"] != "abc123" {
		t.Fatalf("evidence = %+v, %v", evidence, err)
	}

	if err := st.RecordCoverage(ctx, []core.Coverage{{
		IncidentID: "inc_1", ChannelID: "COPS", SourceInput: "slack_1",
		Layer: "scheduler", Status: "unknown",
		Detail: "No authorized Nomad observation was available",
	}}); err != nil {
		t.Fatal(err)
	}
	coverage, err := st.ListCoverage(ctx, "inc_1", "", 10)
	if err != nil || len(coverage) != 1 || coverage[0].Status != "unknown" {
		t.Fatalf("coverage = %+v, %v", coverage, err)
	}

	if err := st.RecordTimeline(ctx, core.TimelineEvent{
		IncidentID: "inc_1", ChannelID: "COPS", Kind: "agent.finding",
		ActorID: "responder", Title: "Topology reconciled",
		Detail:      "Expected capacity verified from repository",
		EvidenceIDs: []string{items[0].ID},
	}); err != nil {
		t.Fatal(err)
	}
	timeline, err := st.ListTimeline(ctx, "inc_1", "", 10)
	if err != nil || len(timeline) != 1 ||
		len(timeline[0].EvidenceIDs) != 1 ||
		timeline[0].EvidenceIDs[0] != items[0].ID {
		t.Fatalf("timeline = %+v, %v", timeline, err)
	}
}

func TestActionProposalRequiresDistinctApprovers(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	created, err := st.CreateActionProposals(ctx, []core.ActionProposal{{
		IncidentID: "inc_1", ChannelID: "COPS", SourceInput: "turn_1",
		ActionName: "restart_allocation", Title: "Restart failed allocation",
		Summary: "The allocation is terminal and its replacement is absent.",
		Target:  "alloc-123", Parameters: map[string]string{"allocation": "alloc-123"},
		BlastRadius: "One allocation", Rollback: "Restore the prior allocation version",
		Verification: "Replacement allocation is healthy",
		Authority:    "emisar", Risk: "medium", Required: 2,
		ExpiresAt: time.Now().UTC().Add(15 * time.Minute),
	}})
	if err != nil || len(created) != 1 {
		t.Fatalf("create proposal = %+v, %v", created, err)
	}
	proposal, err := st.DecideActionProposal(
		ctx, created[0].ID, "U1", "approve", time.Now().UTC(),
	)
	if err != nil || proposal.Status != "pending" || proposal.ApprovalCount != 1 {
		t.Fatalf("first approval = %+v, %v", proposal, err)
	}
	proposal, err = st.DecideActionProposal(
		ctx, created[0].ID, "U1", "approve", time.Now().UTC(),
	)
	if err != nil || proposal.Status != "pending" || proposal.ApprovalCount != 1 {
		t.Fatalf("duplicate approval = %+v, %v", proposal, err)
	}
	proposal, err = st.DecideActionProposal(
		ctx, created[0].ID, "U2", "approve", time.Now().UTC(),
	)
	if err != nil || proposal.Status != "approved" || proposal.ApprovalCount != 2 {
		t.Fatalf("second approval = %+v, %v", proposal, err)
	}
	if err := st.MarkProposalExecution(
		ctx, proposal.ID, "executing", "turn_2", "",
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkProposalExecution(
		ctx, proposal.ID, "finished", "turn_2", "verified",
	); err != nil {
		t.Fatal(err)
	}
	proposal, err = st.GetActionProposal(ctx, proposal.ID)
	if err != nil || proposal.Status != "finished" ||
		proposal.ExecutionTurn != "turn_2" || proposal.Result != "verified" {
		t.Fatalf("finished proposal = %+v, %v", proposal, err)
	}
}

func TestRetireActionProposalsStopsLegacyExecutableState(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	created, err := st.CreateActionProposals(ctx, []core.ActionProposal{{
		IncidentID: "inc_legacy", ChannelID: "COPS", SourceInput: "turn_legacy",
		ActionName: "restart_allocation", Title: "Restart failed allocation",
		Target: "alloc-123", BlastRadius: "One allocation",
		Rollback:     "Restore the prior allocation version",
		Verification: "Replacement allocation is healthy",
		Authority:    "emisar", Risk: "medium", Required: 1,
		ExpiresAt: time.Now().UTC().Add(15 * time.Minute),
	}})
	if err != nil || len(created) != 1 {
		t.Fatalf("create legacy proposal = %+v, %v", created, err)
	}
	retired, err := st.RetireActionProposals(ctx, time.Now().UTC())
	if err != nil || retired != 1 {
		t.Fatalf("retire proposals = %d, %v", retired, err)
	}
	proposal, err := st.GetActionProposal(ctx, created[0].ID)
	if err != nil || proposal.Status != "failed" ||
		!strings.Contains(proposal.Result, "disabled") {
		t.Fatalf("retired proposal = %+v, %v", proposal, err)
	}
	if retired, err := st.RetireActionProposals(ctx, time.Now().UTC()); err != nil ||
		retired != 0 {
		t.Fatalf("repeated retirement = %d, %v", retired, err)
	}
}

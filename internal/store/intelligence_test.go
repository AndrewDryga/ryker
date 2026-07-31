package store

import (
	"context"
	"database/sql"
	"errors"
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
		"memory_entries",
		"conversation_memories",
		"conversation_sessions",
		"conversation_routes",
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

func TestConversationSessionAndRouteAreDurableAndLaneScoped(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.EnsureChannelMemory(ctx, "COPS", "emisar"); err != nil {
		t.Fatal(err)
	}
	if err := st.BindConversationSession(
		ctx,
		"COPS",
		"emisar",
		"emisar-conversation",
		"ses_conversation",
		1,
		1,
		time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	applied, err := st.ApplyWatchDecision(
		ctx,
		core.EvaluationDecision{
			ChannelID: "COPS", ThreadTS: "1700.1", MessageTS: "1700.2",
			Repository: "emisar", SourceInput: "conversation-source",
			Mode: "live", Action: "reply",
		},
		"conversation",
		2,
		core.AgentMemory{SituationSummary: "The answer was 8."},
	)
	if err != nil || !applied {
		t.Fatalf("apply conversation decision = %t, %v", applied, err)
	}
	session, err := st.GetConversationSession(ctx, "COPS")
	if err != nil || session.TurnCount != 1 || session.SessionRevision != 2 {
		t.Fatalf("conversation session = %+v, %v", session, err)
	}
	channel, err := st.GetChannelMemory(ctx, "COPS")
	if err != nil || channel.TurnCount != 0 ||
		channel.State.SituationSummary != "The answer was 8." {
		t.Fatalf("investigation memory after conversation = %+v, %v", channel, err)
	}
	route := core.ConversationRoute{
		ChannelID: "COPS", UserID: "U1",
		PreviousThreadTS: "1700.1", Explicit: true,
	}
	if err := st.PutConversationRoute(ctx, route); err != nil {
		t.Fatal(err)
	}
	storedRoute, err := st.GetConversationRoute(ctx, "COPS", "U1")
	if err != nil || storedRoute.PreviousThreadTS != "1700.1" ||
		!storedRoute.Explicit {
		t.Fatalf("conversation route = %+v, %v", storedRoute, err)
	}
}

func TestConversationMemoryCarriesAcrossPublicWorkspaceWithoutLeakingPrivateChannels(
	t *testing.T,
) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	for _, channel := range []string{"CMAIN", "CPUBLIC", "GPRIVATE"} {
		if err := st.BindChannelSession(
			ctx,
			channel,
			"emisar",
			"session-"+channel,
			1,
			1,
			time.Now().UTC(),
		); err != nil {
			t.Fatal(err)
		}
	}
	for _, item := range []struct {
		channel string
		thread  string
		source  string
		summary string
	}{
		{"CMAIN", "1700.100", "source-main-one", "Main incident"},
		{"CMAIN", "1700.200", "source-main-two", "Related thread in this channel"},
		{"CPUBLIC", "1700.300", "source-public", "Public deployment handoff"},
		{"GPRIVATE", "1700.400", "source-private", "Private security investigation"},
	} {
		applied, applyErr := st.ApplyWatchDecision(
			ctx,
			core.EvaluationDecision{
				ChannelID: item.channel, ThreadTS: item.thread,
				MessageTS: item.thread + "1", Repository: "emisar",
				SourceInput: item.source, Mode: "live", Action: "reply",
			},
			"investigation",
			2,
			core.AgentMemory{SituationSummary: item.summary},
		)
		if applyErr != nil || !applied {
			t.Fatalf("apply %s = %t, %v", item.source, applied, applyErr)
		}
	}
	now := time.Now().UTC().Format(timestampFormat)
	if _, err := st.db.Exec(`
		INSERT INTO slack_channel_memberships (
		  channel_id, channel_name, private, present, onboarding_state, observed_at
		) VALUES
		  ('CPUBLIC', 'deployments', 0, 1, 'complete', ?),
		  ('GPRIVATE', 'security', 1, 1, 'complete', ?)`,
		now, now,
	); err != nil {
		t.Fatal(err)
	}

	target, err := st.GetConversationMemory(ctx, "CMAIN", "1700.100")
	if err != nil || target.State.SituationSummary != "Main incident" {
		t.Fatalf("target conversation memory = %+v, %v", target, err)
	}
	related, err := st.ListRelatedConversationMemories(
		ctx,
		"CMAIN",
		"1700.100",
		"emisar",
		10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(related) != 2 ||
		related[0].State.SituationSummary != "Related thread in this channel" ||
		related[1].State.SituationSummary != "Public deployment handoff" ||
		related[1].ChannelName != "deployments" {
		t.Fatalf("related conversation memory = %+v", related)
	}
	for _, memory := range related {
		if memory.ChannelID == "GPRIVATE" {
			t.Fatalf("private cross-channel memory leaked: %+v", memory)
		}
	}
}

func TestConversationMemoryDeletionAndRetention(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	for _, channel := range []string{"CDELETE", "CEXPIRE"} {
		if err := st.BindChannelSession(
			ctx,
			channel,
			"emisar",
			"session-"+channel,
			1,
			1,
			time.Now().UTC(),
		); err != nil {
			t.Fatal(err)
		}
		applied, applyErr := st.ApplyWatchDecision(
			ctx,
			core.EvaluationDecision{
				ChannelID: channel, ThreadTS: "1700.100",
				MessageTS: "1700.200", Repository: "emisar",
				SourceInput: "source-" + channel, Mode: "live", Action: "reply",
			},
			"investigation",
			2,
			core.AgentMemory{SituationSummary: "Retained conversation summary"},
		)
		if applyErr != nil || !applied {
			t.Fatalf("apply %s = %t, %v", channel, applied, applyErr)
		}
	}

	deleted, err := st.DeleteConversationMemories(ctx, "CDELETE")
	if err != nil || deleted != 1 {
		t.Fatalf("deleted conversation memories = %d, %v", deleted, err)
	}
	if _, err := st.GetConversationMemory(
		ctx,
		"CDELETE",
		"1700.100",
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted conversation memory remained: %v", err)
	}

	if _, err := st.db.Exec(
		`UPDATE conversation_memories SET updated_at = ? WHERE channel_id = ?`,
		time.Now().UTC().Add(-91*24*time.Hour).Format(timestampFormat),
		"CEXPIRE",
	); err != nil {
		t.Fatal(err)
	}
	result, err := st.Prune(
		ctx,
		time.Now().UTC().Add(-24*time.Hour),
		time.Now().UTC().Add(-90*24*time.Hour),
		time.Now().UTC().Add(-7*24*time.Hour),
		time.Now().UTC().Add(-30*24*time.Hour),
	)
	if err != nil || result.ConversationMemories != 1 {
		t.Fatalf("conversation memory prune = %+v, %v", result, err)
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
		Goal:             "Assess production health",
		ChannelPurpose:   "Production infrastructure operations",
		SituationSummary: "Portal health is under review.",
		ActiveTopics:     []string{"portal health"},
		OpenLoops:        []string{"Confirm database latency"},
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
		memory.State.Goal != state.Goal ||
		memory.State.ChannelPurpose != state.ChannelPurpose ||
		memory.State.SituationSummary != state.SituationSummary ||
		len(memory.State.ActiveTopics) != 1 ||
		len(memory.State.OpenLoops) != 1 {
		t.Fatalf("memory = %+v", memory)
	}
	situations, err := st.ListChannelSituations(ctx, 10)
	if err != nil || len(situations) != 1 ||
		situations[0].State.OpenLoops[0] != "Confirm database latency" {
		t.Fatalf("situations = %+v, %v", situations, err)
	}
	decision := core.EvaluationDecision{
		ChannelID: "COPS", SourceInput: "slack_once", Mode: "live",
		Action: "reply", Reason: "explicit question",
	}
	applied, err := st.ApplyWatchDecision(ctx, decision, "investigation", 9, core.AgentMemory{
		Goal: "Answer the explicit question",
	})
	if err != nil || !applied {
		t.Fatalf("apply watch decision = %t, %v", applied, err)
	}
	applied, err = st.ApplyWatchDecision(ctx, decision, "investigation", 10, core.AgentMemory{
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

func TestDetachChannelSessionPreservesDurableMemory(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	started := time.Now().UTC().Add(-time.Minute)
	if err := st.BindChannelSession(
		ctx, "COPS", "emisar", "ses_1", 7, 3, started,
	); err != nil {
		t.Fatal(err)
	}
	state := core.AgentMemory{
		Goal:      "Assess production health",
		Decisions: []string{"Use declared topology to interpret runner identities"},
	}
	if err := st.AdvanceChannelMemory(ctx, "COPS", 8, state); err != nil {
		t.Fatal(err)
	}
	detached, err := st.DetachChannelSession(ctx, "COPS", "ses_other")
	if err != nil || detached {
		t.Fatalf("detach wrong session = %t, %v", detached, err)
	}
	detached, err = st.DetachChannelSession(ctx, "COPS", "ses_1")
	if err != nil || !detached {
		t.Fatalf("detach bound session = %t, %v", detached, err)
	}
	memory, err := st.GetChannelMemory(ctx, "COPS")
	if err != nil {
		t.Fatal(err)
	}
	if memory.SessionID != "" || memory.SessionRevision != 0 ||
		memory.TurnCount != 0 || !memory.SessionStarted.IsZero() ||
		memory.Generation != 3 || memory.Repository != "emisar" ||
		memory.State.Goal != state.Goal ||
		len(memory.State.Decisions) != 1 {
		t.Fatalf("detached memory = %+v", memory)
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

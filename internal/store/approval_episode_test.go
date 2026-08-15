package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// An approval requested from an ordinary Slack thread has no incident, so
// incident_id is NULL and every projection keyed on it is blind to the row.
// That is not a rendering problem — it is the postmortem, the remediation
// record and the retention sweep all agreeing that this approval belongs to no
// work at all, while the operator who pressed the button is watching a card
// that plainly does.
//
// The cost: approvals expire on the OPERATIONAL horizon, so the evidence that
// a thread-scoped approval ever completed is gone within a day, and
// emisar-actions-and-approvals is still an acknowledged coverage gap for
// exactly this reason — "needs a recorded approval without an incident room".
// Section 25 phase 5 moves ownership to the episode; this is the test that says
// the ownership is real rather than a column nobody fills.
func TestAnApprovalWithoutAnIncidentIsStillFoundByItsEpisode(t *testing.T) {
	dir := t.TempDir()
	st := openAt(t, dir)
	ctx := context.Background()
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	st.SetClock(func() time.Time { return now })

	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.100",
		ConversationKey: "conversation:COPS:1700.100",
		SourceKind:      "watch", SourceID: "slack_thread_1", UserID: "UOPERATOR",
		Repository: "owner/repo", Prompt: "restart the pull zone",
		CommitmentTitle: "Restart the pull zone",
		Episode: &core.WorkEpisode{
			Effort: core.EffortOperationalAssessment, Authority: core.AuthorityReadOnly,
			Objective: "Restart the pull zone the operator named",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if run.EpisodeID == "" {
		t.Fatalf("thread-scoped run has no episode: %+v", run)
	}

	stored, created, err := st.Approvals.Record(ctx, core.EmisarApproval{
		RequestID: "apr_thread_1", EpisodeID: run.EpisodeID,
		ChannelID: "COPS", SourceInput: "slack_thread_1", RequestedBy: "UOPERATOR",
		RunID: "run_thread_1", OperationID: "op_1", ActionID: "bunny.pull_zone.update",
		PackRef: "pack@1", RunnerRef: "runner@1", Status: "pending_approval",
		ApprovalURL: "https://emisar.example/approvals/apr_thread_1",
		ExpiresAt:   now.Add(time.Hour),
	})
	if err != nil || !created {
		t.Fatalf("record thread-scoped approval = %+v, %v, %v", stored, created, err)
	}

	// The decision first: the approval knows which work asked for it.
	if stored.EpisodeID != run.EpisodeID {
		t.Fatalf(
			"approval episode = %q, want %q; a thread-scoped approval that names no "+
				"episode belongs to no work anywhere in the system",
			stored.EpisodeID, run.EpisodeID,
		)
	}
	if stored.IncidentID != "" {
		t.Fatalf("approval invented an incident: %q", stored.IncidentID)
	}

	byEpisode, err := st.Approvals.ListForEpisode(ctx, run.EpisodeID)
	if err != nil || len(byEpisode) != 1 || byEpisode[0].RequestID != "apr_thread_1" {
		t.Fatalf("approvals for episode = %+v, %v", byEpisode, err)
	}

	// And the empty id is not a wildcard. Rows the v81 backfill could not
	// resolve carry the empty string, and answering "" with all of them would
	// hand one episode's page another episode's approvals.
	orphaned, err := st.Approvals.ListForEpisode(ctx, "")
	if err != nil || len(orphaned) != 0 {
		t.Fatalf("approvals for the empty episode = %+v, %v", orphaned, err)
	}
}

// The immutable identity check has to cover the episode too. Emisar redelivers,
// and a second result naming the same request id with a different episode is a
// rebinding of somebody else's authority record, not an update.
func TestARedeliveredApprovalCannotRebindItsEpisode(t *testing.T) {
	dir := t.TempDir()
	st := openAt(t, dir)
	ctx := context.Background()
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	st.SetClock(func() time.Time { return now })

	base := core.EmisarApproval{
		RequestID: "apr_rebind", EpisodeID: "episode_run_first",
		ChannelID: "COPS", SourceInput: "slack_rebind", RequestedBy: "UOPERATOR",
		RunID: "run_rebind", OperationID: "op_1", ActionID: "bunny.pull_zone.update",
		PackRef: "pack@1", RunnerRef: "runner@1", Status: "pending_approval",
		ApprovalURL: "https://emisar.example/approvals/apr_rebind",
		ExpiresAt:   now.Add(time.Hour),
	}
	if _, _, err := st.Approvals.Record(ctx, base); err != nil {
		t.Fatal(err)
	}
	base.EpisodeID = "episode_run_second"
	if _, _, err := st.Approvals.Record(ctx, base); err == nil {
		t.Fatal("a redelivered approval rebound its episode without complaint")
	}
}

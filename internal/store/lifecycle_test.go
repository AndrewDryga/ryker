package store

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestPublicationCanRecoverBeforeBranchIdentityIsKnown(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	publication := core.Publication{
		IncidentID: incidents[0].ID, Repository: "owner/repository", BaseBranch: "main",
		ParentHead: "parent", CandidateTree: "tree", State: "publishing",
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save pre-side-effect publication: %v", err)
	}
	stored, err := st.GetPublication(ctx, incidents[0].ID)
	if err != nil || stored.HeadBranch != "" || stored.State != "publishing" {
		t.Fatalf("stored publication = %+v, %v", stored, err)
	}

	publication.State = "published"
	if err := st.SavePublication(ctx, publication); err == nil {
		t.Fatal("published record without remote proof was accepted")
	}
	publication.HeadBranch = "responder/fix"
	publication.CommitSHA = "commit"
	publication.RemoteSHA = "commit"
	publication.PRNumber = 12
	publication.PRURL = "https://github.com/owner/repository/pull/12"
	publication.PublishedAt = time.Now().UTC()
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save proved publication: %v", err)
	}
	changed, err := st.MarkPublicationStale(
		ctx,
		publication.IncidentID,
		"The task changed after publication.",
	)
	if err != nil || !changed {
		t.Fatalf("mark publication stale = %t, %v", changed, err)
	}
	stored, err = st.GetPublication(ctx, publication.IncidentID)
	if err != nil || !stored.NeedsUpdate() || stored.Published() ||
		stored.PRNumber != publication.PRNumber {
		t.Fatalf("stale publication = %+v, %v", stored, err)
	}
	changed, err = st.MarkPublicationStale(
		ctx,
		publication.IncidentID,
		"Repeated invalidation.",
	)
	if err != nil || changed {
		t.Fatalf("repeated stale mark = %t, %v", changed, err)
	}
}

func TestPublicationFollowupPersistsLifecycleAndActiveContext(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "tenant-infra", "source-1", "Reduce Redis pool", "summary", "UOP",
		"COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	publication := core.Publication{
		IncidentID: incident.ID, Repository: "owner/tenant-infra", BaseBranch: "main",
		HeadBranch: "responder/reduce-redis", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "0123456789abcdef", PRNumber: 493,
		PRURL: "https://github.example/owner/tenant-infra/pull/493",
		State: "published", PublishedAt: now,
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsurePublicationFollowup(ctx, incident.ID, now); err != nil {
		t.Fatal(err)
	}
	followup, gotPublication, err := st.NextPublicationFollowup(ctx, now.Add(time.Second))
	if err != nil || followup.IncidentID != incident.ID || gotPublication.PRNumber != 493 {
		t.Fatalf("due follow-up = %+v, %+v, %v", followup, gotPublication, err)
	}
	followup.PRState = "merged"
	followup.ChecksState = "passing"
	followup.MergeSHA = "abcdefabcdef"
	followup.MergedAt = now
	followup.NextCheckAt = now.Add(24 * time.Hour)
	if err := st.SavePublicationFollowup(ctx, followup); err != nil {
		t.Fatal(err)
	}
	contexts, err := st.ListActivePublicationContexts(ctx, now.Add(-time.Hour), 10)
	if err != nil || len(contexts) != 1 || contexts[0].ThreadTS != "1700.100" ||
		contexts[0].RepositoryKey != "tenant-infra" || contexts[0].MergeSHA == "" {
		t.Fatalf("active publication contexts = %+v, %v", contexts, err)
	}
	if err := st.ResetPublicationFollowup(ctx, incident.ID, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	reset, err := st.GetPublicationFollowup(ctx, incident.ID)
	if err != nil || reset.PRState != "open" || reset.ChecksState != "unknown" ||
		reset.MergeSHA != "" || reset.LastEventKey != "" || reset.FailureCount != 0 {
		t.Fatalf("reset publication follow-up = %+v, %v", reset, err)
	}
	event := core.PublicationLifecycleEvent{
		ID: "event-1", IncidentID: incident.ID, Kind: "deployment",
		State: "succeeded", Summary: "Production rollout completed.",
	}
	inserted, err := st.RecordPublicationLifecycleEvent(ctx, event)
	if err != nil || !inserted {
		t.Fatalf("first lifecycle event = %v, %v", inserted, err)
	}
	inserted, err = st.RecordPublicationLifecycleEvent(ctx, event)
	if err != nil || inserted {
		t.Fatalf("duplicate lifecycle event = %v, %v", inserted, err)
	}
}

func TestLoadRemediationRecordAssemblesCanonicalIncidentState(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CINCIDENT", "ems-api"); err != nil {
		t.Fatal(err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: "CINCIDENT", ConversationKey: "incident:" + incident.ID,
		SourceKind: "webhook", SourceID: "delivery-1", Repository: "repo",
		Prompt: "investigate",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CINCIDENT", SourceInput: run.ID,
		Claim: "API returned errors", Observation: "Probe observed HTTP 500",
		SourceType: "emisar", SourceName: "http probe", Target: "api",
	}}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "req_1", IncidentID: incident.ID, ChannelID: "CINCIDENT",
		SourceInput: run.ID, RequestedBy: "UOP", RunID: "emisar_run_1",
		OperationID: "op_1", ActionID: "service.restart", PackRef: "service@1",
		RunnerRef: "runner_1", Status: "pending_approval",
		ApprovalURL: "https://emisar.example/approvals/req_1",
		ExpiresAt:   now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.CreateActionProposals(ctx, []core.ActionProposal{{
		ID: "proposal_1", IncidentID: incident.ID, ChannelID: "CINCIDENT",
		ActionName: "service.restart", Title: "Restart one replica", Target: "api-1",
		BlastRadius: "one replica", Rollback: "restart old process",
		Verification: "probe API", Authority: "operator", Required: 1,
		ExpiresAt: now.Add(time.Hour),
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.SavePublication(ctx, core.Publication{
		IncidentID: incident.ID, Repository: "owner/repo", BaseBranch: "main",
		ParentHead: "parent", CandidateTree: "tree", State: "publishing",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.Intelligence.RecordTimeline(ctx, core.TimelineEvent{
		ID: "operator_1", IncidentID: incident.ID, ChannelID: "CINCIDENT",
		Kind: "operator.message", Title: "Operator requested a restart", CreatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}

	record, err := st.LoadRemediationRecord(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Signals) != 1 || len(record.AgentRuns) != 1 ||
		len(record.Evidence) != 1 || len(record.Events) != 1 ||
		len(record.Proposals) != 1 || len(record.Approvals) != 1 ||
		record.Publication.State != "publishing" {
		t.Fatalf("record = %+v", record)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	latest, err := st.FindLatestIncidentByChannel(ctx, "CINCIDENT")
	if err != nil || latest.ID != incident.ID || latest.Status != core.IncidentClosed {
		t.Fatalf("latest closed incident = %+v, %v", latest, err)
	}
}

func TestExpiredChannelMemoryIsOwnedBeforeItIsPruned(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	started := time.Now().UTC().Add(-2 * time.Hour)
	if err := st.Intelligence.BindChannelSession(ctx, "COPS", "repo", "session-old", 3, 1, started); err != nil {
		t.Fatal(err)
	}
	count, err := st.ScheduleExpiredChannelMemoryCleanup(
		ctx, started.Add(time.Minute), time.Now().Add(-time.Minute),
	)
	if err != nil || count != 1 {
		t.Fatalf("scheduled = %d, %v", count, err)
	}
	item, err := st.NextCleanup(ctx, time.Now())
	if err != nil || item.SessionID != "session-old" || item.IncidentID != "" {
		t.Fatalf("cleanup = %+v, %v", item, err)
	}
	if err := st.SetCleanupState(
		ctx, item.SessionID, "done", "discard-plan", "", time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Prune(
		ctx,
		time.Now().Add(time.Hour),
		time.Now().Add(time.Hour),
		time.Now().Add(time.Hour),
		time.Now().Add(-time.Hour),
		time.Now().Add(-time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.GetChannelMemory(ctx, "COPS"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired channel memory remained after owned cleanup: %v", err)
	}
}

func TestIncidentCardRevisionInvalidatesRenderedCardsOnce(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "ems-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	incident, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkCardRendered(ctx, incident.ID, incident.CardVersion); err != nil {
		t.Fatal(err)
	}
	changed, err := st.EnsureIncidentCardRevision(ctx, "revision-1")
	if err != nil || !changed {
		t.Fatalf("first revision = %v, %v", changed, err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || dirty[0].ID != incident.ID {
		t.Fatalf("dirty after UI upgrade = %+v, %v", dirty, err)
	}
	if err := st.MarkCardRendered(ctx, dirty[0].ID, dirty[0].CardVersion); err != nil {
		t.Fatal(err)
	}
	changed, err = st.EnsureIncidentCardRevision(ctx, "revision-1")
	if err != nil || changed {
		t.Fatalf("same revision = %v, %v", changed, err)
	}
	dirty, err = st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 0 {
		t.Fatalf("same revision dirtied cards = %+v, %v", dirty, err)
	}
	changed, err = st.EnsureIncidentCardRevision(ctx, "revision-2")
	if err != nil || !changed {
		t.Fatalf("second revision = %v, %v", changed, err)
	}
}

func TestResolvedDeletedWorkIsClosedAndQueuedForSafeCleanup(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CDELETED", "ems-deleted"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "session-deleted", "fork-deleted", 1); err != nil {
		t.Fatal(err)
	}
	resolved := event
	resolved.DedupeKey = "delivery-resolved"
	resolved.BodyDigest = "resolved-digest"
	resolved.Signals = append([]core.Signal(nil), event.Signals...)
	resolved.Signals[0].EventID = "event-resolved"
	resolved.Signals[0].Status = core.SignalResolved
	resolved.Signals[0].ReceivedAt = time.Now().UTC()
	if _, err := st.ApplySignals(ctx, resolved, time.Hour, 0, 100); err != nil {
		t.Fatal(err)
	}
	deletedAt := time.Now().UTC()
	if _, err := st.SetIncidentChannelState(
		ctx,
		"CDELETED",
		core.ChannelDeleted,
		deletedAt,
	); err != nil {
		t.Fatal(err)
	}

	retired, err := st.RetireResolvedDeletedWork(
		ctx,
		deletedAt.Add(time.Hour),
	)
	if err != nil || retired != 1 {
		t.Fatalf("retired = %d, %v", retired, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.Status != core.IncidentClosed ||
		incident.Workflow != core.WorkflowClosed {
		t.Fatalf("retired incident = %+v, %v", incident, err)
	}
	askedAt := time.Now().UTC()
	cleanup, err := st.NextCleanup(ctx, askedAt)
	if err != nil || cleanup.SessionID != "session-deleted" ||
		cleanup.IncidentID != incident.ID || cleanup.AllowUnmerged {
		// This assertion has failed intermittently and never reproduced: roughly
		// forty attempts across isolated runs, -count repetition, -shuffle,
		// -race, and full-tree runs at -p 8. Rather than guess at a fix, the
		// failure explains itself when it next happens.
		t.Fatalf(
			"cleanup ownership = %+v, %v\n"+
				"asked at:   %s\n"+
				"deleted at: %s\n"+
				"rows in coop_cleanup:\n%s",
			cleanup, err,
			askedAt.Format(timestampFormat),
			deletedAt.Format(timestampFormat),
			dumpCleanupRows(t, st),
		)
	}
}

// dumpCleanupRows renders the cleanup queue for a failure message. The
// intermittent failure above reports "no row found" without saying whether the
// row is absent, in the wrong state, or merely not yet eligible — and those
// have three different causes.
func dumpCleanupRows(t *testing.T, st *Store) string {
	t.Helper()
	rows, err := st.db.Query(`
		SELECT session_id, incident_id, state, eligible_at, next_attempt_at, created_at
		FROM coop_cleanup ORDER BY created_at`)
	if err != nil {
		return "  (query failed: " + err.Error() + ")"
	}
	defer rows.Close()
	var out strings.Builder
	for rows.Next() {
		var session, incident, state, eligible, next, created string
		if err := rows.Scan(&session, &incident, &state, &eligible, &next, &created); err != nil {
			return "  (scan failed: " + err.Error() + ")"
		}
		fmt.Fprintf(&out, "  session=%s incident=%s state=%s eligible_at=%s next_attempt_at=%s created_at=%s\n",
			session, incident, state, eligible, next, created)
	}
	if out.Len() == 0 {
		return "  (none — the row was never inserted)"
	}
	return out.String()
}

package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestSchemaV28BackfillsPublicationFollowupsWithoutHistoricalSpam(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:27] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (27)`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	for index, id := range []string{"inc_old", "inc_latest"} {
		published := now.Add(time.Duration(index-1) * time.Hour).Format(timestampFormat)
		if _, err := db.Exec(`
			INSERT INTO incidents (
			  id, route, repository, correlation_key, title, status, workflow,
			  work_kind, work_scope, origin_channel_id, origin_thread_ts,
			  created_at, updated_at
			) VALUES (?, 'manual', 'repo', ?, ?, 'active', 'idle',
			  'engineering_task', 'thread', 'CTASK', ?, ?, ?)`,
			id, "correlation:"+id, "Task "+id, "1700."+id,
			published, published,
		); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`
			INSERT INTO publications (
			  incident_id, repository, base_branch, head_branch, parent_head,
			  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
			  created_at, updated_at, published_at
			) VALUES (?, 'owner/repo', 'main', ?, 'parent', 'tree', 'commit', ?, ?, ?,
			  'published', ?, ?, ?)`,
			id, "responder/"+id, "0123456789abcdef"+id, 100+index,
			"https://github.com/owner/repo/pull/"+fmt.Sprint(100+index),
			published, published, published,
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	old, err := st.GetPublicationFollowup(context.Background(), "inc_old")
	if err != nil || old.LastEventKey != "baseline" {
		t.Fatalf("historical follow-up = %+v, %v", old, err)
	}
	latest, err := st.GetPublicationFollowup(context.Background(), "inc_latest")
	if err != nil || latest.LastEventKey != "" {
		t.Fatalf("latest follow-up = %+v, %v", latest, err)
	}
}

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
	if _, err := st.RecordEvidence(ctx, []core.Evidence{{
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
	if _, err := st.CreateActionProposals(ctx, []core.ActionProposal{{
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
	if err := st.RecordTimeline(ctx, core.TimelineEvent{
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
	if err := st.BindChannelSession(ctx, "COPS", "repo", "session-old", 3, 1, started); err != nil {
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
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetChannelMemory(ctx, "COPS"); !errors.Is(err, ErrNotFound) {
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
	cleanup, err := st.NextCleanup(ctx, time.Now().UTC())
	if err != nil || cleanup.SessionID != "session-deleted" ||
		cleanup.IncidentID != incident.ID || cleanup.AllowUnmerged {
		t.Fatalf("cleanup ownership = %+v, %v", cleanup, err)
	}
}

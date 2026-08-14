package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestSchemaV63RepaintsPublicationLifecycleCards(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	incident, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-repaint", "Repaint task", "summary", "UOP",
		"COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SavePublication(ctx, core.Publication{
		IncidentID: incident.ID, Repository: "owner/repo", BaseBranch: "main",
		HeadBranch: "responder/task", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "remote", PRNumber: 529,
		PRURL: "https://github.example/owner/repo/pull/529",
		State: core.PublicationStale, LastError: "follow-up changed after merge",
		PublishedAt: time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Ensure(ctx, incident.ID, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	followup, err := st.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	followup.PRState = "merged"
	followup.ChecksState = "passing"
	followup.MergeSHA = "merge"
	followup.MergedAt = time.Now().UTC()
	followup.NextCheckAt = time.Now().UTC().Add(24 * time.Hour)
	if err := st.PublicationFollowups.Save(ctx, followup); err != nil {
		t.Fatal(err)
	}
	current, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkCardRendered(ctx, incident.ID, current.CardVersion); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		ALTER TABLE slack_deliveries DROP COLUMN response_root;
		ALTER TABLE slack_deliveries DROP COLUMN agent_run_id;
		ALTER TABLE slack_deliveries DROP COLUMN agent_run_key;
		ALTER TABLE slack_deliveries DROP COLUMN source_input_id;
		ALTER TABLE incidents DROP COLUMN latest_update_run_id;
		ALTER TABLE incidents DROP COLUMN latest_update_run_key;
		ALTER TABLE evaluation_decisions DROP COLUMN agent_run_id;
		ALTER TABLE evaluation_decisions DROP COLUMN agent_run_key;
		ALTER TABLE context_manifests DROP COLUMN usage_cost_usd;
		ALTER TABLE context_manifests DROP COLUMN usage_costed_turns;
		ALTER TABLE work_episodes DROP COLUMN last_activity_at;
		DROP TABLE agent_activity;
		DROP TABLE context_artifacts;
		DROP TABLE replay_cancellations;
		UPDATE schema_version SET version = 62;
	`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	repainted, err := st.GetIncident(ctx, incident.ID)
	if err != nil || repainted.CardVersion != current.CardVersion+1 ||
		repainted.CardRenderedVersion != current.CardVersion {
		t.Fatalf("repainted card = %+v after %+v, %v", repainted, current, err)
	}
	publication, err := st.GetPublication(ctx, incident.ID)
	if err != nil || !publication.Published() || publication.LastError != "" {
		t.Fatalf("terminal publication receipt = %+v, %v", publication, err)
	}
}

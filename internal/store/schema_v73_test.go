package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
)

// A database migrated from v72 keeps the work it already holds and gains an
// empty handle on the diff message and an empty stat.
//
// Empty is the honest starting value for both. A task that predates the column
// may well have a diff sitting open in its thread, but nothing recorded which
// message it was, and inventing one would make the first View diff press try to
// delete a message chosen at random. The stat is empty for the same reason: no
// patch has been fetched whole since the column existed.
func TestSchemaV73AddsDiffMessageTrackingAndStat(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 72; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const stamp = "2026-08-13T12:00:00.000000000Z"
	if _, err := db.Exec(`INSERT INTO incidents
		(id, route, repository, correlation_key, source_incident_id, title, severity,
		 status, workflow, signal_count, firing_count, channel_id, channel_name, root_ts,
		 coop_session_id, coop_fork_name, created_at, updated_at, work_kind, work_scope,
		 origin_channel_id, origin_thread_ts, latest_update)
		VALUES ('inc-v72','manual','blitz-infra','key-v72','task:VA1',
		 'VA1: prevent reload-driven Traefik OOM recurrence','sev2','active','parked',
		 0,0,'COPS','ops','1700.1','ses-v72','remote-44f3f67',?,?,
		 'engineering_task','thread','COPS','1700.0','Raised the allocation memory.')`,
		stamp, stamp); err != nil {
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
	ctx := context.Background()

	task, err := st.GetIncident(ctx, "inc-v72")
	if err != nil {
		t.Fatal(err)
	}
	if task.Title != "VA1: prevent reload-driven Traefik OOM recurrence" ||
		task.CoopForkName != "remote-44f3f67" || task.RootTS != "1700.1" ||
		task.LatestUpdate != "Raised the allocation memory." {
		t.Fatalf("the task did not survive the migration intact: %+v", task)
	}
	if task.ChangesMessageTS != "" || task.ChangesStat != "" {
		t.Fatalf("a task older than the columns claims a diff %q and a stat %q",
			task.ChangesMessageTS, task.ChangesStat)
	}

	// The first diff delivered after the migration fills the handle in, and
	// moves the card version so the button can change from View to Hide.
	before := task.CardVersion
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_changes_v73", IncidentID: task.ID, Kind: "changes",
		ChannelID: task.ChannelID, ThreadTS: "1700.0", Body: []byte(`{"text":"Code changes"}`),
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, delivery.ID, "1700.900", "sending"); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.ChangesMessageTS != "1700.900" {
		t.Fatalf("the delivered diff was not tracked: %q", task.ChangesMessageTS)
	}
	if task.CardVersion <= before {
		t.Fatalf("tracking the diff left the card at version %d; the button cannot flip",
			task.CardVersion)
	}

	// Closing it puts the card back where it started, and says so once.
	if err := st.Incidents.ClearChangesMessage(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	cleared, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if cleared.ChangesMessageTS != "" || cleared.CardVersion <= task.CardVersion {
		t.Fatalf("clearing the diff = %q at version %d", cleared.ChangesMessageTS, cleared.CardVersion)
	}
	// Idempotent: Close diff and a delete that found nothing both call it, and
	// neither knows whether the other already did.
	if err := st.Incidents.ClearChangesMessage(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	again, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if again.CardVersion != cleared.CardVersion {
		t.Fatalf("clearing an already-clear diff re-rendered the card: %d then %d",
			cleared.CardVersion, again.CardVersion)
	}

	if err := st.Incidents.SetChangesStat(ctx, task.ID, "3 files · +48 −12"); err != nil {
		t.Fatal(err)
	}
	stat, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stat.ChangesStat != "3 files · +48 −12" {
		t.Fatalf("stat = %q", stat.ChangesStat)
	}
	if stat.CardVersion != again.CardVersion {
		t.Fatalf("recording a counter re-rendered the card: %d then %d",
			again.CardVersion, stat.CardVersion)
	}
}

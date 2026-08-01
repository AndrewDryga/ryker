package store

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestSchemaV26AddsScheduledTasksToExistingState(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:25] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (25)`); err != nil {
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
	now := time.Now().UTC()
	task, err := st.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: "T1", ChannelID: "C1", Repository: "repo", Title: "Migrated reminder",
		Prompt: "Report current health.", Recurrence: "once", StartAt: now.Add(time.Hour),
		NextRunAt: now.Add(time.Hour), Timezone: "UTC", CatchUp: "latest",
		ActorID: "U1", SourceRef: "migration", ExpiresAt: now.Add(24 * time.Hour),
	}, 10, 5)
	if err != nil || task.ID == "" {
		t.Fatalf("create schedule after v25 migration = %+v, %v", task, err)
	}
}

func TestScheduledTasksAreDurableBoundedAndOccurrenceIdempotent(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC().Truncate(time.Second)
	task, err := st.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1", Repository: "repo",
		Title: "Daily health", Prompt: "Check production health and report material changes.",
		Recurrence: "daily", StartAt: now.Add(time.Hour), LocalTime: "09:00",
		Timezone: "UTC", CatchUp: "latest", ActorID: "U1", SourceRef: "Ev1",
		NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(30 * 24 * time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	replayed, err := st.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1", Repository: "repo",
		Title: "Duplicate", Prompt: "This must not create another row.",
		Recurrence: "once", StartAt: now.Add(2 * time.Hour), Timezone: "UTC",
		CatchUp: "latest", ActorID: "U1", SourceRef: "Ev1",
		NextRunAt: now.Add(2 * time.Hour), ExpiresAt: now.Add(30 * 24 * time.Hour),
	}, 10, 5)
	if err != nil || replayed.ID != task.ID {
		t.Fatalf("replayed confirmation = %+v, err=%v; want %s", replayed, err, task.ID)
	}
	listed, err := st.ListScheduledTasksForChannel(ctx, "C1", 10)
	if err != nil || len(listed) != 1 || listed[0].ID != task.ID {
		t.Fatalf("listed schedules = %+v, %v", listed, err)
	}
	scheduledFor := task.NextRunAt
	occurrence, execute, err := st.ClaimScheduledTaskRun(
		ctx, task, scheduledFor, scheduledFor.Add(24*time.Hour), "scheduled_input", true, true, "",
	)
	if err != nil || !execute || occurrence.Outcome != "queued" {
		t.Fatalf("claimed occurrence = %+v, execute=%t, err=%v", occurrence, execute, err)
	}
	if _, duplicate, err := st.ClaimScheduledTaskRun(ctx, task, scheduledFor, time.Time{}, "duplicate", true, true, ""); err != nil || duplicate {
		t.Fatalf("duplicate occurrence execute=%t err=%v", duplicate, err)
	}
	secondFor := scheduledFor.Add(time.Hour)
	second, execute, err := st.ClaimScheduledTaskRun(ctx, task, secondFor, time.Time{}, "overlap", false, true, "")
	if err != nil || execute || second.Outcome != "skipped_overlap" {
		t.Fatalf("overlap occurrence = %+v, execute=%t, err=%v", second, execute, err)
	}
	if err := st.LinkScheduledTaskRun(ctx, task.ID, scheduledFor, "run_1"); err != nil {
		t.Fatal(err)
	}
	if err := st.CompleteScheduledTaskRun(ctx, task.ID, scheduledFor, "completed", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := st.DeleteScheduledTask(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	runs, err := st.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 0 {
		t.Fatalf("active runs after delete = %+v, %v", runs, err)
	}
}

func TestScheduledTaskCapacityIsEnforced(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	base := core.ScheduledTask{TeamID: "T1", ChannelID: "C1", Repository: "repo", Title: "one", Prompt: "report", Recurrence: "once", StartAt: now.Add(time.Hour), Timezone: "UTC", CatchUp: "latest", ActorID: "U1", SourceRef: "one", NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour)}
	if _, err := st.CreateScheduledTask(ctx, base, 1, 1); err != nil {
		t.Fatal(err)
	}
	base.SourceRef = "two"
	if _, err := st.CreateScheduledTask(ctx, base, 1, 1); err == nil {
		t.Fatal("expected scheduled task capacity error")
	}
}

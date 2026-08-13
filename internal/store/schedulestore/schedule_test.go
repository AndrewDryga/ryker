package schedulestore_test

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/schedulestore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

func TestScheduledTasksAreDurableBoundedAndOccurrenceIdempotent(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := schedulestore.New(db, time.Now)
	now := time.Now().UTC().Truncate(time.Second)
	task, err := repo.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1", Repository: "repo",
		Title: "Daily health", Prompt: "Check production health and report material changes.",
		Recurrence: "daily", StartAt: now.Add(time.Hour), LocalTime: "09:00",
		Timezone: "UTC", CatchUp: "latest", ActorID: "U1", SourceRef: "Ev1",
		NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(30 * 24 * time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	replayed, err := repo.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "100.1", Repository: "repo",
		Title: "Duplicate", Prompt: "This must not create another row.",
		Recurrence: "once", StartAt: now.Add(2 * time.Hour), Timezone: "UTC",
		CatchUp: "latest", ActorID: "U1", SourceRef: "Ev1",
		NextRunAt: now.Add(2 * time.Hour), ExpiresAt: now.Add(30 * 24 * time.Hour),
	}, 10, 5)
	if err != nil || replayed.ID != task.ID {
		t.Fatalf("replayed confirmation = %+v, err=%v; want %s", replayed, err, task.ID)
	}
	listed, err := repo.ListScheduledTasksForChannel(ctx, "C1", 10)
	if err != nil || len(listed) != 1 || listed[0].ID != task.ID {
		t.Fatalf("listed schedules = %+v, %v", listed, err)
	}
	scheduledFor := task.NextRunAt
	occurrence, execute, err := repo.ClaimScheduledTaskRun(
		ctx, task, scheduledFor, scheduledFor.Add(24*time.Hour), "scheduled_input", true, true, "",
	)
	if err != nil || !execute || occurrence.Outcome != "queued" {
		t.Fatalf("claimed occurrence = %+v, execute=%t, err=%v", occurrence, execute, err)
	}
	if _, duplicate, err := repo.ClaimScheduledTaskRun(ctx, task, scheduledFor, time.Time{}, "duplicate", true, true, ""); err != nil || duplicate {
		t.Fatalf("duplicate occurrence execute=%t err=%v", duplicate, err)
	}
	secondFor := scheduledFor.Add(time.Hour)
	second, execute, err := repo.ClaimScheduledTaskRun(ctx, task, secondFor, time.Time{}, "overlap", false, true, "")
	if err != nil || execute || second.Outcome != "skipped_overlap" {
		t.Fatalf("overlap occurrence = %+v, execute=%t, err=%v", second, execute, err)
	}
	if err := repo.LinkScheduledTaskRun(ctx, task.ID, scheduledFor, "run_1", "episode_1"); err != nil {
		t.Fatal(err)
	}
	linked, err := repo.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(linked) != 1 || linked[0].EpisodeID != "episode_1" {
		t.Fatalf("linked schedule episode = %+v, %v", linked, err)
	}
	if err := repo.CompleteScheduledTaskRun(ctx, task.ID, scheduledFor, "completed", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.DeleteScheduledTask(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	runs, err := repo.ListActiveScheduledTaskRuns(ctx, 10)
	if err != nil || len(runs) != 0 {
		t.Fatalf("active runs after delete = %+v, %v", runs, err)
	}
}

func TestScheduledTaskCapacityIsEnforced(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := schedulestore.New(db, time.Now)
	now := time.Now().UTC()
	base := core.ScheduledTask{TeamID: "T1", ChannelID: "C1", Repository: "repo", Title: "one", Prompt: "report", Recurrence: "once", StartAt: now.Add(time.Hour), Timezone: "UTC", CatchUp: "latest", ActorID: "U1", SourceRef: "one", NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour)}
	if _, err := repo.CreateScheduledTask(ctx, base, 1, 1); err != nil {
		t.Fatal(err)
	}
	base.SourceRef = "two"
	if _, err := repo.CreateScheduledTask(ctx, base, 1, 1); err == nil {
		t.Fatal("expected scheduled task capacity error")
	}
}

func TestScheduleProposalUpdatesMatchingTaskInPlaceAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := schedulestore.New(db, time.Now)
	now := time.Now().UTC().Truncate(time.Second)
	existing, err := repo.CreateScheduledTask(ctx, core.ScheduledTask{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "old-thread", DeliveryChannel: "C1",
		Repository: "repo", Title: "Daily health v3", Prompt: "Run version 3.",
		Recurrence: "daily", StartAt: now.Add(time.Hour), LocalTime: "09:00",
		Timezone: "UTC", CatchUp: "latest", ActorID: "U1", SourceRef: "old-source",
		NextRunAt: now.Add(time.Hour), ExpiresAt: now.Add(30 * 24 * time.Hour),
	}, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	proposal, err := repo.Create(ctx, core.ScheduleProposal{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "new-thread", ActorID: "U1",
		SourceRef: "activation-message", ReplaceTaskID: existing.ID,
		ExpiresAt: now.Add(24 * time.Hour),
		Task: core.ScheduledTask{
			TeamID: "T1", ChannelID: "C1", ThreadTS: "new-thread", DeliveryChannel: "C1",
			Repository: "repo", Title: "Daily health v5", Prompt: "Run exact version 5 with fresh evidence.",
			Recurrence: "daily", StartAt: now.Add(2 * time.Hour), LocalTime: "09:00",
			Timezone: "UTC", CatchUp: "latest", ActorID: "U1", SourceRef: "activation-message",
			NextRunAt: now.Add(2 * time.Hour), ExpiresAt: now.Add(90 * 24 * time.Hour),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := repo.Accept(ctx, proposal.ID, "T1", "C1", "U1", 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	if accepted.ID != existing.ID || accepted.Title != "Daily health v5" || accepted.Prompt != proposal.Task.Prompt || accepted.ThreadTS != "new-thread" {
		t.Fatalf("updated schedule = %+v", accepted)
	}
	replayed, err := repo.Accept(ctx, proposal.ID, "T1", "C1", "U1", 10, 5)
	if err != nil || replayed.ID != existing.ID {
		t.Fatalf("replayed acceptance = %+v, err=%v", replayed, err)
	}
	listed, err := repo.ListScheduledTasksForChannel(ctx, "C1", 10)
	if err != nil || len(listed) != 1 || listed[0].Prompt != proposal.Task.Prompt {
		t.Fatalf("scheduled tasks after replacement = %+v, err=%v", listed, err)
	}
}

// Pausing is always allowed; resuming is not. A schedule with no future run —
// a one-off that already fired, or anything past its expiry — has nothing to
// be resumed to, and the store refuses rather than flipping a flag that would
// never fire. The control plane turns that refusal into a sentence, so it has
// to be a refusal and not a silent no-op.
func TestResumingNeedsAFutureRunAndPausingAlwaysWorks(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	repo := schedulestore.New(db, time.Now)
	now := time.Now().UTC().Truncate(time.Second)
	create := func(ref, recurrence, localTime string, next time.Time) core.ScheduledTask {
		t.Helper()
		task, err := repo.CreateScheduledTask(ctx, core.ScheduledTask{
			TeamID: "T1", ChannelID: "C1", Repository: "repo",
			Title: "Check " + ref, Prompt: "Check something.", Recurrence: recurrence,
			LocalTime: localTime,
			StartAt:   next, Timezone: "UTC", CatchUp: "latest", ActorID: "U1",
			SourceRef: ref, NextRunAt: next, ExpiresAt: now.Add(30 * 24 * time.Hour),
		}, 10, 5)
		if err != nil {
			t.Fatalf("create %s: %v", ref, err)
		}
		return task
	}

	recurring := create("Ev-daily", "daily", "09:00", now.Add(time.Hour))
	paused, err := repo.SetScheduledTaskEnabled(ctx, recurring.ID, false)
	if err != nil || paused.Enabled {
		t.Fatalf("pause = %+v, %v; want it disabled", paused, err)
	}
	resumed, err := repo.SetScheduledTaskEnabled(ctx, recurring.ID, true)
	if err != nil || !resumed.Enabled {
		t.Fatalf("resume = %+v, %v; want it enabled again", resumed, err)
	}

	// A schedule whose next run has been cleared cannot be resumed.
	spent := create("Ev-once", "once", "", now.Add(time.Hour))
	if _, err := repo.SetScheduledTaskEnabled(ctx, spent.ID, false); err != nil {
		t.Fatalf("pause the one-off: %v", err)
	}
	if _, err := db.ExecContext(ctx,
		`UPDATE scheduled_tasks SET next_run_at = NULL WHERE id = ?`, spent.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetScheduledTaskEnabled(ctx, spent.ID, true); err == nil {
		t.Fatal("resumed a schedule that has no future run to resume to")
	}

	// Deleting reports what was deleted, and doing it twice is an error rather
	// than a silent success, so a stale page cannot claim a second removal.
	deleted, err := repo.DeleteScheduledTask(ctx, recurring.ID)
	if err != nil || deleted.ID != recurring.ID {
		t.Fatalf("delete = %+v, %v", deleted, err)
	}
	if _, err := repo.DeleteScheduledTask(ctx, recurring.ID); err == nil {
		t.Fatal("deleting an already-deleted schedule reported success")
	}
}

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

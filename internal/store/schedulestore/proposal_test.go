package schedulestore_test

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/schedulestore"
)

// Accepting the same proposal twice returns the same schedule rather than
// failing or creating a second one.
//
// This is the ordinary case — a button press after a conversational
// confirmation, or a retried click — and it is handled by an explicit
// already-accepted branch in Accept, not by the race guard below it. The test
// exists because that branch is the thing standing between a duplicate click
// and either a duplicate schedule or an error message for an operation that
// worked.
func TestAcceptingTwiceReturnsTheSameSchedule(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	proposal, err := st.Schedules.Create(ctx, core.ScheduleProposal{
		TeamID: "T1", ChannelID: "C1", ThreadTS: "1700.1", ActorID: "U1",
		SourceRef: "src-1",
		Task: core.ScheduledTask{
			TeamID: "T1", ChannelID: "C1", ActorID: "U1", SourceRef: "src-1",
			Title: "daily report", Prompt: "report on the platform",
			Repository: "repo", Recurrence: "daily", LocalTime: "09:00",
			Timezone: "UTC", CatchUp: "latest",
			ExpiresAt: time.Now().UTC().Add(90 * 24 * time.Hour),
			NextRunAt: time.Now().UTC().Add(time.Hour),
		},
	})
	if err != nil {
		t.Fatalf("create proposal: %v", err)
	}

	first, err := st.Schedules.Accept(ctx, proposal.ID, "T1", "C1", "U1", 50, 10)
	if err != nil {
		t.Fatalf("first accept: %v", err)
	}
	second, err := st.Schedules.Accept(ctx, proposal.ID, "T1", "C1", "U1", 50, 10)
	if err != nil {
		t.Fatalf("second accept failed instead of returning the saved schedule: %v", err)
	}
	if second.ID != first.ID {
		t.Fatalf("a second accept created a different schedule: %s then %s", first.ID, second.ID)
	}
	tasks, err := st.Schedules.ListScheduledTasksForChannel(ctx, "C1", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 1 {
		t.Fatalf("accepting twice left %d scheduled tasks", len(tasks))
	}
}

// The race guard under that branch must report a conflict callers can match.
//
// Two accepts running at once both pass the already-accepted check, and one
// loses the "WHERE status = 'pending'" update. That loser has to be
// distinguishable from a real failure with errors.Is, or the caller shows a
// database error for a schedule that exists.
//
// This package had grown its own expectOne returning a formatted "database
// conflict" string, which errors.Is could never match — the same duplication
// hazard that a shared helper exists to prevent.
func TestLosingTheAcceptRaceIsAMatchableConflict(t *testing.T) {
	err := schedulestore.ConflictFor("accept schedule proposal")
	if !errors.Is(err, core.ErrConflict) {
		t.Fatalf("conflict is not matchable as core.ErrConflict: %v", err)
	}
	if !errors.Is(err, store.ErrConflict) {
		t.Fatalf("conflict is not matchable as store.ErrConflict: %v", err)
	}
}

func TestAcceptManyCreatesEveryScheduleAtomically(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC()
	ids := make([]string, 0, 2)
	for index, delay := range []time.Duration{24 * time.Hour, 72 * time.Hour} {
		proposal, createErr := st.Schedules.Create(ctx, core.ScheduleProposal{
			TeamID: "T1", ChannelID: "C1", ThreadTS: "1700.1", ActorID: "U1",
			SourceRef: "batch-" + string(rune('1'+index)),
			Task: core.ScheduledTask{
				TeamID: "T1", ChannelID: "C1", ThreadTS: "1700.1", ActorID: "U1",
				SourceRef: "batch-" + string(rune('1'+index)), Title: "check Zot logs",
				Prompt: "check Zot logs and report here", Repository: "repo", Recurrence: "once",
				StartAt: now.Add(delay), NextRunAt: now.Add(delay), Timezone: "UTC", CatchUp: "latest",
				ExpiresAt: now.Add(delay + 24*time.Hour),
			},
		})
		if createErr != nil {
			t.Fatalf("create proposal %d: %v", index, createErr)
		}
		ids = append(ids, proposal.ID)
	}

	tasks, err := st.Schedules.AcceptMany(ctx, ids, "T1", "C1", "U1", 10, 10)
	if err != nil {
		t.Fatalf("accept batch: %v", err)
	}
	if len(tasks) != 2 {
		t.Fatalf("accepted %d tasks, want 2", len(tasks))
	}
}

func TestAcceptManyRollsBackTheWholeBatch(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Now().UTC()
	ids := make([]string, 0, 2)
	for index, delay := range []time.Duration{24 * time.Hour, 72 * time.Hour} {
		proposal, createErr := st.Schedules.Create(ctx, core.ScheduleProposal{
			TeamID: "T1", ChannelID: "C1", ThreadTS: "1700.1", ActorID: "U1",
			SourceRef: "rollback-" + string(rune('1'+index)),
			Task: core.ScheduledTask{
				TeamID: "T1", ChannelID: "C1", ThreadTS: "1700.1", ActorID: "U1",
				SourceRef: "rollback-" + string(rune('1'+index)), Title: "check Zot logs",
				Prompt: "check Zot logs and report here", Repository: "repo", Recurrence: "once",
				StartAt: now.Add(delay), NextRunAt: now.Add(delay), Timezone: "UTC", CatchUp: "latest",
				ExpiresAt: now.Add(delay + 24*time.Hour),
			},
		})
		if createErr != nil {
			t.Fatalf("create proposal %d: %v", index, createErr)
		}
		ids = append(ids, proposal.ID)
	}

	if _, err := st.Schedules.AcceptMany(ctx, ids, "T1", "C1", "U1", 1, 1); err == nil {
		t.Fatal("batch exceeding capacity was accepted")
	}
	tasks, err := st.Schedules.ListScheduledTasksForChannel(ctx, "C1", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 0 {
		t.Fatalf("failed batch left %d active tasks", len(tasks))
	}
}

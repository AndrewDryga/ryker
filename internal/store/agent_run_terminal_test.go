package store

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func forceEpisodeCompleted(t *testing.T, st *Store, episodeID string) {
	t.Helper()
	if _, err := st.db.ExecContext(context.Background(), `
		UPDATE work_episodes
		SET lifecycle_state = 'completed', phase = 'finished', status = 'Completed',
		    completed_at = updated_at
		WHERE id = ?`, episodeID); err != nil {
		t.Fatal(err)
	}
}

func TestLeaseAgentRunCancelsTransportForTerminalEpisode(t *testing.T) {
	for _, state := range []string{"pending", "preparing"} {
		t.Run(state, func(t *testing.T) {
			ctx := context.Background()
			st, err := Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()

			run, episode := queueKernelEpisode(t, st, "stale-"+state)
			if state == "preparing" {
				leased, err := st.LeaseAgentRun(ctx)
				if err != nil {
					t.Fatal(err)
				}
				if leased.ID != run.ID {
					t.Fatalf("leased %s, want %s", leased.ID, run.ID)
				}
			}
			forceEpisodeCompleted(t, st, episode.ID)

			if _, err := st.LeaseAgentRun(ctx); !errors.Is(err, ErrNotFound) {
				t.Fatalf("lease after terminal episode = %v, want not found", err)
			}
			stored, err := st.GetAgentRun(ctx, run.ID)
			if err != nil {
				t.Fatal(err)
			}
			if stored.State != core.AgentRunCancelled || stored.TerminalState != string(core.AgentRunCancelled) {
				t.Fatalf("run = %s / %s, want cancelled / cancelled", stored.State, stored.TerminalState)
			}
			attempt, err := st.GetEpisodeAttempt(ctx, run.AttemptID)
			if err != nil {
				t.Fatal(err)
			}
			if attempt.State != core.AttemptCancelled || attempt.FailureClass != "episode_terminal" {
				t.Fatalf("attempt = %s / %q, want cancelled / episode_terminal", attempt.State, attempt.FailureClass)
			}
			completed, err := st.GetWorkEpisode(ctx, episode.ID)
			if err != nil {
				t.Fatal(err)
			}
			if completed.State != core.EpisodeCompleted {
				t.Fatalf("episode was revived to %s", completed.State)
			}
		})
	}
}

func TestLeaseAgentRunSkipsTerminalEpisodeAndLeasesUsefulWork(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	stale, episode := queueKernelEpisode(t, st, "stale")
	forceEpisodeCompleted(t, st, episode.ID)
	useful, _ := queueKernelEpisode(t, st, "useful")

	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != useful.ID {
		t.Fatalf("leased %s, want useful run %s", leased.ID, useful.ID)
	}
	stored, err := st.GetAgentRun(ctx, stale.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunCancelled {
		t.Fatalf("stale run state = %s, want cancelled", stored.State)
	}
}

func TestSupersededOlderAttemptDoesNotCloseNewerWork(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, episode := queueKernelEpisode(t, st, "first")
	second, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: first.ConversationKey, SourceKind: "watch",
		SourceID: "second", Prompt: "Continue with newer evidence",
	})
	if err != nil || !created {
		t.Fatalf("queue replacement: created=%t err=%v", created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != first.ID {
		t.Fatalf("leased %s, want older run %s", leased.ID, first.ID)
	}
	if err := st.SupersedeAgentRun(ctx, first.ID, "newer correlated input queued"); err != nil {
		t.Fatal(err)
	}

	active, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if active.State == core.EpisodeSuperseded || active.State == core.EpisodeCancelled {
		t.Fatalf("older attempt closed shared episode as %s", active.State)
	}
	leased, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != second.ID {
		t.Fatalf("leased %s, want replacement %s", leased.ID, second.ID)
	}
}

func TestPublicPhaseUpdateFromOlderAttemptDoesNotCancelNewerAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "channel:COPS",
		SourceKind: "watch", SourceID: "older-progress", State: core.AgentRunRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, first.ID, "completed", []byte(`{"action":"reply"}`), "", 1,
	); err != nil {
		t.Fatal(err)
	}
	second, created, err := st.QueueEpisodeAttempt(ctx, first.EpisodeID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: first.ConversationKey,
		SourceKind: "watch", SourceID: "newer-terminal", Prompt: "Report terminal state",
	})
	if err != nil || !created {
		t.Fatalf("queue newer attempt: created=%t err=%v", created, err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, first.ID); err != nil {
		t.Fatal(err)
	}

	// The older in-progress result arrives after the terminal notification has
	// already become the episode's latest attempt. This was the public phase
	// path that bypassed the ownership guard and closed the shared episode.
	if err := st.SetWorkEpisodePhase(
		ctx, first.ID, core.EpisodeSuperseded, "finished",
		"Superseded by a newer operational update", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, first.ID); err != nil {
		t.Fatal(err)
	}

	episode, err := st.GetWorkEpisode(ctx, first.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State == core.EpisodeSuperseded || episode.State == core.EpisodeCompleted ||
		episode.LatestAttemptID != second.AttemptID {
		t.Fatalf("older attempt closed shared episode = %+v", episode)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != second.ID {
		t.Fatalf("leased %s, want newer terminal attempt %s", leased.ID, second.ID)
	}
}

func TestQueueEpisodeAttemptAtomicallyPublishesLatestAttemptBeforeOlderTerminalPhase(t *testing.T) {
	ctx := context.Background()
	stateDir := t.TempDir()
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "channel:COPS",
		SourceKind: "watch", SourceID: "atomic-older", State: core.AgentRunRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, first.ID, "completed", []byte(`{"action":"reply"}`), "", 1,
	); err != nil {
		t.Fatal(err)
	}
	inserted := make(chan struct{})
	release := make(chan struct{})
	st.testHookAfterAgentRunInsert = func() {
		close(inserted)
		<-release
	}
	queueDone := make(chan struct{})
	var second core.AgentRun
	var created bool
	var queueErr error
	go func() {
		defer close(queueDone)
		second, created, queueErr = st.QueueEpisodeAttempt(ctx, first.EpisodeID, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: first.ConversationKey,
			SourceKind: "watch", SourceID: "atomic-newer", Prompt: "Report terminal state",
		})
	}()
	<-inserted
	probe, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close()
	var visibleRuns int
	if err := probe.QueryRowContext(ctx, `
		SELECT count(*) FROM agent_runs WHERE source_id = 'atomic-newer'`,
	).Scan(&visibleRuns); err != nil {
		t.Fatal(err)
	}
	if visibleRuns != 0 {
		t.Fatalf("half-admitted newer run became visible: %d", visibleRuns)
	}

	phaseDone := make(chan error, 1)
	phaseStarted := make(chan struct{})
	go func() {
		close(phaseStarted)
		phaseDone <- st.SetWorkEpisodePhase(
			ctx, first.ID, core.EpisodeSuperseded, "finished",
			"Superseded by a newer operational update", "", time.Time{},
		)
	}()
	<-phaseStarted
	select {
	case err := <-phaseDone:
		t.Fatalf("older terminal phase escaped admission transaction: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	<-queueDone
	if queueErr != nil || !created {
		t.Fatalf("queue newer attempt: run=%+v created=%t err=%v", second, created, queueErr)
	}
	if err := <-phaseDone; err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, first.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, first.ID); err != nil {
		t.Fatal(err)
	}

	episode, err := st.GetWorkEpisode(ctx, first.EpisodeID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeRetrying || episode.LatestAttemptID != second.AttemptID {
		t.Fatalf("atomic admission projection = %+v", episode)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil || leased.ID != second.ID {
		t.Fatalf("leased newer attempt = %+v, %v", leased, err)
	}
}

func TestQueueEpisodeAttemptRejectsSourceIdentityFromAnotherEpisode(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	_, first := queueKernelEpisode(t, st, "resume-target")
	otherRun, other := queueKernelEpisode(t, st, "already-owned-source")
	beforeFirst, err := st.GetWorkEpisode(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	beforeOther, err := st.GetWorkEpisode(ctx, other.ID)
	if err != nil {
		t.Fatal(err)
	}

	if _, created, err := st.QueueEpisodeAttempt(ctx, first.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "channel:COPS",
		SourceKind: otherRun.SourceKind, SourceID: otherRun.SourceID,
		Prompt: "Wrong episode",
	}); !errors.Is(err, ErrConflict) || created {
		t.Fatalf("cross-episode resume = created %t, err %v", created, err)
	}
	afterFirst, err := st.GetWorkEpisode(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	afterOther, err := st.GetWorkEpisode(ctx, other.ID)
	if err != nil {
		t.Fatal(err)
	}
	if afterFirst.State != beforeFirst.State ||
		afterFirst.LatestAttemptID != beforeFirst.LatestAttemptID ||
		afterFirst.EventSequence != beforeFirst.EventSequence ||
		afterOther.State != beforeOther.State ||
		afterOther.LatestAttemptID != beforeOther.LatestAttemptID ||
		afterOther.EventSequence != beforeOther.EventSequence {
		t.Fatalf("cross-episode conflict mutated episodes: first %+v -> %+v; other %+v -> %+v",
			beforeFirst, afterFirst, beforeOther, afterOther)
	}
}

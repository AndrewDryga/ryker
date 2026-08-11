package store

import (
	"context"
	"errors"
	"testing"

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

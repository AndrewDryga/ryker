package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// finishKernelEpisode makes an episode and its run terminal and ages both past
// whatever horizon the caller is about to apply.
//
// Written against the tables rather than through the lifecycle API on purpose:
// these tests are about which rows Prune will and will not delete, and driving
// a real completion would make each case depend on the reducer's rules for
// reaching that state as well as on the predicate under test.
func finishKernelEpisode(
	t *testing.T,
	st *Store,
	source string,
	episodeState core.WorkEpisodeState,
	age time.Duration,
) (core.AgentRun, core.WorkEpisode) {
	t.Helper()
	run, episode := queueKernelEpisode(t, st, source)
	aged := time.Now().UTC().Add(-age).Format(timestampFormat)
	if _, err := st.db.Exec(
		`UPDATE work_episodes SET lifecycle_state = ?, updated_at = ? WHERE id = ?`,
		string(episodeState), aged, episode.ID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(
		`UPDATE agent_runs SET state = 'completed', updated_at = ? WHERE id = ?`,
		aged, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(
		`UPDATE episode_attempts SET state = 'succeeded', updated_at = ? WHERE agent_run_id = ?`,
		aged, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	return run, episode
}

// pruneAll runs every sweep with the same horizon, so a test only has to age a
// row past one number to make it eligible everywhere.
func pruneAll(t *testing.T, st *Store, before time.Time) core.PruneResult {
	t.Helper()
	result, err := st.Prune(context.Background(), before, before, before, before, before)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func episodeExists(t *testing.T, st *Store, id string) bool {
	t.Helper()
	var found int
	if err := st.db.QueryRow(
		`SELECT EXISTS (SELECT 1 FROM work_episodes WHERE id = ?)`, id,
	).Scan(&found); err != nil {
		t.Fatal(err)
	}
	return found == 1
}

// Episode history expires on its own horizon and not on the operational one.
//
// This is the whole reason the class exists. The operational sweep runs at
// twenty-four hours and expires message bodies and queue rows; episode history
// is the account of what the agent did and the source the replay corpus is
// built from, and a day is not long enough to decide whether to keep it — the
// 24h sweep has already destroyed a completed schedule run before anyone could
// record it as a fixture.
func TestEpisodeHistoryExpiresOnItsOwnHorizonAndNotTheOperationalOne(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
	now := time.Now().UTC()

	// Two days old: past the operational horizon, nowhere near the episode one.
	result, err := st.Prune(
		ctx,
		now.Add(-24*time.Hour),
		now.Add(-90*24*time.Hour),
		now.Add(-7*24*time.Hour),
		now.Add(-30*24*time.Hour),
		now.Add(-30*24*time.Hour),
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Episodes != 0 {
		t.Fatalf("the operational sweep expired %d episodes", result.Episodes)
	}
	if !episodeExists(t, st, episode.ID) {
		t.Fatal("a two-day-old episode was deleted by the twenty-four hour horizon")
	}

	// The episode horizon reaches it, and takes the whole tree.
	result = pruneAll(t, st, now.Add(-time.Hour))
	if result.Episodes != 1 {
		t.Fatalf("episodes expired = %d, want 1", result.Episodes)
	}
	if episodeExists(t, st, episode.ID) {
		t.Fatal("the expired episode survived")
	}
	for _, table := range []string{
		"work_episode_events", "work_episode_progress", "episode_attempts",
		"context_manifests", "claim_assessments", "commitments", "episode_goals",
		"episode_wakeups",
	} {
		var remaining int
		if err := st.db.QueryRow(
			`SELECT COUNT(*) FROM `+table+` WHERE episode_id = ?`, episode.ID,
		).Scan(&remaining); err != nil {
			t.Fatal(err)
		}
		if remaining != 0 {
			t.Fatalf("%s kept %d rows for a deleted episode", table, remaining)
		}
	}
	// The run is collected in the same pass, by the guard that was reported as a
	// dead no-op. It only ever looked dead because nothing expired episodes.
	if result.AgentRuns != 1 {
		t.Fatalf("agent runs expired = %d, want 1", result.AgentRuns)
	}
	if _, err := st.GetAgentRun(ctx, run.ID); err == nil {
		t.Fatal("the run outlived the episode it belonged to")
	}
}

// Retention refuses every episode something is still waiting on. Each case is a
// thing that would be reading a deleted row if the refusal were missing.
func TestEpisodeRetentionRefusesWhatIsStillDependedOn(t *testing.T) {
	ctx := context.Background()
	for _, testCase := range []struct {
		name    string
		state   core.WorkEpisodeState
		expire  bool
		arrange func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode)
	}{
		{
			// The control. Without it the cases below would still pass if the
			// sweep never deleted anything at all.
			name:    "nothing is waiting on it",
			state:   core.EpisodeCompleted,
			expire:  true,
			arrange: func(*testing.T, *Store, core.AgentRun, core.WorkEpisode) {},
		},
		{
			name:  "a correction is queued for review against it",
			state: core.EpisodeCompleted,
			arrange: func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode) {
				if err := st.RecordFixtureCandidate(ctx, core.FixtureCandidate{
					EpisodeID: episode.ID, RunID: run.ID, Capability: "triage",
					CorrectionClass: "tone", Correction: "too long",
				}); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name:  "an operator approved a correction and it is not promoted yet",
			state: core.EpisodeCompleted,
			arrange: func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode) {
				if err := st.RecordFixtureCandidate(ctx, core.FixtureCandidate{
					EpisodeID: episode.ID, RunID: run.ID, Capability: "triage",
					CorrectionClass: "tone", Correction: "too long",
				}); err != nil {
					t.Fatal(err)
				}
				candidates, err := st.ListPendingFixtureCandidates(ctx, time.Now().UTC(), 10)
				if err != nil || len(candidates) != 1 {
					t.Fatalf("pending candidates = %+v, %v", candidates, err)
				}
				if err := st.ReviewFixtureCandidate(
					ctx, candidates[0].ID, "approved", "UOPERATOR",
				); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name:  "somebody complained about it and nobody answered",
			state: core.EpisodeCompleted,
			arrange: func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode) {
				if _, err := st.RecordFeedback(ctx, FeedbackItem{
					ID: "fb_open", WorkspaceID: "T1", ChannelID: "COPS", UserID: "U1",
					Source: "reaction", Category: "accuracy", Sentiment: "negative",
					Summary: "this was wrong", EpisodeID: episode.ID, AgentRunID: run.ID,
				}); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name:  "it is scheduled to wake up and carry on",
			state: core.EpisodeCompleted,
			arrange: func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode) {
				if _, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
					EpisodeID: episode.ID, Kind: "deployment",
					DueAt: time.Now().UTC().Add(time.Hour),
				}); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name:    "the work is not finished",
			state:   core.EpisodeWorking,
			arrange: func(*testing.T, *Store, core.AgentRun, core.WorkEpisode) {},
		},
		{
			name:  "a child episode still calls it its parent",
			state: core.EpisodeCompleted,
			arrange: func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode) {
				child, _ := queueKernelEpisode(t, st, "message-child")
				if _, err := st.db.Exec(
					`UPDATE work_episodes SET parent_episode_id = ?, lifecycle_state = 'working'
					 WHERE agent_run_id = ?`, episode.ID, child.ID,
				); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name:  "the incident it belongs to is still open",
			state: core.EpisodeCompleted,
			arrange: func(t *testing.T, st *Store, run core.AgentRun, episode core.WorkEpisode) {
				if _, err := st.db.Exec(`
					INSERT INTO incidents (
					  id, route, repository, correlation_key, title, status, workflow,
					  created_at, updated_at
					) VALUES ('inc_open', 'manual', 'repo', 'k', 'Live', 'active', 'idle',
					  '2026-01-01T00:00:00.000000000Z', '2026-01-01T00:00:00.000000000Z')`,
				); err != nil {
					t.Fatal(err)
				}
				if _, err := st.db.Exec(
					`UPDATE agent_runs SET incident_id = 'inc_open' WHERE id = ?`, run.ID,
				); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			st, err := Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			run, episode := finishKernelEpisode(t, st, "message-1", testCase.state, 90*24*time.Hour)
			testCase.arrange(t, st, run, episode)

			// A horizon that would otherwise expire everything on disk.
			result := pruneAll(t, st, time.Now().UTC().Add(time.Hour))
			if testCase.expire {
				if result.Episodes != 1 || episodeExists(t, st, episode.ID) {
					t.Fatalf("an unencumbered finished episode was kept: %d expired", result.Episodes)
				}
				return
			}
			if result.Episodes != 0 {
				t.Fatalf("retention deleted %d episodes it should have refused", result.Episodes)
			}
			if !episodeExists(t, st, episode.ID) {
				t.Fatal("retention deleted the episode")
			}
		})
	}
}

// A refusal has to clear once the thing depending on the episode is settled, or
// it is not a guard, it is a leak. The corrections queue is the case that
// matters: candidates lapse after a fortnight on their own.
func TestEpisodeRetentionResumesOnceTheCorrectionIsSettled(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 90*24*time.Hour)
	if err := st.RecordFixtureCandidate(ctx, core.FixtureCandidate{
		EpisodeID: episode.ID, RunID: run.ID, Capability: "triage",
		CorrectionClass: "tone", Correction: "too long",
	}); err != nil {
		t.Fatal(err)
	}
	if result := pruneAll(t, st, time.Now().UTC().Add(time.Hour)); result.Episodes != 0 {
		t.Fatalf("a pending correction did not hold its episode: %d expired", result.Episodes)
	}
	if _, err := st.ExpireFixtureCandidates(ctx, time.Now().UTC().Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if result := pruneAll(t, st, time.Now().UTC().Add(time.Hour)); result.Episodes != 1 {
		t.Fatalf("episodes expired after the correction lapsed = %d, want 1", result.Episodes)
	}
}

// Closing an incident deletes its agent runs, and work_episodes references
// agent_runs ON DELETE CASCADE, so the closed-work sweep reaches episode history
// on a seven-day horizon — shorter than the fourteen days a correction is given
// to be reviewed. Without the guard, a queued lesson is reviewed against
// nothing.
func TestClosedWorkPruneKeepsEpisodesACorrectionStillNeeds(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 90*24*time.Hour)
	if _, err := st.db.Exec(`
		INSERT INTO incidents (
		  id, route, repository, correlation_key, title, status, workflow,
		  closed_at, created_at, updated_at
		) VALUES ('inc_closed', 'manual', 'repo', 'k', 'Done', 'closed', 'closed',
		  '2026-01-01T00:00:00.000000000Z', '2026-01-01T00:00:00.000000000Z',
		  '2026-01-01T00:00:00.000000000Z')`,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(
		`UPDATE agent_runs SET incident_id = 'inc_closed' WHERE id = ?`, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordFixtureCandidate(ctx, core.FixtureCandidate{
		EpisodeID: episode.ID, RunID: run.ID, Capability: "triage",
		CorrectionClass: "tone", Correction: "too long",
	}); err != nil {
		t.Fatal(err)
	}

	result := pruneAll(t, st, time.Now().UTC().Add(time.Hour))
	if result.ClosedIncidents != 0 {
		t.Fatalf("closed-work prune removed %d incidents holding a queued correction", result.ClosedIncidents)
	}
	if !episodeExists(t, st, episode.ID) {
		t.Fatal("closed-work prune cascaded through the incident and deleted the episode")
	}

	// Settle the correction and the incident becomes collectable as before.
	if _, err := st.ExpireFixtureCandidates(ctx, time.Now().UTC().Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if result := pruneAll(t, st, time.Now().UTC().Add(time.Hour)); result.ClosedIncidents != 1 {
		t.Fatalf("closed incidents expired after the correction lapsed = %d, want 1", result.ClosedIncidents)
	}
}

// The assembled prompt input is emptied out of runs that are over, and left
// alone on every run something can still read it back from.
func TestPruneEmptiesOnlySpentAgentRunContext(t *testing.T) {
	ctx := context.Background()
	setContext := func(t *testing.T, st *Store, runID string) {
		t.Helper()
		if _, err := st.db.Exec(
			`UPDATE agent_runs SET context_json = ? WHERE id = ?`,
			`{"repository":"tenant","situations":["one"]}`, runID,
		); err != nil {
			t.Fatal(err)
		}
	}
	contextLength := func(t *testing.T, st *Store, runID string) int {
		t.Helper()
		var length int
		if err := st.db.QueryRow(
			`SELECT length(context_json) FROM agent_runs WHERE id = ?`, runID,
		).Scan(&length); err != nil {
			t.Fatal(err)
		}
		return length
	}

	t.Run("a finished run keeps its row and loses its context", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		run, _ := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
		setContext(t, st, run.ID)
		if _, err := st.db.Exec(
			`UPDATE agent_runs SET result_json = ? WHERE id = ?`, `{"action":"reply"}`, run.ID,
		); err != nil {
			t.Fatal(err)
		}
		now := time.Now().UTC()
		result, err := st.Prune(
			ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
			now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
		)
		if err != nil {
			t.Fatal(err)
		}
		if result.AgentRunContexts != 1 {
			t.Fatalf("emptied contexts = %d, want 1", result.AgentRunContexts)
		}
		stored, err := st.GetAgentRun(ctx, run.ID)
		if err != nil {
			t.Fatalf("the run row was deleted rather than emptied: %v", err)
		}
		if len(stored.Context) != 0 {
			t.Fatalf("context = %q, want empty", stored.Context)
		}
		if string(stored.Result) != `{"action":"reply"}` {
			t.Fatalf("result = %q, want the record of what happened kept", stored.Result)
		}
		// Idempotent: a second pass finds nothing left to empty.
		second, err := st.Prune(
			ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
			now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
		)
		if err != nil || second.AgentRunContexts != 0 {
			t.Fatalf("second pass emptied %d contexts, %v", second.AgentRunContexts, err)
		}
	})

	t.Run("a live episode can still resume from it", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		run, _ := finishKernelEpisode(t, st, "message-1", core.EpisodeWaitingExternal, 48*time.Hour)
		setContext(t, st, run.ID)
		now := time.Now().UTC()
		if _, err := st.Prune(
			ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
			now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
		); err != nil {
			t.Fatal(err)
		}
		if contextLength(t, st, run.ID) == 0 {
			t.Fatal("emptied the context a waiting episode resumes from")
		}
	})

	t.Run("an operator can still retry it", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		run := failKernelEpisode(t, st, "message-1")
		setContext(t, st, run.ID)
		aged := time.Now().UTC().Add(-48 * time.Hour).Format(timestampFormat)
		if _, err := st.db.Exec(
			`UPDATE agent_runs SET updated_at = ? WHERE id = ?`, aged, run.ID,
		); err != nil {
			t.Fatal(err)
		}
		if _, err := st.db.Exec(
			`UPDATE work_episodes SET updated_at = ? WHERE agent_run_id = ?`, aged, run.ID,
		); err != nil {
			t.Fatal(err)
		}
		now := time.Now().UTC()
		if _, err := st.Prune(
			ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
			now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
		); err != nil {
			t.Fatal(err)
		}
		if contextLength(t, st, run.ID) == 0 {
			t.Fatal("emptied the context the control plane's retry says it preserves")
		}
		// And the retry the guard exists for still works.
		if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried"); err != nil {
			t.Fatalf("retry after pruning: %v", err)
		}
	})
}

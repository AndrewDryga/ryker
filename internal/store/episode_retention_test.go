package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
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
// The fuel line, and the reason it was empty.
//
// The prompt text was being written for every attempt and then emptied
// twenty-four hours later alongside the agent run context it shared a clock
// with. On the blitz database that left 428 of 1221 manifests holding a prompt,
// every one of them from the previous two days — so record-episode and
// promote-fixtures were not limited to some particular code path, they were
// limited to yesterday, and a correction reviewed on Monday for a Friday turn
// had nothing left to harvest. A fixture_candidate pins its episode precisely
// because it wants the evidence, while the evidence was already gone.
//
// So the two copies keep two clocks. The submitted column is transport and is
// spent with the turn; the sanitized copy is the account of the turn and lives
// as long as the episode does.
func TestTheRetainedPromptOutlivesTheTurnThatSubmittedIt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
	const archived = "SYSTEM: kept for as long as the episode, with [REDACTED] where a secret was"
	manifest, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: episode.ID, AttemptID: run.AttemptID,
		PromptVersion: "p1", ContractVersion: "c1", ToolSchemaVersion: "t1",
		SubmittedPrompt: "SYSTEM: retained only while the operational trace is live",
		RetainedPrompt:  archived,
		References: []core.ContextReference{{
			Kind: "compiled_prompt", SourceRef: "agent-run:" + run.ID + ":prompt",
			ContentDigest: "prompt-digest-1", Visibility: "private",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	aged := time.Now().UTC().Add(-48 * time.Hour).Format(timestampFormat)
	if _, err := st.db.Exec(
		`UPDATE context_manifests SET created_at = ? WHERE id = ?`, aged, manifest.ID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(
		`UPDATE context_manifest_texts SET created_at = ? WHERE manifest_id = ?`, aged, manifest.ID,
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
	stored, err := st.GetContextManifest(ctx, manifest.ID)
	if err != nil {
		t.Fatalf("the manifest was deleted rather than emptied: %v", err)
	}
	// The assertion this test exists for. The contrast beside it is what makes
	// it mean anything: a pass that came from nothing being swept at all would
	// satisfy the first check and fail the second.
	if stored.RetainedPrompt != archived {
		t.Fatalf("the archive copy was swept with the transport copy: %q", stored.RetainedPrompt)
	}
	if stored.SubmittedPrompt != "" {
		t.Fatalf("the transport copy outlived the operational horizon: %q", stored.SubmittedPrompt)
	}
	// And it goes when the episode does, which is the horizon it was moved to
	// rather than a promise that it is kept forever.
	if _, err := st.db.Exec(`DELETE FROM work_episodes WHERE id = ?`, episode.ID); err != nil {
		t.Fatal(err)
	}
	var orphans int
	if err := st.db.QueryRow(
		`SELECT COUNT(*) FROM context_manifest_texts WHERE manifest_id = ?`, manifest.ID,
	).Scan(&orphans); err != nil {
		t.Fatal(err)
	}
	if orphans != 0 {
		t.Fatalf("%d retained prompts survived their episode, so the table has no horizon", orphans)
	}
}

func TestPruneEmptiesOnlySpentAgentRunContext(t *testing.T) {
	ctx := context.Background()
	setContext := func(t *testing.T, st *Store, runID string) {
		t.Helper()
		if _, err := st.db.Exec(
			`UPDATE agent_runs SET context_json = ? WHERE id = ?`,
			`{"repository":"blitz","situations":["one"]}`, runID,
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
		run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
		setContext(t, st, run.ID)
		manifest, err := st.CreateContextManifest(ctx, core.ContextManifest{
			EpisodeID: episode.ID, AttemptID: run.AttemptID,
			PromptVersion: "p1", ContractVersion: "c1", ToolSchemaVersion: "t1",
			SubmittedPrompt: "SYSTEM: retained only while the operational trace is live",
			References: []core.ContextReference{{
				Kind: "artifact", SourceRef: "artifact:github-pr-1.md:0",
				ContentDigest: "artifact-digest-1", Visibility: "eligible",
			}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := st.Artifacts.Save(ctx, []core.ContextArtifact{{
			Digest: "artifact-digest-1", Name: "github-pr-1.md",
			MediaType: "text/markdown", Body: []byte("# PR body"),
		}}); err != nil {
			t.Fatal(err)
		}
		aged := time.Now().UTC().Add(-48 * time.Hour).Format(timestampFormat)
		if _, err := st.db.Exec(
			`UPDATE context_manifests SET created_at = ? WHERE id = ?`, aged, manifest.ID,
		); err != nil {
			t.Fatal(err)
		}
		if _, err := st.db.Exec(
			`UPDATE context_artifacts SET created_at = ?`, aged,
		); err != nil {
			t.Fatal(err)
		}
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
		storedManifest, err := st.GetContextManifest(ctx, manifest.ID)
		if err != nil {
			t.Fatalf("the manifest was deleted rather than redacted: %v", err)
		}
		if storedManifest.SubmittedPrompt != "" {
			t.Fatalf("submitted prompt = %q, want redacted with spent context", storedManifest.SubmittedPrompt)
		}
		// The artifact body follows the prompt text out; its digest stays on
		// the manifest reference for audit.
		if result.ContextArtifacts != 1 {
			t.Fatalf("pruned artifact bodies = %d, want 1", result.ContextArtifacts)
		}
		if _, found, err := st.Artifacts.Get(ctx, "artifact-digest-1"); err != nil || found {
			t.Fatalf("artifact body survived its prompt: found=%t err=%v", found, err)
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

	// Emptying blobs frees pages, and under incremental auto-vacuum a freed page
	// is only handed back to the operating system by a vacuum this pass has to
	// ask for. Deleting no rows while reclaiming the largest payload in the
	// database is the ordinary case here, not an edge one.
	t.Run("emptying context alone still returns pages", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		run, _ := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
		if _, err := st.db.Exec(
			`UPDATE agent_runs SET context_json = ? WHERE id = ?`,
			make([]byte, 256*1024), run.ID,
		); err != nil {
			t.Fatal(err)
		}
		freelist := func() int {
			var pages int
			if err := st.db.QueryRow(`PRAGMA freelist_count`).Scan(&pages); err != nil {
				t.Fatal(err)
			}
			return pages
		}
		before := freelist()
		now := time.Now().UTC()
		result, err := st.Prune(
			ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
			now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
		)
		if err != nil {
			t.Fatal(err)
		}
		if result.Total() != 0 || result.AgentRunContexts != 1 {
			t.Fatalf("expected a pass that only emptied context: %+v", result)
		}
		if after := freelist(); after > before {
			t.Fatalf("free list grew from %d to %d pages; the vacuum never ran", before, after)
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

	// Praise is collected so a corpus of the target behaviour can be built, and
	// an answer with no question in front of it is not an example of anything.
	// Both links are exercised: a model-recorded sentiment names the run, a
	// Slack reaction only knows the episode the delivery came from.
	for _, praise := range []struct {
		name  string
		byRun bool
	}{{"a reaction names only the episode", false}, {"a recorded sentiment names the run", true}} {
		t.Run("praise keeps the context that made the answer good: "+praise.name, func(t *testing.T) {
			st, err := Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
			setContext(t, st, run.ID)
			item := FeedbackItem{
				ID: "fb_praise", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
				Source: "positive_reaction", Category: "other", Sentiment: "positive",
				Summary: "User reacted positively to a Ryker message",
				Status:  "noted", EpisodeID: episode.ID,
			}
			if praise.byRun {
				item.EpisodeID, item.AgentRunID = "", run.ID
			}
			if _, err := st.RecordFeedback(ctx, item); err != nil {
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
			if result.AgentRunContexts != 0 || contextLength(t, st, run.ID) == 0 {
				t.Fatal("emptied the input half of an answer somebody said was right")
			}
			// The pin is deliberately narrow: praise buys the example the rest of
			// the episode's own lifetime, not immortality. Feedback rows are never
			// pruned, so a 'noted' row that held its episode open would keep it
			// forever for a consumer that does not exist yet.
			if pruned := pruneAll(t, st, now.Add(-time.Hour)); pruned.Episodes != 1 {
				t.Fatalf("praised episodes expired on their own horizon = %d, want 1", pruned.Episodes)
			}
		})
	}

	// A complaint is not praise, and a feedback row that resolved to neither run
	// nor episode must not match every run that also has neither.
	t.Run("an unrelated feedback row protects nothing", func(t *testing.T) {
		st, err := Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		run, episode := finishKernelEpisode(t, st, "message-1", core.EpisodeCompleted, 48*time.Hour)
		setContext(t, st, run.ID)
		for _, item := range []FeedbackItem{
			{
				ID: "fb_negative", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
				Source: "negative_reaction", Category: "other", Sentiment: "negative",
				Summary: "not right", EpisodeID: episode.ID,
			},
			{
				ID: "fb_unlinked", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
				Source: "positive_reaction", Category: "other", Sentiment: "positive",
				Summary: "liked something", Status: "noted",
			},
		} {
			if _, err := st.RecordFeedback(ctx, item); err != nil {
				t.Fatal(err)
			}
		}
		now := time.Now().UTC()
		result, err := st.Prune(
			ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
			now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
		)
		if err != nil {
			t.Fatal(err)
		}
		if result.AgentRunContexts != 1 || contextLength(t, st, run.ID) != 0 {
			t.Fatalf(
				"a complaint and an unlinked praise kept %d bytes of spent context",
				contextLength(t, st, run.ID),
			)
		}
	})
}

// Standing rule runs are the only evidence a rule ever produces about itself,
// and they were expiring on the twenty-four hour clock that message bodies use.
// That is why blitz's rule reports 41 fires and zero surviving rows, and why no
// operator could tell a working rule from one that fires constantly and answers
// nothing.
func TestStandingRuleRunsExpireOnTheEpisodeHistoryHorizon(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	rule, _, err := st.Behavior.UpsertStandingRule(ctx, core.StandingRule{
		ChannelID: "COPS", Repository: "repo",
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "app", SourceRef: "slack_rule", ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(365 * 24 * time.Hour),
	}, 20, 10)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	for input, age := range map[string]time.Duration{
		"plan_recent": time.Hour,
		"plan_week":   7 * 24 * time.Hour,
		"plan_year":   365 * 24 * time.Hour,
	} {
		if _, err := st.Behavior.RecordStandingRuleRun(
			ctx, rule.ID, input, "Ev_"+input, "reply",
		); err != nil {
			t.Fatal(err)
		}
		if _, err := st.db.Exec(
			`UPDATE standing_rule_runs SET created_at = ? WHERE source_input = ?`,
			now.Add(-age).Format(timestampFormat), input,
		); err != nil {
			t.Fatal(err)
		}
	}
	result, err := st.Prune(
		ctx, now.Add(-24*time.Hour), now.Add(-90*24*time.Hour),
		now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour),
	)
	if err != nil {
		t.Fatal(err)
	}
	// Only the year-old run goes. Under the old horizon the week-old one went
	// too, and so did every fire from the day before yesterday.
	if result.StandingRuleRuns != 1 {
		t.Fatalf("expired rule runs = %d, want only the one past the episode horizon", result.StandingRuleRuns)
	}
	var remaining int
	if err := st.db.QueryRow(
		`SELECT count(*) FROM standing_rule_runs WHERE rule_id = ?`, rule.ID,
	).Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if remaining != 2 {
		t.Fatalf("surviving rule runs = %d, want the hour-old and the week-old", remaining)
	}
	// Whatever the sweep took, the rule still knows what its fires produced.
	stored, err := st.Behavior.GetStandingRule(ctx, rule.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.TriggerCount != 3 || stored.ActedCount != 3 {
		t.Fatalf(
			"after the sweep fired=%d acted=%d, want 3/3",
			stored.TriggerCount, stored.ActedCount,
		)
	}
}

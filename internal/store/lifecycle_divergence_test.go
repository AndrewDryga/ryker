package store

import (
	"context"
	"testing"

	"github.com/AndrewDryga/responder/internal/store/lifecyclecheck"
)

// The comparison must actually detect a disagreement.
//
// This is the point of the test. A divergence report that returns zero because
// it cannot see anything is indistinguishable from a clean system, and reading
// an empty result as good news is how a broken instrument gets mistaken for
// evidence. Each condition is constructed here and has to be found.
func TestLifecycleDivergenceDetectsEachDisagreement(t *testing.T) {
	ctx := context.Background()

	for _, tc := range []struct {
		name     string
		episode  string
		run      string
		sameCols bool
		want     func(lifecyclecheck.Report) []string
	}{
		{
			name: "work running under a finished episode",
			// The dangerous one, and the one only a live system shows: at rest
			// every run is terminal, so a query over a stopped database can
			// never produce this row by itself.
			episode: "completed", run: "running",
			want: func(d lifecyclecheck.Report) []string { return d.RunningUnderFinished },
		},
		{
			name:    "episode executing with no live run",
			episode: "working", run: "completed",
			want: func(d lifecyclecheck.Report) []string { return d.ExecutingWithoutRun },
		},
		{
			name:    "episode and its latest run disagree on the outcome",
			episode: "completed", run: "failed",
			want: func(d lifecyclecheck.Report) []string { return d.OutcomeConflict },
		},
		{
			name:    "state and lifecycle_state drifted apart",
			episode: "completed", run: "completed",
			sameCols: true,
			want:     func(d lifecyclecheck.Report) []string { return d.ProjectionMismatch },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := openAt(t, t.TempDir())
			state := tc.episode
			if tc.sameCols {
				state = "failed" // state disagrees with lifecycle_state
			}
			seedEpisodeWithRun(t, st, "ep_1", state, tc.episode,
				map[string][2]string{"run_1": {tc.run, "2026-08-07T12:00:00.000000000Z"}})

			report, err := lifecyclecheck.Divergences(ctx, st.db)
			if err != nil {
				t.Fatal(err)
			}
			if found := tc.want(report); len(found) != 1 || found[0] != "ep_1" {
				t.Fatalf(
					"the comparison did not find the disagreement it was given: %+v",
					report,
				)
			}
			if report.Clean() {
				t.Fatal("Clean() reported agreement over a constructed disagreement")
			}
		})
	}
}

// An agreeing pair must not be reported, or every cutover slice is blocked by
// noise. In particular an episode that failed once and then succeeded is
// correct behaviour, not a conflict — comparing against every run rather than
// the latest reports it as one.
func TestLifecycleDivergenceAcceptsARetriedEpisode(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_1", "completed", "completed", map[string][2]string{
		"run_1": {"failed", "2026-08-07T12:00:00.000000000Z"},
		"run_2": {"completed", "2026-08-07T12:05:00.000000000Z"},
	})
	report, err := lifecyclecheck.Divergences(ctx, st.db)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Clean() {
		t.Fatalf(
			"a failed attempt followed by a successful one was reported as a conflict: %+v",
			report,
		)
	}
	if report.Episodes != 1 {
		t.Fatalf("episodes counted = %d", report.Episodes)
	}
}

// seedEpisodeWithRun inserts a linked episode and run.
//
// The run goes in first with no episode, then the episode, then the link. The
// two tables reference each other, so neither can be inserted already pointing
// at the other.
func seedEpisodeWithRun(
	t *testing.T, st *Store, episodeID, episodeState, lifecycleState string,
	runs map[string][2]string,
) {
	t.Helper()
	ctx := context.Background()
	const stamp = "2026-08-07T12:00:00.000000000Z"
	first := ""
	for id, row := range runs {
		if first == "" || row[1] < runs[first][1] {
			first = id
		}
		if _, err := st.db.ExecContext(ctx, `
			INSERT INTO agent_runs (id, mode, channel_id, thread_ts, conversation_key,
			  source_kind, source_id, user_id, repository, prompt, idempotency_key,
			  state, created_at, updated_at, next_attempt_at)
			VALUES (?,'triage','C1','1700.1','k','slack',?,'U1','repo','p',?,?,?,?,?)`,
			id, id, "idem_"+id, row[0], row[1], row[1], row[1],
		); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO work_episodes (id, agent_run_id, effort, authority, state, objective,
		  phase, status, next_action, created_at, updated_at, lifecycle_state)
		VALUES (?,?,'focused_check','read_only',?,'o','p','s','n',?,?,?)`,
		episodeID, first, episodeState, stamp, stamp, lifecycleState,
	); err != nil {
		t.Fatal(err)
	}
	for id := range runs {
		if _, err := st.db.ExecContext(ctx,
			`UPDATE agent_runs SET episode_id = ? WHERE id = ?`, episodeID, id,
		); err != nil {
			t.Fatal(err)
		}
	}
}

// state is a lossy projection of lifecycle_state, not a copy of it:
// waiting_operator, waiting_external and retrying all collapse to blocked,
// accepted collapses to acknowledged, refused collapses to failed.
//
// Comparing the two columns for equality reports every one of those as drift.
// They look equal in the deployed data only because no episode comes to rest in
// a collapsing state, so the mistake survives a clean production run — which is
// how it shipped in 4551562 and why this test exists.
func TestLifecycleDivergenceAcceptsACorrectlyProjectedState(t *testing.T) {
	ctx := context.Background()
	for lifecycle, legacy := range map[string]string{
		"waiting_operator": "blocked",
		"waiting_external": "blocked",
		"retrying":         "blocked",
		"accepted":         "acknowledged",
		"refused":          "failed",
	} {
		t.Run(lifecycle, func(t *testing.T) {
			st := openAt(t, t.TempDir())
			// A live run, so the executing-without-a-run probe stays quiet and
			// this test only measures the projection.
			seedEpisodeWithRun(t, st, "ep_1", legacy, lifecycle,
				map[string][2]string{"run_1": {"running", "2026-08-07T12:00:00.000000000Z"}})

			report, err := lifecyclecheck.Divergences(ctx, st.db)
			if err != nil {
				t.Fatal(err)
			}
			if len(report.ProjectionMismatch) != 0 {
				t.Fatalf(
					"%s correctly projects to %s, but was reported as drift",
					lifecycle, legacy,
				)
			}
		})
	}
}

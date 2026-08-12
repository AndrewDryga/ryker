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
		name    string
		episode string
		run     string
		want    func(lifecyclecheck.Report) []string
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
			name:    "accepted episode has no live run",
			episode: "accepted", run: "completed",
			want: func(d lifecyclecheck.Report) []string { return d.ExecutingWithoutRun },
		},
		{
			name:    "acknowledged episode has no live run",
			episode: "acknowledged", run: "completed",
			want: func(d lifecyclecheck.Report) []string { return d.ExecutingWithoutRun },
		},
		{
			name:    "episode and its latest run disagree on the outcome",
			episode: "completed", run: "failed",
			want: func(d lifecyclecheck.Report) []string { return d.OutcomeConflict },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := openAt(t, t.TempDir())
			seedEpisodeWithRun(t, st, "ep_1", tc.episode,
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
	seedEpisodeWithRun(t, st, "ep_1", "completed", map[string][2]string{
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
	t *testing.T, st *Store, episodeID, lifecycleState string,
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
		INSERT INTO work_episodes (id, agent_run_id, effort, authority, objective,
		  phase, status, next_action, created_at, updated_at, lifecycle_state)
		VALUES (?,?,'focused_check','read_only','o','p','s','n',?,?,?)`,
		episodeID, first, stamp, stamp, lifecycleState,
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

// A refused episode must not be counted as overdue.
//
// The overdue metric used to read the legacy state column, whose vocabulary
// collapsed refused into failed — so a refused episode was excluded by the
// 'failed' entry. When the column was dropped in migration 47, renaming it to
// lifecycle_state without adding 'refused' would have silently started counting
// every refused episode as overdue work needing attention.
func TestRefusedEpisodesAreNotOverdue(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_1", "refused",
		map[string][2]string{"run_1": {"completed", "2026-08-07T12:00:00.000000000Z"}})
	// Due an hour before the epoch of any clock this test could run under.
	if _, err := st.db.ExecContext(ctx,
		`UPDATE work_episodes SET progress_due_at = '2000-01-01T00:00:00.000000000Z'`,
	); err != nil {
		t.Fatal(err)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if metrics.EpisodesOverdue != 0 {
		t.Fatalf(
			"a refused episode was counted as overdue (%d); refused is terminal",
			metrics.EpisodesOverdue,
		)
	}
}

package retention_test

import (
	"context"
	"database/sql"
	"sort"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/retention"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

// liveTables reads the table names out of a freshly migrated database, so these
// tests compare Policies against the schema the product actually creates rather
// than against a list somebody kept up to date by hand.
func liveTables(t *testing.T, db *sql.DB) []string {
	t.Helper()
	rows, err := db.Query(`
		SELECT name FROM sqlite_master
		WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
		ORDER BY name`)
	if err != nil {
		t.Fatalf("list the tables in a migrated database: %v", err)
	}
	defer rows.Close()
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("read a table name: %v", err)
		}
		tables = append(tables, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("read the table list: %v", err)
	}
	if len(tables) == 0 {
		t.Fatal("a migrated database reported no tables at all")
	}
	return tables
}

// Every table has to have an answer. This is the whole mechanism: the five
// tables that leaked did so because nothing asked the question when they were
// created, and prose in a design document does not fail a build.
func TestEveryTableHasARetentionPolicy(t *testing.T) {
	db := storetest.DB(t)
	for _, table := range liveTables(t, db) {
		policy, found := retention.Lookup(table)
		if !found {
			t.Errorf(
				"table %q has no retention policy.\n"+
					"Add it to retention.Policies with a class and a reason saying what the "+
					"table holds and why that class fits. Cascade (its rows go when a parent "+
					"row goes) and Kept (deliberately permanent — operator configuration, a "+
					"decision a person made, or a singleton) are legitimate answers; having "+
					"no answer is not, because that is how five tables started growing "+
					"forever without anyone noticing.",
				table,
			)
			continue
		}
		if policy.Why == "" {
			t.Errorf("table %q has a class but no reason; Why is what makes the policy reviewable", table)
		}
	}
}

// The list cannot rot in the other direction either. A policy naming a table
// that was dropped is stale documentation that reads as current.
func TestNoPolicyNamesADroppedTable(t *testing.T) {
	db := storetest.DB(t)
	live := map[string]bool{}
	for _, table := range liveTables(t, db) {
		live[table] = true
	}
	seen := map[string]bool{}
	for _, policy := range retention.Policies {
		if !live[policy.Table] {
			t.Errorf(
				"retention.Policies names %q, which no longer exists in the schema; "+
					"remove the entry", policy.Table,
			)
		}
		if seen[policy.Table] {
			t.Errorf("retention.Policies names %q twice", policy.Table)
		}
		seen[policy.Table] = true
	}
}

const (
	// Old enough to be swept, and a cutoff after it. The timestamp format the
	// store writes sorts lexicographically, which is what these comparisons rely
	// on.
	oldTimestamp = "2020-01-01T00:00:00.000000000Z"
	sweepCutoff  = "2021-01-01T00:00:00.000000000Z"
)

// The same instant as sweepCutoff. Sweep takes the operational horizon as
// text because Prune already has it in that form, and the other two as
// instants so it renders them itself.
var sweepCutoffTime = time.Date(2021, 1, 1, 0, 0, 0, 0, time.UTC)

// Age is not what decides these two tables; state is. A pending correction and
// an open complaint are both older than the cutoff and neither is spent, so a
// sweep that only looked at timestamps would delete an unreviewed lesson and a
// person's unanswered question.
func TestSweepSparesUnreviewedAndOpenRows(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	for _, candidate := range []struct{ id, class, status string }{
		{"fixture_pending", "tone", "pending"},
		{"fixture_rejected", "accuracy", "rejected"},
	} {
		if _, err := db.ExecContext(ctx, `
			INSERT INTO fixture_candidates (
			  id, episode_id, run_id, capability, correction_class, correction,
			  status, reviewed_by, created_at, expires_at, updated_at
			) VALUES (?, 'episode_1', 'run_1', '', ?, 'say it plainly', ?, '', ?, ?, ?)`,
			candidate.id, candidate.class, candidate.status,
			oldTimestamp, oldTimestamp, oldTimestamp,
		); err != nil {
			t.Fatalf("insert fixture candidate %q: %v", candidate.id, err)
		}
	}
	for _, item := range []struct{ id, status string }{
		{"feedback_open", "open"},
		{"feedback_dismissed", "dismissed"},
	} {
		if _, err := db.ExecContext(ctx, `
			INSERT INTO feedback_items (
			  id, workspace_id, channel_id, user_id, source, category, sentiment,
			  summary, context_json, status, created_at, updated_at
			) VALUES (?, 'T1', 'C1', 'U1', 'model_sentiment', 'accuracy', 'negative',
			  'the answer was wrong', '[]', ?, ?, ?)`,
			item.id, item.status, oldTimestamp, oldTimestamp,
		); err != nil {
			t.Fatalf("insert feedback item %q: %v", item.id, err)
		}
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin the sweep transaction: %v", err)
	}
	defer tx.Rollback()
	swept, err := retention.Sweep(ctx, tx, sweepCutoff, sweepCutoffTime, sweepCutoffTime)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if swept != 2 {
		t.Errorf("swept %d rows, want the rejected candidate and the dismissed item only", swept)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit the sweep: %v", err)
	}

	assertSurvivors(t, db, `SELECT id FROM fixture_candidates`, []string{"fixture_pending"})
	assertSurvivors(t, db, `SELECT id FROM feedback_items`, []string{"feedback_open"})
}

func assertSurvivors(t *testing.T, db *sql.DB, query string, want []string) {
	t.Helper()
	rows, err := db.Query(query)
	if err != nil {
		t.Fatalf("read survivors with %q: %v", query, err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatalf("scan a survivor: %v", err)
		}
		got = append(got, id)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("read survivors: %v", err)
	}
	sort.Strings(got)
	sort.Strings(want)
	if len(got) != len(want) {
		t.Fatalf("%q left %v, want %v", query, got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("%q left %v, want %v", query, got, want)
		}
	}
}

// A schedule proposal is an offer waiting on a yes. Two things end it: the
// answer, and the deadline — and only the second is invisible in the status,
// which is why the sweep tests both. A live offer inside its window survives a
// sweep that is older than it, because deleting one silently drops a question
// somebody was about to answer.
func TestSweepSettlesLapsedProposalsAndSparesLiveOnes(t *testing.T) {
	ctx := context.Background()
	db := storetest.DB(t)
	future := sweepCutoffTime.Add(24 * time.Hour).Format(core.TimestampFormat)
	for _, proposal := range []struct{ id, status, expires, updated string }{
		{"live", "pending", future, oldTimestamp},
		{"lapsed", "pending", oldTimestamp, oldTimestamp},
		{"answered", "accepted", future, oldTimestamp},
	} {
		if _, err := db.ExecContext(ctx, `
			INSERT INTO schedule_proposals (
			  id, team_id, channel_id, thread_ts, actor_id, source_ref, task_json,
			  replace_task_id, status, accepted_task_id, expires_at, created_at, updated_at
			) VALUES (?, 'T1', 'C1', '', 'U1', ?, '{}', '', ?, '', ?, ?, ?)`,
			proposal.id, "ref_"+proposal.id, proposal.status,
			proposal.expires, oldTimestamp, proposal.updated,
		); err != nil {
			t.Fatalf("insert proposal %q: %v", proposal.id, err)
		}
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin the sweep transaction: %v", err)
	}
	defer tx.Rollback()
	if _, err := retention.Sweep(ctx, tx, sweepCutoff, sweepCutoffTime, sweepCutoffTime); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit the sweep: %v", err)
	}
	assertSurvivors(t, db, `SELECT id FROM schedule_proposals`, []string{"live"})
}

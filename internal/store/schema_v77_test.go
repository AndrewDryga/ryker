package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/remediation"
)

// A database migrated from v76 keeps what it holds and gains an empty ladder.
//
// Empty is the only honest starting value. Every grant is an operator decision
// and no operator has taken one yet, so a deployment that upgrades into this
// migration has exactly today's authority — read-only everything plus the one
// exact action a person asked for — until somebody confirms otherwise. There is
// deliberately no backfill: a grant inferred from history would be authority
// nobody granted, which is the failure this whole table exists to prevent.
//
// The two constraints are asserted rather than assumed, because they are the
// ones that carry the rules. expires_at is NOT NULL so a permanent grant cannot
// be written at all, and the rung CHECK is what stops a typo or a future writer
// inventing a rung the matcher has never heard of and would rank at -1.
func TestSchemaV77AddsAnEmptyRemediationLadder(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 76; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const stamp = "2026-08-15T12:00:00.000000000Z"
	// One supervised Emisar approval from before the ladder existed. It must
	// survive the migration untouched — the record of what was already done is
	// what the first promotion will eventually be counted from.
	if _, err := db.Exec(`INSERT INTO emisar_approvals
		(request_id, channel_id, source_input, requested_by, run_id, operation_id,
		 action_id, pack_ref, runner_ref, status, approval_url, next_check_at,
		 expires_at, created_at, updated_at)
		VALUES ('req-old', 'C0INCIDENT', 'input-old', 'U0OPERATOR', 'emisarrun-old',
		 'op-old', 'nomad.job.restart', 'nomad@1.4.0', 'runner:prod', 'success',
		 'https://emisar/a', ?, ?, ?, ?)`,
		stamp, stamp, stamp, stamp,
	); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ctx := context.Background()

	var status string
	if err := st.db.QueryRow(
		`SELECT status FROM emisar_approvals WHERE request_id = 'req-old'`,
	).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "success" {
		t.Fatalf("the pre-migration approval reads %q, want it untouched at success", status)
	}

	class := remediation.TriggerClass{
		AlertGroupKey: "grafana:api-5xx:production", ChannelID: "C0INCIDENT", Repository: "api",
	}
	action := remediation.ActionRef{
		ActionID: "nomad.job.restart", PackRef: "nomad@1.4.0", RunnerRef: "runner:prod",
	}
	grants, err := st.Grants.Matching(ctx, class)
	if err != nil {
		t.Fatal(err)
	}
	if len(grants) != 0 {
		t.Fatalf("%d grants after the migration, want an empty ladder", len(grants))
	}
	decision := remediation.Decide(
		grants, remediation.Trigger{Class: class, Action: action}, time.Now().UTC(),
	)
	if decision.MayOffer || decision.Rung != remediation.RungObserve {
		t.Fatalf("a fresh ladder authorized %q with MayOffer=%v", decision.Rung, decision.MayOffer)
	}

	// The first write after the migration fills it, and reads back as itself.
	granted, err := st.Grants.Confirm(ctx, remediation.Grant{
		Trigger: class, Action: action, Rung: remediation.RungPropose,
		GrantedBy: "U0OPERATOR", ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
		SuccessCount: 3,
	})
	if err != nil {
		t.Fatal(err)
	}
	if granted.ID == "" || granted.Rung != remediation.RungPropose {
		t.Fatalf("stored grant reads back as %+v", granted)
	}

	// A permanent grant cannot be written, and neither can a rung the matcher
	// does not know. Both go through raw SQL because the point is the column
	// constraint rather than the Go check in front of it.
	if _, err := st.db.Exec(`INSERT INTO remediation_grants
		(id, alert_group_key, channel_id, repository, action_id, pack_ref, runner_ref,
		 rung, granted_by, granted_at, created_at, updated_at)
		VALUES ('grant-forever', 'g', 'c', '', 'a', 'p', 'r', 'propose', 'U0', ?, ?, ?)`,
		stamp, stamp, stamp,
	); err == nil {
		t.Fatal("a grant with no expiry was written; authority is never permanent")
	}
	if _, err := st.db.Exec(`INSERT INTO remediation_grants
		(id, alert_group_key, channel_id, repository, action_id, pack_ref, runner_ref,
		 rung, granted_by, granted_at, expires_at, created_at, updated_at)
		VALUES ('grant-invented', 'g', 'c', '', 'a', 'p', 'r', 'supervisor', 'U0', ?, ?, ?, ?)`,
		stamp, stamp, stamp, stamp,
	); err == nil {
		t.Fatal("a rung outside the ladder was written")
	}
}

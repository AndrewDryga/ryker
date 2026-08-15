package grantstore_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/remediation"
	"github.com/AndrewDryga/responder/internal/store/grantstore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

func at(hour int) time.Time {
	return time.Date(2026, 8, 15, hour, 0, 0, 0, time.UTC)
}

var restartAPI = remediation.ActionRef{
	ActionID:  "nomad.job.restart",
	PackRef:   "nomad@1.4.0+sha256:1111",
	RunnerRef: "runner:prod-us-east",
}

var apiAlert = remediation.TriggerClass{
	AlertGroupKey: "grafana:api-5xx:production",
	ChannelID:     "C0INCIDENT",
	Repository:    "api",
}

func repo(t *testing.T) (*grantstore.Repository, *sql.DB) {
	t.Helper()
	db := storetest.DB(t)
	return grantstore.New(db, func() time.Time { return at(2) }), db
}

func confirmed(rung remediation.Rung) remediation.Grant {
	return remediation.Grant{
		Trigger: apiAlert, Action: restartAPI, Rung: rung,
		GrantedBy: "U0OPERATOR", GrantedAt: at(2), ExpiresAt: at(9), SuccessCount: 3,
	}
}

// TestTheStoreRefusesAGrantWithNoExpiry puts the "nothing is permanent by
// default" rule at the write boundary rather than only in the caller.
//
// Every caller that reaches this table is granting authority, and a rule each of
// them has to remember is a rule one of them will forget. The column is NOT NULL
// so the database would refuse it eventually; refusing here means the error
// names the authority problem instead of a constraint.
func TestTheStoreRefusesAGrantWithNoExpiry(t *testing.T) {
	store, _ := repo(t)
	forever := confirmed(remediation.RungPropose)
	forever.ExpiresAt = time.Time{}
	if _, err := store.Confirm(context.Background(), forever); err == nil {
		t.Fatal("a grant with no expiry was stored")
	}
}

// TestTheStoreRefusesAGrantNamingNoOperator holds the other half: promotion
// requires a human, and the row is where that claim has to be checkable.
func TestTheStoreRefusesAGrantNamingNoOperator(t *testing.T) {
	store, _ := repo(t)
	anonymous := confirmed(remediation.RungPropose)
	anonymous.GrantedBy = ""
	if _, err := store.Confirm(context.Background(), anonymous); err == nil {
		t.Fatal("a grant with no confirming operator was stored")
	}
}

// TestAReconfirmedGrantReplacesItsOwnRow is what makes a retried click safe.
//
// Slack redelivers, an operator double-taps, and the same confirmation arrives
// twice. Two rows for one authority would mean the matcher's "newest wins" tie
// break decides which of two identical grants applies — and worse, a later
// demotion would take a rung from one of them and leave the other live.
func TestAReconfirmedGrantReplacesItsOwnRow(t *testing.T) {
	ctx := context.Background()
	store, db := repo(t)
	first, err := store.Confirm(ctx, confirmed(remediation.RungPropose))
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Confirm(ctx, confirmed(remediation.RungOneClick))
	if err != nil {
		t.Fatal(err)
	}
	var rows int
	if err := db.QueryRow(`SELECT COUNT(*) FROM remediation_grants`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("%d grant rows for one authority, want 1", rows)
	}
	if second.ID != first.ID {
		t.Fatalf("reconfirmation minted a new id %q beside %q", second.ID, first.ID)
	}
	if second.Rung != remediation.RungOneClick {
		t.Fatalf("rung=%q, want the reconfirmed %q", second.Rung, remediation.RungOneClick)
	}
}

// TestAGrantAtADifferentPackIsADifferentRow proves the identity the unique
// index enforces is the whole immutable ref and not just the action id. An
// upgraded pack has earned nothing yet, and it must be able to sit beside the
// grant the old one earned rather than overwrite it.
func TestAGrantAtADifferentPackIsADifferentRow(t *testing.T) {
	ctx := context.Background()
	store, _ := repo(t)
	if _, err := store.Confirm(ctx, confirmed(remediation.RungOneClick)); err != nil {
		t.Fatal(err)
	}
	upgraded := confirmed(remediation.RungPropose)
	upgraded.Action.PackRef = "nomad@1.5.0+sha256:2222"
	if _, err := store.Confirm(ctx, upgraded); err != nil {
		t.Fatal(err)
	}
	grants, err := store.Matching(ctx, apiAlert)
	if err != nil {
		t.Fatal(err)
	}
	if len(grants) != 2 {
		t.Fatalf("%d grants on file, want the old pack and the new one", len(grants))
	}
	decision := remediation.Decide(
		grants, remediation.Trigger{Class: apiAlert, Action: upgraded.Action}, at(3),
	)
	if decision.Rung != remediation.RungPropose {
		t.Fatalf("the upgraded pack acts at %q, want its own %q", decision.Rung, remediation.RungPropose)
	}
}

// TestMatchingReturnsExpiredGrantsForTheMatcherToJudge keeps the expiry
// decision in one place. If the query filtered them out, "no grant covers this"
// and "the grant for this expired" would be the same answer, and the second one
// is the one an operator can act on.
func TestMatchingReturnsExpiredGrantsForTheMatcherToJudge(t *testing.T) {
	ctx := context.Background()
	store, _ := repo(t)
	if _, err := store.Confirm(ctx, confirmed(remediation.RungOneClick)); err != nil {
		t.Fatal(err)
	}
	grants, err := store.Matching(ctx, apiAlert)
	if err != nil {
		t.Fatal(err)
	}
	decision := remediation.Decide(
		grants, remediation.Trigger{Class: apiAlert, Action: restartAPI}, at(20),
	)
	if decision.MayOffer {
		t.Fatal("an expired grant still offered its action")
	}
	if decision.Reason == "" || decision.Grant.ID != "" {
		t.Fatalf("expired decision did not report as unmatched: %+v", decision)
	}
}

// TestDemotingAnActionDropsEveryGrantThatOfferedIt is the conservative reading
// the automatic side needs. The action just failed; nothing about that failure
// is specific to whichever alert happened to fire, so every trigger class that
// granted this exact action loses the rung.
func TestDemotingAnActionDropsEveryGrantThatOfferedIt(t *testing.T) {
	ctx := context.Background()
	store, _ := repo(t)
	if _, err := store.Confirm(ctx, confirmed(remediation.RungOneClick)); err != nil {
		t.Fatal(err)
	}
	latency := confirmed(remediation.RungPropose)
	latency.Trigger.AlertGroupKey = "grafana:api-latency:production"
	if _, err := store.Confirm(ctx, latency); err != nil {
		t.Fatal(err)
	}
	demoted, err := store.Demote(ctx, restartAPI, remediation.VerificationFailed)
	if err != nil {
		t.Fatal(err)
	}
	if len(demoted) != 2 {
		t.Fatalf("demoted %d grants, want both that offered the action", len(demoted))
	}
	stored, err := store.Get(ctx, apiAlert, restartAPI)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Rung != remediation.RungPropose {
		t.Fatalf("rung=%q, want one rung down at %q", stored.Rung, remediation.RungPropose)
	}
	if stored.DemotedReason != string(remediation.VerificationFailed) {
		t.Fatalf("demoted_reason=%q, want %q", stored.DemotedReason, remediation.VerificationFailed)
	}
	if stored.SuccessCount != 0 {
		t.Fatalf("the earned count survived demotion at %d", stored.SuccessCount)
	}
	// A second failure keeps walking down and stops at the floor.
	if _, err := store.Demote(ctx, restartAPI, remediation.VerificationFailed); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Demote(ctx, restartAPI, remediation.VerificationFailed); err != nil {
		t.Fatal(err)
	}
	stored, err = store.Get(ctx, apiAlert, restartAPI)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Rung != remediation.RungObserve {
		t.Fatalf("rung=%q, want the floor %q", stored.Rung, remediation.RungObserve)
	}
}

// TestConfirmingAPromotionClearsTheDemotionNote stops a live grant from
// rendering as one that was taken away.
func TestConfirmingAPromotionClearsTheDemotionNote(t *testing.T) {
	ctx := context.Background()
	store, _ := repo(t)
	if _, err := store.Confirm(ctx, confirmed(remediation.RungOneClick)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Demote(ctx, restartAPI, remediation.ContractChanged); err != nil {
		t.Fatal(err)
	}
	restored, err := store.Confirm(ctx, confirmed(remediation.RungOneClick))
	if err != nil {
		t.Fatal(err)
	}
	if restored.DemotedReason != "" || !restored.DemotedAt.IsZero() {
		t.Fatalf("a reconfirmed grant still reads as demoted: %q at %v",
			restored.DemotedReason, restored.DemotedAt)
	}
}

func TestGetReportsAMissingGrantAsNotFound(t *testing.T) {
	store, _ := repo(t)
	if _, err := store.Get(context.Background(), apiAlert, restartAPI); !errors.Is(err, grantstore.ErrNotFound) {
		t.Fatalf("err=%v, want ErrNotFound", err)
	}
}

// --- the promotion counter ----------------------------------------------

// seedVerifiedRemediation writes the exact shape a real verified remediation
// leaves behind: an Emisar approval Responder supervised to success, the
// continuation run it queued to go and CHECK the effect, and that episode's
// projected outcome.
//
// Raw SQL on purpose. This is a test of one query's WHERE clause, and building
// the rows through the service would prove the service agrees with itself
// rather than that the join finds what it claims to find.
func seedVerifiedRemediation(
	t *testing.T,
	db *sql.DB,
	request string,
	action remediation.ActionRef,
	class remediation.TriggerClass,
	status string,
	verified int,
) {
	t.Helper()
	episode := "episode_" + request
	run := "run_" + request
	stamp := at(1).Format(time.RFC3339)
	if _, err := db.Exec(`
		INSERT INTO agent_runs (
		  id, mode, channel_id, conversation_key, source_kind, source_id, prompt,
		  idempotency_key, state, next_attempt_at, created_at, updated_at, episode_id
		) VALUES (?, 'triage', ?, ?, ?, ?, 'verify', ?, 'completed', ?, ?, ?, ?)`,
		run, class.ChannelID, "conv_"+request, "emisar_approval:"+request,
		"input_"+request, "idem_"+request, stamp, stamp, stamp, episode,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO work_episodes (
		  id, agent_run_id, effort, authority, objective, created_at, updated_at
		) VALUES (?, ?, 'incident_investigation', 'governed_operation', 'verify', ?, ?)`,
		episode, run, stamp, stamp,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO episode_outcomes (
		  episode_id, channel_id, repository, terminal_state, terminal_at,
		  alert_group_key, verified, created_at
		) VALUES (?, ?, ?, 'completed', ?, ?, ?, ?)`,
		episode, class.ChannelID, class.Repository, stamp,
		class.AlertGroupKey, verified, stamp,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO emisar_approvals (
		  request_id, channel_id, source_input, requested_by, run_id, operation_id,
		  action_id, pack_ref, runner_ref, status, approval_url, next_check_at,
		  expires_at, created_at, updated_at
		) VALUES (?, ?, ?, 'U0OPERATOR', ?, ?, ?, ?, ?, ?, 'https://emisar/a', ?, ?, ?, ?)`,
		request, class.ChannelID, "input_"+request, "emisarrun_"+request,
		"op_"+request, action.ActionID, action.PackRef, action.RunnerRef, status,
		stamp, stamp, stamp, stamp,
	); err != nil {
		t.Fatal(err)
	}
}

// TestVerifiedSuccessesCountsOnlyTheExactActionForTheExactAlert is the query a
// promotion is graded on, and every clause in it is load-bearing.
//
// This is the number that decides whether authority is handed out, so the ways
// it can be too generous are the ways this feature becomes dangerous: a pack
// upgrade that inherits the old pack's record, a different runner that inherits
// a fleet-mate's, a different alert in the same channel funding a grant it never
// earned, or a run Emisar never reported as successful counting anyway.
func TestVerifiedSuccessesCountsOnlyTheExactActionForTheExactAlert(t *testing.T) {
	ctx := context.Background()
	store, db := repo(t)

	// Three that count.
	seedVerifiedRemediation(t, db, "req-1", restartAPI, apiAlert, "success", 1)
	seedVerifiedRemediation(t, db, "req-2", restartAPI, apiAlert, "success", 1)
	seedVerifiedRemediation(t, db, "req-3", restartAPI, apiAlert, "success", 1)

	// The same action, verified, but Emisar never reported success.
	seedVerifiedRemediation(t, db, "req-failed", restartAPI, apiAlert, "failed", 1)
	// Emisar reported success, but the episode never verified the effect.
	seedVerifiedRemediation(t, db, "req-unverified", restartAPI, apiAlert, "success", 0)
	// A newer pack of the same action. It has earned nothing yet.
	otherPack := restartAPI
	otherPack.PackRef = "nomad@1.5.0+sha256:2222"
	seedVerifiedRemediation(t, db, "req-pack", otherPack, apiAlert, "success", 1)
	// The same action on another runner.
	otherRunner := restartAPI
	otherRunner.RunnerRef = "runner:prod-eu-west"
	seedVerifiedRemediation(t, db, "req-runner", otherRunner, apiAlert, "success", 1)
	// The same action for a different alert in the same channel.
	otherAlert := apiAlert
	otherAlert.AlertGroupKey = "grafana:api-latency:production"
	seedVerifiedRemediation(t, db, "req-alert", restartAPI, otherAlert, "success", 1)
	// The same alert in another channel.
	otherChannel := apiAlert
	otherChannel.ChannelID = "C0OTHER"
	seedVerifiedRemediation(t, db, "req-channel", restartAPI, otherChannel, "success", 1)

	count, err := store.VerifiedSuccesses(ctx, apiAlert, restartAPI)
	if err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("VerifiedSuccesses = %d, want exactly the 3 that match on every axis", count)
	}
}

// TestDroppingTheRepositoryScopeCountsNothingRatherThanEverything is the
// privilege escalation this query originally shipped with, kept shut.
//
// The clause used to read "no repository means any repository", which sounds
// like a convenience. It is not: remediation.TriggerClass compares repository
// exactly, so a confirmation payload that simply omitted the field described a
// strictly WIDER grant than the card had offered — and this query then funded
// it with every repository's successes at once. A service test caught it by
// tampering with a button value, which is exactly how it would have been found
// in production. A counter must never be more permissive than the matcher it
// feeds.
func TestDroppingTheRepositoryScopeCountsNothingRatherThanEverything(t *testing.T) {
	ctx := context.Background()
	store, db := repo(t)
	seedVerifiedRemediation(t, db, "req-1", restartAPI, apiAlert, "success", 1)
	seedVerifiedRemediation(t, db, "req-2", restartAPI, apiAlert, "success", 1)
	seedVerifiedRemediation(t, db, "req-3", restartAPI, apiAlert, "success", 1)
	widened := apiAlert
	widened.Repository = ""
	count, err := store.VerifiedSuccesses(ctx, widened, restartAPI)
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf(
			"a trigger class with no repository counted %d successes earned under one; "+
				"dropping the scope must not widen the evidence", count,
		)
	}
}

// TestVerifiedSuccessesIsZeroForAnIncompleteIdentity keeps a half-filled offer
// from being graded against a query whose empty clauses match everything.
func TestVerifiedSuccessesIsZeroForAnIncompleteIdentity(t *testing.T) {
	ctx := context.Background()
	store, db := repo(t)
	seedVerifiedRemediation(t, db, "req-1", restartAPI, apiAlert, "success", 1)
	partial := restartAPI
	partial.PackRef = ""
	count, err := store.VerifiedSuccesses(ctx, apiAlert, partial)
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("an action ref with no pack counted %d successes", count)
	}
}

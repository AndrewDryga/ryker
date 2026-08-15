package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/remediation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

var grantAction = remediation.ActionRef{
	ActionID:  "nomad.job.restart",
	PackRef:   "nomad@1.4.0+sha256:1111",
	RunnerRef: "runner:prod-us-east",
}

var grantAlert = remediation.TriggerClass{
	AlertGroupKey: "grafana:api-5xx:production",
	ChannelID:     "COPS",
	Repository:    "repo",
}

// seedVerifiedRemediations writes `count` episodes that each ran this exact
// action through Emisar to success and then verified the effect. This is the
// only evidence the ladder accepts, and writing it as rows rather than through
// the service is the point: the handler must be graded against what is on disk.
func seedVerifiedRemediations(t *testing.T, db *sql.DB, from, to int) {
	t.Helper()
	stamp := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	for index := from; index < to; index++ {
		request := "req-" + string(rune('a'+index))
		episode, run := "episode_"+request, "run_"+request
		for _, statement := range []struct {
			query string
			args  []any
		}{
			{`INSERT INTO agent_runs (
			    id, mode, channel_id, conversation_key, source_kind, source_id, prompt,
			    idempotency_key, state, next_attempt_at, created_at, updated_at, episode_id
			  ) VALUES (?, 'triage', ?, ?, ?, ?, 'verify', ?, 'completed', ?, ?, ?, ?)`,
				[]any{run, grantAlert.ChannelID, "conv_" + request, "emisar_approval:" + request,
					"input_" + request, "idem_" + request, stamp, stamp, stamp, episode}},
			{`INSERT INTO work_episodes (
			    id, agent_run_id, effort, authority, objective, created_at, updated_at
			  ) VALUES (?, ?, 'incident_investigation', 'governed_operation', 'verify', ?, ?)`,
				[]any{episode, run, stamp, stamp}},
			{`INSERT INTO episode_outcomes (
			    episode_id, channel_id, repository, terminal_state, terminal_at,
			    alert_group_key, verified, created_at
			  ) VALUES (?, ?, ?, 'completed', ?, ?, 1, ?)`,
				[]any{episode, grantAlert.ChannelID, grantAlert.Repository, stamp,
					grantAlert.AlertGroupKey, stamp}},
			{`INSERT INTO emisar_approvals (
			    request_id, channel_id, source_input, requested_by, run_id, operation_id,
			    action_id, pack_ref, runner_ref, status, approval_url, next_check_at,
			    expires_at, created_at, updated_at
			  ) VALUES (?, ?, ?, 'U0', ?, ?, ?, ?, ?, 'success', 'https://e/a', ?, ?, ?, ?)`,
				[]any{request, grantAlert.ChannelID, "input_" + request, "emisarrun_" + request,
					"op_" + request, grantAction.ActionID, grantAction.PackRef,
					grantAction.RunnerRef, stamp, stamp, stamp, stamp}},
		} {
			if _, err := db.Exec(statement.query, statement.args...); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func grantConfirmationInput(t *testing.T, cfg config.Config, id, user string, issued time.Time, mutate func(*remediation.Confirmation)) core.SlackInput {
	t.Helper()
	payload := remediation.NewConfirmation(remediation.Grant{
		Trigger: grantAlert, Action: grantAction, Rung: remediation.RungPropose,
	}, issued)
	if mutate != nil {
		mutate(&payload)
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return core.SlackInput{
		ID: id, EnvelopeID: "env_" + id, EventID: "event_" + id,
		Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: grantAlert.ChannelID, MessageTS: "1700.001",
		UserID: user, ActionID: slackui.ActionConfirmGrantPromotion,
		ActionValue: string(encoded),
	}
}

func grantService(t *testing.T) (*Service, *store.Store, *sql.DB, config.Config) {
	t.Helper()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	// The seeds below are the shape a verified remediation leaves on disk, and
	// they are written as rows on purpose: the handler has to be graded against
	// what is recorded, not against what a service call would have recorded.
	raw, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { raw.Close() })
	return svc, st, raw, cfg
}

func clickGrantConfirmation(t *testing.T, svc *Service, st *store.Store, input core.SlackInput) {
	t.Helper()
	ctx := context.Background()
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit grant confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
}

// TestAConfirmedPromotionIsGrantedOnlyOnTheHostsRecomputedCount is the whole
// authority story in one test.
//
// The card is a proposal and the click is a request; what actually decides is
// the host counting verified successes of this exact action for this exact
// alert, at the moment of the click. Below the threshold nothing is granted no
// matter what was clicked, and the operator is told so rather than left to
// assume it worked.
func TestAConfirmedPromotionIsGrantedOnlyOnTheHostsRecomputedCount(t *testing.T) {
	ctx := context.Background()
	svc, st, raw, cfg := grantService(t)
	operator := cfg.Slack.Operators[0]

	// Two verified successes is one short of the default threshold.
	seedVerifiedRemediations(t, raw, 0, 2)
	clickGrantConfirmation(t, svc, st, grantConfirmationInput(
		t, cfg, "slack_grant_early", operator, time.Now().UTC(), nil,
	))
	if grants, err := st.Grants.Matching(ctx, grantAlert); err != nil || len(grants) != 0 {
		t.Fatalf("a rung was granted on two verified successes: %+v, %v", grants, err)
	}

	// The third lands, and the same click now earns the rung.
	seedVerifiedRemediations(t, raw, 2, 3)
	clickGrantConfirmation(t, svc, st, grantConfirmationInput(
		t, cfg, "slack_grant_earned", operator, time.Now().UTC(), nil,
	))
	grants, err := st.Grants.Matching(ctx, grantAlert)
	if err != nil || len(grants) != 1 {
		t.Fatalf("grants = %+v, %v", grants, err)
	}
	granted := grants[0]
	if granted.Rung != remediation.RungPropose {
		t.Fatalf("rung=%q, want %q", granted.Rung, remediation.RungPropose)
	}
	if granted.GrantedBy != operator {
		t.Fatalf("granted_by=%q, want the operator who clicked", granted.GrantedBy)
	}
	if granted.ExpiresAt.IsZero() || !granted.ExpiresAt.After(time.Now().UTC()) {
		t.Fatalf("granted expiry %v is not in the future; no grant is permanent", granted.ExpiresAt)
	}
	// And the grant now actually authorizes the offer, which is the only
	// observable difference a rung makes.
	decision := remediation.Decide(
		grants, remediation.Trigger{Class: grantAlert, Action: grantAction}, time.Now().UTC(),
	)
	if !decision.MayOffer {
		t.Fatalf("a granted propose rung authorizes no offer: %s", decision.Reason)
	}
	if decision.MaySubmitUnattended {
		t.Fatal("a propose grant authorized unattended submission")
	}
}

// TestARedeliveredPromotionClickGrantsTheSameRungOnce is the retry case Slack
// makes routine. The second press must not mint a second grant, must not climb
// a second rung, and must not tell an operator that nothing was granted over a
// grant that plainly exists.
func TestARedeliveredPromotionClickGrantsTheSameRungOnce(t *testing.T) {
	ctx := context.Background()
	svc, st, raw, cfg := grantService(t)
	seedVerifiedRemediations(t, raw, 0, 3)
	for _, id := range []string{"slack_grant_first", "slack_grant_again"} {
		clickGrantConfirmation(t, svc, st, grantConfirmationInput(
			t, cfg, id, cfg.Slack.Operators[0], time.Now().UTC(), nil,
		))
	}
	grants, err := st.Grants.Matching(ctx, grantAlert)
	if err != nil || len(grants) != 1 {
		t.Fatalf("grants after a redelivered click = %+v, %v", grants, err)
	}
	if grants[0].Rung != remediation.RungPropose {
		t.Fatalf("rung=%q after two presses, want the one rung that was earned", grants[0].Rung)
	}
}

// TestOnlyAnOperatorCanGrantRemediationAuthority is the check the memory
// confirmation never got its own test for, on the click where it matters most:
// this one decides what Responder may DO.
func TestOnlyAnOperatorCanGrantRemediationAuthority(t *testing.T) {
	ctx := context.Background()
	svc, st, raw, cfg := grantService(t)
	seedVerifiedRemediations(t, raw, 0, 3)
	clickGrantConfirmation(t, svc, st, grantConfirmationInput(
		t, cfg, "slack_grant_bystander", "U0BYSTANDER", time.Now().UTC(), nil,
	))
	if grants, err := st.Grants.Matching(ctx, grantAlert); err != nil || len(grants) != 0 {
		t.Fatalf("a non-operator granted remediation authority: %+v, %v", grants, err)
	}
}

// TestAStalePromotionClickGrantsNothing covers the payload bound. The evidence
// is recomputed on every click, so a stale one cannot grant against stale
// numbers — but it can show an operator one sentence and act on another, and a
// day is where that stops being acceptable.
func TestAStalePromotionClickGrantsNothing(t *testing.T) {
	ctx := context.Background()
	svc, st, raw, cfg := grantService(t)
	seedVerifiedRemediations(t, raw, 0, 3)
	clickGrantConfirmation(t, svc, st, grantConfirmationInput(
		t, cfg, "slack_grant_stale", cfg.Slack.Operators[0],
		time.Now().UTC().Add(-25*time.Hour), nil,
	))
	if grants, err := st.Grants.Matching(ctx, grantAlert); err != nil || len(grants) != 0 {
		t.Fatalf("a day-old confirmation granted authority: %+v, %v", grants, err)
	}
}

// TestAPromotionClickCannotWidenItsOwnScope is the tamper case. The button
// value made a round trip through a Slack client, so the one thing it must not
// be able to do is come back naming a bigger grant than the card offered.
func TestAPromotionClickCannotWidenItsOwnScope(t *testing.T) {
	ctx := context.Background()
	svc, st, raw, cfg := grantService(t)
	seedVerifiedRemediations(t, raw, 0, 3)
	for _, tc := range []struct {
		name   string
		mutate func(*remediation.Confirmation)
	}{
		{"another runner", func(c *remediation.Confirmation) { c.RunnerRef = "runner:prod-eu-west" }},
		{"another pack", func(c *remediation.Confirmation) { c.PackRef = "nomad@9.9.9" }},
		{"a dropped repository scope", func(c *remediation.Confirmation) { c.Repository = "" }},
		{"a skipped rung", func(c *remediation.Confirmation) { c.Rung = "one_click" }},
		{"the auto rung", func(c *remediation.Confirmation) { c.Rung = "auto" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			clickGrantConfirmation(t, svc, st, grantConfirmationInput(
				t, cfg, "slack_grant_"+strings.ReplaceAll(tc.name, " ", "_"),
				cfg.Slack.Operators[0], time.Now().UTC(), tc.mutate,
			))
			grants, err := st.Grants.Matching(ctx, grantAlert)
			if err != nil {
				t.Fatal(err)
			}
			for _, grant := range grants {
				if grant.Rung != remediation.RungObserve {
					t.Fatalf(
						"%s produced a live grant at %q over %s",
						tc.name, grant.Rung, grant.Action,
					)
				}
			}
		})
	}
}

// TestAFailedRunDemotesEveryGrantThatOfferedTheAction is the automatic half,
// driven through the same terminal-approval path production uses.
//
// Demotion asks nobody and waits for nothing. A run that failed is evidence
// about the action, and the grant that offered it drops a rung the moment
// Responder learns of it.
func TestAFailedRunDemotesEveryGrantThatOfferedTheAction(t *testing.T) {
	ctx := context.Background()
	svc, st, _, cfg := grantService(t)
	granted, err := st.Grants.Confirm(ctx, remediation.Grant{
		Trigger: grantAlert, Action: grantAction, Rung: remediation.RungOneClick,
		GrantedBy: cfg.Slack.Operators[0], ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
		SuccessCount: 3,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		status string
		want   remediation.Rung
	}{
		// Emisar declining is the control working, not the action failing.
		{"denied", remediation.RungOneClick},
		{"cancelled", remediation.RungOneClick},
		// The action ran and did not work.
		{"failed", remediation.RungPropose},
		// The identity no longer resolves to what the successes were earned on.
		{"unknown_action", remediation.RungObserve},
	} {
		t.Run(tc.status, func(t *testing.T) {
			svc.demoteGrantsForRun(ctx, core.EmisarApproval{
				RequestID: "req-" + tc.status, RunID: "run-" + tc.status,
				ChannelID: grantAlert.ChannelID, Status: tc.status,
				ActionID: grantAction.ActionID, PackRef: grantAction.PackRef,
				RunnerRef: grantAction.RunnerRef,
			})
			stored, err := st.Grants.Get(ctx, grantAlert, grantAction)
			if err != nil {
				t.Fatal(err)
			}
			if stored.Rung != tc.want {
				t.Fatalf("after a %q run the grant is %q, want %q", tc.status, stored.Rung, tc.want)
			}
		})
	}
	if granted.ID == "" {
		t.Fatal("the seeded grant has no id")
	}
}

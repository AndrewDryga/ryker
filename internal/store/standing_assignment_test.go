package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/standingassignmentstore"
)

// shadowedAssignment is what an operator can actually create: scoped authority
// that is evaluated and withheld.
func shadowedAssignment(t *testing.T, st *Store, budget int) core.StandingAssignment {
	t.Helper()
	assignment, err := st.StandingAssignments.Create(context.Background(), core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "sentry payments timeout",
		Repository: "payments-api", PathGlobs: []string{"src/payments/**"},
		ChangeClass: "observability", DailyBudget: budget, ActorID: "UOPERATOR",
		Shadow:    true,
		ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	return assignment
}

// grantedAssignment is one whose flag has been cleared, which today only a test
// does. The claim, the budget and the deduplication are the invariants that
// make unattended work survivable, and they have to stay reachable while the
// grant is withheld or they rot until the day somebody switches it on.
func grantedAssignment(t *testing.T, st *Store, budget int) core.StandingAssignment {
	t.Helper()
	assignment := shadowedAssignment(t, st, budget)
	if err := st.StandingAssignments.SetShadow(context.Background(), assignment.ID, false); err != nil {
		t.Fatal(err)
	}
	granted, err := st.StandingAssignments.Get(context.Background(), assignment.ID)
	if err != nil {
		t.Fatal(err)
	}
	return granted
}

// An assignment is created with its authority withheld, and asking for it
// outright is refused.
//
// The consumption half of this feature has been complete and gated since
// migration 43 and has never run: both deployments held zero rows because
// nothing could create an assignment. Adding the creation path is what makes
// the gate real, and it must not also be what grants unattended pull-request
// authority — the gate leans on completion.status == decision_ready, which was
// the largest single source of defects on 2026-08-09, and the evidence that it
// holds is what the shadow period is being run to collect.
//
// The default is the load-bearing half. Shadow is a Go bool, so a caller that
// forgets the field asks for live authority by saying nothing; the column
// defaults to 1 and this refuses the zero value, so silence means shadow.
func TestAnAssignmentIsCreatedWithItsAuthorityWithheld(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())

	assignment := shadowedAssignment(t, st, 3)
	if !assignment.Shadow {
		t.Fatal("a newly created assignment may act unattended; it must be shadowed")
	}
	stored, err := st.StandingAssignments.Get(ctx, assignment.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !stored.Shadow {
		t.Fatal("the shadow flag did not survive the round trip to the row")
	}

	_, err = st.StandingAssignments.Create(ctx, core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "sentry", Repository: "payments-api",
		ChangeClass: "observability", DailyBudget: 3, ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	})
	if !errors.Is(err, standingassignmentstore.ErrGrantWithheld) {
		t.Fatalf("creating an unshadowed assignment = %v, want ErrGrantWithheld", err)
	}
}

// A shadowed assignment cannot claim, so it cannot spend a budget, mark a
// signal handled, or reach the code that opens a task.
//
// The service checks the flag between eligibility and action; this is the same
// door locked from the other side. The claim is the step that makes a signal
// look handled forever, so a caller that reaches it while shadowed has already
// lost the invariant, and every later occurrence of that signal would be
// silently skipped by a feature that never did anything.
func TestAShadowedAssignmentCannotClaimAnything(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	assignment := shadowedAssignment(t, st, 5)

	_, err := st.StandingAssignments.ClaimAction(
		ctx, assignment.ID, "sentry:PAY-1", time.Now().UTC(),
	)
	if !errors.Is(err, standingassignmentstore.ErrGrantWithheld) {
		t.Fatalf("a shadowed assignment claimed an action: %v, want ErrGrantWithheld", err)
	}
	var claims int
	if err := st.db.QueryRowContext(
		ctx, `SELECT COUNT(*) FROM standing_assignment_actions`,
	).Scan(&claims); err != nil {
		t.Fatal(err)
	}
	if claims != 0 {
		t.Fatalf("a shadowed assignment left %d claims behind; it must leave none", claims)
	}
}

// Acting twice on the same issue must be impossible, not merely avoided.
//
// A proactive agent that opens a second pull request for an issue it already
// handled is worse than one that does nothing: it costs review attention every
// time the signal repeats, which during an incident is constantly. The unique
// constraint carries this, so no caller can forget it.
func TestAnAssignmentActsOnceForOneIssue(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	assignment := grantedAssignment(t, st, 5)
	now := time.Now().UTC()

	if _, err := st.StandingAssignments.ClaimAction(ctx, assignment.ID, "sentry:PAY-1", now); err != nil {
		t.Fatalf("first claim: %v", err)
	}
	_, err := st.StandingAssignments.ClaimAction(ctx, assignment.ID, "sentry:PAY-1", now)
	if !errors.Is(err, standingassignmentstore.ErrAlreadyActed) {
		t.Fatalf("second claim on the same issue = %v, want ErrAlreadyActed", err)
	}
	// A different issue is still allowed.
	if _, err := st.StandingAssignments.ClaimAction(ctx, assignment.ID, "sentry:PAY-2", now); err != nil {
		t.Fatalf("claim for a different issue: %v", err)
	}
}

// The budget is what stops an outage becoming a wall of pull requests.
//
// One signal repeating is the normal shape of an incident, and correlation
// handles that. The budget covers the other case: many genuinely distinct
// issues at once, which is exactly what a bad deploy produces.
func TestAnAssignmentStopsAtItsDailyBudget(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	assignment := grantedAssignment(t, st, 2)
	now := time.Now().UTC()

	for index, key := range []string{"issue:1", "issue:2"} {
		if _, err := st.StandingAssignments.ClaimAction(ctx, assignment.ID, key, now); err != nil {
			t.Fatalf("claim %d: %v", index+1, err)
		}
	}
	_, err := st.StandingAssignments.ClaimAction(ctx, assignment.ID, "issue:3", now)
	if !errors.Is(err, standingassignmentstore.ErrBudgetSpent) {
		t.Fatalf("claim past the budget = %v, want ErrBudgetSpent", err)
	}
	// The budget is a rolling day, so yesterday's work does not block today's.
	if _, err := st.StandingAssignments.ClaimAction(
		ctx, assignment.ID, "issue:3", now.Add(25*time.Hour),
	); err != nil {
		t.Fatalf("claim a day later: %v", err)
	}
}

// Lapsed authority must not act, and the check belongs in the store so that no
// caller can forget it.
func TestLapsedAuthorityCannotAct(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	now := time.Now().UTC()

	assignment := grantedAssignment(t, st, 5)
	if err := st.StandingAssignments.SetEnabled(ctx, assignment.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := st.StandingAssignments.ClaimAction(ctx, assignment.ID, "issue:1", now); err == nil {
		t.Fatal("a disabled assignment acted")
	}
	if err := st.StandingAssignments.SetEnabled(ctx, assignment.ID, true); err != nil {
		t.Fatal(err)
	}
	// Expired is the same: authority that never lapses is not scoped.
	if _, err := st.StandingAssignments.ClaimAction(
		ctx, assignment.ID, "issue:1", assignment.ExpiresAt.Add(time.Hour),
	); err == nil {
		t.Fatal("an expired assignment acted")
	}
	live, err := st.StandingAssignments.ListLive(ctx, "CALERTS", assignment.ExpiresAt.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(live) != 0 {
		t.Fatalf("expired assignment listed as live: %+v", live)
	}
	// A paused or expired assignment must still be findable, or the operator
	// who paused it has no way back to it and a pause reads as a deletion.
	managed, err := st.StandingAssignments.ListForChannel(ctx, "CALERTS", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(managed) != 1 {
		t.Fatalf("management list held %d assignments, want the paused one", len(managed))
	}
}

// Scope is typed, and the refusals are the point.
//
// A change class outside the allowlist, or authority with no expiry, would each
// turn a scoped grant into an open one.
func TestScopeMustBeBounded(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	valid := core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "sentry", Repository: "payments-api",
		ChangeClass: "observability", DailyBudget: 3, ActorID: "UOPERATOR",
		Shadow:    true,
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	for _, testCase := range []struct {
		name   string
		mutate func(*core.StandingAssignment)
	}{
		{"a change class outside the allowlist", func(a *core.StandingAssignment) {
			a.ChangeClass = "refactor_business_logic"
		}},
		{"authority that never expires", func(a *core.StandingAssignment) {
			a.ExpiresAt = time.Time{}
		}},
		{"an unbounded daily budget", func(a *core.StandingAssignment) { a.DailyBudget = 0 }},
		{"a budget large enough to be no budget", func(a *core.StandingAssignment) {
			a.DailyBudget = 500
		}},
		{"no record of who confirmed it", func(a *core.StandingAssignment) { a.ActorID = "" }},
		{"no repository to change", func(a *core.StandingAssignment) { a.Repository = "" }},
		{"a path pattern that escapes upward", func(a *core.StandingAssignment) {
			a.PathGlobs = []string{"../../etc/**"}
		}},
		{"authority granted at creation", func(a *core.StandingAssignment) { a.Shadow = false }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			candidate := valid
			testCase.mutate(&candidate)
			if _, err := st.StandingAssignments.Create(ctx, candidate); err == nil {
				t.Fatal("accepted an assignment that is not actually scoped")
			}
		})
	}
}

// The tally has to count the refusals, and say which one repeated.
//
// "Of the signals this assignment would have acted on, how many deserved a pull
// request" is the only question the shadow period exists to answer, and it
// cannot be answered from the passes alone: two eligible out of three is a
// different proposition from two out of forty. The most-repeated refusal is
// what separates a misconfigured scope from traffic that simply did not deserve
// a change, and those call for opposite responses.
func TestTheTallyCountsRefusalsAndNamesTheRepeatedOne(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	assignment := shadowedAssignment(t, st, 3)

	record := func(verdict, reason string) {
		t.Helper()
		if _, err := st.StandingAssignments.RecordEvaluation(
			ctx, core.StandingAssignmentEvaluation{
				AssignmentID: assignment.ID, InputID: "in_" + reason, Signal: "sentry timeout",
				Shadow: true, Verdict: verdict, Reason: reason,
			},
		); err != nil {
			t.Fatal(err)
		}
	}
	record("declined", "this has not happened often enough to be a pattern yet")
	record("declined", "this has not happened often enough to be a pattern yet")
	record("declined", "no verified evidence supports the change")
	record("eligible", "in scope, recurring, and evidence-backed")

	tally, err := st.StandingAssignments.Tally(ctx, assignment.ID)
	if err != nil {
		t.Fatal(err)
	}
	if tally.Evaluated != 4 || tally.Eligible != 1 || tally.Declined != 3 {
		t.Fatalf(
			"tally evaluated=%d eligible=%d declined=%d, want 4/1/3",
			tally.Evaluated, tally.Eligible, tally.Declined,
		)
	}
	if tally.TopDecline != "this has not happened often enough to be a pattern yet" ||
		tally.TopDeclineCount != 2 {
		t.Fatalf(
			"most repeated refusal = %q x%d, want the recurrence one twice",
			tally.TopDecline, tally.TopDeclineCount,
		)
	}
	if tally.LastEligible.IsZero() || tally.LastEvaluated.IsZero() {
		t.Fatal("the tally cannot say when it last looked or last passed")
	}

	// An assignment nobody has offered a signal to reports zeros rather than an
	// error, because an empty shadow period is a normal state and a page that
	// cannot render it is a page that hides the feature.
	empty, err := st.StandingAssignments.Tally(ctx, "assign_nothing")
	if err != nil {
		t.Fatalf("tally over no evaluations: %v", err)
	}
	if empty.Evaluated != 0 || empty.TopDecline != "" {
		t.Fatalf("empty tally invented %+v", empty)
	}
}

// Recurrence counts distinct episodes, not runs.
//
// One problem investigated across three retries is one occurrence. Counting
// runs would let a flaky provider manufacture a pattern out of a single event,
// and proactive work would then open a pull request about Coop being slow.
func TestRecurrenceCountsProblemsNotRetries(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	since := time.Now().UTC().Add(-24 * time.Hour)

	count, err := st.StandingAssignments.CountCorrelatedEpisodes(ctx, "operation:payments-timeout", since)
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("count with no history = %d, want 0", count)
	}

	// One problem, queued once.
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CALERTS",
		ConversationKey: "operation:payments-timeout",
		SourceKind:      "watch", SourceID: "alert_1", UserID: "B_GRAFANA",
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}

	// The same problem retried twice more, as a provider failure would produce.
	for index := 0; index < 2; index++ {
		if _, _, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: "CALERTS",
			ConversationKey: "operation:payments-timeout",
			SourceKind:      "watch", SourceID: fmt.Sprintf("alert_1_retry_%d", index),
			UserID: "B_GRAFANA",
		}); err != nil {
			t.Fatal(err)
		}
	}

	count, err = st.StandingAssignments.CountCorrelatedEpisodes(ctx, "operation:payments-timeout", since)
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("count after one problem and two retries = %d, want 1 — retries are not "+
			"recurrences, or a flaky provider becomes a pattern", count)
	}
}

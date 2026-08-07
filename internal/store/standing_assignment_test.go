package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func liveAssignment(t *testing.T, st *Store, budget int) core.StandingAssignment {
	t.Helper()
	assignment, err := st.CreateStandingAssignment(context.Background(), core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "sentry payments timeout",
		Repository: "payments-api", PathGlobs: []string{"src/payments/**"},
		ChangeClass: "observability", DailyBudget: budget, ActorID: "UOPERATOR",
		ExpiresAt: time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	return assignment
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
	assignment := liveAssignment(t, st, 5)
	now := time.Now().UTC()

	if _, err := st.ClaimStandingAssignmentAction(ctx, assignment.ID, "sentry:PAY-1", now); err != nil {
		t.Fatalf("first claim: %v", err)
	}
	_, err := st.ClaimStandingAssignmentAction(ctx, assignment.ID, "sentry:PAY-1", now)
	if !errors.Is(err, ErrAssignmentAlreadyActed) {
		t.Fatalf("second claim on the same issue = %v, want ErrAssignmentAlreadyActed", err)
	}
	// A different issue is still allowed.
	if _, err := st.ClaimStandingAssignmentAction(ctx, assignment.ID, "sentry:PAY-2", now); err != nil {
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
	assignment := liveAssignment(t, st, 2)
	now := time.Now().UTC()

	for index, key := range []string{"issue:1", "issue:2"} {
		if _, err := st.ClaimStandingAssignmentAction(ctx, assignment.ID, key, now); err != nil {
			t.Fatalf("claim %d: %v", index+1, err)
		}
	}
	_, err := st.ClaimStandingAssignmentAction(ctx, assignment.ID, "issue:3", now)
	if !errors.Is(err, ErrAssignmentBudgetSpent) {
		t.Fatalf("claim past the budget = %v, want ErrAssignmentBudgetSpent", err)
	}
	// The budget is a rolling day, so yesterday's work does not block today's.
	if _, err := st.ClaimStandingAssignmentAction(
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

	assignment := liveAssignment(t, st, 5)
	if err := st.SetStandingAssignmentEnabled(ctx, assignment.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ClaimStandingAssignmentAction(ctx, assignment.ID, "issue:1", now); err == nil {
		t.Fatal("a disabled assignment acted")
	}
	if err := st.SetStandingAssignmentEnabled(ctx, assignment.ID, true); err != nil {
		t.Fatal(err)
	}
	// Expired is the same: authority that never lapses is not scoped.
	if _, err := st.ClaimStandingAssignmentAction(
		ctx, assignment.ID, "issue:1", assignment.ExpiresAt.Add(time.Hour),
	); err == nil {
		t.Fatal("an expired assignment acted")
	}
	live, err := st.ListLiveStandingAssignments(ctx, "CALERTS", assignment.ExpiresAt.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(live) != 0 {
		t.Fatalf("expired assignment listed as live: %+v", live)
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
	} {
		t.Run(testCase.name, func(t *testing.T) {
			candidate := valid
			testCase.mutate(&candidate)
			if _, err := st.CreateStandingAssignment(ctx, candidate); err == nil {
				t.Fatal("accepted an assignment that is not actually scoped")
			}
		})
	}
}

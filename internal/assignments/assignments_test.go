package assignments

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The brief an unattended task works from must state its boundary, not suggest
// it.
//
// This task starts with nobody watching. The scope the operator agreed to is
// the only thing between a narrow fix and a rewrite, so it has to be in the
// objective the model actually reads — and it has to say what to do when the
// fix does not fit, or the model will widen the change to make it fit.
func TestProactiveObjectiveStatesItsBoundary(t *testing.T) {
	assignment := core.StandingAssignment{
		Repository: "payments-api", ChangeClass: "observability",
		PathGlobs: []string{"src/payments/**"},
	}
	objective := Objective(assignment, "timeouts trace to a missing client deadline")

	for _, required := range []string{
		"observability",           // the class is named
		"Do not change behaviour", // as a limit, not a hint
		"stop and say so",         // what to do when it does not fit
		"src/payments/**",         // the path scope
		"out of scope",            // paths are a limit too
		"timeouts trace to",       // the conclusion it works from
	} {
		if !strings.Contains(objective, required) {
			t.Errorf("objective is missing %q:\n%s", required, objective)
		}
	}

	// Without path globs the objective must not claim a path restriction it
	// does not have — a false boundary is worse than a stated wide one.
	wide := Objective(core.StandingAssignment{
		Repository: "payments-api", ChangeClass: "documentation",
	}, "timeouts trace to a missing client deadline")
	if strings.Contains(wide, "Only these paths") {
		t.Errorf("objective invented a path restriction:\n%s", wide)
	}
}

// A typed command grants exactly what was typed, and refuses the rest.
//
// Every field of an assignment is a bound on unattended work. A key this
// command does not recognize is a bound it did not apply — a mistyped `paths=`
// silently becoming no path restriction is a repository-wide grant nobody
// asked for — so an unknown key is a refusal rather than something skipped.
func TestACreateCommandGrantsOnlyWhatWasTyped(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	request, err := ParseCreate(strings.Fields(
		"repo=payments-api class=observability budget=2 days=30 paths=src/payments/**,docs/** "+
			"signal=sentry payments timeout",
	), "CALERTS", "UOPERATOR", now)
	if err != nil {
		t.Fatal(err)
	}
	got := request.Assignment
	if got.Repository != "payments-api" || got.ChangeClass != "observability" ||
		got.DailyBudget != 2 || got.ChannelID != "CALERTS" || got.ActorID != "UOPERATOR" {
		t.Fatalf("parsed assignment lost a bound: %+v", got)
	}
	if got.SignalPattern != "sentry payments timeout" {
		t.Fatalf("signal = %q, want every word after signal=", got.SignalPattern)
	}
	if len(got.PathGlobs) != 2 {
		t.Fatalf("path globs = %v, want both", got.PathGlobs)
	}
	if !got.ExpiresAt.Equal(now.Add(30 * 24 * time.Hour)) {
		t.Fatalf("expiry = %s, want thirty days on", got.ExpiresAt)
	}
	// The default that matters. Shadow is a Go bool: a parser that simply did
	// not mention it would hand the store live authority by saying nothing.
	if !got.Shadow {
		t.Fatal("a typed create command produced an assignment that may act unattended")
	}

	for _, refusal := range []struct{ name, command string }{
		{"an unknown key", "repo=x class=observability signal=timeout mode=live"},
		{"a positional argument", "payments-api class=observability signal=timeout"},
		{"no signal at all", "repo=payments-api class=observability budget=1"},
		{"authority for longer than anybody plans", "repo=x class=observability days=400 signal=t"},
	} {
		t.Run(refusal.name, func(t *testing.T) {
			if _, err := ParseCreate(
				strings.Fields(refusal.command), "CALERTS", "UOPERATOR", now,
			); err == nil {
				t.Fatal("accepted a command that grants more than it says")
			}
		})
	}
}

// An eligible verdict under shadow must say the pull request was withheld.
//
// A decline reads the same either way — it refused. An eligible one does not:
// an operator reading "eligible" in the audit log goes looking for the pull
// request it implies, finds none, and has no way to tell a withheld grant from
// a task that failed to start.
func TestAWithheldGrantSaysSoInTheAudit(t *testing.T) {
	reason := "in scope, recurring, and evidence-backed"
	shadowed := AuditDetail(core.StandingAssignment{Shadow: true}, reason)
	if !strings.Contains(shadowed, "nothing was opened") {
		t.Fatalf("a withheld grant audits as %q, which reads as a pull request", shadowed)
	}
	if granted := AuditDetail(core.StandingAssignment{}, reason); granted != reason {
		t.Fatalf("a granted assignment's audit detail was decorated: %q", granted)
	}
}

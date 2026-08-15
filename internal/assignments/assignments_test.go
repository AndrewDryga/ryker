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

// A normalized offer grants exactly the bounds it names, and nothing wider.
//
// This is the invariant the retired `/responder assignments create` grammar
// carried and the one that matters most now that a model writes the proposal
// rather than an operator: every field is a bound on unattended pull-request
// authority, so a value the host cannot store must be refused where the model
// can read the refusal, and a value it can store must survive normalization
// unchanged in meaning. The card an operator confirms renders exactly what this
// returns, so a bound lost here is a bound nobody was shown.
func TestANormalizedOfferGrantsOnlyTheBoundsItNames(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	got, err := Normalize(core.StandingAssignmentOffer{
		// Deliberately the shapes an operator's own sentence produces: the
		// class spelled with a space, whitespace around the repository, a
		// duplicate and an empty glob from a trailing comma, and a signal with
		// a line break in it.
		Repository: " payments-api ", ChangeClass: "Dependency Upgrade",
		SignalPattern: "sentry payments\n  timeout",
		PathGlobs:     []string{"src/payments/**", " ", "docs/**", "src/payments/**"},
		DailyBudget:   2, ExpiryDays: 30,
	}, "CALERTS", now)
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if got.Repository != "payments-api" || got.ChangeClass != "dependency_upgrade" ||
		got.DailyBudget != 2 || got.ChannelID != "CALERTS" {
		t.Fatalf("normalized assignment lost a bound: %+v", got)
	}
	if got.SignalPattern != "sentry payments timeout" {
		t.Fatalf("signal = %q, want the words collapsed to one line", got.SignalPattern)
	}
	if len(got.PathGlobs) != 2 {
		t.Fatalf("path globs = %v, want the empty and the duplicate dropped", got.PathGlobs)
	}
	if !got.ExpiresAt.Equal(now.Add(30 * 24 * time.Hour)) {
		t.Fatalf("expiry = %s, want thirty days on", got.ExpiresAt)
	}
	// The default that matters. Shadow is a Go bool: a normalizer that simply
	// did not mention it would hand the store live authority by saying nothing,
	// and the store's refusal would then be the only thing between a model's
	// sentence and unattended pull requests.
	if !got.Shadow {
		t.Fatal("a confirmed offer would produce an assignment that may act unattended")
	}
	// An offer that says nothing about how much gets the cautious answer, not
	// the permissive one.
	quiet, err := Normalize(core.StandingAssignmentOffer{
		Repository: "payments-api", ChangeClass: "documentation", SignalPattern: "renovate",
	}, "CALERTS", now)
	if err != nil {
		t.Fatalf("normalize without budget or expiry: %v", err)
	}
	if quiet.DailyBudget != 1 || !quiet.ExpiresAt.Equal(now.Add(14*24*time.Hour)) {
		t.Fatalf("unstated bounds did not default cautiously: %+v", quiet)
	}
}

// Bounds the host cannot grant are refused where the model reads the refusal.
//
// The slash grammar refused an unknown key rather than skipping it, because a
// mistyped `paths=` silently becoming no path restriction was a
// repository-wide grant nobody asked for. A model writing free text can make
// every one of those mistakes and several the grammar could not — inventing a
// change class, asking for a year, asking for fifty pull requests a day — and
// the operation validator is where it finds out, because it is the only place
// a correction turn can act on.
func TestAnUngrantableBoundIsRefusedByTheOperationValidator(t *testing.T) {
	for _, refusal := range []struct {
		name  string
		offer core.StandingAssignmentOffer
		says  string
	}{
		{
			"a change class nobody allowlisted",
			core.StandingAssignmentOffer{
				Repository: "payments-api", ChangeClass: "refactor", SignalPattern: "timeout",
			},
			"dependency_upgrade",
		},
		{
			"authority for longer than anybody plans",
			core.StandingAssignmentOffer{
				Repository: "payments-api", ChangeClass: "observability",
				SignalPattern: "timeout", ExpiryDays: 400,
			},
			"at most 90",
		},
		{
			"more pull requests a day than a reviewer reads",
			core.StandingAssignmentOffer{
				Repository: "payments-api", ChangeClass: "observability",
				SignalPattern: "timeout", DailyBudget: 50,
			},
			"range is 1 to 20",
		},
		{
			"no signal at all, which is every message in the channel",
			core.StandingAssignmentOffer{
				Repository: "payments-api", ChangeClass: "observability",
			},
			"signal_pattern",
		},
		{
			"no repository, which is whichever one is default",
			core.StandingAssignmentOffer{
				ChangeClass: "observability", SignalPattern: "timeout",
			},
			"requires a repository",
		},
		{
			"a path pattern that leaves the repository it is scoped to",
			core.StandingAssignmentOffer{
				Repository: "payments-api", ChangeClass: "observability",
				SignalPattern: "timeout", PathGlobs: []string{"../other-repo/**"},
			},
			"traverses upward",
		},
	} {
		t.Run(refusal.name, func(t *testing.T) {
			err := ValidateOffer("assign-1", &refusal.offer)
			if err == nil {
				t.Fatal("accepted an offer that grants more than the host can store")
			}
			if !strings.Contains(err.Error(), refusal.says) {
				t.Fatalf(
					"the refusal does not tell the model what to write instead: %v", err,
				)
			}
			// And the refusal holds on the path the operator's click takes, not
			// only on the path the model's result takes. An offer accepted at
			// result time and refused at confirmation time is a broken promise;
			// one accepted at confirmation time and refused by the store is a
			// stack trace where a sentence belongs.
			if _, err := Normalize(refusal.offer, "CALERTS", time.Now().UTC()); err == nil {
				t.Fatal("normalization granted bounds the validator refused")
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

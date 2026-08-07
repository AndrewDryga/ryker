package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
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
	completion := &investigation.CompletionAssessment{
		Summary: "timeouts trace to a missing client deadline",
	}
	objective := proactiveObjective(assignment, completion)

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
	wide := proactiveObjective(core.StandingAssignment{
		Repository: "payments-api", ChangeClass: "documentation",
	}, completion)
	if strings.Contains(wide, "Only these paths") {
		t.Errorf("objective invented a path restriction:\n%s", wide)
	}
}

// Nothing happens in a channel with no standing assignment, and it happens
// without a store round trip beyond the one lookup.
func TestProactiveIsInertWithoutAnAssignment(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	err = svc.considerProactiveWork(
		ctx,
		core.SlackInput{ID: "in_1", ChannelID: "CQUIET", Text: "FIRING: something"},
		&investigation.CompletionAssessment{Status: "decision_ready", Summary: "fine"},
		[]core.Evidence{{SourceType: "emisar"}},
	)
	if err != nil {
		t.Fatalf("proactive consideration in an unassigned channel: %v", err)
	}
}

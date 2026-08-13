package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The repository map is the only memory Responder writes without an operator
// confirming it, so the shape of that exemption is what this pins: one row per
// repository that replaces rather than accumulates, an expiry that never comes,
// and a configured repository or nothing at all.
func TestRepositoryContentsIsOnePermanentSelfMaintainedRowPerRepository(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, _ := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), logger)
	run := core.AgentRun{ID: "run_contents"}

	write := func(contents string) {
		t.Helper()
		if err := svc.applyRepositoryContents(ctx, run, decisionpkg.WatchDecision{
			RepositoryContents: []investigation.RepositoryContentsOperation{
				{Repository: "repo", Contents: contents},
			},
		}); err != nil {
			t.Fatal(err)
		}
	}

	write("Elixir umbrella holding the backend services.")
	stored, err := st.Memory.ListRepositoryContents(ctx)
	if err != nil || stored["repo"] != "Elixir umbrella holding the backend services." {
		t.Fatalf("first description = %+v, %v", stored, err)
	}

	// A later turn that reads the repository more carefully replaces the
	// sentence. Two rows would make the map ambiguous and the prompt longer
	// every time somebody looked.
	write("Elixir umbrella holding the backend services and their shared libraries.")
	stored, err = st.Memory.ListRepositoryContents(ctx)
	if err != nil || len(stored) != 1 ||
		!strings.HasSuffix(stored["repo"], "and their shared libraries.") {
		t.Fatalf("replaced description = %+v, %v", stored, err)
	}

	entries, err := st.Memory.ListMemoryForContext(
		ctx, cfg.Slack.TeamID, "COPS", "repo", cfg.Slack.Operators[0], 50,
	)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, entry := range entries {
		if entry.SubjectKey != core.RepositoryContentsSubject {
			continue
		}
		found++
		if !core.IsPermanentExpiry(entry.ExpiresAt) {
			t.Fatalf("repository description expires at %s", entry.ExpiresAt)
		}
		if entry.ScopeKind != "repository" || entry.ScopeKey != "repo" ||
			entry.Predicate != "guidance" {
			t.Fatalf("repository description is scoped wrong: %+v", entry)
		}
	}
	if found != 1 {
		t.Fatalf("found %d repository descriptions, want exactly 1", found)
	}

	// A companion that no repositories: entry configures is still describable.
	// The emisar deployment mounts `coop` and `responder` as companions and
	// configures neither, and those are the two repositories an agent there
	// reads most; requiring configuration would have silenced exactly them.
	if err := svc.applyRepositoryContents(ctx, run, decisionpkg.WatchDecision{
		RepositoryContents: []investigation.RepositoryContentsOperation{
			{Repository: "coop", Contents: "Session and turn supervisor for agent runs."},
		},
	}); err != nil {
		t.Fatal(err)
	}
	stored, err = st.Memory.ListRepositoryContents(ctx)
	if err != nil || stored["coop"] != "Session and turn supervisor for agent runs." {
		t.Fatalf("unconfigured companion was not described: %+v, %v", stored, err)
	}

	// A name that is not an alias at all is dropped. The turn still finishes:
	// a description nobody asked for must not cost the operator the reply.
	if err := svc.applyRepositoryContents(ctx, run, decisionpkg.WatchDecision{
		RepositoryContents: []investigation.RepositoryContentsOperation{
			{Repository: "../etc/passwd", Contents: "Something invented."},
		},
	}); err != nil {
		t.Fatal(err)
	}
	stored, err = st.Memory.ListRepositoryContents(ctx)
	if err != nil || len(stored) != 2 {
		t.Fatalf("an unusable scope key was stored: %+v, %v", stored, err)
	}
}

// The contract is what stops this slot becoming a changelog. Nothing downstream
// asks an operator whether the sentence is right, so the bound is the only
// thing standing between "which part of the product lives here" and a paragraph
// of release notes that never expires.
func TestRepositoryContentsOperationRejectsWhatItCannotHold(t *testing.T) {
	valid := investigation.ResultOperation{
		ID: "repo-contents-1", Type: "record_repository_contents",
		RepositoryContents: &investigation.RepositoryContentsOperation{
			Repository: "repo", Contents: "Flutter mobile application.",
		},
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid repository contents rejected: %v", err)
	}
	oversized := valid
	oversized.RepositoryContents = &investigation.RepositoryContentsOperation{
		Repository: "repo",
		Contents:   strings.Repeat("a", investigation.MaxRepositoryContentsBytes+1),
	}
	err := oversized.Validate()
	if err == nil || !strings.Contains(err.Error(), "one sentence") {
		t.Fatalf("oversized repository contents = %v", err)
	}
	empty := valid
	empty.RepositoryContents = &investigation.RepositoryContentsOperation{Repository: "repo"}
	if err := empty.Validate(); err == nil {
		t.Fatal("repository contents without a sentence was accepted")
	}
}

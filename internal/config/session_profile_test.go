package config

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// The routing table is decided before any model runs and must stay decidable
// from the record alone.
//
// Every case here is a shape the host already tells apart: the effort contract
// it committed the turn to, the authority that turn may use, and whether
// anybody addressed Responder. Nothing in it consults a model, because a
// routing key that did would leave "why did this run on that rung" answerable
// only by re-reading the answer that rung gave.
func TestEveryShapeOfWorkRoutesToTheProfileThatNamesIt(t *testing.T) {
	for name, testCase := range map[string]struct {
		effort    core.EffortContract
		authority core.AuthorityBoundary
		addressed bool
		want      string
	}{
		"a question somebody asked": {
			core.EffortConversational, core.AuthorityReadOnly, true, ProfileChat,
		},
		"a focused check somebody asked for": {
			core.EffortFocusedCheck, core.AuthorityReadOnly, true, ProfileChat,
		},
		"an operational assessment": {
			core.EffortOperationalAssessment, core.AuthorityReadOnly, true, ProfileInvestigate,
		},
		"an incident investigation": {
			core.EffortIncidentInvestigation, core.AuthorityReadOnly, true, ProfileInvestigate,
		},
		"an engineering task": {
			core.EffortEngineeringTask, core.AuthorityRepositoryWrite, true, ProfileEngineer,
		},
		// Authority decides on its own. A writable turn is engineering work
		// whatever contract admitted it, because the profile selects the box the
		// fork lives in.
		"a writable turn under a lighter contract": {
			core.EffortFocusedCheck, core.AuthorityRepositoryWrite, true, ProfileEngineer,
		},
		"ambient chatter nobody addressed": {
			core.EffortConversational, core.AuthorityReadOnly, false, ProfileWatch,
		},
		"an app alert nobody addressed": {
			core.EffortFocusedCheck, core.AuthorityReadOnly, false, ProfileWatch,
		},
		// The cheap rung is for deciding whether an unaddressed message deserves
		// attention, never for the deep work that decision can lead to.
		"an unaddressed message that reads as an operational assessment": {
			core.EffortOperationalAssessment, core.AuthorityReadOnly, false, ProfileInvestigate,
		},
		// An operator's governed action is answered, not triaged.
		"a governed operation somebody requested": {
			core.EffortFocusedCheck, core.AuthorityGovernedOperation, true, ProfileChat,
		},
	} {
		got := SessionProfileFor(testCase.effort, testCase.authority, testCase.addressed)
		if got != testCase.want {
			t.Errorf("%s routed to %q, want %q", name, got, testCase.want)
		}
		if !KnownSessionProfile(got) {
			t.Errorf("%s routed to %q, which is not a configurable profile", name, got)
		}
	}
}

// A profile an operator writes has to be one Responder routes to, and has to
// name a policy.
//
// Both refusals exist because the alternative is silent. A misspelled profile
// is asked for by no lane, and a profile with no policy falls back to the lane
// policy — so a deployment that meant to move its watch lane onto a cheaper
// rung would keep paying for the old one and never hear about it.
func TestExecutionProfilesAreRefusedUnlessTheyCanRouteAnything(t *testing.T) {
	base := `version: 1
state_dir: /tmp/responder-profile-config-test
slack:
  team_id: T123ABC
  default_repository: emisar
  operators: [U123ABC]
coop: {}
repositories:
  emisar:
    coop_policy: emisar-observe
    conversation_policy: emisar-conversation
    path: /srv/repos/emisar
%s
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: emisar
`
	for name, testCase := range map[string]struct {
		profiles string
		accepted bool
	}{
		"no profiles at all": {profiles: "", accepted: true},
		"one routed lane": {
			profiles: "    profiles:\n      watch:\n        policy: emisar-watch",
			accepted: true,
		},
		"every profile routed": {
			profiles: "    profiles:\n" +
				"      chat:\n        policy: emisar-chat\n" +
				"      investigate:\n        policy: emisar-observe\n" +
				"      engineer:\n        policy: emisar-contributor\n" +
				"      watch:\n        policy: emisar-watch",
			accepted: true,
		},
		"a misspelled profile": {
			profiles: "    profiles:\n      watching:\n        policy: emisar-watch",
		},
		"a profile naming no policy": {
			profiles: "    profiles:\n      watch:\n        policy: \"\"",
		},
		"a profile with nothing in it": {
			profiles: "    profiles:\n      watch: {}",
		},
	} {
		path := filepath.Join(t.TempDir(), "responder.yaml")
		if err := os.WriteFile(
			path, fmt.Appendf(nil, base, testCase.profiles), 0o600,
		); err != nil {
			t.Fatal(err)
		}
		_, err := Load(path)
		if testCase.accepted && err != nil {
			t.Fatalf("%s was rejected: %v", name, err)
		}
		if !testCase.accepted && err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

// A repository set overrides the profiles it names and inherits the rest, the
// way it already does for every policy field beside them — and resolving one
// must not write its routing back into the repository every other context
// reads, which a map shared by copy would do.
func TestARepositorySetOverridesOneProfileWithoutTakingTheOthers(t *testing.T) {
	cfg := Config{
		Repositories: map[string]Repository{
			"emisar": {
				CoopPolicy: "emisar-observe",
				Profiles: map[string]SessionProfile{
					ProfileWatch: {Policy: "emisar-watch"},
					ProfileChat:  {Policy: "emisar-chat"},
				},
			},
		},
		RepositorySets: map[string]RepositorySet{
			"platform": {
				DisplayName: "Platform", Primary: "emisar",
				CoopPolicy: "platform-observe",
				Profiles:   map[string]SessionProfile{ProfileWatch: {Policy: "platform-watch"}},
			},
		},
	}
	set, ok := cfg.RepositoryContext("platform")
	if !ok {
		t.Fatal("the repository set did not resolve")
	}
	if got := set.SessionProfilePolicy(ProfileWatch, "platform-observe"); got != "platform-watch" {
		t.Errorf("the set's watch profile resolved to %q, want platform-watch", got)
	}
	if got := set.SessionProfilePolicy(ProfileChat, "platform-observe"); got != "emisar-chat" {
		t.Errorf("the set dropped the inherited chat profile: %q", got)
	}
	if got := set.SessionProfilePolicy(ProfileEngineer, "platform-contributor"); got != "platform-contributor" {
		t.Errorf("an unconfigured profile resolved to %q, want the lane policy", got)
	}
	repository, _ := cfg.RepositoryContext("emisar")
	if got := repository.SessionProfilePolicy(ProfileWatch, "emisar-observe"); got != "emisar-watch" {
		t.Errorf("resolving the set rewrote the repository's own watch profile: %q", got)
	}
}

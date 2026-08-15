package app

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/repomirror"
	"gopkg.in/yaml.v3"
)

// managedConfig is one slug-declared repository with all three policy kinds.
func managedConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := config.Config{StateDir: t.TempDir()}
	cfg.Coop.Policies = filepath.Join(t.TempDir(), "session-policies.yaml")
	cfg.Slack.DefaultRepository = "backend"
	cfg.Repositories = map[string]config.Repository{
		"backend": {
			DisplayName:        "Backend",
			CoopPolicy:         "backend-observe",
			ContributorPolicy:  "backend-contributor",
			ConversationPolicy: "backend-conversation",
			GitHub:             "example/backend",
		},
	}
	return cfg
}

// A generated session policy names the clone Coop can actually fork from.
//
// Coop validates a policy repository with realGitRepository: the
// EvalSymlinks-real path must equal `rev-parse --show-toplevel`. A generated
// policy naming the unresolved path fails at session creation with a message
// mentioning neither the symlink nor the policy — and on macOS this is not
// hypothetical, because /var is a symlink to /private/var and a state directory
// under either spells the same clone two ways.
func TestGeneratedSessionPoliciesNameTheRealClonePath(t *testing.T) {
	cfg := managedConfig(t)
	clone, err := repomirror.Path(repomirror.Root(cfg.StateDir), "example/backend")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(clone, 0o700); err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(clone)
	if err != nil {
		t.Fatal(err)
	}

	body, err := generateSessionPolicies(cfg, map[string]string{"example/backend": real})
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Version  int `yaml:"version"`
		Policies map[string]struct {
			Repository      string `yaml:"repository"`
			Target          string `yaml:"target"`
			MaxTurns        int    `yaml:"max_turns"`
			WarmIdleTimeout string `yaml:"warm_idle_timeout"`
		} `yaml:"policies"`
	}
	if err := yaml.Unmarshal(body, &file); err != nil {
		t.Fatalf("generated policies do not parse: %v\n%s", err, body)
	}
	if file.Version != 1 {
		t.Fatalf("generated policies version = %d", file.Version)
	}
	for _, name := range []string{"backend-observe", "backend-contributor", "backend-conversation"} {
		policy, ok := file.Policies[name]
		if !ok {
			t.Fatalf("policy %q was not generated:\n%s", name, body)
		}
		if policy.Repository != real {
			t.Fatalf("policy %q names %q, want the real clone path %q", name, policy.Repository, real)
		}
		if policy.Target == "" || policy.MaxTurns == 0 {
			t.Fatalf("policy %q is not usable as written: %+v", name, policy)
		}
	}
	// Conversation prewarming refuses to start without a positive
	// warm_idle_timeout and names this file in the refusal, so a generated file
	// that omitted it would fail the very next startup on its own output.
	if file.Policies["backend-conversation"].WarmIdleTimeout == "" {
		t.Fatal("the generated conversation policy has no warm_idle_timeout")
	}
	if file.Policies["backend-observe"].WarmIdleTimeout != "" {
		t.Fatal("a non-conversation policy was given a warm idle lease it does not need")
	}
	cfg.Coop.PrewarmSessions = 4
	if err := os.WriteFile(cfg.Coop.Policies, body, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := validateConversationPrewarmPolicies(cfg); err != nil {
		t.Fatalf("Responder's own generated policies fail its startup check: %v", err)
	}
}

// An explicit policies file wins, and is never edited.
//
// The live deployments' file is 13 KB of hand-tuned targets, fallback ladders,
// companion mounts and warm-idle leases. Regenerating it from a template to
// correct a path would throw all of that away, and rewriting one field inside
// it is a YAML round-trip against a file whose schema Coop owns. So bootstrap
// reports the exact change and leaves the file alone.
func TestAnExplicitPoliciesFileIsReportedOnRatherThanRewritten(t *testing.T) {
	cfg := managedConfig(t)
	clone, err := repomirror.RepositoryPath(cfg.StateDir, cfg.Repositories["backend"])
	if err != nil {
		t.Fatal(err)
	}
	existing := `version: 1
policies:
  backend-observe:
    repository: /srv/repos/backend
    target: [codex:gpt-5.6/medium@oncall, claude@oncall]
    companions:
      - name: shared
        repository: /srv/repos/shared
    max_turns: 100
  backend-contributor:
    repository: ` + clone + `
    target: codex:gpt-5.6/medium@oncall
    max_turns: 100
`
	if err := os.WriteFile(cfg.Coop.Policies, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	if err := writeSessionPolicies(cfg, nil, &stdout); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != existing {
		t.Fatalf("Responder rewrote an operator's policies file:\n%s", after)
	}
	report := stdout.String()
	// The one that points at a hand-maintained checkout is named, with the
	// value to put there — an operator cannot act on "some policy is wrong".
	if !strings.Contains(report, "backend-observe") || !strings.Contains(report, clone) {
		t.Fatalf("the stale policy and its correct path were not both reported:\n%s", report)
	}
	// The one that is already correct is not, and neither is anything about a
	// repository nobody declared by slug.
	if strings.Contains(report, "backend-contributor") {
		t.Fatalf("a policy that already names the clone was reported as needing a change:\n%s", report)
	}
	// A policy the configuration binds but the file never defines is a session
	// that fails at creation, so it is named too.
	if !strings.Contains(report, "backend-conversation") {
		t.Fatalf("a bound policy missing from the file was not reported:\n%s", report)
	}
}

// A deployment with no slug repositories is untouched: this must be a no-op
// deploy before it is a migration.
func TestNothingIsGeneratedForAPathOnlyDeployment(t *testing.T) {
	cfg := managedConfig(t)
	cfg.Repositories = map[string]config.Repository{
		"backend": {CoopPolicy: "backend-observe", Path: "/srv/repos/backend"},
	}
	var stdout bytes.Buffer
	if err := writeSessionPolicies(cfg, nil, &stdout); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(cfg.Coop.Policies); !os.IsNotExist(err) {
		t.Fatalf("a policies file was written for a deployment with no managed repositories: %v", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("a path-only deployment was told something: %s", stdout.String())
	}
}

// Generation runs once. Responder writes a starting file and then the file is
// the operator's; a later bootstrap that regenerated it would silently discard
// whatever they had set since.
func TestGenerationNeverOverwritesAFileItAlreadyWrote(t *testing.T) {
	cfg := managedConfig(t)
	var stdout bytes.Buffer
	if err := writeSessionPolicies(cfg, nil, &stdout); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		t.Fatal(err)
	}
	// The operator sets a real target, which is what the generated file tells
	// them to do.
	edited := strings.ReplaceAll(
		string(first), policyDefaultTarget, "codex:gpt-5.6-sol/xhigh@oncall",
	)
	if err := os.WriteFile(cfg.Coop.Policies, []byte(edited), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeSessionPolicies(cfg, nil, &stdout); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != edited {
		t.Fatalf("a second bootstrap discarded the operator's targets:\n%s", after)
	}
}

// A profile policy is a policy: bootstrap writes it, and review names it when
// it is missing.
//
// Left out of this list, a deployment that routes its watch lane to a cheaper
// rung gets a policy nothing generates and nothing checks — and finds out at
// session creation, in a channel, with a message naming neither the profile nor
// the file. The conversation lane's own policy follows the chat profile for the
// same reason: prewarming refuses to start unless that exact policy sets a
// warm_idle_timeout, so the generated file has to know which one the lane will
// ask for.
func TestAProfilePolicyIsGeneratedAndReviewedLikeEveryOtherPolicy(t *testing.T) {
	cfg := managedConfig(t)
	repository := cfg.Repositories["backend"]
	repository.Profiles = map[string]config.SessionProfile{
		config.ProfileWatch: {Policy: "backend-watch"},
		config.ProfileChat:  {Policy: "backend-chat"},
	}
	cfg.Repositories["backend"] = repository

	if err := writeSessionPolicies(cfg, nil, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Policies map[string]struct {
			Repository      string `yaml:"repository"`
			WarmIdleTimeout string `yaml:"warm_idle_timeout"`
		} `yaml:"policies"`
	}
	if err := yaml.Unmarshal(body, &file); err != nil {
		t.Fatalf("generated policies do not parse: %v\n%s", err, body)
	}
	for _, name := range []string{"backend-watch", "backend-chat"} {
		if _, ok := file.Policies[name]; !ok {
			t.Fatalf("profile policy %q was not generated:\n%s", name, body)
		}
	}
	// The bounded lane runs under the chat profile's policy now, so that is the
	// one that has to carry the timeout prewarming demands.
	if file.Policies["backend-chat"].WarmIdleTimeout == "" {
		t.Fatalf("the routed conversation policy has no warm_idle_timeout:\n%s", body)
	}

	// Reviewing an operator's own file names the profile policy it lacks.
	if err := os.WriteFile(cfg.Coop.Policies, []byte("version: 1\npolicies: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	if err := writeSessionPolicies(cfg, nil, &stdout); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), "backend-watch") {
		t.Fatalf("a routed profile policy missing from the file was not reported:\n%s",
			stdout.String())
	}
}

// The policies file holds every host path this deployment reads code from, and
// is written owner-private like everything else bootstrap projects.
func TestGeneratedPoliciesAreOwnerPrivate(t *testing.T) {
	cfg := managedConfig(t)
	if err := writeSessionPolicies(cfg, nil, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(cfg.Coop.Policies)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("generated policies have mode %o, want 0600", mode)
	}
}

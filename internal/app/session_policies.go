package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/repomirror"
	"gopkg.in/yaml.v3"
)

// Session policies name the host directory Coop forks from, and until slugs
// existed that directory was one an operator cloned and pulled by hand.
//
// bootstrap-coop now does two things about that. It makes sure every repository
// declared by slug actually has a clone — the first bootstrap is where a clone
// comes from — and it writes a starting session-policies file pointing at those
// clones when there is no policies file yet.
//
// An explicit policies file WINS, always. The shipped file is 13 KB of
// hand-tuned targets, fallback ladders, companions and warm-idle timeouts on
// the live deployments, and regenerating it from a template would throw all of
// that away to fix a path. When one is present, bootstrap reports every slug
// repository whose policy names something other than the resolved clone, and
// prints the exact value to put there. That is a cutover an operator makes once
// and can check, rather than a rewrite they have to trust.

// policyDefaults mirror the shipped session-policies example. A generated file
// has to be immediately usable, and these are the bounds that example ships.
const (
	policyMaxTurns        = 100
	policyMaxQueuedTurns  = 20
	policyMaxQueuedBytes  = 1048576
	policyTurnTimeout     = "1h"
	policyMaxPatchBytes   = 1048576
	policyWarmIdleTimeout = "15m"
	// policyDefaultTarget pins no credential. Coop runs it on the provider's
	// default account, and `responder doctor` names the exact `coop login` when
	// there is not one — which is a better first run than a generated file
	// referring to an account this deployment has never heard of.
	policyDefaultTarget = "codex:gpt-5.6/medium"
)

// ensureManagedRepositories clones every slug-declared repository that is not
// there yet, and returns the resolved host path for each one.
//
// Clone-on-bootstrap rather than clone-on-first-incident: this command is an
// operator running something and waiting, which is the right place for a
// multi-gigabyte download. The prepare path only ever fetches.
func ensureManagedRepositories(
	ctx context.Context,
	cfg config.Config,
	stdout io.Writer,
	logger *slog.Logger,
) (map[string]string, error) {
	slugs := repomirror.Slugs(cfg)
	if len(slugs) == 0 {
		return nil, nil
	}
	mirrors := repomirror.New(cfg, logger, repomirror.WithToken(
		func(ctx context.Context) (string, error) {
			return publisher.Token(ctx, cfg.GitHub)
		},
	))
	paths := make(map[string]string, len(slugs))
	for _, slug := range slugs {
		status, err := mirrors.Ensure(ctx, slug)
		if err != nil {
			return nil, fmt.Errorf(
				"prepare the managed clone for %s (%s): %w",
				slug, repomirror.Classify(err), err,
			)
		}
		resolved, err := filepath.EvalSymlinks(status.Path)
		if err != nil {
			return nil, fmt.Errorf("resolve the managed clone for %s: %w", slug, err)
		}
		paths[slug] = resolved
		fmt.Fprintf(stdout, "Managed clone %-40s %s\n", slug, resolved)
	}
	return paths, nil
}

// policyRepositoryPaths reads the repository each policy names, loosely.
//
// Only the one field, and tolerant of everything else: Coop owns this file's
// schema, and a field it gains must not stop Responder from starting or from
// checking the one thing it does care about.
func policyRepositoryPaths(data []byte) (map[string]string, error) {
	var file struct {
		Policies map[string]struct {
			Repository string `yaml:"repository"`
		} `yaml:"policies"`
	}
	if err := yaml.Unmarshal(data, &file); err != nil {
		return nil, fmt.Errorf("parse session policies: %w", err)
	}
	paths := make(map[string]string, len(file.Policies))
	for name, policy := range file.Policies {
		paths[name] = strings.TrimSpace(policy.Repository)
	}
	return paths, nil
}

// repositoryPolicyNames lists the policies a repository context binds, with the
// host path each of them must name.
func repositoryPolicyNames(cfg config.Config) (map[string]string, error) {
	wanted := make(map[string]string)
	for _, key := range cfg.RepositoryContextKeys() {
		repository, ok := cfg.RepositoryContext(key)
		if !ok || !repository.Managed() {
			continue
		}
		path, err := repomirror.RepositoryPath(cfg.StateDir, repository)
		if err != nil {
			return nil, err
		}
		for _, policy := range []string{
			repository.CoopPolicy, repository.ContributorPolicy, repository.ConversationPolicy,
		} {
			if name := strings.TrimSpace(policy); name != "" {
				wanted[name] = path
			}
		}
	}
	return wanted, nil
}

// generateSessionPolicies renders a starting policies file for the managed
// repositories in cfg.
func generateSessionPolicies(cfg config.Config, paths map[string]string) ([]byte, error) {
	wanted, err := repositoryPolicyNames(cfg)
	if err != nil {
		return nil, err
	}
	if len(wanted) == 0 {
		return nil, nil
	}
	// Prefer the freshly resolved clone path over the one derived from
	// configuration: after a first clone they are the same, and before one the
	// derived path is the only answer there is.
	for _, key := range cfg.RepositoryContextKeys() {
		repository, ok := cfg.RepositoryContext(key)
		if !ok || !repository.Managed() {
			continue
		}
		resolved, cloned := paths[strings.TrimSpace(repository.GitHub)]
		if !cloned {
			continue
		}
		for _, policy := range []string{
			repository.CoopPolicy, repository.ContributorPolicy, repository.ConversationPolicy,
		} {
			if name := strings.TrimSpace(policy); name != "" {
				wanted[name] = resolved
			}
		}
	}
	conversation := make(map[string]bool)
	for _, key := range cfg.RepositoryContextKeys() {
		if repository, ok := cfg.RepositoryContext(key); ok {
			if name := strings.TrimSpace(repository.ConversationPolicy); name != "" {
				conversation[name] = true
			}
		}
	}

	names := make([]string, 0, len(wanted))
	for name := range wanted {
		names = append(names, name)
	}
	sort.Strings(names)

	var body strings.Builder
	body.WriteString("version: 1\n")
	body.WriteString("# Generated by `responder bootstrap-coop` because no session policies file\n")
	body.WriteString("# existed yet. Every `repository:` below is a Responder-managed clone, kept\n")
	body.WriteString("# current by the maintenance lane; do not point one at a hand-maintained\n")
	body.WriteString("# checkout, and do not edit inside a clone.\n")
	body.WriteString("#\n")
	body.WriteString("# `target:` is a starting value that pins no account. Set the provider,\n")
	body.WriteString("# model and @credential this deployment uses — `target:` also takes an\n")
	body.WriteString("# ordered fallback ladder — and run `responder doctor`, which checks that\n")
	body.WriteString("# every rung is signed in.\n")
	body.WriteString("#\n")
	body.WriteString("# This file is yours from now on. Responder writes it once and never\n")
	body.WriteString("# again; a later bootstrap only reports paths that no longer match.\n")
	body.WriteString("policies:\n")
	for _, name := range names {
		fmt.Fprintf(&body, "  %s:\n", name)
		fmt.Fprintf(&body, "    repository: %s\n", wanted[name])
		fmt.Fprintf(&body, "    target: %s\n", policyDefaultTarget)
		fmt.Fprintf(&body, "    max_turns: %d\n", policyMaxTurns)
		fmt.Fprintf(&body, "    max_queued_turns: %d\n", policyMaxQueuedTurns)
		fmt.Fprintf(&body, "    max_queued_bytes: %d\n", policyMaxQueuedBytes)
		fmt.Fprintf(&body, "    turn_timeout: %s\n", policyTurnTimeout)
		if conversation[name] {
			// Conversation prewarming refuses to start without one, and the
			// refusal names this file — so a generated file that omitted it
			// would fail the next startup on its own output.
			fmt.Fprintf(&body, "    warm_idle_timeout: %s\n", policyWarmIdleTimeout)
		}
		fmt.Fprintf(&body, "    max_patch_bytes: %d\n", policyMaxPatchBytes)
		body.WriteString("\n")
	}
	return []byte(body.String()), nil
}

// reviewSessionPolicies reports every managed repository whose existing policy
// does not name its clone.
//
// Reported, not corrected. This file is the operator's, and the failure mode of
// rewriting it is losing a ladder or a companion mount to fix a path.
func reviewSessionPolicies(cfg config.Config, data []byte) ([]string, error) {
	wanted, err := repositoryPolicyNames(cfg)
	if err != nil {
		return nil, err
	}
	if len(wanted) == 0 {
		return nil, nil
	}
	actual, err := policyRepositoryPaths(data)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(wanted))
	for name := range wanted {
		names = append(names, name)
	}
	sort.Strings(names)

	var findings []string
	for _, name := range names {
		path := wanted[name]
		current, defined := actual[name]
		switch {
		case !defined:
			findings = append(findings, fmt.Sprintf(
				"policy %q is not defined; add it with `repository: %s`", name, path,
			))
		case current != path:
			findings = append(findings, fmt.Sprintf(
				"policy %q names %s; the Responder-managed clone is %s", name, current, path,
			))
		}
	}
	return findings, nil
}

// writeSessionPolicies generates the policies file when there is not one, and
// reviews it when there is.
func writeSessionPolicies(
	cfg config.Config,
	paths map[string]string,
	stdout io.Writer,
) error {
	path := strings.TrimSpace(cfg.Coop.Policies)
	if path == "" {
		return nil
	}
	existing, err := os.ReadFile(path)
	switch {
	case err == nil:
		findings, reviewErr := reviewSessionPolicies(cfg, existing)
		if reviewErr != nil {
			return reviewErr
		}
		if len(findings) == 0 {
			return nil
		}
		fmt.Fprintf(stdout, "\n%s needs %d change(s) before managed clones are in use:\n", path, len(findings))
		for _, finding := range findings {
			fmt.Fprintf(stdout, "  - %s\n", finding)
		}
		fmt.Fprintln(stdout, "Responder did not edit this file; its targets and companions are yours.")
		return nil
	case !errors.Is(err, os.ErrNotExist):
		return fmt.Errorf("read session policies: %w", err)
	}
	body, err := generateSessionPolicies(cfg, paths)
	if err != nil || body == nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if err := atomicPrivateWrite(path, body); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Wrote session policies for the managed clones to %s\n", path)
	fmt.Fprintln(stdout, "Set each policy's target before starting Coop; `responder doctor` checks them.")
	return nil
}

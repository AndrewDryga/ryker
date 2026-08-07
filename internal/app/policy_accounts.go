package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/config"
	"gopkg.in/yaml.v3"
)

// Session policies name a model account per policy. Nothing verifies those
// accounts exist until a session is needed, and by then the error says only
// "ACP request was rejected" — naming neither the account nor the fix.
//
// On 2026-08-07 both deployments targeted `codex:...@oncall` while codex had
// only a `personal` account. The running Coop kept serving sessions it already
// held, so the service looked healthy while every fresh session was refused,
// and it would have become a full outage at the next restart, discovered by
// the restart.
//
// This is reported by doctor rather than enforced at startup: a running
// instance still works, so refusing to start would turn a partial failure into
// a total one.
//
// A stale `agents/<agent>/profiles/<account>/` directory in the state directory
// is not evidence the account exists — that is what made the original
// diagnosis take three wrong turns. Coop's own credential list is the source of
// truth, so that is what this asks.

// policyTargetPattern pulls the agent and account out of ONE session policy
// target such as `codex:gpt-5.6-sol/xhigh@oncall`. The model and effort in the
// middle are deliberately not captured: an unknown model fails loudly on first
// use with a message naming it, whereas a missing account does not.
var policyTargetPattern = regexp.MustCompile(`^([a-z0-9_-]+)[^@\s]*@([a-z0-9_-]+)$`)

// policyTargets collects every credential named by every policy's `target:`.
//
// This reads the YAML rather than matching lines because `target:` now takes a
// fallback ladder as well as a single target, in flow or block form. A
// line-anchored regex matches NOTHING on a list — and finding no targets is
// indistinguishable from finding no problems, so the check would pass while
// vouching for nothing. That silent pass is the exact failure this file exists
// to prevent, one level up.
//
// Only the one field is read, loosely: Coop's parser owns that file's schema,
// and a field added there must not stop Responder from starting.
func policyTargets(data []byte) (map[string]map[string]bool, error) {
	var file struct {
		Policies map[string]struct {
			Target yaml.Node `yaml:"target"`
		} `yaml:"policies"`
	}
	if err := yaml.Unmarshal(data, &file); err != nil {
		return nil, fmt.Errorf("parse session policies: %w", err)
	}
	wanted := map[string]map[string]bool{}
	for name, policy := range file.Policies {
		rungs, err := policyTargetRungs(&policy.Target)
		if err != nil {
			return nil, fmt.Errorf("policy %q: %w", name, err)
		}
		for _, rung := range rungs {
			match := policyTargetPattern.FindStringSubmatch(rung)
			if match == nil {
				// A rung with no @credential runs on that provider's default,
				// which Coop resolves when it loads the policy. There is no
				// name here to check, so there is nothing to vouch for.
				continue
			}
			if wanted[match[1]] == nil {
				wanted[match[1]] = map[string]bool{}
			}
			wanted[match[1]][match[2]] = true
		}
	}
	return wanted, nil
}

// policyTargetRungs reads a `target:` as either one target or an ordered ladder.
func policyTargetRungs(node *yaml.Node) ([]string, error) {
	switch node.Kind {
	case yaml.ScalarNode:
		return []string{strings.TrimSpace(node.Value)}, nil
	case yaml.SequenceNode:
		rungs := make([]string, 0, len(node.Content))
		for index, item := range node.Content {
			if item.Kind != yaml.ScalarNode {
				return nil, fmt.Errorf("target[%d] is not a target", index)
			}
			rungs = append(rungs, strings.TrimSpace(item.Value))
		}
		return rungs, nil
	case 0:
		// Coop requires a target and rejects the file without one. Responder
		// does not re-litigate its schema.
		return nil, nil
	default:
		return nil, errors.New("target must be a target or a list of targets")
	}
}

// accountLister reports which accounts an agent has signed in.
type accountLister func(ctx context.Context, agent string) ([]string, error)

// coopAccountLister asks the coop binary, which owns the credential store.
func coopAccountLister(cfg config.Config) accountLister {
	return func(ctx context.Context, agent string) ([]string, error) {
		command := exec.CommandContext(ctx, cfg.Coop.Binary, "credentials", agent)
		// Credentials are per-deployment, not global. Coop reads them from
		// COOP_CONFIG_DIR, and without it this asks about a completely
		// different credential store — one where the deployment's accounts do
		// not appear and unrelated ones do.
		//
		// This check shipped without it and immediately reported a signed-in
		// account as missing. The same mistake, made by hand, sent a day of
		// diagnosis chasing an account that was signed in the whole time.
		command.Env = append(
			os.Environ(),
			"COOP_CONFIG_DIR="+filepath.Join(cfg.Coop.StateDir, "agents"),
		)
		output, err := command.Output()
		if err != nil {
			return nil, fmt.Errorf("list %s accounts: %w", agent, err)
		}
		return parseCoopAccounts(string(output)), nil
	}
}

// parseCoopAccounts reads `coop credentials <agent>` output.
//
// The format is an agent heading followed by indented account lines:
//
//	codex
//	  personal  signed in  rotated 6d ago  (default)
//
// Only signed-in accounts count. An account listed but not signed in fails the
// same way at session time, so treating it as present would defeat the check.
func parseCoopAccounts(output string) []string {
	var accounts []string
	for _, line := range strings.Split(output, "\n") {
		if strings.TrimSpace(line) == "" || !strings.HasPrefix(line, " ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 || !strings.Contains(line, "signed in") {
			continue
		}
		accounts = append(accounts, fields[0])
	}
	return accounts
}

// validatePolicyAccounts checks every account named by a policy target.
func validatePolicyAccounts(
	ctx context.Context,
	cfg config.Config,
	accountsFor accountLister,
) error {
	if !cfg.Coop.Supervise || strings.TrimSpace(cfg.Coop.Policies) == "" {
		// Someone else supervises Coop, so its credential store is not this
		// process's to vouch for.
		return nil
	}
	policies, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		return fmt.Errorf("read session policies: %w", err)
	}
	wanted, err := policyTargets(policies)
	if err != nil {
		return err
	}

	var missing []string
	for agent, accounts := range wanted {
		available, err := accountsFor(ctx, agent)
		if err != nil {
			return err
		}
		signedIn := map[string]bool{}
		for _, account := range available {
			signedIn[account] = true
		}
		for account := range accounts {
			if !signedIn[account] {
				missing = append(missing, agent+"@"+account)
			}
		}
	}
	if len(missing) == 0 {
		return nil
	}
	sort.Strings(missing)
	remedies := make([]string, 0, len(missing))
	for _, target := range missing {
		remedies = append(remedies, "coop login "+target)
	}
	return fmt.Errorf(
		"session policies name %d account(s) that are not signed in: %s.\n"+
			"Every new model session will be refused with \"ACP request was "+
			"rejected\", which names neither the account nor the fix.\n"+
			"Sign in with: %s",
		len(missing), strings.Join(missing, ", "), strings.Join(remedies, " && "),
	)
}

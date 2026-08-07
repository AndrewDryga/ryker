package app

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/config"
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

// policyTargetPattern pulls the agent and account out of a session policy
// target such as `codex:gpt-5.6-sol/xhigh@oncall`. The model and effort in the
// middle are deliberately not captured: an unknown model fails loudly on first
// use with a message naming it, whereas a missing account does not.
var policyTargetPattern = regexp.MustCompile(
	`(?m)^\s*target:\s*([a-z0-9_-]+)[^@\s]*@([a-z0-9_-]+)\s*$`,
)

// accountLister reports which accounts an agent has signed in.
type accountLister func(ctx context.Context, agent string) ([]string, error)

// coopAccountLister asks the coop binary, which owns the credential store.
func coopAccountLister(cfg config.Config) accountLister {
	return func(ctx context.Context, agent string) ([]string, error) {
		output, err := exec.CommandContext(
			ctx, cfg.Coop.Binary, "credentials", agent,
		).Output()
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
	wanted := map[string]map[string]bool{}
	for _, match := range policyTargetPattern.FindAllStringSubmatch(string(policies), -1) {
		agent, account := match[1], match[2]
		if wanted[agent] == nil {
			wanted[agent] = map[string]bool{}
		}
		wanted[agent][account] = true
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

package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
)

// The exact output shape coop produces, so the parser is tested against the
// real thing rather than a convenient invention.
const coopCredentialsOutput = `codex
  personal  signed in          rotated 6d ago  (default)
  retired   needs sign-in      rotated 90d ago
`

func policiesFile(t *testing.T, body string) config.Config {
	t.Helper()
	path := filepath.Join(t.TempDir(), "session-policies.yaml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	var cfg config.Config
	cfg.Coop.Supervise = true
	cfg.Coop.Policies = path
	cfg.Coop.Binary = "coop"
	return cfg
}

// An account a policy names but nobody signed in must stop startup.
//
// This is the failure it exists to prevent: on 2026-08-07 both deployments
// targeted codex@oncall while codex had only personal. The running Coop kept
// serving from state it already held, so nothing looked wrong, and every new
// session was refused with "ACP request was rejected" — which names neither the
// account nor the fix. The next restart would have been a total outage.
func TestMissingPolicyAccountStopsStartup(t *testing.T) {
	cfg := policiesFile(t, "policies:\n  a:\n    target: codex:gpt-5.6-sol/xhigh@oncall\n")
	err := validatePolicyAccounts(context.Background(), cfg,
		func(context.Context, string) ([]string, error) {
			return parseCoopAccounts(coopCredentialsOutput), nil
		})
	if err == nil {
		t.Fatal("a policy naming an account nobody signed in was accepted")
	}
	for _, want := range []string{"codex@oncall", "coop login codex@oncall"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error does not carry %q: %v", want, err)
		}
	}
}

// An account that is signed in must not stop startup, or every deployment
// fails to boot.
func TestSignedInPolicyAccountIsAccepted(t *testing.T) {
	cfg := policiesFile(t, "policies:\n  a:\n    target: codex:gpt-5.6-sol/xhigh@personal\n")
	if err := validatePolicyAccounts(context.Background(), cfg,
		func(context.Context, string) ([]string, error) {
			return parseCoopAccounts(coopCredentialsOutput), nil
		}); err != nil {
		t.Fatalf("a signed-in account was rejected: %v", err)
	}
}

// An account that exists but needs sign-in is as broken as one that is absent:
// it fails the same way at session time.
func TestAccountNeedingSignInIsTreatedAsMissing(t *testing.T) {
	cfg := policiesFile(t, "policies:\n  a:\n    target: codex:gpt-5.6-sol/xhigh@retired\n")
	err := validatePolicyAccounts(context.Background(), cfg,
		func(context.Context, string) ([]string, error) {
			return parseCoopAccounts(coopCredentialsOutput), nil
		})
	if err == nil {
		t.Fatal("an account listed as needing sign-in was accepted as usable")
	}
}

// Not supervising Coop means its credential store belongs to someone else.
func TestUnsupervisedCoopIsNotVouchedFor(t *testing.T) {
	cfg := policiesFile(t, "policies:\n  a:\n    target: codex:gpt-5.6-sol/xhigh@absent\n")
	cfg.Coop.Supervise = false
	if err := validatePolicyAccounts(context.Background(), cfg,
		func(context.Context, string) ([]string, error) { return nil, nil }); err != nil {
		t.Fatalf("checked a Coop this process does not supervise: %v", err)
	}
}

// Every distinct account across every policy is reported, not just the first.
func TestAllMissingAccountsAreNamed(t *testing.T) {
	cfg := policiesFile(t, `policies:
  a:
    target: codex:gpt-5.6-sol/xhigh@oncall
  b:
    target: codex:gpt-5.6-terra/low@relief
  c:
    target: codex:gpt-5.6-sol/xhigh@personal
`)
	err := validatePolicyAccounts(context.Background(), cfg,
		func(context.Context, string) ([]string, error) {
			return parseCoopAccounts(coopCredentialsOutput), nil
		})
	if err == nil {
		t.Fatal("missing accounts were accepted")
	}
	for _, want := range []string{"codex@oncall", "codex@relief"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error omits %q, so a second fix would be found only after the first: %v", want, err)
		}
	}
	if strings.Contains(err.Error(), "codex@personal") {
		t.Fatalf("a signed-in account was reported as missing: %v", err)
	}
}

package app

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
)

// preflightConfig is a configuration that passes every check whose dependency
// is local, with the remote ones pointed at test servers by the caller.
func preflightConfig(t *testing.T) config.Config {
	t.Helper()
	t.Setenv("PREFLIGHT_BOT_TOKEN", "xoxb-preflight-bot-token")
	t.Setenv("PREFLIGHT_APP_TOKEN", "xapp-preflight-app-token")
	t.Setenv("PREFLIGHT_EMISAR_TOKEN", "emk-preflight-emisar-token")

	var cfg config.Config
	cfg.StateDir = filepath.Join(t.TempDir(), "state")
	cfg.Slack.BotTokenEnv = "PREFLIGHT_BOT_TOKEN"
	cfg.Slack.AppTokenEnv = "PREFLIGHT_APP_TOKEN"
	cfg.Coop.EmisarTokenEnv = "PREFLIGHT_EMISAR_TOKEN"
	cfg.Coop.RequestTimeout.Duration = 5 * 1e9
	return cfg
}

// Each check must be exercisable on its own. Before this, they were statements
// inside a 160-line function that also opened a database, acquired a process
// lock and probed a listening port — so none of them had a test, and doctor's
// copy silently diverged from serve's.
func TestEachPreflightCheckRunsOnItsOwn(t *testing.T) {
	ctx := context.Background()

	t.Run("prewarm policies reject an unknown policy", func(t *testing.T) {
		cfg := preflightConfig(t)
		cfg.Coop.PrewarmSessions = 1
		cfg.Coop.Policies = ""
		err := newPreflight(cfg).checkPrewarmPolicies(ctx)
		if err == nil || !strings.Contains(err.Error(), "policies file") {
			t.Fatalf("error = %v, want prewarming to require a policies file", err)
		}
	})

	t.Run("runtime secrets fail closed", func(t *testing.T) {
		cfg := preflightConfig(t)
		t.Setenv("PREFLIGHT_EMISAR_TOKEN", "")
		if err := newPreflight(cfg).checkRuntimeSecrets(ctx); err == nil {
			t.Fatal("preflight accepted a missing Emisar token")
		}
	})

	t.Run("state directory is created private", func(t *testing.T) {
		cfg := preflightConfig(t)
		if err := newPreflight(cfg).checkStateDirectory(ctx); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(cfg.StateDir)
		if err != nil {
			t.Fatal(err)
		}
		if mode := info.Mode().Perm(); mode != 0o700 {
			t.Fatalf("state directory mode = %o, want 700", mode)
		}
	})

	t.Run("Emisar MCP failure names the dependency", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusUnauthorized)
		}))
		defer server.Close()
		cfg := preflightConfig(t)
		cfg.Coop.EmisarURL = server.URL

		pre := newPreflight(cfg)
		if err := pre.checkRuntimeSecrets(ctx); err != nil {
			t.Fatal(err)
		}
		if err := pre.checkEmisarMCP(ctx); err == nil {
			t.Fatal("preflight accepted an Emisar endpoint that rejected its credential")
		}
	})
}

// The sequence stops at the first failure, because a later check depends on an
// earlier one having succeeded: reaching Emisar needs the token that
// authenticates to it. Running on would report a cascade of failures that all
// have one cause.
func TestPreflightStopsAtTheFirstFailureAndNamesIt(t *testing.T) {
	cfg := preflightConfig(t)
	cfg.Coop.PrewarmSessions = 1
	cfg.Coop.Policies = ""

	pre := newPreflight(cfg)
	err := pre.run(context.Background())
	if err == nil {
		t.Fatal("preflight passed with an invalid prewarm policy")
	}
	if !strings.HasPrefix(err.Error(), "conversation prewarm policies: ") {
		t.Fatalf("error = %q, want the failing check named first", err)
	}
	if pre.botToken != "" {
		t.Fatal("preflight loaded secrets after an earlier check had already failed")
	}
	if _, statErr := os.Stat(cfg.StateDir); statErr == nil {
		t.Fatal("preflight created the state directory after an earlier check had failed")
	}
}

// Every secret the process holds must be registered for redaction. This is the
// bug the shared preflight exists to prevent: serve assembled this list inline
// and doctor did not assemble it at all, so a GitHub failure printed by doctor
// could quote a token that serve would have redacted.
func TestPreflightRedactsEverySecretItLoads(t *testing.T) {
	cfg := preflightConfig(t)
	cfg.Webhooks = map[string]config.Webhook{
		"grafana": {Name: "grafana", SecretEnv: "PREFLIGHT_HOOK_SECRET"},
	}
	cfg.GitHub.TokenEnv = "PREFLIGHT_GITHUB_TOKEN"
	t.Setenv("PREFLIGHT_HOOK_SECRET", "grafana-webhook-secret")
	t.Setenv("PREFLIGHT_GITHUB_TOKEN", "ghp-preflight-github-token")

	pre := newPreflight(cfg)
	if err := pre.checkRuntimeSecrets(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{
		"xoxb-preflight-bot-token",
		"xapp-preflight-app-token",
		"emk-preflight-emisar-token",
		"grafana-webhook-secret",
		"ghp-preflight-github-token",
	} {
		if !slices.Contains(pre.redactions, secret) {
			t.Fatalf("secret %q is held by the process but not registered for redaction", secret)
		}
	}
}

// Serve and doctor deliberately differ, and the difference is worth pinning:
// doctor proves a box can start and checks the projected bootstrap files even
// when Responder does not supervise Coop, while serve repairs a missing image
// rather than refusing to start over something it can fix. Anything else they
// disagree on is drift.
func TestServeAndDoctorShareTheSameCoreChecks(t *testing.T) {
	pre := newPreflight(preflightConfig(t))
	var names []string
	for _, check := range pre.checks() {
		names = append(names, check.name)
	}
	want := []string{
		"conversation prewarm policies",
		"runtime secrets",
		"Emisar MCP",
		"GitHub publisher",
		"state directory",
	}
	if !slices.Equal(names, want) {
		t.Fatalf("shared checks = %v, want %v", names, want)
	}
	if name := pre.managedCoopImageCheck().name; name != "managed Coop image" {
		t.Fatalf("doctor-only check = %q", name)
	}
	if slices.Contains(names, pre.managedCoopImageCheck().name) {
		t.Fatal("serve would now refuse to start over an image it repairs on demand")
	}
	if slices.Contains(names, pre.coopBootstrapCheck().name) {
		t.Fatal("the bootstrap check is caller-specific and must not be in the shared core")
	}
}

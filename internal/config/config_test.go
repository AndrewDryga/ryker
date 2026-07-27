package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoadStrictDefaultsAndRoutes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "responder.yaml")
	body := `version: 1
listen: 127.0.0.1:8080
state_dir: state
slack:
  team_id: T123ABC
  default_repository: emisar
  operators: [U123ABC]
  invite_users: [U123ABC]
  summon_channels: [C123ABC]
coop: {}
repositories:
  emisar:
    display_name: Emisar
    coop_policy: emisar-observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: emisar
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(cfg.StateDir) || !strings.HasSuffix(cfg.StateDir, "/state") {
		t.Fatalf("state dir = %q", cfg.StateDir)
	}
	if cfg.Webhooks["grafana"].CorrelationWindow.Duration != 2*time.Hour {
		t.Fatalf("route defaults = %+v", cfg.Webhooks["grafana"])
	}
	if cfg.Coop.EmisarTokenEnv != "EMISAR_API_KEY" || cfg.Coop.Binary != "coop" ||
		cfg.Coop.RestartDelay.Duration != 5*time.Second || !cfg.Slack.NativeStatus {
		t.Fatalf("defaults missing: %+v %+v", cfg.Coop, cfg.Slack)
	}
	if cfg.Coop.StateDir != filepath.Join(cfg.StateDir, "coop") ||
		cfg.Coop.Socket != filepath.Join(cfg.Coop.StateDir, "control.sock") ||
		cfg.Coop.BootstrapDir != filepath.Join(cfg.Coop.StateDir, "agents") {
		t.Fatalf("derived Coop paths = %+v", cfg.Coop)
	}
}

func TestLoadRejectsUnknownAndUnsafeConfig(t *testing.T) {
	base := `version: 1
state_dir: /tmp/responder-test
slack:
  team_id: T123ABC
  default_repository: emisar
  operators: [U123ABC]
coop: {}
repositories:
  emisar:
    coop_policy: observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: emisar
`
	for name, mutate := range map[string]func(string) string{
		"unknown": func(s string) string { return s + "mystery: true\n" },
		"empty operators": func(s string) string {
			return strings.Replace(s, "operators: [U123ABC]", "operators: []", 1)
		},
		"public listener": func(s string) string {
			return strings.Replace(s, "version: 1", "version: 1\nlisten: 0.0.0.0:8080", 1)
		},
		"implicit public listener": func(s string) string {
			return strings.Replace(s, "version: 1", "version: 1\nlisten: :8080", 1)
		},
		"bad route": func(s string) string {
			return strings.Replace(s, "kind: grafana", "kind: javascript", 1)
		},
		"unknown repository": func(s string) string {
			return strings.Replace(s, "repository: emisar", "repository: other", 1)
		},
		"managed without policies": func(s string) string {
			return strings.Replace(s, "coop: {}", "coop: {supervise: true}", 1)
		},
		"relative Coop binary path": func(s string) string {
			return strings.Replace(s, "coop: {}", "coop: {binary: bin/coop}", 1)
		},
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "responder.yaml")
			if err := os.WriteFile(path, []byte(mutate(base)), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path); err == nil {
				t.Fatal("unsafe config was accepted")
			}
		})
	}
}

func TestGenericMappingRequiresOnlyBoringDotPaths(t *testing.T) {
	w := Webhook{
		Kind: "generic", Auth: "hmac-sha256", SecretEnv: "HOOK_SECRET",
		Repository: "repo", CorrelationWindow: Duration{time.Hour},
		Mapping: GenericMapping{EventID: "event.id", Status: "incident.status", Title: "incident.title"},
	}
	if err := validateWebhook(w); err != nil {
		t.Fatal(err)
	}
	w.Mapping.Title = "incident[0].title"
	if err := validateWebhook(w); err == nil {
		t.Fatal("expression language unexpectedly accepted")
	}
}

func TestExampleConfigurationStaysValid(t *testing.T) {
	cfg, err := Load(filepath.Join("..", "..", "config", "responder.example.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Repositories) != 2 || len(cfg.Webhooks) != 2 {
		t.Fatalf("example config = %+v", cfg)
	}
}

func TestSecretRequiresNontrivialSingleLineValue(t *testing.T) {
	cfg := Config{}
	for name, value := range map[string]string{
		"empty":   "",
		"short":   "short-secret",
		"newline": "this-is-long-enough\nbut-split",
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("TEST_SECRET", value)
			if _, err := cfg.Secret("TEST_SECRET"); err == nil {
				t.Fatal("unsafe secret accepted")
			}
		})
	}
	t.Setenv("TEST_SECRET", "0123456789abcdef")
	if value, err := cfg.Secret("TEST_SECRET"); err != nil || value != "0123456789abcdef" {
		t.Fatalf("valid secret = %q, %v", value, err)
	}
}

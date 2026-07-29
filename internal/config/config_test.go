package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
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
  watch_channels: [C456DEF]
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
		cfg.Coop.RestartDelay.Duration != 5*time.Second || cfg.Coop.TurnLimit != 1000 ||
		cfg.Coop.WatchSessionTurns != 40 ||
		cfg.Coop.WatchSessionAge.Duration != 24*time.Hour ||
		cfg.Slack.ChannelPrefix != "ems" || cfg.Slack.WatchContext != 20 ||
		cfg.Slack.WatchSettleDelay.Duration != 2*time.Second ||
		!cfg.Slack.NativeStatus || !cfg.Slack.AssistantExperience ||
		!cfg.IsWatchChannel("C456DEF") ||
		cfg.Limits.MaxWebhookAttempts != 12 ||
		cfg.Limits.MaxSlackInputAttempts != 12 ||
		cfg.Limits.MaxDeliveryAttempts != 12 ||
		cfg.Limits.MaxAgentRunAttempts != 20 ||
		cfg.Limits.MaxMemoryEntries != 1000 ||
		cfg.Limits.MaxMemoryEntriesPerScope != 100 ||
		cfg.Limits.MaxPreferences != 500 ||
		cfg.Limits.MaxPreferencesPerScope != 50 ||
		cfg.Limits.MaxStandingRules != 500 ||
		cfg.Limits.MaxRulesPerChannel != 25 {
		t.Fatalf("defaults missing: %+v %+v", cfg.Coop, cfg.Slack)
	}
	if cfg.Coop.StateDir != filepath.Join(cfg.StateDir, "coop") ||
		cfg.Coop.Socket != filepath.Join(cfg.Coop.StateDir, "control.sock") ||
		cfg.Coop.BootstrapDir != filepath.Join(cfg.Coop.StateDir, "agents") {
		t.Fatalf("derived Coop paths = %+v", cfg.Coop)
	}
}

func TestLegacyOutboxLimitSeedsOnlyUnspecifiedFailureBudgets(t *testing.T) {
	cfg := defaults()
	data := []byte(`limits:
  max_outbox_attempts: 7
  max_delivery_attempts: 9
`)
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if err := applyLegacyLimitDefaults(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.Limits.MaxWebhookAttempts != 7 ||
		cfg.Limits.MaxSlackInputAttempts != 7 ||
		cfg.Limits.MaxAgentRunAttempts != 7 ||
		cfg.Limits.MaxDeliveryAttempts != 9 {
		t.Fatalf("legacy retry limit migration = %+v", cfg.Limits)
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
		"relative additional MCP file": func(s string) string {
			return strings.Replace(
				s, "coop: {}", "coop: {additional_mcp_file: config/mcp.json}", 1,
			)
		},
		"relative additional environment file": func(s string) string {
			return strings.Replace(
				s, "coop: {}", "coop: {additional_env_file: config/mcp.env}", 1,
			)
		},
		"unsafe automatic turn ceiling": func(s string) string {
			return strings.Replace(s, "coop: {}", "coop: {turn_limit: 99}", 1)
		},
		"too little watch context": func(s string) string {
			return strings.Replace(
				s, "operators: [U123ABC]", "operators: [U123ABC]\n  watch_context_messages: 9", 1,
			)
		},
		"excessive watch settle delay": func(s string) string {
			return strings.Replace(
				s, "operators: [U123ABC]", "operators: [U123ABC]\n  watch_settle_delay: 11s", 1,
			)
		},
		"short watch memory session": func(s string) string {
			return strings.Replace(
				s, "coop: {}", "coop: {watch_session_max_turns: 4}", 1,
			)
		},
		"young watch memory session": func(s string) string {
			return strings.Replace(
				s, "coop: {}", "coop: {watch_session_max_age: 59m}", 1,
			)
		},
		"too few memory entries": func(s string) string {
			return s + "limits:\n  max_memory_entries: 9\n"
		},
		"memory scope exceeds total": func(s string) string {
			return s + "limits:\n  max_memory_entries: 100\n  max_memory_entries_per_scope: 101\n"
		},
		"preference scope exceeds total": func(s string) string {
			return s + "limits:\n  max_preferences: 10\n  max_preferences_per_scope: 11\n"
		},
		"rule channel exceeds total": func(s string) string {
			return s + "limits:\n  max_standing_rules: 10\n  max_rules_per_channel: 11\n"
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

func TestActionPoliciesAreRejectedUntilRequestsAreHostBound(t *testing.T) {
	base := `version: 1
state_dir: /tmp/responder-action-test
slack:
  team_id: T123ABC
  default_repository: emisar
  operators: [U123ABC]
coop: {}
repositories:
  emisar:
    coop_policy: observe
actions:
  restart_allocation:
    description: Restart one failed allocation.
    authority: emisar
    risk: medium
    approval: two_person
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: emisar
`
	write := func(t *testing.T, body string) string {
		t.Helper()
		path := filepath.Join(t.TempDir(), "responder.yaml")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	_, err := Load(write(t, base))
	if err == nil ||
		!strings.Contains(err.Error(), "actions are not supported in this release") {
		t.Fatalf("unsafe action catalog accepted or unclear error: %v", err)
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

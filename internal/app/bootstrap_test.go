package app

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
)

// bootstrapConfig is the minimum configuration these tests need: the service
// credential names that must never be projected into the agent box.
func bootstrapConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := config.Config{}
	cfg.Slack.BotTokenEnv = "TEST_SLACK_BOT_TOKEN"
	cfg.Slack.AppTokenEnv = "TEST_SLACK_APP_TOKEN"
	cfg.Coop.EmisarTokenEnv = "TEST_EMISAR_TOKEN"
	cfg.GitHub.TokenEnv = "TEST_GITHUB_TOKEN"
	cfg.Webhooks = map[string]config.Webhook{
		"grafana": {Name: "grafana", SecretEnv: "TEST_HOOK_SECRET"},
	}
	return cfg
}

// The agent box must never see a service credential. Projecting extra
// environment is a deliberate escape hatch, so its refusals are the boundary
// that keeps the hatch from becoming a hole.
func TestAdditionalEnvironmentRefusesServiceSecrets(t *testing.T) {
	cfg := bootstrapConfig(t)
	dir := t.TempDir()
	write := func(body string) string {
		t.Helper()
		path := filepath.Join(dir, "extra.env")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}

	cfg.Coop.AdditionalEnv = write("MY_TOOL_TOKEN=abc123-long-enough\n# a comment\n\n")
	values, err := additionalEnvironmentValues(cfg)
	if err != nil {
		t.Fatalf("an ordinary variable was refused: %v", err)
	}
	if values["MY_TOOL_TOKEN"] != "abc123-long-enough" {
		t.Fatalf("values = %+v", values)
	}

	for name, body := range map[string]string{
		"the Slack bot token":     cfg.Slack.BotTokenEnv + "=xoxb-leak\n",
		"the Emisar token":        cfg.Coop.EmisarTokenEnv + "=emk-leak\n",
		"a malformed line":        "NOT_AN_ASSIGNMENT\n",
		"a name with a bad shape": "lower-case=value-long-enough\n",
	} {
		cfg.Coop.AdditionalEnv = write(body)
		if _, err := additionalEnvironmentValues(cfg); err == nil {
			t.Errorf("%s was projected into the agent box", name)
		}
	}

	// A NUL or CR would let a value smuggle a second assignment past the parser.
	cfg.Coop.AdditionalEnv = write("A=one-long-enough\rB=two-long-enough\n")
	if _, err := additionalEnvironmentValues(cfg); err == nil {
		t.Error("a carriage return was accepted in projected environment")
	}
}

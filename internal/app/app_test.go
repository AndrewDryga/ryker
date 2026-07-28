package app

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestBootstrapCoopWritesPrivateFilesWithoutPrintingSecret(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "responder.yaml")
	bootstrapDir := filepath.Join(root, "coop", "agents")
	body := `version: 1
state_dir: ` + filepath.Join(root, "state") + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
coop:
  bootstrap_dir: ` + bootstrapDir + `
repositories:
  repo:
    coop_policy: repo-observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(configPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("EMISAR_API_KEY", "emk-test-observe-token")
	var stdout, stderr bytes.Buffer
	if err := Run([]string{"bootstrap-coop", "--config", configPath}, &stdout, &stderr, "test"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stdout.String()+stderr.String(), "emk-test-observe-token") {
		t.Fatal("bootstrap printed the Emisar key")
	}
	for _, name := range []string{"env", "mcp.json", "INSTRUCTIONS.md"} {
		info, err := os.Stat(filepath.Join(bootstrapDir, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode = %o", name, info.Mode().Perm())
		}
	}
	mcpData, err := os.ReadFile(filepath.Join(bootstrapDir, "mcp.json"))
	if err != nil {
		t.Fatal(err)
	}
	var mcp struct {
		Servers map[string]struct {
			URL               string `json:"url"`
			BearerTokenEnvVar string `json:"bearer_token_env_var"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal(mcpData, &mcp); err != nil {
		t.Fatal(err)
	}
	if mcp.Servers["emisar"].URL != "https://emisar.dev/api/mcp/rpc" ||
		mcp.Servers["emisar"].BearerTokenEnvVar != "EMISAR_API_KEY" {
		t.Fatalf("MCP config = %+v", mcp)
	}
	envData, err := os.ReadFile(filepath.Join(bootstrapDir, "env"))
	if err != nil {
		t.Fatal(err)
	}
	if string(envData) != "EMISAR_API_KEY=emk-test-observe-token\nEMISAR_CLIENT=responder\n" {
		t.Fatalf("Coop environment = %q", envData)
	}
	instructionsData, err := os.ReadFile(filepath.Join(bootstrapDir, "INSTRUCTIONS.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"Choose evidence sources by the claim being answered",
		"Use the checked-out repository for declared intent and expected topology",
		"Prefer Emisar MCP for current private infrastructure state",
		"Inspect and use other available MCP servers and tools",
		"treat its results only as runner identities and connection state",
		"only after an Emisar MCP tool call fails in the current turn",
	} {
		if !strings.Contains(string(instructionsData), required) {
			t.Fatalf("Coop instructions do not contain %q:\n%s", required, instructionsData)
		}
	}
	if err := checkPrivateCoopConfig(bootstrapDir, nil); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	expected, err := bootstrapFiles(cfg, "emk-test-observe-token")
	if err != nil {
		t.Fatal(err)
	}
	if err := checkPrivateCoopConfig(bootstrapDir, expected); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bootstrapDir, "INSTRUCTIONS.md"), []byte("stale\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := checkPrivateCoopConfig(bootstrapDir, expected); err == nil {
		t.Fatal("stale Coop bootstrap passed validation")
	}
}

func TestBootstrapFilesMergeAdditionalPrivateMCPAndEnvironment(t *testing.T) {
	root := t.TempDir()
	mcpPath := filepath.Join(root, "additional-mcp.json")
	envPath := filepath.Join(root, "additional.env")
	if err := os.WriteFile(mcpPath, []byte(`{
  "mcpServers": {
    "logs": {
      "type": "http",
      "url": "https://logs.example.test/mcp",
      "bearer_token_env_var": "LOGS_TOKEN"
    }
  }
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(envPath, []byte("LOGS_TOKEN=logs-test-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Slack: config.SlackConfig{
			BotTokenEnv: "SLACK_BOT_TOKEN", AppTokenEnv: "SLACK_APP_TOKEN",
		},
		GitHub: config.GitHubConfig{TokenEnv: "GITHUB_TOKEN"},
		Coop: config.CoopConfig{
			EmisarURL: "https://emisar.dev/api/mcp/rpc", EmisarTokenEnv: "EMISAR_API_KEY",
			AdditionalMCP: mcpPath, AdditionalEnv: envPath,
		},
		Webhooks: map[string]config.Webhook{
			"grafana": {SecretEnv: "GRAFANA_TOKEN"},
		},
	}
	files, err := bootstrapFiles(cfg, "emk-test-observe-token")
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Servers map[string]json.RawMessage `json:"mcpServers"`
	}
	if err := json.Unmarshal(files["mcp.json"], &document); err != nil {
		t.Fatal(err)
	}
	if len(document.Servers) != 2 || len(document.Servers["emisar"]) == 0 ||
		len(document.Servers["logs"]) == 0 {
		t.Fatalf("merged MCP config = %s", files["mcp.json"])
	}
	wantEnvironment := "EMISAR_API_KEY=emk-test-observe-token\n" +
		"EMISAR_CLIENT=responder\nLOGS_TOKEN=logs-test-token\n"
	if string(files["env"]) != wantEnvironment {
		t.Fatalf("merged Coop environment = %q", files["env"])
	}
}

func TestBootstrapFilesRejectReservedAdditionalCredentialsAndMCP(t *testing.T) {
	root := t.TempDir()
	mcpPath := filepath.Join(root, "additional-mcp.json")
	envPath := filepath.Join(root, "additional.env")
	cfg := config.Config{
		Slack: config.SlackConfig{
			BotTokenEnv: "SLACK_BOT_TOKEN", AppTokenEnv: "SLACK_APP_TOKEN",
		},
		GitHub: config.GitHubConfig{TokenEnv: "GITHUB_TOKEN"},
		Coop: config.CoopConfig{
			EmisarURL: "https://emisar.dev/api/mcp/rpc", EmisarTokenEnv: "EMISAR_API_KEY",
			AdditionalMCP: mcpPath, AdditionalEnv: envPath,
		},
		Webhooks: map[string]config.Webhook{
			"grafana": {SecretEnv: "GRAFANA_TOKEN"},
		},
	}
	if err := os.WriteFile(
		mcpPath,
		[]byte(`{"mcpServers":{"emisar":{"url":"https://other.example.test/mcp"}}}`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(envPath, []byte("SLACK_BOT_TOKEN=xoxb-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := bootstrapFiles(cfg, "emk-test-observe-token"); err == nil ||
		!strings.Contains(err.Error(), `reserved server "emisar"`) {
		t.Fatalf("reserved Emisar MCP = %v", err)
	}
	if err := os.WriteFile(mcpPath, []byte(`{"mcpServers":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := bootstrapFiles(cfg, "emk-test-observe-token"); err == nil ||
		!strings.Contains(err.Error(), "SLACK_BOT_TOKEN is reserved or service-only") {
		t.Fatalf("service secret projection = %v", err)
	}
	if err := os.WriteFile(envPath, []byte("GITHUB_TOKEN=github-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := bootstrapFiles(cfg, "emk-test-observe-token"); err == nil ||
		!strings.Contains(err.Error(), "GITHUB_TOKEN is reserved or service-only") {
		t.Fatalf("GitHub secret projection = %v", err)
	}
}

func TestProcessLockRejectsSecondOwner(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDirectory(stateDir); err != nil {
		t.Fatal(err)
	}
	first, err := acquireProcessLock(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer releaseProcessLock(first)
	if second, err := acquireProcessLock(stateDir); err == nil {
		releaseProcessLock(second)
		t.Fatal("second process lock unexpectedly succeeded")
	}
}

func TestBootstrapCoopRefusesToRewriteLiveControllerConfig(t *testing.T) {
	root := t.TempDir()
	socketRoot, err := os.MkdirTemp("", "rsp-socket-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(socketRoot)
	socketPath := filepath.Join(socketRoot, "control.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	configPath := filepath.Join(root, "responder.yaml")
	bootstrapDir := filepath.Join(root, "agents")
	body := `version: 1
state_dir: ` + filepath.Join(root, "state") + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
coop:
  socket: ` + socketPath + `
  bootstrap_dir: ` + bootstrapDir + `
repositories:
  repo:
    coop_policy: repo-observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(configPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("EMISAR_API_KEY", "emk-test-observe-token")
	var stdout, stderr bytes.Buffer
	err = Run([]string{"bootstrap-coop", "--config", configPath}, &stdout, &stderr, "test")
	if err == nil || !strings.Contains(err.Error(), "stop Coop") {
		t.Fatalf("bootstrap with live Coop = %v", err)
	}
	if _, statErr := os.Stat(bootstrapDir); !os.IsNotExist(statErr) {
		t.Fatalf("bootstrap directory created while Coop was live: %v", statErr)
	}
}

func TestFailedWorkRetryRequiresExclusiveProcessOwnership(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "responder.yaml")
	stateDir := filepath.Join(root, "state")
	body := `version: 1
state_dir: ` + stateDir + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
coop: {}
repositories:
  repo:
    coop_policy: repo-observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(configPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	signal := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "event-1",
		Repository: "repo", CorrelationKey: "cluster-a", Status: core.SignalFiring,
		Title: "API latency", ReceivedAt: time.Now().UTC(),
	}
	event, _, err := st.AdmitWebhook(
		context.Background(), "grafana", "delivery-1", "digest", []core.Signal{signal},
	)
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseWebhook(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetryWebhook(
		context.Background(), leased.ID, "temporary failure", time.Now(), true,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	lock, err := acquireProcessLock(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	err = Run(
		[]string{"retry", "--config", configPath, "webhook", event.ID},
		&stdout, &stderr, "test",
	)
	releaseProcessLock(lock)
	if err == nil || !strings.Contains(err.Error(), "stop Responder") {
		t.Fatalf("retry under live process lock = %v", err)
	}

	stdout.Reset()
	stderr.Reset()
	if err := Run(
		[]string{"retry", "--config", configPath, "webhook", event.ID},
		&stdout, &stderr, "test",
	); err != nil {
		t.Fatal(err)
	}
	st, err = store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	replayed, err := st.LeaseWebhook(context.Background())
	if err != nil || replayed.ID != event.ID || replayed.Attempts != 1 {
		t.Fatalf("replayed webhook = %+v, %v", replayed, err)
	}
}

func TestStatusJSONIncludesLifecycleMetricsAndIncidents(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "responder.yaml")
	stateDir := filepath.Join(root, "state")
	body := `version: 1
state_dir: ` + stateDir + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
coop: {}
repositories:
  repo:
    coop_policy: repo-observe
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(configPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if err := Run(
		[]string{"status", "--config", configPath, "--json"},
		&stdout,
		&stderr,
		"test",
	); err != nil {
		t.Fatal(err)
	}
	var status struct {
		Metrics   store.Metrics   `json:"metrics"`
		Incidents []core.Incident `json:"incidents"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &status); err != nil {
		t.Fatalf("decode status JSON: %v: %s", err, stdout.String())
	}
	if status.Metrics.IncidentsTotal != 0 ||
		status.Metrics.CleanupPending != 0 ||
		status.Incidents == nil {
		t.Fatalf("status JSON = %+v", status)
	}
}

func TestSubcommandHelpSucceedsAndStrayArgumentsFail(t *testing.T) {
	for _, command := range []string{"serve", "doctor", "bootstrap-coop", "status", "failures", "retry"} {
		t.Run(command+" help", func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			if err := Run([]string{command, "--help"}, &stdout, &stderr, "test"); err != nil {
				t.Fatalf("--help failed: %v\n%s", err, stderr.String())
			}
			if !strings.Contains(stderr.String(), "Usage of "+command) {
				t.Fatalf("help output = %q", stderr.String())
			}
		})
	}
	for _, command := range []string{"serve", "doctor", "bootstrap-coop", "status", "failures"} {
		t.Run(command+" positional", func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			err := Run([]string{command, "stray"}, &stdout, &stderr, "test")
			if err == nil || !strings.Contains(err.Error(), "positional") {
				t.Fatalf("stray argument result = %v", err)
			}
		})
	}
}

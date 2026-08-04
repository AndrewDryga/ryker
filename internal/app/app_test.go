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
	"github.com/AndrewDryga/responder/internal/slackui"
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
	var replayStdout, replayStderr bytes.Buffer
	if err := Run(
		[]string{"replay", "slack", "--help"},
		&replayStdout,
		&replayStderr,
		"test",
	); err != nil || !strings.Contains(replayStderr.String(), "Usage of replay slack") {
		t.Fatalf("replay help = %v, %q", err, replayStderr.String())
	}
}

func TestSlackReplayParsingAndPayloadFidelity(t *testing.T) {
	channel, timestamp, err := parseSlackPermalink(
		"https://example.slack.com/archives/C012ABC34/p1785652207489039?thread_ts=1785652000.000001",
	)
	if err != nil || channel != "C012ABC34" || timestamp != "1785652207.489039" {
		t.Fatalf("parse permalink = %q, %q, %v", channel, timestamp, err)
	}
	for _, invalid := range []string{
		"http://example.slack.com/archives/C1/p1785652207489039",
		"https://example.slack.com/client/C1/p1785652207489039",
		"https://example.slack.com/archives/C1/pnot-a-time",
	} {
		if _, _, err := parseSlackPermalink(invalid); err == nil {
			t.Fatalf("invalid permalink accepted: %s", invalid)
		}
	}
	source := core.SlackInput{
		ID: "slack_original", Kind: "message", TeamID: "T123", ChannelID: "C123",
		ThreadTS: "1700.001", MessageTS: "1700.002", UserID: "U123", Text: "check this",
		Attachments: []core.SlackAttachment{{ID: "F1", Name: "failure.png", MediaType: "image/png", Size: 42, URLPrivate: "https://files.example.test/F1"}},
	}
	replay, err := cloneSlackReplay(source, false)
	if err != nil {
		t.Fatal(err)
	}
	if replay.ID == source.ID || replay.Kind != "mention" || replay.TeamID != source.TeamID ||
		replay.ChannelID != source.ChannelID || replay.ThreadTS != source.ThreadTS ||
		replay.MessageTS != source.MessageTS || replay.UserID != source.UserID ||
		replay.Text != source.Text || len(replay.Attachments) != 1 ||
		replay.Attachments[0] != source.Attachments[0] ||
		!strings.HasPrefix(replay.EnvelopeID, "replay-private:") || replay.EventID != replay.EnvelopeID {
		t.Fatalf("replay payload = %+v", replay)
	}
	replay.Attachments[0].Name = "changed.png"
	if source.Attachments[0].Name != "failure.png" {
		t.Fatal("replay attachment mutation changed the source")
	}
	published, err := cloneSlackReplay(source, true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(published.EnvelopeID, "replay-public:") ||
		published.EventID != published.EnvelopeID {
		t.Fatalf("published replay identity = %+v", published)
	}
}

func TestSlackReplayMessageLookupPrefersOriginalOverEarlierReplay(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	original := core.SlackInput{
		ID: "slack_original_lookup", EnvelopeID: "env_original_lookup",
		EventID: "event_original_lookup", Kind: "mention", TeamID: "T123",
		ChannelID: "C123", MessageTS: "1700.001", UserID: "U123", Text: "verify",
		ReceivedAt: time.Now().Add(-time.Minute),
	}
	if created, err := st.AdmitSlackInput(ctx, original); err != nil || !created {
		t.Fatalf("admit original = %v, %v", created, err)
	}
	replay, err := cloneSlackReplay(original, false)
	if err != nil {
		t.Fatal(err)
	}
	if created, err := st.AdmitSlackInput(ctx, replay); err != nil || !created {
		t.Fatalf("admit earlier replay = %v, %v", created, err)
	}
	selected, err := findSlackReplaySource(ctx, st, "", original.ChannelID, original.MessageTS)
	if err != nil || selected.ID != original.ID {
		t.Fatalf("selected replay source = %+v, %v", selected, err)
	}
}

func TestSlackReplaySourceFromHistoryPreservesMessageContext(t *testing.T) {
	source := slackReplaySourceFromHistory("T123", "C123", slackui.HistoryMessage{
		Timestamp: "1700.002", ThreadTS: "1700.001", UserID: "U123",
		Text: "check this screenshot",
		Files: []slackui.HistoryFile{{
			ID: "F1", Name: "failure.png", MediaType: "image/png",
			Size: 42, URLPrivate: "https://files.example.test/F1",
		}},
		Reactions: []slackui.HistoryReaction{{
			Name: "eyes", Count: 2, UserIDs: []string{"U1", "U2"},
		}},
	})
	if source.Kind != "message" || source.TeamID != "T123" ||
		source.ChannelID != "C123" || source.ThreadTS != "1700.001" ||
		source.MessageTS != "1700.002" || source.UserID != "U123" ||
		source.Text != "check this screenshot" || len(source.Attachments) != 1 ||
		source.Attachments[0].ID != "F1" || len(source.Reactions) != 1 ||
		source.Reactions[0].Name != "eyes" {
		t.Fatalf("history replay source = %+v", source)
	}

	bot := slackReplaySourceFromHistory("T123", "C123", slackui.HistoryMessage{
		Timestamp: "1700.003", BotID: "B123", Text: "alert",
	})
	if bot.Kind != "bot_message" || bot.UserID != "B123" {
		t.Fatalf("bot replay source = %+v", bot)
	}
}

func TestWaitForSlackReplayRequiresCompletedRunAndSentReply(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_replay_test", EnvelopeID: "replay:slack_replay_test",
		EventID: "replay:slack_replay_test", Kind: "mention", TeamID: "T123",
		ChannelID: "C123", MessageTS: "1700.001", UserID: "U123", Text: "verify",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit replay = %v, %v", created, err)
	}
	leasedInput, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_replay_test", Mode: core.AgentRunTriage,
		ChannelID: input.ChannelID, ThreadTS: input.ThreadTS,
		ConversationKey: "channel:" + input.ChannelID,
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		Repository: "repo", Prompt: "verify",
	})
	if err != nil || !created {
		t.Fatalf("queue replay run = %+v, %v, %v", run, created, err)
	}
	leasedRun, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(ctx, leasedRun.ID, "session_replay", 1, "repo", 0, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leasedRun.ID, "turn_replay", 1, 0); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, leasedRun.ID, "completed", []byte(`{"action":"reply","message":"verified"}`), "", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, leasedRun.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, leasedRun.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackInput(ctx, leasedInput.ID); err != nil {
		t.Fatal(err)
	}
	deliveryID := "watch_reply_" + input.ID
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: deliveryID, Operation: "post", Kind: "notice",
		ChannelID: input.ChannelID, ThreadTS: input.ThreadTS,
		Body: []byte(`{"text":"verified"}`),
	}); err != nil || !created {
		t.Fatalf("enqueue replay delivery = %v, %v", created, err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, delivery.ID, "1700.003", "sending"); err != nil {
		t.Fatal(err)
	}
	waitCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	result, err := waitForSlackReplay(waitCtx, st, "slack_original", input.ID, "reply", true)
	if err != nil {
		t.Fatal(err)
	}
	if result.Action != "reply" || result.RunState != core.AgentRunCompleted ||
		result.InputState != "done" || len(result.Deliveries) != 1 ||
		result.Deliveries[0].State != "sent" ||
		!result.Published || !result.Deliveries[0].SlackUX.Passed {
		t.Fatalf("replay verification = %+v", result)
	}
	private, err := waitForSlackReplay(waitCtx, st, "slack_original", input.ID, "reply", false)
	if err != nil || private.Published || len(private.Deliveries) != 0 {
		t.Fatalf("private replay verification = %+v, %v", private, err)
	}
	if _, err := waitForSlackReplay(waitCtx, st, "slack_original", input.ID, "ignore", false); err == nil || !strings.Contains(err.Error(), `action was "reply", want "ignore"`) {
		t.Fatalf("mismatched replay expectation = %v", err)
	}
}

func TestReplayActionUsesProductionTranscriptParser(t *testing.T) {
	action, err := replayAction([]byte(
		"I’m checking declared and live state first.\n" +
			`{"action":"reply","message":"Verified result.","reason":"direct request"}`,
	))
	if err != nil || action != "reply" {
		t.Fatalf("replay transcript action = %q, %v", action, err)
	}
}

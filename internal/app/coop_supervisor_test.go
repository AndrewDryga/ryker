package app

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
)

type fakeCoopReadiness struct {
	err error
}

func (f fakeCoopReadiness) Ready(context.Context) error {
	return f.err
}

func TestCoopSupervisorBuildsRestrictedProcessAndStopsIt(t *testing.T) {
	root := t.TempDir()
	argsPath := filepath.Join(root, "args")
	envPath := filepath.Join(root, "env")
	script := writeSupervisorScript(t, `#!/bin/sh
printf '%s\n' "$@" > "$TRACE_ARGS.tmp"
mv "$TRACE_ARGS.tmp" "$TRACE_ARGS"
env | sort > "$TRACE_ENV.tmp"
mv "$TRACE_ENV.tmp" "$TRACE_ENV"
trap 'exit 0' TERM INT
while :; do sleep 1; done
`)
	t.Setenv("TRACE_ARGS", argsPath)
	t.Setenv("TRACE_ENV", envPath)
	t.Setenv("TEST_SLACK_BOT_TOKEN", "secret-bot")
	t.Setenv("TEST_SLACK_APP_TOKEN", "secret-app")
	t.Setenv("TEST_EMISAR_TOKEN", "secret-emisar")
	t.Setenv("TEST_WEBHOOK_TOKEN", "secret-webhook")

	cfg := supervisorTestConfig(root, script)
	supervisor, err := startCoopSupervisor(cfg, io.Discard, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	if err := supervisor.WaitReady(context.Background(), fakeCoopReadiness{}); err != nil {
		t.Fatal(err)
	}
	supervisor.processMu.Lock()
	process := supervisor.process.Process
	supervisor.processMu.Unlock()
	waitFor(t, func() bool {
		_, argsErr := os.Stat(argsPath)
		_, envErr := os.Stat(envPath)
		return argsErr == nil && envErr == nil
	})

	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	expectedArgs := strings.Join([]string{
		"sessions", "serve",
		"--state", cfg.Coop.StateDir,
		"--policies", cfg.Coop.Policies,
		"--socket", cfg.Coop.Socket,
		"",
	}, "\n")
	if string(args) != expectedArgs {
		t.Fatalf("managed Coop arguments = %q, want %q", args, expectedArgs)
	}

	environment, err := os.ReadFile(envPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{
		"TEST_SLACK_BOT_TOKEN=",
		"TEST_SLACK_APP_TOKEN=",
		"TEST_EMISAR_TOKEN=",
		"TEST_WEBHOOK_TOKEN=",
	} {
		if strings.Contains(string(environment), forbidden) {
			t.Fatalf("managed Coop inherited %s", forbidden)
		}
	}
	for _, expected := range []string{
		"COOP_CONFIG_DIR=" + cfg.Coop.BootstrapDir,
		"COOP_SPINNER=0",
		"NO_COLOR=1",
		"TERM=dumb",
	} {
		if !strings.Contains(string(environment), expected+"\n") {
			t.Fatalf("managed Coop environment is missing %q", expected)
		}
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := supervisor.Close(stopCtx); err != nil {
		t.Fatal(err)
	}
	if err := process.Signal(syscall.Signal(0)); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("managed Coop process remains after shutdown: %v", err)
	}
}

func TestCoopSupervisorRestartsAfterUnexpectedExit(t *testing.T) {
	root := t.TempDir()
	counterPath := filepath.Join(root, "starts")
	script := writeSupervisorScript(t, `#!/bin/sh
count=0
if [ -f "$START_COUNTER" ]; then
  count=$(cat "$START_COUNTER")
fi
count=$((count + 1))
printf '%s' "$count" > "$START_COUNTER"
trap 'exit 0' TERM INT
while :; do sleep 1; done
`)
	t.Setenv("START_COUNTER", counterPath)
	cfg := supervisorTestConfig(root, script)
	cfg.Coop.RestartDelay.Duration = 20 * time.Millisecond

	supervisor, err := startCoopSupervisor(cfg, io.Discard, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	if err := supervisor.WaitReady(context.Background(), fakeCoopReadiness{}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return readCount(counterPath) == 1 })
	supervisor.signal(syscall.SIGTERM)
	waitFor(t, func() bool { return readCount(counterPath) >= 2 })

	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := supervisor.Close(stopCtx); err != nil {
		t.Fatal(err)
	}
}

func TestCoopSupervisorReportsExitBeforeReadiness(t *testing.T) {
	root := t.TempDir()
	script := writeSupervisorScript(t, "#!/bin/sh\nexit 23\n")
	cfg := supervisorTestConfig(root, script)
	supervisor, err := startCoopSupervisor(cfg, io.Discard, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	waitCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err = supervisor.WaitReady(waitCtx, fakeCoopReadiness{err: errors.New("not ready")})
	if err == nil || !strings.Contains(err.Error(), "exit status 23") {
		t.Fatalf("early managed Coop exit = %v", err)
	}
	if err := supervisor.Close(waitCtx); err != nil {
		t.Fatal(err)
	}
}

func supervisorTestConfig(root, binary string) config.Config {
	return config.Config{
		Slack: config.SlackConfig{
			BotTokenEnv: "TEST_SLACK_BOT_TOKEN",
			AppTokenEnv: "TEST_SLACK_APP_TOKEN",
		},
		Coop: config.CoopConfig{
			Supervise:      true,
			Binary:         binary,
			StateDir:       filepath.Join(root, "coop"),
			Policies:       filepath.Join(root, "policies.yaml"),
			RestartDelay:   config.Duration{Duration: 100 * time.Millisecond},
			Socket:         filepath.Join(root, "coop", "control.sock"),
			BootstrapDir:   filepath.Join(root, "coop", "agents"),
			EmisarTokenEnv: "TEST_EMISAR_TOKEN",
		},
		Webhooks: map[string]config.Webhook{
			"test": {SecretEnv: "TEST_WEBHOOK_TOKEN"},
		},
	}
}

func writeSupervisorScript(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-coop")
	if err := os.WriteFile(path, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition was not satisfied before timeout")
}

func readCount(path string) int {
	body, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	count, _ := strconv.Atoi(string(body))
	return count
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

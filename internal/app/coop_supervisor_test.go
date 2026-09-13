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

	"github.com/AndrewDryga/ryker/internal/config"
)

type fakeCoopReadiness struct {
	err error
}

func (f fakeCoopReadiness) Ready(context.Context) error {
	return f.err
}

func TestDoctorUsesAlreadyRunningManagedCoop(t *testing.T) {
	cfg := supervisorTestConfig(t.TempDir(), filepath.Join(t.TempDir(), "missing-coop"))
	cfg.Coop.RequestTimeout.Duration = time.Second
	supervisor, mode, err := startDoctorCoop(
		cfg,
		io.Discard,
		discardLogger(),
		fakeCoopReadiness{},
	)
	if err != nil || supervisor != nil || mode != "managed; already running" {
		t.Fatalf(
			"doctor managed Coop attachment = supervisor=%v mode=%q err=%v",
			supervisor,
			mode,
			err,
		)
	}
}

func TestServeAttachesToAlreadyRunningManagedCoop(t *testing.T) {
	cfg := supervisorTestConfig(t.TempDir(), filepath.Join(t.TempDir(), "missing-coop"))
	cfg.Coop.RequestTimeout.Duration = time.Second
	supervisor, err := startManagedCoop(
		cfg,
		io.Discard,
		discardLogger(),
		fakeCoopReadiness{},
	)
	if err != nil || supervisor == nil {
		t.Fatalf("attach managed Coop supervisor=%v err=%v", supervisor, err)
	}
	if err := stopManagedCoop(supervisor, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureManagedCoopImageBuildsOnlyWhenMissing(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repo")
	if err := os.Mkdir(repository, 0o700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(root, "image-ready")
	trace := filepath.Join(root, "trace")
	script := writeSupervisorScript(t, `#!/bin/sh
printf '%s\n' "$1" >> "$TRACE"
case "$1" in
  run)
    if [ ! -f "$IMAGE_READY" ]; then
	  echo "coop: Coop box image is not built; run 'coop build'" >&2
	  exit 1
    fi
    ;;
  build)
    : > "$IMAGE_READY"
    ;;
esac
`)
	t.Setenv("TRACE", trace)
	t.Setenv("IMAGE_READY", state)
	cfg := supervisorTestConfig(root, script)
	cfg.Slack.DefaultRepository = "repo"
	cfg.Repositories = map[string]config.Repository{"repo": {Path: repository}}
	var output strings.Builder
	if err := ensureManagedCoopImage(cfg, &output); err != nil {
		t.Fatal(err)
	}
	if err := ensureManagedCoopImage(cfg, &output); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "run\nbuild\nrun\nrun\n" {
		t.Fatalf("runtime commands = %q", got)
	}
	if !strings.Contains(output.String(), "building it now") {
		t.Fatalf("build output = %q", output.String())
	}
}

func TestCheckManagedCoopImageExplainsRemediation(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repo")
	if err := os.Mkdir(repository, 0o700); err != nil {
		t.Fatal(err)
	}
	script := writeSupervisorScript(t, `#!/bin/sh
echo "coop: Coop box image is not built; run 'coop build'" >&2
exit 1
`)
	cfg := supervisorTestConfig(root, script)
	cfg.Slack.DefaultRepository = "repo"
	cfg.Repositories = map[string]config.Repository{"repo": {Path: repository}}
	err := checkManagedCoopImage(cfg)
	if err == nil || !strings.Contains(err.Error(), "Ryker cannot execute agent turns") ||
		!strings.Contains(err.Error(), "build") {
		t.Fatalf("missing image remediation = %v", err)
	}
}

func TestManagedCoopImageMissingDiagnosticVariants(t *testing.T) {
	for _, test := range []struct {
		detail string
		want   bool
	}{
		{detail: "coop: Coop box image is not built; run 'coop build'", want: true},
		{detail: "✗ image \"coop-blitz-infra\" not built — run 'coop build'", want: true},
		{detail: "image build failed: Docker daemon unavailable", want: false},
		{detail: "repository is not built", want: false},
	} {
		if got := managedCoopImageMissingDiagnostic(test.detail); got != test.want {
			t.Errorf("missing image diagnostic for %q = %t, want %t", test.detail, got, test.want)
		}
	}
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
	t.Setenv("TEST_GITHUB_TOKEN", "secret-github")
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
		"TEST_GITHUB_TOKEN=",
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

func TestCoopSupervisorReportsAuthenticationRemediation(t *testing.T) {
	root := t.TempDir()
	// Verbatim from `coop sessions serve` on an unauthenticated ladder rung. It
	// names the rung by index and the account as a credential; matching a
	// remembered older wording here would pass while the real diagnostic went
	// unrecognised, which is the whole failure this remediation replaces.
	script := writeSupervisorScript(t, `#!/bin/sh
echo '✗ policy "emisar-observe": target[0] credential "personal" is not authenticated' >&2
exit 1
`)
	cfg := supervisorTestConfig(root, script)
	policies := `version: 1
policies:
  emisar-observe:
    repository: /tmp/emisar
    target: [codex:gpt-5.6/medium@personal, claude@oncall]
`
	if err := os.WriteFile(cfg.Coop.Policies, []byte(policies), 0o600); err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	supervisor, err := startCoopSupervisor(cfg, &output, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	waitCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err = supervisor.WaitReady(waitCtx, fakeCoopReadiness{err: errors.New("not ready")})
	if err == nil {
		t.Fatal("unauthenticated managed Coop unexpectedly became ready")
	}
	wantCommand := "COOP_CONFIG_DIR='" + cfg.Coop.BootstrapDir + "' '" +
		cfg.Coop.Binary + "' login 'codex@personal'"
	for _, want := range []string{
		"managed Coop target codex@personal is not authenticated",
		wantCommand,
		"then retry Ryker",
		"exit status 1",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("authentication error = %q; missing %q", err, want)
		}
	}
	if !strings.Contains(output.String(), `target[0] credential "personal" is not authenticated`) {
		t.Fatalf("managed Coop output was not forwarded: %q", output.String())
	}
	if err := supervisor.Close(waitCtx); err != nil {
		t.Fatal(err)
	}
}

func TestValidateConversationPrewarmPolicies(t *testing.T) {
	root := t.TempDir()
	cfg := supervisorTestConfig(root, "/bin/true")
	cfg.Coop.PrewarmSessions = 2
	cfg.Repositories = map[string]config.Repository{
		"repo": {ConversationPolicy: "repo-conversation"},
	}
	writePolicies := func(body string) {
		t.Helper()
		if err := os.WriteFile(cfg.Coop.Policies, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writePolicies(`version: 1
policies:
  repo-conversation:
    repository: /tmp/repo
    target: codex:gpt-5.6/medium@personal
`)
	if err := validateConversationPrewarmPolicies(cfg); err == nil ||
		!strings.Contains(err.Error(), `policy "repo-conversation"`) ||
		!strings.Contains(err.Error(), "warm_idle_timeout: 15m") {
		t.Fatalf("missing warm lease error = %v", err)
	}
	writePolicies(`version: 1
policies:
  repo-conversation:
    repository: /tmp/repo
    target: codex:gpt-5.6/medium@personal
    warm_idle_timeout: 15m
`)
	if err := validateConversationPrewarmPolicies(cfg); err != nil {
		t.Fatalf("valid warm policy = %v", err)
	}
}

func supervisorTestConfig(root, binary string) config.Config {
	return config.Config{
		Slack: config.SlackConfig{
			BotTokenEnv: "TEST_SLACK_BOT_TOKEN",
			AppTokenEnv: "TEST_SLACK_APP_TOKEN",
		},
		GitHub: config.GitHubConfig{TokenEnv: "TEST_GITHUB_TOKEN"},
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

// waitFor polls because the condition is a side effect of a real child
// process: the supervisor starts it, and the only evidence it ran is what it
// wrote. There is no channel to select on and no clock to advance, so a bounded
// poll is the honest mechanism rather than a substitute for one.
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

func TestCoopRestartBackoff(t *testing.T) {
	base := 100 * time.Millisecond
	for _, test := range []struct {
		failures int
		want     time.Duration
	}{
		{1, 100 * time.Millisecond},
		{2, 200 * time.Millisecond},
		{5, 1600 * time.Millisecond},
		{20, 5 * time.Minute},
	} {
		if got := coopRestartBackoff(base, test.failures); got != test.want {
			t.Fatalf("failures %d: got %s, want %s", test.failures, got, test.want)
		}
	}
}

func TestCoopRuntimeRepairGateBacksOffSharedBuildFailure(t *testing.T) {
	base := 100 * time.Millisecond
	now := time.Date(2026, time.August, 5, 12, 0, 0, 0, time.UTC)
	attempts := 0
	gate := newCoopRuntimeRepairGate(base, func() error {
		attempts++
		return errors.New("Docker daemon unavailable")
	}, nil)
	gate.now = func() time.Time { return now }

	if err := gate.Repair(context.Background()); err == nil {
		t.Fatal("initial repair unexpectedly succeeded")
	}
	if err := gate.Repair(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "is waiting until") {
		t.Fatalf("shared cooldown error = %v", err)
	}
	if attempts != 1 {
		t.Fatalf("repair attempts during cooldown = %d, want 1", attempts)
	}

	now = now.Add(base + time.Millisecond)
	if err := gate.Repair(context.Background()); err == nil {
		t.Fatal("repair after cooldown unexpectedly succeeded")
	}
	if attempts != 2 {
		t.Fatalf("repair attempts after cooldown = %d, want 2", attempts)
	}
}

// Two consecutive build failures are the corruption signature. On 2026-08-13
// and again on 2026-08-14 the box build failed against a buildkit cache
// referencing deleted overlay2 layers, runs parked at failure counts up to 17,
// and both incidents were resolved by hand with the same `docker builder
// prune` the gate now runs itself — twice the same 3.2 GB of dead cache,
// twice a human in the loop for a mechanical fix.
func TestARepeatedBuildFailurePrunesTheCacheItTripsOn(t *testing.T) {
	base := 100 * time.Millisecond
	now := time.Date(2026, time.August, 14, 23, 0, 0, 0, time.UTC)
	attempts, prunes := 0, 0
	cacheCorrupted := true
	gate := newCoopRuntimeRepairGate(base, func() error {
		attempts++
		if cacheCorrupted {
			return errors.New("build managed Coop box image: exit status 1")
		}
		return nil
	}, func() error {
		prunes++
		cacheCorrupted = false
		return nil
	})
	gate.now = func() time.Time { return now }

	if err := gate.Repair(context.Background()); err == nil {
		t.Fatal("the first build against a corrupted cache unexpectedly succeeded")
	}
	if prunes != 0 {
		t.Fatalf("pruned after a single failure: %d prunes; one failure is not the signature", prunes)
	}
	now = now.Add(coopRestartBackoff(base, 1) + time.Millisecond)
	if err := gate.Repair(context.Background()); err == nil {
		t.Fatal("the second build against a corrupted cache unexpectedly succeeded")
	}
	if prunes != 0 {
		t.Fatalf("pruned before two consecutive failures: %d prunes", prunes)
	}
	now = now.Add(coopRestartBackoff(base, 2) + time.Millisecond)
	if err := gate.Repair(context.Background()); err != nil {
		t.Fatalf("the build after the self-prune failed: %v", err)
	}
	if prunes != 1 || attempts != 3 {
		t.Fatalf("prunes = %d attempts = %d, want exactly one prune before the third attempt",
			prunes, attempts)
	}

	// The streak flag resets with success: a later, unrelated failure pair
	// earns its own prune instead of inheriting a spent one.
	cacheCorrupted = true
	for range 2 {
		now = now.Add(time.Hour)
		_ = gate.Repair(context.Background())
	}
	now = now.Add(time.Hour)
	if err := gate.Repair(context.Background()); err != nil {
		t.Fatalf("the second streak's post-prune build failed: %v", err)
	}
	if prunes != 2 {
		t.Fatalf("second streak prunes = %d, want a fresh prune per streak", prunes)
	}
}

// A failed prune must not replace the build error the operator diagnoses from,
// and must not stop the build attempt.
func TestAFailedPruneStillAttemptsTheBuild(t *testing.T) {
	base := 100 * time.Millisecond
	now := time.Date(2026, time.August, 14, 23, 0, 0, 0, time.UTC)
	attempts := 0
	gate := newCoopRuntimeRepairGate(base, func() error {
		attempts++
		return errors.New("build managed Coop box image: exit status 1")
	}, func() error {
		return errors.New("docker daemon went away mid-prune")
	})
	gate.now = func() time.Time { return now }

	for failures := 1; failures <= 3; failures++ {
		if err := gate.Repair(context.Background()); err == nil ||
			!strings.Contains(err.Error(), "build managed Coop box image") {
			t.Fatalf("attempt %d error = %v, want the build's own error", failures, err)
		}
		now = now.Add(coopRestartBackoff(base, failures) + time.Millisecond)
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d; a failed prune must not swallow a build attempt", attempts)
	}
}

// Readiness reads the streak, so it must move exactly with Repair: up on every
// failed build, untouched by the shared-cooldown early return, and cleared
// with the rest of the gate state on success. Without this the 2026-08-13
// outage shape — 75 minutes of failed rebuilds — kept /readyz green throughout.
func TestCoopRuntimeRepairGateReportsItsFailureStreak(t *testing.T) {
	base := 100 * time.Millisecond
	now := time.Date(2026, time.August, 5, 12, 0, 0, 0, time.UTC)
	healthy := false
	gate := newCoopRuntimeRepairGate(base, func() error {
		if healthy {
			return nil
		}
		return errors.New("invalid output path: stat /var/lib/docker/overlay2/x")
	}, func() error { return nil })
	gate.now = func() time.Time { return now }

	if count, lastErr := gate.FailureStreak(); count != 0 || lastErr != nil {
		t.Fatalf("fresh gate streak = %d, %v", count, lastErr)
	}
	_ = gate.Repair(context.Background())
	if count, lastErr := gate.FailureStreak(); count != 1 || lastErr == nil {
		t.Fatalf("streak after one failure = %d, %v", count, lastErr)
	}
	// The cooldown early return is not a build attempt and must not count.
	_ = gate.Repair(context.Background())
	if count, _ := gate.FailureStreak(); count != 1 {
		t.Fatalf("streak after cooldown return = %d, want 1", count)
	}
	now = now.Add(base + time.Millisecond)
	_ = gate.Repair(context.Background())
	if count, _ := gate.FailureStreak(); count != 2 {
		t.Fatalf("streak after second failure = %d, want 2", count)
	}
	healthy = true
	now = now.Add(time.Hour)
	if err := gate.Repair(context.Background()); err != nil {
		t.Fatalf("recovered repair = %v", err)
	}
	if count, lastErr := gate.FailureStreak(); count != 0 || lastErr != nil {
		t.Fatalf("streak after recovery = %d, %v; readiness would keep naming "+
			"a condition that ended", count, lastErr)
	}
}

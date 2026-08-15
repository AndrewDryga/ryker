package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/evaluation"
	"github.com/AndrewDryga/responder/internal/store"
)

// Every secret the process needs is read once at startup and the process
// refuses to run without it. That fail-closed behaviour is the whole security
// posture of the deployment, so it is worth pinning rather than assuming.
func TestRuntimeSecretsFailClosed(t *testing.T) {
	cfg := config.Config{}
	cfg.Slack.BotTokenEnv = "TEST_BOT_TOKEN"
	cfg.Slack.AppTokenEnv = "TEST_APP_TOKEN"
	cfg.Webhooks = map[string]config.Webhook{
		"grafana": {Name: "grafana", SecretEnv: "TEST_HOOK_SECRET"},
	}

	if _, _, _, err := runtimeSecrets(cfg); err == nil {
		t.Fatal("startup accepted a missing bot token")
	}

	t.Setenv("TEST_BOT_TOKEN", "xoxb-test-token-value")
	if _, _, _, err := runtimeSecrets(cfg); err == nil {
		t.Fatal("startup accepted a missing app token")
	}

	t.Setenv("TEST_APP_TOKEN", "xapp-test-token-value")
	if _, _, _, err := runtimeSecrets(cfg); err == nil {
		t.Fatal("startup accepted a missing webhook secret")
	}

	t.Setenv("TEST_HOOK_SECRET", "webhook-secret-value")
	secrets, bot, app, err := runtimeSecrets(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if bot != "xoxb-test-token-value" || app != "xapp-test-token-value" {
		t.Fatalf("tokens = %q, %q", bot, app)
	}
	if secrets["grafana"] != "webhook-secret-value" {
		t.Fatalf("webhook secrets = %+v", secrets)
	}

	// A secret that is present but too short is also refused: a short token is
	// far more likely to be a placeholder than a real credential.
	t.Setenv("TEST_HOOK_SECRET", "short")
	if _, _, _, err := runtimeSecrets(cfg); err == nil {
		t.Fatal("startup accepted a webhook secret below the minimum length")
	}
}

// The evaluation baseline gates the release, so a corrupt or unreadable one
// must fail loudly rather than silently comparing against nothing.
func TestEvaluationBaselineRoundTripAndRejection(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "baseline.json")

	if _, err := readEvaluationBaseline(path); err == nil {
		t.Fatal("a missing baseline was accepted")
	}

	baseline := evaluation.EvaluationBaseline{
		Version:         1,
		CorpusDigest:    "sha256:abc123",
		OverallPassRate: 0.92,
		CasePassRates:   map[string]float64{"health-verdict": 0.95},
	}
	if err := writeEvaluationBaseline(path, baseline); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("baseline permissions = %o, want 600; it can contain private case names", mode)
	}
	restored, err := readEvaluationBaseline(path)
	if err != nil {
		t.Fatal(err)
	}
	if restored.CorpusDigest != baseline.CorpusDigest ||
		restored.CasePassRates["health-verdict"] != 0.95 {
		t.Fatalf("baseline round trip = %+v", restored)
	}

	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readEvaluationBaseline(path); err == nil {
		t.Fatal("a corrupt baseline was accepted")
	}
}

// A release fails when the corpus does worse than the baseline says it did.
//
// This is the whole point of the slice and it is checked end to end through the
// command, not through the gate function: MaxBaselineRegression had existed for
// months and no target passed --baseline, so the plumbing between the flag and
// the exit code was the part that had never run. Offline by construction — the
// replay corpus carries its own recorded outputs, so a gate that fails on
// quality needs no model to prove it.
func TestAReplayThatDoesWorseThanItsBaselineFailsTheCommand(t *testing.T) {
	dir := t.TempDir()
	corpus := filepath.Join(dir, "corpus.jsonl")
	// Shaped like testdata/eval/golden.jsonl: a recorded model answer and the
	// action it has to produce.
	clean := []string{
		`{"name":"answers","kind":"watch","want_action":"reply","output":` +
			`"{\"action\":\"reply\",\"reason\":\"the operator asked directly\",\"message\":\"It is up.\"}"}`,
		`{"name":"stays quiet","kind":"watch","want_action":"ignore","output":` +
			`"{\"action\":\"ignore\",\"reason\":\"two people are talking to each other\"}"}`,
	}
	if err := os.WriteFile(corpus, []byte(strings.Join(clean, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	baseline := filepath.Join(dir, "baseline.json")
	var out, errOut bytes.Buffer
	if err := runEval([]string{
		"--replay", "--input", corpus, "--write-baseline", baseline,
	}, &out, &errOut); err != nil {
		t.Fatalf("clean replay: %v (%s)", err, out.String())
	}

	// The same corpus, one case now answering the way it used to be corrected
	// for. Nothing about the thresholds changed; only the baseline knows.
	regressed := append([]string(nil), clean...)
	regressed[1] = `{"name":"stays quiet","kind":"watch","want_action":"ignore","output":` +
		`"{\"action\":\"reply\",\"reason\":\"joining in\",\"message\":\"Sure!\"}"}`
	if err := os.WriteFile(corpus, []byte(strings.Join(regressed, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	err := runEval([]string{
		"--replay", "--input", corpus,
		"--baseline", baseline, "--max-regression", "0.1", "--min-case-pass-rate", "0.4",
	}, &out, &errOut)
	if err == nil {
		t.Fatalf("a regressed corpus passed its baseline: %s", out.String())
	}
	printed := out.String()
	if !strings.Contains(printed, "GATE:") ||
		!strings.Contains(printed, "regressed") {
		t.Fatalf("the failure did not name the regression: %v\n%s", err, printed)
	}
}

// A baseline records the newest clean run and refuses everything else.
//
// Both halves matter. Reading the newest is what lets an operator record a
// baseline from an hour of credentialed evaluation that already happened
// instead of paying for it twice, and refusing a run with a failure in it is
// what stops "the release is allowed to be this bad" from being written down by
// accident on the one afternoon the provider was struggling.
func TestABaselineIsRecordedFromTheNewestCleanRun(t *testing.T) {
	history := t.TempDir()
	write := func(name string, summary evaluation.EvaluationSummary) {
		t.Helper()
		encoded, err := json.Marshal(summary)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(history, name), encoded, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	clean := evaluation.EvaluationSummary{
		CorpusDigest: "digest", Total: 2, Passed: 2,
		Cases: []evaluation.CaseAggregate{
			{Name: "answers", Samples: 1, Passed: 1, PassRate: 1},
			{Name: "stays quiet", Samples: 1, Passed: 1, PassRate: 1},
		},
		Results: []evaluation.EvaluationResult{
			{Name: "answers", CaseName: "answers", Passed: true},
			{Name: "stays quiet", CaseName: "stays quiet", Passed: true},
		},
	}
	older := clean
	older.CorpusDigest = "older digest"
	write("regressions-20260810T000000Z.json", older)
	write("regressions-20260811T000000Z.json", clean)

	target := filepath.Join(t.TempDir(), "baselines", "regressions.json")
	var out, errOut bytes.Buffer
	if err := runEvalBaseline([]string{
		"--history", history, "--corpus", "regressions", "--write", target,
	}, &out, &errOut); err != nil {
		t.Fatalf("record baseline: %v (%s)", err, errOut.String())
	}
	recorded, err := readEvaluationBaseline(target)
	if err != nil {
		t.Fatal(err)
	}
	if recorded.CorpusDigest != "digest" || recorded.CasePassRates["answers"] != 1 {
		t.Fatalf("recorded the wrong run: %+v", recorded)
	}
	info, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o644 {
		t.Fatalf("baseline permissions = %o, want 644; it is committed and reviewed", mode)
	}

	failed := clean
	failed.Passed = 1
	failed.Failed = 1
	failed.Results[1].Passed = false
	write("regressions-20260812T000000Z.json", failed)
	if err := runEvalBaseline([]string{
		"--history", history, "--corpus", "regressions", "--write", target,
	}, &out, &errOut); err == nil {
		t.Fatal("a run with a failed case was recorded as the baseline")
	}
	unevaluated := clean
	unevaluated.Unevaluated = 2
	write("regressions-20260813T000000Z.json", unevaluated)
	if err := runEvalBaseline([]string{
		"--history", history, "--corpus", "regressions", "--write", target,
	}, &out, &errOut); err == nil {
		t.Fatal("a run the provider refused was recorded as the baseline")
	}
	// The refusals must not have overwritten the good one.
	again, err := readEvaluationBaseline(target)
	if err != nil || again.CorpusDigest != "digest" {
		t.Fatalf("a refused run still rewrote the baseline: %+v, %v", again, err)
	}
}

// Two Responder processes sharing a state directory would corrupt each other's
// leases, so the lock is the thing that makes a single-writer design safe.
func TestProcessLockIsExclusive(t *testing.T) {
	dir := t.TempDir()
	first, err := acquireProcessLock(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := acquireProcessLock(dir); err == nil {
		t.Fatal("a second process acquired the same state directory lock")
	} else if !strings.Contains(err.Error(), "another Responder process") &&
		err != errProcessLocked {
		t.Fatalf("unexpected lock error: %v", err)
	}
	releaseProcessLock(first)

	second, err := acquireProcessLock(dir)
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	releaseProcessLock(second)
}

// The readiness probe is what `doctor` uses to tell "not running" from
// "running but unhealthy", which are different problems with different fixes.
func TestReadinessProbeReportsAnUnreachableService(t *testing.T) {
	// Port 1 on loopback is reserved and never listening.
	if err := probeResponderReady(context.Background(), "127.0.0.1:1"); err == nil {
		t.Fatal("the probe reported an unreachable service as ready")
	}
}

// Help is the first thing a new operator sees.
func TestHelpListsEveryCommand(t *testing.T) {
	var output bytes.Buffer
	printHelp(&output)
	text := output.String()
	for _, command := range []string{
		"serve", "doctor", "bootstrap-coop", "status", "failures", "retry", "replay", "eval",
	} {
		if !strings.Contains(text, command) {
			t.Errorf("help does not mention the %q command", command)
		}
	}
}

func TestSmallDisplayHelpers(t *testing.T) {
	if got := displayOr("", "fallback"); got != "fallback" {
		t.Fatalf("displayOr empty = %q", got)
	}
	if got := displayOr("value", "fallback"); got != "value" {
		t.Fatalf("displayOr value = %q", got)
	}
	if yesNo(true) == yesNo(false) {
		t.Fatal("yesNo renders both states the same")
	}
	if newLogger(&bytes.Buffer{}, "debug") == nil {
		t.Fatal("newLogger returned nil")
	}
	// An unknown level must not panic or return nil; it falls back.
	if newLogger(&bytes.Buffer{}, "nonsense") == nil {
		t.Fatal("newLogger returned nil for an unknown level")
	}
}

// writeInspectionConfig writes the minimum configuration the read-only
// inspection commands need. They deliberately work without Slack, Coop or
// Emisar so an operator can debug a broken deployment.
func writeInspectionConfig(t *testing.T) (configPath string, stateDir string) {
	t.Helper()
	root := t.TempDir()
	configPath = filepath.Join(root, "responder.yaml")
	stateDir = filepath.Join(root, "state")
	body := `version: 1
listen: 127.0.0.1:8080
state_dir: ` + stateDir + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
coop: {}
repositories:
  repo:
    coop_policy: repo-observe
    path: /srv/repos/repo
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
	// The inspection commands read an existing deployment; they do not create
	// one, which is why they refuse a state directory that is not there.
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	return configPath, stateDir
}

// status and failures are what an operator reaches for when something is
// wrong, so they must work against a database alone — no Slack, no Coop, no
// Emisar, none of which may be reachable at that moment.
func TestInspectionCommandsWorkWithoutDependencies(t *testing.T) {
	configPath, stateDir := writeInspectionConfig(t)

	var stdout, stderr bytes.Buffer
	// Inspection reads a deployment; it does not create one. Pointing it at a
	// directory with no database is an operator error worth reporting clearly,
	// not something to paper over by creating a fresh database.
	if err := runStatus([]string{"--config", configPath}, &stdout, &stderr); err == nil {
		t.Fatal("status invented a deployment that does not exist")
	}

	created, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	created.Close()

	stdout.Reset()
	stderr.Reset()
	if err := runStatus([]string{"--config", configPath}, &stdout, &stderr); err != nil {
		t.Fatalf("status failed on a healthy empty database: %v (%s)", err, stderr.String())
	}
	if stdout.Len() == 0 {
		t.Fatal("status printed nothing")
	}

	stdout.Reset()
	stderr.Reset()
	if err := runStatus([]string{"--config", configPath, "--json"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	var status map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &status); err != nil {
		t.Fatalf("status --json is not valid JSON: %v\n%s", err, stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	if err := runFailures([]string{"--config", configPath, "--json"}, &stdout, &stderr); err != nil {
		t.Fatalf("failures failed: %v (%s)", err, stderr.String())
	}
	var failures []any
	if err := json.Unmarshal(stdout.Bytes(), &failures); err != nil {
		t.Fatalf("failures --json is not valid JSON: %v\n%s", err, stdout.String())
	}
	if len(failures) != 0 {
		t.Fatalf("a fresh database reported failures: %+v", failures)
	}
}

// A positional argument is almost always a mistyped flag, and silently
// ignoring it would run a different command than the operator intended.
func TestInspectionCommandsRejectStrayArguments(t *testing.T) {
	configPath, _ := writeInspectionConfig(t)
	var stdout, stderr bytes.Buffer
	for name, run := range map[string]func([]string, io.Writer, io.Writer) error{
		"status":   runStatus,
		"failures": runFailures,
	} {
		if err := run([]string{"--config", configPath, "stray"}, &stdout, &stderr); err == nil {
			t.Errorf("%s accepted a positional argument", name)
		}
	}
}

// Retry names an exact durable record, so an unknown one must fail rather than
// silently doing nothing an operator would read as success.
func TestRetryRejectsAnUnknownRecord(t *testing.T) {
	configPath, _ := writeInspectionConfig(t)
	var stdout, stderr bytes.Buffer
	if err := runRetry(
		[]string{"--config", configPath, "--kind", "webhook", "--id", "does_not_exist"},
		&stdout, &stderr,
	); err == nil {
		t.Fatal("retry reported success for a record that does not exist")
	}
}

// Run dispatches by name; an unknown command must say so rather than doing
// nothing.
func TestRunRejectsAnUnknownCommand(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if err := Run([]string{"nonsense"}, &stdout, &stderr, "test"); err == nil {
		t.Fatal("an unknown command was accepted")
	}
	stdout.Reset()
	if err := Run([]string{"version"}, &stdout, &stderr, "v1.2.3"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), "v1.2.3") {
		t.Fatalf("version printed %q", stdout.String())
	}
	stdout.Reset()
	if err := Run(nil, &stdout, &stderr, "test"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), "serve") {
		t.Fatal("running with no arguments did not print help")
	}
}

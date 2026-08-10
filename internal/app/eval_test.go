package app

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/service"
)

func TestEvalCommandReportsGoldenCorpusAndFailures(t *testing.T) {
	var stdout, stderr bytes.Buffer
	resultsPath := filepath.Join(t.TempDir(), "results.json")
	err := runEval(
		[]string{
			"--replay",
			"--input",
			filepath.Join("..", "..", "testdata", "eval", "golden.jsonl"),
			"--results",
			resultsPath,
		},
		&stdout,
		&stderr,
	)
	if err != nil || !strings.Contains(stdout.String(), "passed, 0 failed") {
		t.Fatalf("golden eval = stdout=%q stderr=%q err=%v", stdout.String(), stderr.String(), err)
	}
	info, err := os.Stat(resultsPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("results mode = %o, want 600", info.Mode().Perm())
	}
	body, err := os.ReadFile(resultsPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(body, []byte(`"mode": "replay"`)) {
		t.Fatalf("results = %s", body)
	}

	path := filepath.Join(t.TempDir(), "failed.jsonl")
	if err := os.WriteFile(path, []byte(
		`{"name":"wrong action","kind":"watch","output":"{\"action\":\"ignore\"}","want_action":"reply"}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	failedResults := filepath.Join(t.TempDir(), "failed-results.json")
	err = runEval(
		[]string{
			"--replay", "--input", path,
			"--results", failedResults,
		},
		&stdout,
		&stderr,
	)
	if err == nil || !strings.Contains(stdout.String(), "FAIL wrong action") {
		t.Fatalf("failed eval = stdout=%q stderr=%q err=%v", stdout.String(), stderr.String(), err)
	}
	if body, readErr := os.ReadFile(failedResults); readErr != nil ||
		!bytes.Contains(body, []byte(`"failed": 1`)) {
		t.Fatalf("failed results = %s, %v", body, readErr)
	}
}

func TestEvalCommandRejectsLiveOnlyReplayFlags(t *testing.T) {
	for _, args := range [][]string{
		{"--replay", "--case", "health"},
		{"--replay", "--repeat", "2"},
		{"--repeat", "0"},
		{"--repeat", "11"},
	} {
		var stdout, stderr bytes.Buffer
		if err := runEval(args, &stdout, &stderr); err == nil {
			t.Fatalf("runEval(%v) unexpectedly passed", args)
		}
	}
}

// A repeat-scored corpus is judged by its gate, not by its worst sample.
//
// The regression corpus replays each case three times and asks for two thirds,
// because the same fixture gives a materially different response run to run.
// The exit check ran before that gate and failed on any single bad sample, so a
// corpus judged 8 of 9 with every case above its bar still exited non-zero —
// which makes the repeats pure cost and no signal. With no per-case bar
// configured there is nothing else judging, so one failure is still a failure.
func TestRepeatScoredRunExitsOnItsGateNotItsWorstSample(t *testing.T) {
	judged := service.EvaluationSummary{
		Total: 9, Passed: 8, Failed: 1,
		Gate: service.EvaluationGateResult{Evaluated: true, Passed: true},
	}
	if err := evaluationExit(judged, 0.66); err != nil {
		t.Errorf("a corpus every case passed its bar exited non-zero: %v", err)
	}
	ungated := service.EvaluationSummary{Total: 9, Passed: 8, Failed: 1}
	if err := evaluationExit(ungated, 0); err == nil {
		t.Error("an ungated corpus with a failure exited zero")
	}
	refused := service.EvaluationSummary{
		Total: 3, Unevaluated: 3,
		Gate: service.EvaluationGateResult{Evaluated: true, Passed: false},
	}
	if err := evaluationExit(refused, 0.66); err == nil {
		t.Error("a corpus the provider refused exited zero")
	}
}

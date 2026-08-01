package app

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	if err != nil || !strings.Contains(stdout.String(), "18/18 passed") {
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

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
	err := runEval(
		[]string{"--input", filepath.Join("..", "..", "testdata", "eval", "golden.jsonl")},
		&stdout,
		&stderr,
	)
	if err != nil || !strings.Contains(stdout.String(), "5/5 passed") {
		t.Fatalf("golden eval = stdout=%q stderr=%q err=%v", stdout.String(), stderr.String(), err)
	}

	path := filepath.Join(t.TempDir(), "failed.jsonl")
	if err := os.WriteFile(path, []byte(
		`{"name":"wrong action","kind":"watch","output":"{\"action\":\"ignore\"}","want_action":"reply"}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	err = runEval([]string{"--input", path}, &stdout, &stderr)
	if err == nil || !strings.Contains(stdout.String(), "FAIL wrong action") {
		t.Fatalf("failed eval = stdout=%q stderr=%q err=%v", stdout.String(), stderr.String(), err)
	}
}

package service

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGoldenEvaluationCorpus(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "golden.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	summary, err := EvaluateJSONL(file)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Total < 5 || summary.Failed != 0 || summary.Passed != summary.Total {
		t.Fatalf("evaluation summary = %+v", summary)
	}
}

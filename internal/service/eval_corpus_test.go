package service

import (
	"os"
	"path/filepath"
	"testing"
)

// Every checked-in evaluation corpus must decode and validate.
//
// A malformed case fails only when someone runs the credentialed suite, which
// is exactly when nobody wants to be debugging JSON. Validation is entirely
// deterministic, so it belongs here where it runs on every commit.
func TestEveryEvaluationCorpusIsValid(t *testing.T) {
	corpora, err := filepath.Glob(filepath.Join("..", "..", "testdata", "eval", "*.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if len(corpora) == 0 {
		t.Fatal("no evaluation corpora found; the path has moved")
	}
	for _, path := range corpora {
		t.Run(filepath.Base(path), func(t *testing.T) {
			file, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()

			// Three corpora, three shapes: scenarios carry seeds and steps,
			// calibration carries a labelled response, everything else is a case.
			var names []string
			switch filepath.Base(path) {
			case "scenarios.jsonl":
				scenarios, err := decodeEvaluationScenarios(file)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				for _, scenario := range scenarios {
					names = append(names, scenario.Name)
				}
			case "quality-calibration.jsonl":
				cases, err := decodeQualityCalibrationCases(file)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				for _, testCase := range cases {
					names = append(names, testCase.Name)
				}
			default:
				cases, err := decodeEvaluationCases(file)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				for _, testCase := range cases {
					names = append(names, testCase.Name)
				}
			}
			if len(names) == 0 {
				t.Fatal("corpus has no cases")
			}
			seen := make(map[string]bool, len(names))
			for _, name := range names {
				if seen[name] {
					t.Errorf("duplicate case name %q", name)
				}
				seen[name] = true
			}
		})
	}
}

// The memory corpus is the regression net for recall, and its value is entirely
// in what each case forbids: a case that only asserts a reply happened would
// pass while the agent forgot everything it was taught.
func TestMemoryCorpusAssertsRecallBehaviour(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "memory.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeEvaluationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) < 5 {
		t.Fatalf("memory corpus has %d cases, want at least 5", len(cases))
	}
	for _, testCase := range cases {
		t.Run(testCase.Name, func(t *testing.T) {
			if len(testCase.Memories) == 0 {
				t.Error("a memory case with no memories in context proves nothing")
			}
			asserts := len(testCase.ForbidMessageContains) > 0 ||
				len(testCase.WantMessageContains) > 0 ||
				len(testCase.ForbidEvidenceSources) > 0 ||
				len(testCase.WantMemoryContains) > 0
			if !asserts {
				t.Error("case asserts nothing about how the memory was used")
			}
		})
	}
}

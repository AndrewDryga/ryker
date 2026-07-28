package service

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

type EvaluationCase struct {
	Name        string `json:"name"`
	Kind        string `json:"kind"`
	Output      string `json:"output"`
	WantAction  string `json:"want_action,omitempty"`
	MinEvidence int    `json:"min_evidence,omitempty"`
	MinCoverage int    `json:"min_coverage,omitempty"`
}

type EvaluationResult struct {
	Name   string `json:"name"`
	Passed bool   `json:"passed"`
	Detail string `json:"detail,omitempty"`
}

type EvaluationSummary struct {
	Total   int                `json:"total"`
	Passed  int                `json:"passed"`
	Failed  int                `json:"failed"`
	Results []EvaluationResult `json:"results"`
}

func EvaluateJSONL(reader io.Reader) (EvaluationSummary, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	var summary EvaluationSummary
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var testCase EvaluationCase
		decoder := json.NewDecoder(strings.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&testCase); err != nil {
			return EvaluationSummary{}, fmt.Errorf(
				"decode evaluation case %d: %w", summary.Total+1, err,
			)
		}
		result := evaluateCase(testCase)
		summary.Total++
		if result.Passed {
			summary.Passed++
		} else {
			summary.Failed++
		}
		summary.Results = append(summary.Results, result)
	}
	if err := scanner.Err(); err != nil {
		return EvaluationSummary{}, err
	}
	if summary.Total == 0 {
		return EvaluationSummary{}, fmt.Errorf("evaluation corpus is empty")
	}
	return summary, nil
}

func evaluateCase(testCase EvaluationCase) EvaluationResult {
	result := EvaluationResult{Name: testCase.Name}
	if strings.TrimSpace(testCase.Name) == "" {
		result.Detail = "case has no name"
		return result
	}
	var action string
	var evidence int
	var coverage int
	switch testCase.Kind {
	case "watch":
		decision, err := parseWatchDecision(testCase.Output)
		if err != nil {
			result.Detail = err.Error()
			return result
		}
		action = decision.Action
		evidence = len(decision.Evidence)
		coverage = len(decision.Coverage)
	case "incident":
		report, structured, err := parseAgentReport(testCase.Output)
		if err != nil {
			result.Detail = err.Error()
			return result
		}
		if !structured {
			result.Detail = "incident response is not structured"
			return result
		}
		evidence = len(report.Evidence)
		coverage = len(report.Coverage)
	default:
		result.Detail = "kind must be watch or incident"
		return result
	}
	if testCase.WantAction != "" && action != testCase.WantAction {
		result.Detail = fmt.Sprintf("action = %q, want %q", action, testCase.WantAction)
		return result
	}
	if evidence < testCase.MinEvidence {
		result.Detail = fmt.Sprintf("evidence = %d, want at least %d", evidence, testCase.MinEvidence)
		return result
	}
	if coverage < testCase.MinCoverage {
		result.Detail = fmt.Sprintf("coverage = %d, want at least %d", coverage, testCase.MinCoverage)
		return result
	}
	result.Passed = true
	return result
}

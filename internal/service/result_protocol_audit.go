package service

import (
	"sort"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// ResultProtocolAudit is what replaying stored model results says about the
// legacy compatibility path.
type ResultProtocolAudit struct {
	Total      int      `json:"total"`
	Typed      int      `json:"typed"`
	Fallback   int      `json:"fallback"`
	LegacyOnly int      `json:"legacy_only"`
	Unparsed   int      `json:"unparsed"`
	Reasons    []string `json:"fallback_reasons,omitempty"`
	Examples   []string `json:"fallback_examples,omitempty"`
	// UnparsedExamples matter as much as fallbacks: a result nobody can parse
	// is a turn whose reading is unknown, which is not the same as a turn that
	// used the typed path.
	UnparsedExamples []string `json:"unparsed_examples,omitempty"`
	UnparsedReasons  []string `json:"unparsed_reasons,omitempty"`
}

// StoredResult is one historical model output to replay.
//
// Mode matters: a triage run produces a watch decision and an incident or
// engineering task run produces an agent report. They are different shapes with
// different parsers, and replaying one through the other's parser reports a
// parse failure that says nothing about the legacy path.
type StoredResult struct {
	RunID     string
	Mode      string
	Message   string
	CreatedAt time.Time
}

// AuditResultProtocol re-parses stored model results and reports how many would
// take the legacy fallback.
//
// The forward telemetry counters answer "does anything still rely on the legacy
// reading?" by watching for a week. This answers the same question by replaying
// what already happened, which is available now rather than a week from the
// next deploy. It is the same class of evidence over the same kind of traffic.
//
// What it cannot tell you: whether a future prompt revision reintroduces the
// legacy shape. It measures history under the prompt that produced it. That
// makes it a strong signal and not a proof, and the right way to read a zero
// here is "nothing in four days of real traffic needed the fallback", not
// "the fallback can never be needed".
func AuditResultProtocol(results []StoredResult, now time.Time) ResultProtocolAudit {
	audit := ResultProtocolAudit{Total: len(results)}
	reasons := make(map[string]int)
	for _, result := range results {
		fallback, legacyShape, reason, err := replayStoredResult(result, now)
		switch {
		case err != nil:
			audit.Unparsed++
			if len(audit.UnparsedExamples) < 10 {
				audit.UnparsedExamples = append(audit.UnparsedExamples, result.RunID)
				audit.UnparsedReasons = append(audit.UnparsedReasons, err.Error())
			}
		case fallback:
			audit.Fallback++
			reasons[reason]++
			if len(audit.Examples) < 10 {
				audit.Examples = append(audit.Examples, result.RunID)
			}
		case legacyShape:
			audit.LegacyOnly++
		default:
			audit.Typed++
		}
	}
	for reason := range reasons {
		audit.Reasons = append(audit.Reasons, reason)
	}
	sort.Strings(audit.Reasons)
	return audit
}

// replayStoredResult re-reads one stored result with the parser its mode
// actually used.
func replayStoredResult(
	result StoredResult,
	now time.Time,
) (fallback bool, legacyShape bool, reason string, err error) {
	if result.Mode == string(core.AgentRunTriage) {
		decision, parseErr := parseWatchDecision(result.Message, now)
		if parseErr != nil {
			return false, false, "", parseErr
		}
		return decision.LegacyFallback, decision.LegacyShape, decision.FallbackReason, nil
	}
	report, _, parseErr := parseAgentReport(result.Message)
	if parseErr != nil {
		return false, false, "", parseErr
	}
	return report.LegacyFallback, report.LegacyShape, report.FallbackReason, nil
}

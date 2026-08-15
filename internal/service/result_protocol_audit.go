package service

import (
	"sort"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// ResultProtocolAudit is what replaying stored model results says about the
// legacy compatibility path.
type ResultProtocolAudit struct {
	Total    int      `json:"total"`
	Typed    int      `json:"typed"`
	Fallback int      `json:"fallback"`
	Unparsed int      `json:"unparsed"`
	Reasons  []string `json:"fallback_reasons,omitempty"`
	Examples []string `json:"fallback_examples,omitempty"`
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

// AuditResultProtocol re-parses stored model results and reports how the
// current parser reads them.
//
// It was written to answer one question — "does anything still rely on the
// legacy fallback?" — by replaying history rather than watching forward for a
// week. Against 259 real production turns the answer was zero, and the fallback
// is now gone, so Fallback is always zero by construction.
//
// It stays useful for the job it grew into: Unparsed now counts results the
// current parser cannot read at all, which is exactly what a prompt or contract
// change risks introducing. Run it against recent history before shipping one.
//
// The legacy-shape counter it also carried is gone with the dialect it counted.
// A result that puts its answer in the envelope is refused at the turn that
// produced it, so a stored one is either typed or unreadable.
//
// What it cannot tell you: how a future prompt will behave. It measures history
// under the prompt that produced it.
func AuditResultProtocol(results []StoredResult, now time.Time) ResultProtocolAudit {
	audit := ResultProtocolAudit{Total: len(results)}
	reasons := make(map[string]int)
	for _, result := range results {
		fallback, reason, err := replayStoredResult(result, now)
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
) (fallback bool, reason string, err error) {
	if result.Mode == string(core.AgentRunTriage) {
		if _, parseErr := decisionpkg.ParseWatchDecision(result.Message, now); parseErr != nil {
			return false, "", parseErr
		}
		return false, "", nil
	}
	if _, _, parseErr := decisionpkg.ParseAgentReport(result.Message); parseErr != nil {
		return false, "", parseErr
	}
	return false, "", nil
}

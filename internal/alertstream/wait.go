package alertstream

import (
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// WaitState says whether an answered alert remains active, has just recovered,
// or does not own a host-managed stream wait.
type WaitState uint8

const (
	WaitNone WaitState = iota
	WaitActive
	WaitRecovered
)

// WaitFor classifies only typed verdicts and the host-observed source lifecycle.
func WaitFor(input core.SlackInput, decision decisionpkg.WatchDecision) WaitState {
	if decision.AlertAssessment == nil {
		return WaitNone
	}
	switch decision.AlertAssessment.Verdict {
	case "confirmed_issue", "likely_issue":
		return WaitActive
	case "unverified":
		if !decisionpkg.OperationalAlertResolvedEvent(input.Text) {
			return WaitActive
		}
	case "not_issue":
		return WaitRecovered
	}
	return WaitNone
}

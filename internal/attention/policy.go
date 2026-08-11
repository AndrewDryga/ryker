package attention

import (
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
)

// Enforce suppresses ambient Slack interruptions that do not meet the host's
// configured attention threshold. Typed app-alert assessments are preserved.
func Enforce(
	input core.SlackInput,
	state decision.WatchTurnState,
	result decision.WatchDecision,
	replyThreshold int,
	reactionThreshold int,
) decision.WatchDecision {
	// Once an app alert has been investigated into a typed assessment, its
	// result is the reason the channel policy exists. In particular, recovery
	// updates are naturally low urgency and must not disappear just because the
	// generic ambient-conversation threshold is higher than their attention
	// score. Non-actionable lifecycle noise is suppressed before this point.
	if input.Kind == "bot_message" && state.AlertPolicy != "" &&
		result.Action == "reply" && result.AlertAssessment != nil &&
		decision.OperationalAlertEvent(input.Text) {
		return result
	}
	if !result.Attention.Present() {
		switch {
		case result.Action == "react":
			return decision.SuppressWatchDecision(
				result,
				"host attention policy suppressed a reaction without an assessment",
			)
		case result.Action == "reply" && !decision.WatchInputTargeted(input, state):
			return decision.SuppressWatchDecision(
				result,
				"host attention policy suppressed an ambient reply without an assessment",
			)
		default:
			return result
		}
	}
	targeted := decision.WatchInputTargeted(input, state)
	explicitlyTargeted := decision.WatchInputExplicitlyTargeted(input, state)
	humanAddressee := result.Attention.Addressee == "human"
	insufficient := false
	switch result.Action {
	case "reply":
		insufficient = (!explicitlyTargeted && humanAddressee) ||
			(!targeted && result.Attention.Score() < replyThreshold)
	case "react":
		insufficient = humanAddressee ||
			result.Attention.Score() < reactionThreshold
	}
	if !insufficient {
		return result
	}
	return decision.SuppressWatchDecision(
		result,
		"host attention policy suppressed a low-value interruption",
	)
}

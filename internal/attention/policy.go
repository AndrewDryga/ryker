package attention

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
)

const AmbientContributionPrompt = `
For an ambient message that is not addressed to Emisar, classify the specific new value a reply
would add in attention.contribution: none, material_correction, new_evidence, decision,
completed_action, or necessary_question. Set attention.material=true only when that contribution
changes the team's understanding, decision, or next action. Restating visible message or attachment
content, repeating a blocker already established by nearby people, offering generic advice, or
saying that access is unavailable adds no material value: use contribution=none, material=false,
and action=ignore. A high attention score cannot make a non-material interruption useful.`

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
	humanDirectedThread := ambientHumanDirectedThread(input, state)
	insufficient := false
	switch result.Action {
	case "reply":
		insufficient = (!explicitlyTargeted && humanAddressee) ||
			(humanDirectedThread && !supportsHumanThreadInterruption(result.Attention)) ||
			(!targeted && (result.Attention.Score() < replyThreshold ||
				!supportsAmbientReply(result.Attention)))
	case "react":
		insufficient = humanAddressee ||
			(humanDirectedThread && !supportsHumanThreadInterruption(result.Attention)) ||
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

func supportsAmbientReply(value decision.AttentionAssessment) bool {
	if !value.Material {
		return false
	}
	switch value.Contribution {
	case "material_correction", "new_evidence", "decision", "completed_action", "necessary_question":
		return true
	default:
		return false
	}
}

func supportsHumanThreadInterruption(value decision.AttentionAssessment) bool {
	return value.Material &&
		(value.Contribution == "material_correction" || value.Contribution == "new_evidence")
}

// ambientHumanDirectedThread catches a common Slack shape before trusting a
// model's addressee guess: a human starts a thread by mentioning another human,
// and later replies continue that conversation without addressing Responder.
// In that case an ambient bot reply needs a stronger reason than general
// channel participation: genuinely new evidence or a material correction.
func ambientHumanDirectedThread(input core.SlackInput, state decision.WatchTurnState) bool {
	if input.Kind != "message" || input.ThreadTS == "" ||
		decision.WatchInputExplicitlyTargeted(input, state) || state.ConversationFollowup {
		return false
	}
	for _, message := range state.RecentMessages {
		if message.MessageTS != input.ThreadTS {
			continue
		}
		return message.SenderType == "human" && !message.MentionsResponder &&
			containsSlackUserMention(message.Text)
	}
	return false
}

func containsSlackUserMention(text string) bool {
	for {
		start := strings.Index(text, "<@")
		if start < 0 {
			return false
		}
		text = text[start+2:]
		if end := strings.IndexByte(text, '>'); end > 0 {
			return true
		}
	}
}

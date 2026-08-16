package alertstream

import (
	"strings"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// AnsweredPrompt tells the model what this stream has already been told, so
// that "nothing has changed" is a decision it can actually make.
//
// The instruction to stay silent unless something changed has been in the
// prompt the whole time, and it never said what "unchanged" was measured
// against: a repeat card looked exactly like a first one, so the only honest
// answer available was to restate the assessment. That is what happened five
// times in ninety minutes on 2026-08-16.
//
// Empty for a stream with no answer behind it, which is exactly the case where
// silence is not allowed.
func AnsweredPrompt(state decisionpkg.WatchTurnState) string {
	at := strings.TrimSpace(state.StreamAnsweredAt)
	if at == "" {
		return ""
	}
	verdict := strings.TrimSpace(state.StreamAnsweredVerdict)
	if verdict == "" {
		verdict = "not recorded"
	}
	action := strings.TrimSpace(state.StreamAnsweredAction)
	if action == "" {
		action = "none recorded"
	}
	return "\n\n<host-stream-answered>\n" +
		"Responder already answered this alert stream in this thread at " + at +
		": verdict " + verdict + "; recommended action: " + action + ".\n" +
		"Reply only if the verdict, the impact, or the recommended action has changed since " +
		"then, and lead with the change. A card that restates the same condition — a threshold " +
		"crossed again, another node over the same line, a resolve that is not a recovery — is " +
		"a duplicate: return ignore with the same typed evidence and coverage.\n" +
		"</host-stream-answered>"
}

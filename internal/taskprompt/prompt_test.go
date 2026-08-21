package taskprompt

import (
	"strings"
	"testing"
)

// A production feedback turn changed two files and passed thirty tests, then
// reported completion with the task workspace still dirty. The next PR review
// correctly refused that workspace, so the accepted answer appeared to do
// nothing and the operator was left with a broken Update PR button.
func TestEngineeringFeedbackCommitsItsIntendedChangesBeforeCompletion(t *testing.T) {
	for name, prompt := range map[string]string{
		"operator":    OperatorConversation("UOPERATOR", "Use five-minute windows.", true),
		"contributor": Conversation("UMEMBER", "Use five-minute windows.", true),
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"commit all intended repository changes",
				"Do not push",
				"Responder updates the existing draft PR",
			} {
				if !strings.Contains(prompt, want) {
					t.Fatalf("engineering feedback prompt lacks %q:\n%s", want, prompt)
				}
			}
		})
	}
}

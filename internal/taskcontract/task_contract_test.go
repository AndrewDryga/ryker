package taskcontract

import (
	"slices"
	"testing"

	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
)

// Publication intent is classified once from the operator request and stored
// as a stable contract token. Later validation never searches model prose.
func TestReusableArtifactOutcomeHandlesParaphraseAndNegation(t *testing.T) {
	for _, test := range []struct {
		text string
		want bool
	}{
		{"Create a reusable playbook and make it the default for tomorrow's review.", true},
		{"Ship the runbook so the scheduled check uses this revision.", true},
		{"Draft a runbook for discussion; do not publish or activate it.", false},
	} {
		episode := &core.WorkEpisode{RequiredCoverage: []string{"task"}}
		ApplyReusableArtifact(episode, test.text)
		got := slices.Contains(episode.CompletionCriteria, completionpolicy.PublishedArtifactCriterion)
		if got != test.want {
			t.Errorf("publication contract for %q = %t, want %t", test.text, got, test.want)
		}
	}
}

package investigation

import "testing"

// The authoring guard must read words, not letter sequences.
//
// Matching the verbs as substrings read "authorized" as "author", which demoted
// a real whole-platform health assessment — a scheduled review whose prompt
// says "Decide healthy, degraded, or unhealthy" — into a factual assessment,
// because the same prompt allowed running "equivalent authorized read-only
// checks". The regression corpus caught it as a blocked completion two layers
// downstream, which says nothing about the cause.
func TestReusableArtifactAuthoringReadsWholeWords(t *testing.T) {
	for text, want := range map[string]bool{
		"Create reusable deep infrastructure health review runbook": true,
		"Please write a runbook for the nightly checks":             true,
		"Extend that playbook and test it":                          true,
		"Rewrite the deploy workflow so it fails loudly":            true,
		"Draft a runbook covering the failover":                     true,
		"Editing the runbook to drop the stale step":                true,

		// Authoring words hiding inside other words.
		"Use the runbook, or run equivalent authorized read-only checks":    false,
		"Give the runbook credit for catching it; is the platform healthy?": false,
		"The authoritative runbook says the workflow is fine":               false,

		// Execution, not authoring.
		"Run the deep infrastructure health review runbook and report health":  false,
		"The build for the deploy workflow failed; make sure everything is ok": false,

		// No artifact named at all.
		"Create a summary of the infrastructure health review": false,
	} {
		if got := ReusableArtifactAuthoring(text); got != want {
			t.Errorf("ReusableArtifactAuthoring(%q) = %v, want %v", text, got, want)
		}
	}
}

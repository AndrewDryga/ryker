package service

import "testing"

// A Coop target is provider[:model][/effort][@credential], and the three
// columns that hold its parts sat empty on all 57 manifest rows because nothing
// ever assigned them. Parsed here rather than imported from Coop so a target
// this cannot read degrades to a blank field instead of failing an episode over
// a formatting change in another repository.
func TestTargetPartsAreRecordedFromWhatActuallyRan(t *testing.T) {
	for _, testCase := range []struct{ target, provider, model, effort string }{
		{"claude:opus/max@oncall", "claude", "opus", "max"},
		{"codex:gpt-5.6-sol/xhigh@oncall", "codex", "gpt-5.6-sol", "xhigh"},
		{"claude:opus", "claude", "opus", ""},
		{"claude/high", "claude", "", "high"},
		{"claude", "claude", "", ""},
		{"claude@personal", "claude", "", ""},
		{"", "", "", ""},
		// Unreadable rather than invalid: a blank beats an episode failing
		// because another repository changed its target grammar.
		{"::/", "", ":", ""},
	} {
		provider, model, effort := targetParts(testCase.target)
		if provider != testCase.provider || model != testCase.model || effort != testCase.effort {
			t.Errorf("targetParts(%q) = %q/%q/%q, want %q/%q/%q", testCase.target,
				provider, model, effort, testCase.provider, testCase.model, testCase.effort)
		}
	}
}

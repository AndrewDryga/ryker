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
		if got := targetProvider(testCase.target); got != testCase.provider {
			t.Errorf("targetProvider(%q) = %q, want %q", testCase.target, got, testCase.provider)
		}
		if got := targetModel(testCase.target); got != testCase.model {
			t.Errorf("targetModel(%q) = %q, want %q", testCase.target, got, testCase.model)
		}
		if got := targetEffort(testCase.target); got != testCase.effort {
			t.Errorf("targetEffort(%q) = %q, want %q", testCase.target, got, testCase.effort)
		}
	}
}

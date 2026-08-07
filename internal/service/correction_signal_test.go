package service

import "testing"

// The correction vocabulary is small on purpose: it is meant to be counted.
//
// Correction text quotes model output and is unbounded prose. The class is what
// makes the signal a metric rather than a log, so it must stay a closed set —
// the moment it becomes free text, "correction rate per class" stops meaning
// anything.
func TestCorrectionClassesAreASmallClosedSet(t *testing.T) {
	classes := []correctionClass{
		correctionUnreadable,
		correctionIncomplete,
		correctionPolicy,
	}
	seen := make(map[correctionClass]bool, len(classes))
	for _, class := range classes {
		if class == "" {
			t.Error("a correction class is empty; it would count as an unlabelled bucket")
		}
		if seen[class] {
			t.Errorf("duplicate correction class %q", class)
		}
		seen[class] = true
	}
	if len(classes) > 5 {
		t.Errorf("%d correction classes; past a handful this stops being countable "+
			"and becomes a second copy of the correction text", len(classes))
	}
}

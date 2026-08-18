package scheduletext

import (
	"slices"
	"testing"
)

func TestRequestedDayOffsetsReadsWhatWasAsked(t *testing.T) {
	for _, testCase := range []struct {
		text string
		want []int
	}{
		{"check the disk tomorrow and in 3 days", []int{1, 3}},
		{"same time tomorrow please", []int{1}},
		{"look again in two weeks", []int{14}},
		{"in a day, and in 3 days as well", []int{1, 3}},
		// Recurrence is a different shape of request, and reading an offset out
		// of it would invent an occurrence the operator never named.
		{"every morning at 9", nil},
		{"remind me every three days", nil},
		// Nothing unambiguous to read leaves the batch to the checks that were
		// already there rather than guessing.
		{"check it again soon", nil},
	} {
		got := RequestedDayOffsets(testCase.text)
		if len(got) == 0 && len(testCase.want) == 0 {
			continue
		}
		if !slices.Equal(got, testCase.want) {
			t.Fatalf("RequestedDayOffsets(%q) = %v, want %v", testCase.text, got, testCase.want)
		}
	}
}

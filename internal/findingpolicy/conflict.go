// Package findingpolicy owns cross-record invariants for structured findings.
package findingpolicy

import (
	"strconv"
	"strings"

	"github.com/AndrewDryga/responder/internal/investigation"
)

// InitialCorrection applies the finding checks that precede completion policy.
// A false second result means later checks should continue.
func InitialCorrection(action string, findings []investigation.FindingOperation) (string, bool) {
	if action != "reply" {
		return "", true
	}
	for earlierIndex, earlier := range findings {
		earlierKey := strings.TrimSpace(earlier.Key)
		earlierWhat := strings.TrimSpace(earlier.What)
		if earlierKey == "" || earlierWhat == "" {
			continue
		}
		for _, later := range findings[earlierIndex+1:] {
			laterKey := strings.TrimSpace(later.Key)
			if laterKey == "" || earlierKey == laterKey ||
				!strings.EqualFold(earlierWhat, strings.TrimSpace(later.What)) ||
				earlier.Status == later.Status {
				continue
			}
			return "finding " + strconv.Quote(earlierWhat) + " has conflicting statuses under " +
				"stable keys " + strconv.Quote(earlierKey) + " and " + strconv.Quote(laterKey) +
				"; rewrite the original stable key with the current classification instead of " +
				"creating a second finding", true
		}
	}
	return "", false
}

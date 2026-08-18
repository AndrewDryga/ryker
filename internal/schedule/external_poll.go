package schedule

import "time"

const minimumTerraformPollInterval = 10 * time.Minute

// BoundedExternalPollAfter keeps model-authored lifecycle waits from becoming
// busy loops. Slack lifecycle events remain the fast path; this poll is only a
// fallback for a missed or delayed card.
func BoundedExternalPollAfter(
	kind string,
	pollAfter time.Time,
	deadline time.Time,
	now time.Time,
) time.Time {
	if kind != "terraform_run" || pollAfter.IsZero() {
		return pollAfter
	}
	earliest := now.UTC().Add(minimumTerraformPollInterval)
	if !deadline.IsZero() && deadline.Before(earliest) {
		earliest = deadline
	}
	if pollAfter.Before(earliest) {
		return earliest
	}
	return pollAfter
}

package alertstream

import "strings"

// WithOOMCompletionCriteria adds the concrete questions an OOM investigation
// must answer before it can finish.
func WithOOMCompletionCriteria(criteria []string, alertText string) []string {
	if !containsAnyFold(alertText, "oom", "out of memory") {
		return criteria
	}
	return append(criteria,
		"identify the killed process, cgroup, event time, and owning allocation or task",
		"verify Nomad restart or replacement state, restart count, current task memory versus its limit, and host memory pressure",
		"verify current service health and bound user impact during and after the kill",
	)
}

func containsAnyFold(text string, values ...string) bool {
	for _, value := range values {
		if strings.Contains(strings.ToLower(text), value) {
			return true
		}
	}
	return false
}

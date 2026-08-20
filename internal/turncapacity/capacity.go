// Package turncapacity owns the host's automatic Coop request ceiling.
package turncapacity

import "fmt"

const reachedPrefix = "Responder reached this channel's automatic safety ceiling"

type LimitError struct {
	Limit int
}

func (e *LimitError) Error() string {
	return fmt.Sprintf(
		"automatic turn ceiling %d reached; raise coop.turn_limit in responder.yaml to continue",
		e.Limit,
	)
}

func Message(limit int) string {
	return fmt.Sprintf(
		reachedPrefix+" of %d agent requests. "+
			"The pending request and Coop session are preserved. The ceiling is "+
			"`coop.turn_limit` in responder.yaml; raising it needs a deployment change, "+
			"because a session that has spent %d accepted requests is usually looping "+
			"rather than short of room. This counts accepted requests, not tool calls or "+
			"investigation steps within a request.",
		limit,
		limit,
	)
}

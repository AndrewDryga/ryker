// Package agentprompt owns reusable host instructions for agent turns.
package agentprompt

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

func ToolTransport() string {
	return `

<host-tool-transport>
Keep tool output bounded without reducing investigation quality. Prefer precise filters, narrow time
windows, server-side aggregation, counts or top-N results, and pagination when the tool supports it.
Do not request complete logs, histories, inventories, or source trees when narrower queries can answer
the claim. If a result is truncated or unexpectedly large, refine the next query instead of repeating
the broad call. Maintain a concise working summary of verified facts as you go. Transport limits are
not a reason to stop: continue until the work episode is decision-ready or has an exact external
blocker.
</host-tool-transport>`
}

func Continuation(run core.AgentRun) string {
	lower := strings.ToLower(run.LastError)
	if decisionpkg.StructuredResultFailure(run.LastError) {
		return `

<host-structured-correction>
The previous turn completed its work, but Responder rejected only its final structured report.
Preserve the work and verified result. Return a corrected report that fixes this exact host validation
error: ` + decisionpkg.BoundedField(run.LastError, 1200) + `
Do not repeat the investigation or drop completed work merely to repair the response envelope.
</host-structured-correction>`
	}
	if strings.Contains(lower, "acp transcript") {
		return `

<host-transport-recovery>
The previous read-only session exceeded Coop's ACP transcript bound and returned no usable final
answer. This is a fresh authenticated session with the original Slack request and saved Responder
context. Restart the required checks from current authoritative evidence. Avoid the prior failure by
using tightly filtered queries, short time windows, aggregation, top-N results, and pagination rather
than broad raw output. Do not assume that observations from the failed session are valid. Complete the
full effort contract and return the exact structured response requested by the host.
</host-transport-recovery>`
	}
	if strings.Contains(lower, "acp child closed") ||
		strings.Contains(lower, "turn was interrupted") {
		return `

<host-transport-recovery>
The previous read-only agent process ended before returning an answer. This is a fresh authenticated
session with the original Slack request and saved context. Perform the requested work from current
authoritative evidence; do not assume that unreported observations from the interrupted process are
valid. Long task duration is not a reason to stop. Return the exact structured response requested by
the host when the task is complete.
</host-transport-recovery>`
	}
	return ""
}

// LegacyResultShape asks for the same decision in the typed shape, and is
// deliberately not the correction blocks above it.
//
// Those open by telling the model its result was rejected and close by asking
// for a fresh one. Both would be false here and the second would be harmful:
// the host read this result, validated it through the whole ladder, and is
// ready to act on it — so a re-decided answer is a different answer to a
// question that was already answered well. The only thing being asked for is
// the transport.
func LegacyResultShape(detail string) string {
	if strings.TrimSpace(detail) == "" {
		return ""
	}
	return `

<host-result-shape-correction>
Your previous decision was accepted and is not in question: ` + detail + `
Do not re-evaluate the target message, change the decision, soften it, or redo any work. Re-emit
exactly what you already concluded, in the typed shape.
</host-result-shape-correction>`
}

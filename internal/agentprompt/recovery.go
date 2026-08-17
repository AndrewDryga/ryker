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
		// core.CorrectionTextLimit rather than the 1200 this carried while a
		// correction was one validator sentence. A refused completion's
		// correction quotes both sides of every conflict with their evidence
		// ids, and the ids are last on each line: bounding at 1200 cut the
		// answer out of the question on a two-claim refusal.
		return `

<host-structured-correction>
The previous turn completed its work, but Responder rejected only its final structured report.
Preserve the work and verified result. Return a corrected report that fixes this exact host validation
error: ` + decisionpkg.BoundedField(run.LastError, core.CorrectionTextLimit) + `
Return only what changes: your one complete_episode with the report message every time, beside the
operations you are changing. Leave out any record_evidence, record_coverage or record_finding you are
not changing — the host still holds it, and omitting one does not retract it. Change a record by
sending it again with the same id and the same finding what; that replaces it.
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

// SessionHandoff asks a Coop session that is about to be retired for the one
// thing that dies with it.
//
// It is the whole envelope rather than a sentence because the turn has to
// produce a valid silent ignore — exactly one update_memory and no reply — and
// the shortest way to be sure of that is to show the shape. Nothing is waiting
// on this turn, so it is also told, in as few words as possible, not to do
// anything that would make anyone wait.
func SessionHandoff() string {
	return `This session is being retired and its transcript will not be carried forward.

Write down what the next session needs to continue this channel's work without repeating it:
the current situation, what has been established, what is still open, and the decisions taken.

Do not investigate, read anything, or reply in Slack. Answer with exactly this shape:

{"action":"ignore","reason":"<what is worth carrying>","operations":[{"id":"handoff","type":"update_memory","memory":{"situation_summary":"","channel_purpose":"","open_loops":[],"decisions":[],"topology":[]}}]}

Omit any memory field you have nothing durable to put in.`
}

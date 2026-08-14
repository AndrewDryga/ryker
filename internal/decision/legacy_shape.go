package decision

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// envelopeOwnedWatchFields names the members of WatchDecisionPayload that
// belong to the transport envelope rather than to the result.
//
// The distinction is the whole point of this file. LegacyShape is set whenever
// a decision arrives without an operation stream, and for ignore, react and
// incident that is the documented, correct answer — those actions carry no
// result. Reading LegacyShape alone as "the model used the old protocol" makes
// every routine ignore look like a violation: across both live instances, 110
// of the 147 readable legacy results were bare envelopes with nothing in them
// to move. Correcting those would spend a model turn per ignored Slack message
// to rewrite nothing.
//
//   - reaction and title are the react and incident payloads, and no operation
//     carries either.
//   - publication_updates is routing state the host reconciles, and
//     MarshalWatchDecisionResult keeps it beside operations for that reason.
//   - task_pull_request has no operation at all: TaskOffer carries kind, title,
//     repository and prompt, and nothing else. A model asked to update an exact
//     existing PR has no typed way to say so, so the field stays top-level and
//     stays documented until an operation carries it.
var envelopeOwnedWatchFields = map[string]bool{
	"reaction":            true,
	"title":               true,
	"task_pull_request":   true,
	"publication_updates": true,
}

// LegacyResultFields names the result-bearing fields this decision put in the
// envelope instead of in its operation stream, in the table's order.
//
// Derived from WatchDecisionPayload so that adding a field to WatchDecision
// keeps being the single-line change that table was built to make it. A new
// field is treated as result-bearing unless it is named above, which is the
// safe default: the cost of a wrong guess here is one correction turn, not a
// silently unread field.
func LegacyResultFields(decision WatchDecision) []string {
	var fields []string
	for _, field := range WatchDecisionPayload {
		if envelopeOwnedWatchFields[field.name] || !field.present(decision) {
			continue
		}
		fields = append(fields, field.name)
	}
	// memory is absent from WatchDecisionPayload because per-action validation
	// never restricted it, but it is exactly what the typed protocol moved into
	// update_memory — and it is the most common thing a legacy ignore carries.
	if !watchMemoryEmpty(decision.Memory) {
		fields = append(fields, "memory")
	}
	return fields
}

// watchMemoryEmpty reports whether a conversation situation says nothing.
//
// Written out rather than compared against a zero value because AgentMemory
// holds slices and cannot be compared with ==, and rather than reflected over
// because this runs on the result of every watch turn.
func watchMemoryEmpty(memory core.AgentMemory) bool {
	return memory.Goal == "" && memory.ChannelPurpose == "" &&
		memory.SituationSummary == "" && len(memory.ActiveTopics) == 0 &&
		len(memory.OpenLoops) == 0 && len(memory.Topology) == 0 &&
		len(memory.Decisions) == 0 && len(memory.UnresolvedQuestions) == 0 &&
		len(memory.EvidenceRefs) == 0 && len(memory.Knowledge) == 0
}

// LegacyShapeCorrectionPrefix opens every legacy-shape correction.
//
// It leads with the fact that the result was accepted because that is the part
// the model has to believe: this correction is the only one in the ladder that
// is not a complaint about the answer, and one read as a rejection produces a
// re-decided answer to a question that was already answered well.
const LegacyShapeCorrectionPrefix = "the result was read and accepted, but it carried"

// LegacyShapeCorrection asks for the same decision back in the typed shape, or
// returns empty when there is nothing to move.
//
// It fires only on a decision that actually put result content in the envelope.
// An empty operation stream is not by itself a violation — it is what ignore
// and react are documented to return — and the tolerance stays either way: this
// is pressure on the protocol, not a gate on the answer.
//
// sent is WatchTurnState.LegacyShapeDetail, the correction this turn already
// issued. One request, hard: the result parsed and is already usable, so a
// second round trip buys nothing but the shape of the JSON, and a correction of
// a correction is the loop that would turn a tolerated format into an unbounded
// retry. The rule lives beside the field that carries it so the two cannot
// drift.
func LegacyShapeCorrection(decision WatchDecision, sent string) string {
	if !decision.LegacyShape || sent != "" {
		return ""
	}
	fields := LegacyResultFields(decision)
	if len(fields) == 0 {
		return ""
	}
	// Only where the typed shape can actually express this decision. Asking for
	// operations the host would then read as a different decision is worse than
	// tolerating the old shape, because the answer changes rather than the
	// envelope.
	switch decision.Action {
	case "reply":
		// Folding operations onto a reply is the identity: every field above
		// has an operation, and ApplyWatchResultOperations projects them back.
	case "ignore":
		// The silent path is exact — ApplySilentWatchMemoryOperation takes one
		// update_memory and refuses any other operation or result field. An
		// ignore that also recorded evidence has nowhere to put it: two
		// operations fail that check, and evidence alone falls through to the
		// projection below it, which rewrites the action to reply. Correcting
		// one would make Responder speak in a conversation it had decided to
		// stay out of.
		if len(fields) != 1 || fields[0] != "memory" {
			return ""
		}
	default:
		// incident, react and escalate carry their result in the envelope by
		// design. ApplyWatchResultOperations rewrites any non-ignore action
		// that arrives with operations to reply, so a corrected incident would
		// come back as a reply and never open the incident it classified.
		return ""
	}
	return LegacyShapeCorrectionPrefix + " its result in the legacy top-level " +
		"field(s) " + strings.Join(fields, ", ") + " instead of a typed operations array. " +
		"Return the same decision again, unchanged in substance, with every one of those " +
		"fields moved into operations: the answer and its completion in one complete_episode, " +
		"conversation memory in update_memory, each finding in record_evidence, each assessed " +
		"claim group in record_coverage, an offered incident or engineering task in offer_task, " +
		"and each durable behavior offer in its own offer_memory, offer_preference, offer_rule " +
		"or offer_schedule. Keep action, attention and reason where they are, and send no " +
		"legacy result field beside operations."
}

package decision

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// envelopeOwnedWatchFields names the members of WatchDecisionPayload that
// belong to the transport envelope rather than to the result.
//
// The distinction is the whole point of this file. An empty operation stream is
// not by itself wrong — for ignore, react and incident it is the documented,
// correct answer, and across both live instances 110 of the 147 readable
// envelope-shaped results were bare envelopes with nothing in them to move.
// Rejecting those would spend a model turn per ignored Slack message.
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

// MisplacedResultFields names the result-bearing fields this decision put in
// the envelope instead of in its operation stream, in the table's order.
//
// Derived from WatchDecisionPayload so that adding a field to WatchDecision
// keeps being the single-line change that table was built to make it. A new
// field is treated as result-bearing unless it is named above, which is the
// safe default: a wrong guess here rejects one turn that had a typed way to say
// what it said, rather than silently letting a field go unread forever.
func MisplacedResultFields(decision WatchDecision) []string {
	var fields []string
	for _, field := range WatchDecisionPayload {
		if envelopeOwnedWatchFields[field.name] || !field.present(decision) {
			continue
		}
		fields = append(fields, field.name)
	}
	// memory is absent from WatchDecisionPayload because per-action validation
	// never restricted it, but it is exactly what the typed protocol moved into
	// update_memory — and it is the most common thing an envelope-shaped ignore
	// carries.
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

// UnreadableEnvelopeResult says why a decision cannot be read, or returns empty
// when the envelope carries only routing.
//
// There is one result dialect. A decision whose result sits in top-level fields
// with no operation stream behind it is the retired one, and until 2026-08-14
// the host read it, acted on it, and asked once for the same answer back in
// typed operations — a correction class of its own that existed only to
// translate. Tolerating it is what taught every model serving both lanes two
// dialects for the same channel, so it is deleted: this is a rejection now, and
// the caller turns it into the ordinary unreadable correction.
//
// It fires only where the typed shape expresses the same decision. That
// restraint is not politeness, it is the difference between a correction the
// model can satisfy and one it cannot: ApplyWatchResultOperations rewrites any
// non-ignore action arriving with operations to reply, so an incident told to
// move its evidence into operations would come back as a reply and never open
// the incident it classified.
func UnreadableEnvelopeResult(decision WatchDecision) string {
	if len(decision.Operations) != 0 {
		return ""
	}
	fields := MisplacedResultFields(decision)
	if len(fields) == 0 {
		return ""
	}
	switch decision.Action {
	case "reply":
		// Folding operations onto a reply is the identity: every field above
		// has an operation, and ApplyWatchResultOperations projects them back.
	case "ignore":
		// The silent path is exact — ApplySilentWatchMemoryOperation takes one
		// update_memory and refuses any other operation or result field. An
		// ignore that also recorded evidence has nowhere to put it: two
		// operations fail that check, and evidence alone falls through to the
		// projection below it, which rewrites the action to reply. Rejecting
		// one would make Responder speak in a conversation it had decided to
		// stay out of, or block it over a shape it cannot fix.
		if len(fields) != 1 || fields[0] != "memory" {
			return ""
		}
	default:
		// incident, react and escalate carry their result in the envelope by
		// design; see the note above about the action being rewritten.
		return ""
	}
	return "the result envelope carries " + strings.Join(fields, ", ") +
		" instead of a typed operations array. The envelope's whole field set is " +
		"action, reaction, title, attention, reason, task_pull_request, " +
		"publication_updates and operations, and every part of a result travels as " +
		"an operation: the answer and its completion in one complete_episode, " +
		"conversation memory in update_memory, each finding in record_evidence, each " +
		"assessed claim group in record_coverage, an offered incident or engineering " +
		"task in offer_task, and each durable behavior offer in its own offer_memory, " +
		"offer_preference, offer_rule or offer_schedule. Return the same decision, " +
		"unchanged in substance, with those fields moved into operations."
}

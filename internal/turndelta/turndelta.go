// Package turndelta decides whether a follow-up attempt may speak into the Coop
// session that already holds its briefing, instead of restating that briefing.
//
// Every Ryker prompt restates its durable context so a turn survives session
// rotation, Coop restarts and fresh-session replay. That invariant is right and
// nothing here weakens it — but its granularity was wrong. Self-containment is
// needed per SESSION-OPENING turn, not per turn, and the host already knows
// which turns open a session and which continue one.
//
// Measured on the blitz deployment over 2026-08-14 and the first five hours of
// 2026-08-15: 201 follow-up attempts submitted 30,258,462 bytes into sessions
// that already held the previous briefing, of which 99.22% was byte-identical to
// the message immediately before it. The median follow-up carried 0.43% new
// material inside a 150 KB message, and prefix caching cannot dedupe repeated
// text inside a NEW message, so all of it was billed and prefilled again:
// 9,095,356 uncached input tokens across 14,427 seconds of provider time, spent
// restating what the conversation already contained.
//
// Replaying those 201 turns through what this package sends instead: 30,258,462
// bytes become 2,464,614, an average turn of 150,540 bytes becomes 12,262, and
// about 8.35 million of those 9.1 million input tokens are never sent. The
// remainder is deliberate — the episode contract and the correction ride every
// delta, for the reason written on Sections.Contract.
//
// Decide is deliberately a pile of veto clauses over a pure input. Every doubt
// falls back to the full briefing, and the full briefing is what the host does
// today — so the failure mode of this package is the status quo, and the only
// way it can hurt is by saying "delta" when the session does not in fact hold
// the standing briefing. Each clause below exists to make one of those cases
// impossible to reach.
package turndelta

import "strings"

// Session is the live Coop session this attempt would submit into, as the
// channel projection and Coop itself report it at lease time.
type Session struct {
	ID    string
	State string
	// Preset is the Coop session policy. A session whose policy changed is a
	// session whose standing instructions changed with it.
	Preset     string
	Generation int
	// Cursor is the projection's position in this session's event stream. It is
	// advanced only when a run reaches a terminal, which is what makes it a
	// statement about what the session has finished saying.
	Cursor int64
}

// Attempt is the run being leased, as it sits in the store before this turn is
// bound and submitted.
type Attempt struct {
	// FrozenManifestID is the manifest this attempt already recorded, empty when
	// it has none. A manifest freezes the exact prompt that was submitted, so an
	// attempt holding one must resubmit that prompt rather than a shorter one —
	// otherwise the record and the conversation disagree about what was sent.
	FrozenManifestID string
	SessionID        string
	// TurnID is this run's live Coop turn. It is cleared when a turn reaches a
	// terminal, so a non-empty one means the previous turn has not finished.
	TurnID            string
	SessionGeneration int
	// Cursor is the run's own read position, advanced only by writes that
	// require state='running'. A run whose cursor has moved is a run whose turn
	// reached Coop, which is the delivery proof this package needs and the one
	// the store can actually make.
	Cursor int64
	// Replay marks an attempt deliberately being retried in a fresh session, and
	// Handoff an attempt that opens its own session to retire another.
	Replay  bool
	Handoff bool
	// TargetFloor is the rung of the session policy's target ladder this
	// attempt will not be answered below. A repeated correction raises it, and
	// a raised rung is a different model — so it is a statement about WHO is
	// about to answer, not about how hard they will try.
	TargetFloor int
}

// Contract is the triple a briefing teaches: how to read the prompt, what the
// investigation must contain, and the shape of the result.
type Contract struct {
	Prompt        string
	Investigation string
	ToolSchema    string
}

// Standing is the briefing the session already holds — the previous manifest of
// this episode.
type Standing struct {
	ManifestID string
	Preset     string
	Contract   Contract
	// Prompt is the briefing's text as submitted.
	Prompt string
	// Delivered reports that this briefing carried a real submitted prompt. A
	// manifest is frozen BEFORE the submit it describes, so its existence alone
	// proves only that the host meant to send something.
	Delivered bool
	// TargetFloor is the rung this briefing was submitted at, frozen on its
	// manifest. It is the only record of which model was taught the contract.
	TargetFloor int
}

// Decision is the answer and the sentence explaining it. Reason is recorded
// either way: a delta that was not taken is the more interesting of the two,
// and until it is written down nobody can tell a rotation from a policy change.
type Decision struct {
	Delta bool
	// ParentManifestID is the briefing the delta leans on, empty unless Delta.
	ParentManifestID string
	Reason           string
	// StandingPrompt is that briefing's text, so Prompt can drop any section it
	// already carried word for word. Empty unless Delta.
	StandingPrompt string
}

// The reasons, as sentences rather than codes, because they are read in an
// omission record and on the episode trace by people who did not write them.
const (
	ReasonStandingBriefingHeld = "the standing briefing is already in this session"
	ReasonNoStandingBriefing   = "no earlier briefing of this episode was delivered"
	ReasonAttemptAlreadyFrozen = "this attempt already froze the briefing it must submit"
	ReasonRotatedSession       = "the session rotated after the standing briefing"
	ReasonSessionNotOpen       = "the Coop session is not open"
	ReasonTurnInFlight         = "the previous turn of this run has not finished"
	ReasonCursorMoved          = "the session moved past the standing briefing's turn"
	ReasonContractChanged      = "the prompt contract changed mid-episode"
	ReasonPresetChanged        = "the session policy changed mid-episode"
	ReasonFreshSessionReplay   = "this attempt replays in a fresh session"
	ReasonSessionHandoff       = "a session handoff opens the session it speaks into"
	ReasonRungEscalated        = "the retry is delivered on a higher policy rung than " +
		"the standing briefing was; the model answering has not read it"
)

// Decide reports whether this attempt may submit a delta turn.
//
// The clauses are ordered from the cheapest and most common negative to the
// subtlest, so the reason an operator reads is the first true thing about the
// turn rather than the last one checked.
func Decide(
	session Session,
	attempt Attempt,
	standing Standing,
	contract Contract,
) Decision {
	full := func(reason string) Decision { return Decision{Reason: reason} }
	switch {
	case attempt.Handoff:
		return full(ReasonSessionHandoff)
	case attempt.Replay:
		return full(ReasonFreshSessionReplay)
	case attempt.FrozenManifestID != "":
		return full(ReasonAttemptAlreadyFrozen)
	case standing.ManifestID == "" || !standing.Delivered:
		return full(ReasonNoStandingBriefing)
	case attempt.TargetFloor > standing.TargetFloor:
		// The session holds the briefing and a different model is about to read
		// the session. Every other clause here asks whether the CONVERSATION
		// still holds the standing briefing; this one asks whether the model
		// answering has read it, and a ladder step means it has not.
		//
		// Measured on blitz on 2026-08-16: an escalated retry answered
		// `unknown field "completion_contract"` and then `unknown field
		// "record_evidence"` — two envelope rounds, about $0.85 and four
		// minutes, spent learning a schema the previous rung had been taught
		// and this one had never seen.
		//
		// Strictly greater, so the ordinary retries that follow an escalation
		// stay deltas: they submit at the rung their own briefing went out on.
		return full(ReasonRungEscalated)
	case attempt.TurnID != "":
		return full(ReasonTurnInFlight)
	case session.State != "open":
		return full(ReasonSessionNotOpen)
	case session.ID == "" || attempt.SessionID == "" ||
		session.ID != attempt.SessionID ||
		session.Generation != attempt.SessionGeneration:
		// A new run for a superseded episode arrives here with an empty session
		// and takes this branch, which is the intended answer: the episode was
		// handed to a run that has never spoken, and nothing in Coop has heard
		// the briefing on its behalf.
		return full(ReasonRotatedSession)
	case attempt.Cursor <= 0 || session.Cursor != attempt.Cursor:
		// The whole delivery proof, in one comparison. The run's cursor moves
		// only from a state='running' write, so a positive cursor means this run
		// reached Coop; the projection's cursor moves only at a terminal, so
		// equality means the session has finished exactly the turn this run last
		// held and nothing has spoken since.
		return full(ReasonCursorMoved)
	case standing.Preset != session.Preset:
		return full(ReasonPresetChanged)
	case standing.Contract != contract:
		return full(ReasonContractChanged)
	}
	return Decision{
		Delta:            true,
		ParentManifestID: standing.ManifestID,
		Reason:           ReasonStandingBriefingHeld,
		StandingPrompt:   standing.Prompt,
	}
}

// Sections is what a delta turn carries: what arrived, what the host recorded
// since, and what the host is correcting. Anything the standing briefing
// already stated is deliberately absent.
type Sections struct {
	// Input is the message or trigger this attempt answers. It is always sent:
	// the session's own transcript is not repeated, so this is what re-anchors
	// "the thing you were asked".
	Input string
	// Contract is the episode's effort contract, and it is always sent even
	// though it was byte-identical on all 201 measured follow-ups. A follow-up
	// almost always carries a correction — 195 of those 201 did — and a
	// correction is the model being told it failed to satisfy this exact
	// contract. Restating what it must satisfy alongside the complaint is worth
	// 9,412 bytes; whether it is, is a prompt question that make eval-prompts
	// answers, not one this package should decide by dropping it.
	Contract string
	// Episode is the recorded ledger: evidence, coverage, active publications.
	// This is the dedupe-eligible group, and it is where the weight is — the
	// ledger averaged 23,476 bytes and was byte-identical to the turn before it
	// on 164 of the 201, which is 4.7 MB of re-reading in a day and a half.
	Episode []string
	// Host is the corrections, escalations and continuation instructions that
	// apply to this turn and no earlier one.
	Host string
	// Standing is the briefing's own text. Any Episode section that appears in
	// it word for word is dropped, which is what turns "the ledger" into "the
	// ledger delta" without the store having to answer a since-when query.
	//
	// This is worth the comparison: measured over the 201 eligible follow-ups on
	// blitz, the episode contract averaged 9,412 bytes and was identical on
	// every one of them, and the evidence ledger averaged 23,476 bytes. Those
	// two are the whole remaining weight of a delta turn.
	Standing string
}

// standingBriefing is the one line that makes a short turn safe to answer. It
// names what is not repeated so the model does not read the absence as a
// narrowing of scope — the failure this sentence exists to prevent is a model
// that receives four hundred bytes and concludes it has been asked a smaller
// question than it was.
const standingBriefing = `<host-standing-briefing>
This is a follow-up turn in the conversation you are already in. The full briefing
delivered earlier in this session — your role, the operating policy, the evidence
and reply rules, the result envelope, the operation list, the repository set and
the tool transport limits — still applies in full and is deliberately not repeated.
Nothing in it has changed. Treat the work, tool results and findings already in this
conversation as yours to build on rather than to re-derive. Answer in the same
structured result envelope that briefing specified.
</host-standing-briefing>`

// NewInput is the message the delta turn answers, re-anchored by hand because
// the session's own transcript is not repeated and "the last thing you were
// asked" is otherwise ambiguous in a room that keeps talking.
func NewInput(userID, text string) string {
	return "\n\n<host-new-input>\nThis turn answers this message from the conversation you are in.\n" +
		"from: <@" + userID + ">\n" + text + "\n</host-new-input>"
}

// Escalation is the bounded conversation lane handing a request to the full
// investigation lane. It lives here so the delta turn and the full briefing say
// it in the same words; two copies of this paragraph would drift, and the model
// would be told two slightly different things about the same escalation.
func Escalation(reason string) string {
	if strings.TrimSpace(reason) == "" {
		return ""
	}
	return "\n\n<host-escalation>\nThe bounded conversation lane escalated this " +
		"request because: " + reason +
		". Perform the full evidence-backed work now.\n</host-escalation>"
}

// Prompt assembles the delta turn.
//
// Empty sections are dropped rather than emitted as empty tags: a header with
// nothing under it reads to a model as a section it failed to receive.
func Prompt(sections Sections) string {
	ordered := append([]string{sections.Input, sections.Contract}, sections.Episode...)
	ordered = append(ordered, sections.Host)
	var b strings.Builder
	b.WriteString(standingBriefing)
	for index, section := range ordered {
		section = strings.TrimSpace(section)
		if section == "" {
			continue
		}
		// Only the ledger is eligible. The input is what this turn is about, the
		// contract is what it is being held to, and a correction the model
		// already saw and failed to satisfy is exactly the one worth repeating.
		ledger := index >= 2 && index < 2+len(sections.Episode)
		if ledger && sections.Standing != "" &&
			strings.Contains(sections.Standing, section) {
			continue
		}
		b.WriteString("\n\n")
		b.WriteString(section)
	}
	return b.String()
}

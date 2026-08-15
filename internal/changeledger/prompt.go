package changeledger

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

const (
	// Layer is the omission key and the prompt-budget section name; they are one
	// string so a rename cannot separate them.
	Layer = "recent_changes"
	// ReferenceKind is how one recalled change appears on a context manifest.
	ReferenceKind = "recent_change"
	// DroppedReason is what an operator reads on the trace when the layer did
	// not fit. Its own key, not the recall one: an incident that could not be
	// told what changed has a different cause from one that could not be told
	// about a similar past episode.
	DroppedReason = "recent changes to the implicated services were omitted to fit the turn"
)

// Candidates is how much of the window one read pulls back before scope
// matching. Generous on purpose — matching happens in Select, and a cap applied
// before matching would return the newest changes in the estate rather than the
// ones about this incident — and still bounded, because an incident during a
// mass rollout must not read an unbounded table into memory.
const Candidates = 400

// PolicyText is the frame. Every sentence is load-bearing.
//
// The first job is the one the whole feature could fail at: a list of deploys
// beside a firing alert is an invitation to name one as the cause, and naming a
// cause is precisely what needs evidence rather than a coincidence in a list.
// The host cannot check prose, but it does check the binding — the cause gate
// requires cause_claim_ids and evidence_refs pointing at recorded observations
// — so the text tells the model the only route by which a change can end up in
// a verdict, which is to go and verify it and record what it found.
//
// The second job is scope honesty. matched_on says why the host selected each
// change, and "implicated repository" in a one-repository deployment selects
// everything; a model that treats that as a signal will confidently correlate
// the wrong deploy. Saying so is cheaper than a ranking nobody can audit.
//
// The third is that these are HOST-recorded facts, not model prose: unlike a
// recalled episode they carry no instructions and no conclusions, only what a
// webhook, a merge or an Emisar run reported. That makes them safer than
// recalled history and no more authoritative.
const PolicyText = `recent_changes are changes the host RECORDED — deploys, merges, infrastructure applies,
configuration actions — that happened inside the recall window and name something this incident
implicates. They are correlation material and nothing else. A change sitting minutes before an alert
is a place to look first, not a cause: proximity in time is not causation, and this list is
deliberately not ranked by likelihood. They do not prove anything is broken, do not prove anything
is fixed, and never authorize an action.
A change may become part of an asserted cause in exactly one way: verify it against the live source,
then record what you found with record_evidence citing the change's source_ref, and bind that
evidence id in cause_claim_ids and evidence_refs like any other. Citing a change_id in place of
evidence is not a cause; an assessment that names a cause without bound evidence is rejected by the
host whatever this section says.
matched_on says which implicated service or repository selected each change. A match on a
repository every service in the deployment shares is weak and you should say so rather than lean on
it. When a change shaped your reasoning, name it by change_id and say what you checked.`

// Prompt renders the layer inside the untrusted-context framing.
//
// It carries the framing itself rather than borrowing the section beside it,
// for the same reason the recall layer does: the layer has to be droppable
// without taking operational memory with it, and a section wrapped by another
// section's tags could not be.
func Prompt(changes []core.RecentChange) string {
	if len(changes) == 0 {
		return ""
	}
	data, err := json.Marshal(map[string]any{Layer: changes})
	if err != nil {
		return ""
	}
	return PolicyText + `

<untrusted-prior-operational-context>
` + string(data) + `
</untrusted-prior-operational-context>`
}

// RecalledBy reports whether a turn's effort contract is entitled to the layer.
//
// An assessment and an investigation are asking what is wrong with something
// running, which is the only question "what changed?" answers. A conversation
// turn about what a flag does is not helped by this morning's deploys, and an
// engineering task is a code change rather than an outage. Both would pay the
// budget for it out of the context they actually need.
func RecalledBy(effort core.EffortContract) bool {
	return effort == core.EffortOperationalAssessment ||
		effort == core.EffortIncidentInvestigation
}

// Turn is what the host knows about the work being done, in the terms the
// ledger can match on.
type Turn struct {
	Repository string
	Signals    []core.Signal
	// Evidence arrives as the prompt entries the turn already loaded, because
	// the target identity an operation recorded is the sharpest scope Responder
	// ever has and it costs nothing to read here.
	Evidence []decisionpkg.EvidencePromptEntry
	Effort   core.EffortContract
	Now      time.Time
	Window   time.Duration
	Limit    int
}

// Reader is the ledger read this package needs, which is one query. It is an
// interface so the whole of "which changes does this turn see" lives here
// rather than half here and half in the prompt assembler.
type Reader interface {
	Recent(ctx context.Context, since time.Time, limit int) ([]core.ChangeEvent, error)
}

// Read answers what changed recently to anything this turn implicates.
//
// A read failure returns no changes AND the error, so the caller can say so
// without the turn depending on it: the layer is an addition to what triage
// already had, and losing it must cost no more than the answer it was written
// to improve.
func Read(ctx context.Context, reader Reader, turn Turn) ([]core.RecentChange, error) {
	if !RecalledBy(turn.Effort) || turn.Window <= 0 || turn.Limit <= 0 {
		return nil, nil
	}
	candidates, err := reader.Recent(ctx, turn.Now.Add(-turn.Window), Candidates)
	if err != nil {
		return nil, err
	}
	targets := make([]string, 0, len(turn.Evidence))
	for _, item := range turn.Evidence {
		targets = append(targets, item.Target)
	}
	return Select(
		candidates,
		ScopeFrom(turn.Repository, turn.Signals, targets),
		turn.Now, turn.Window, turn.Limit,
	), nil
}

// Dropped reports whether the budget removed the layer, which is the one thing
// a manifest reference must never contradict.
func Dropped(omissions []core.ContextOmission) bool {
	for _, omission := range omissions {
		if omission.Kind == Layer {
			return true
		}
	}
	return false
}

// References records one manifest reference per recalled change so the trace
// can show what the host spent budget on.
//
// Nothing is recorded when the layer was dropped. A reference row says the
// model read this, and a manifest claiming a change reached a prompt the budget
// removed it from is worse than no record at all — it is the exact reading an
// operator would use to explain an answer.
func References(changes []core.RecentChange, dropped bool) []core.ContextReference {
	if dropped {
		return nil
	}
	references := make([]core.ContextReference, 0, len(changes))
	for _, change := range changes {
		encoded, err := json.Marshal(change)
		if err != nil {
			continue
		}
		sum := sha256.Sum256(encoded)
		references = append(references, core.ContextReference{
			Kind: ReferenceKind, SourceRef: "change:" + change.ChangeID,
			ContentDigest: hex.EncodeToString(sum[:]), Visibility: "eligible",
			Metadata: map[string]string{"kind": change.Kind, "source": change.Source},
		})
	}
	return references
}

// Carried reads the recalled changes back out of an attempt's frozen context.
//
// It reads what was actually frozen rather than what a caller believes it
// passed, which is the only version the trace can honestly claim.
func Carried(frozen []byte) []core.RecentChange {
	if len(frozen) == 0 {
		return nil
	}
	var carried struct {
		Changes []core.RecentChange `json:"recent_changes"`
	}
	if json.Unmarshal(frozen, &carried) != nil {
		return nil
	}
	return carried.Changes
}

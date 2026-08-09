package core

// The three section 24 rows a run's own mode can name without guessing.
//
// They live beside FixtureCandidate rather than in the service that records
// one because the service package is at its line budget, and because this is
// vocabulary over a core type with no runtime in it: a pure reading of
// AgentRunMode that the recorder, the promoter, and the coverage ratchet all
// need to agree on.
const (
	CapabilityConversation = "mentions-dms-and-proactive-messages"
	CapabilityIncidents    = "incidents"
	CapabilityEngineering  = "engineering-changes"
)

// PromotableCapabilities lists every capability slug a promoted correction can
// claim, so the coverage ratchet can check them against the matrix it parses
// out of the design document.
//
// Same reason CorrectionClasses exists: a slug that drifts from section 24 of
// docs/architecture-next.md is a fixture claiming coverage of a capability
// nobody has, and the ratchet is the only thing that would notice.
func PromotableCapabilities() []string {
	return []string{
		CapabilityConversation,
		CapabilityIncidents,
		CapabilityEngineering,
	}
}

// DefaultFixtureCapability is what a correction gets when its run mode says
// nothing more specific, including a candidate queued before the recording site
// labeled anything. It is the entry point every Slack turn shares.
func DefaultFixtureCapability() string { return CapabilityConversation }

// FixtureCapability names the capability a corrected run exercised.
//
// Every fixture promoted before this existed carries "capability:" with nothing
// after it, because the recording site never set the field the corpus format
// requires. An empty slug is not a missing tag: it is a claim to cover a
// capability that is not in the matrix, which is why the coverage ratchet
// rejects it and why the promoted cases could never be moved anywhere the
// ratchet looks.
//
// The run's mode is the finest label available without guessing. It names the
// entry point rather than the subject — a triage run that spent its whole life
// building an Emisar runbook is tagged as a conversation, not as
// runbook-control-plane-work — and that is deliberately the conservative
// direction. All three reachable slugs are capabilities the corpus already
// covers, so promotion can never close an acknowledged coverage gap by itself.
// Closing a gap stays a human act, performed while reading the promotion diff,
// which is the same moment the reviewer can sharpen the tag.
// NewFixtureCandidate assembles the correction a reviewer will be shown.
//
// What a candidate is made of belongs beside the type rather than at the one
// call site that builds one. That is not only tidiness: the field the call site
// forgot was Capability, and a struct literal spelled out in the middle of the
// retry path is exactly where a missing field is invisible. Here there is one
// place to look, and FixtureCapability is applied by construction.
//
// The correction text arrives already sanitized. Sanitizing needs the running
// service's redaction list, which core cannot have, so the caller does it and
// this only assembles.
func NewFixtureCandidate(run AgentRun, class string, sanitized string) FixtureCandidate {
	return FixtureCandidate{
		EpisodeID:       run.EpisodeID,
		RunID:           run.ID,
		Capability:      FixtureCapability(run),
		CorrectionClass: class,
		Correction:      sanitized,
	}
}

func FixtureCapability(run AgentRun) string {
	switch run.Mode {
	case AgentRunEngineeringTask:
		return CapabilityEngineering
	case AgentRunIncident:
		return CapabilityIncidents
	default:
		return DefaultFixtureCapability()
	}
}

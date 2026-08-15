package core

import "time"

// EpisodeOutcome is what one finished episode amounts to, projected out of the
// event stream at the moment it reaches a terminal state.
//
// The corpus is the moat and it was inert. Everything here already existed —
// evidence, verdicts, remediations, the trigger text — spread across six tables
// keyed three different ways, which is another way of saying no new incident
// could ever be told about an old one. A projection is the difference between
// data that is durable and data that is recallable.
type EpisodeOutcome struct {
	EpisodeID   string
	WorkspaceID string
	ChannelID   string
	Repository  string
	Mode        string
	Effort      string
	// TerminalState is the lifecycle state that produced this row: completed,
	// or blocked with a diagnosis. See intelligencestore for why cancelled,
	// refused and superseded episodes are never projected.
	TerminalState string
	TerminalAt    time.Time
	Objective     string
	// SymptomFingerprint is the normalized token set recall scores against.
	SymptomFingerprint string
	// FingerprintSource names where those tokens came from, per row and never
	// silently mixed: "trigger_text" when the originating input row survives,
	// "alert_labels" or "objective" when retention has pruned it. A recall
	// ranked on a truncated 180-byte objective is a different measurement from
	// one ranked on what the operator actually said, and a corpus that cannot
	// tell them apart cannot be audited.
	FingerprintSource string
	// AlertGroupKey is Grafana's stable identity for an alert group. Two
	// episodes sharing it are the same alert firing twice, which is the
	// strongest signal recall has.
	AlertGroupKey string
	Services      []string
	RootCause     string
	Remediation   string
	Verification  string
	// Verified records whether the remediation was confirmed by evidence
	// gathered after it, rather than merely asserted in the closing summary.
	Verified bool
	// TimeToDecision is how long the episode took from admission to its
	// terminal transition.
	TimeToDecision time.Duration
	CreatedAt      time.Time
}

// SimilarEpisode is one recalled outcome in the shape a prompt sees it.
//
// It is HISTORY. It never proves current health, never authorizes work, and
// never counts as evidence — the same rule confirmed memory lives under. The
// field names say so where the model reads them, because a section called
// "root_cause" beside live evidence is an invitation to skip the checking.
type SimilarEpisode struct {
	EpisodeID     string `json:"episode_id"`
	ResolvedAt    string `json:"resolved_at"`
	TerminalState string `json:"terminal_state"`
	// MatchedOn is why the host selected this episode, in the host's words.
	// Without it a recalled episode is an assertion; with it the model can
	// discount a match that rests on nothing but shared vocabulary.
	MatchedOn []string `json:"matched_on"`
	// Symptom is the past episode's objective — a headline, and a readable one.
	Symptom string `json:"past_symptom"`
	// SymptomSource names the text the host's fingerprint was built from, which
	// is not necessarily the headline above it. "trigger_text" means the words
	// the operator or the alert actually used; "objective" means the 180-byte
	// truncated headline was all that survived retention, and a match on that
	// is a materially weaker claim.
	SymptomSource  string   `json:"symptom_match_source"`
	Services       []string `json:"services,omitempty"`
	Repository     string   `json:"repository,omitempty"`
	RootCause      string   `json:"past_root_cause,omitempty"`
	Remediation    string   `json:"past_remediation,omitempty"`
	Verification   string   `json:"past_verification,omitempty"`
	Verified       bool     `json:"past_remediation_verified"`
	TimeToDecision string   `json:"past_time_to_decision,omitempty"`
}

package core

import "time"

// RelatedTask is one engineering task already open in this channel, in the
// shape a prompt sees it.
//
// The corpus knew about finished investigations and nothing else. Work that was
// OPENED — a task an operator approved, that a session then wrote, committed,
// and parked short of publishing — was invisible to every later turn, and the
// consequence is specific: on 2026-08-13 an investigation of va1-nomad-oom-risk
// produced inc_01ce33abd249e2e16a9990cdbc312dcc, "VA1: prevent reload-driven
// Traefik OOM recurrence", which was completed and committed as f804b18c in a
// fork and never published. When the same alert fired on 2026-08-16 the host
// had no way to say so, and five investigations proposed writing that change
// again at roughly $15 each.
//
// Like a recalled episode it is HISTORY and untrusted text: it says what was
// opened, not what is true now, and a status column is a record of the last
// write rather than a claim about the estate.
type RelatedTask struct {
	IncidentID string `json:"incident_id"`
	Title      string `json:"title"`
	Repository string `json:"repository,omitempty"`
	Status     string `json:"status,omitempty"`
	Workflow   string `json:"workflow,omitempty"`
	// LatestUpdate is the task's own last word about itself, bounded. It is the
	// field that carries "committed as f804b18c" — the sentence a later turn
	// most needs and had no way to read.
	LatestUpdate string `json:"latest_update,omitempty"`
	// CommitSHA is a commit named in that update, pulled out so the difference
	// between "we plan to" and "we already did, it is sitting in a fork" is a
	// field rather than something the model has to notice in prose.
	CommitSHA string `json:"commit_sha,omitempty"`
	// MergeState is where that commit actually is, read from the repository the
	// task names. See MergeState for why the answer stops at the default branch.
	MergeState MergeState `json:"merge_state,omitempty"`
	UpdatedAt  time.Time  `json:"updated_at"`
	ThreadLink string     `json:"thread_link,omitempty"`
}

// MergeState is where a committed change is, as the host read it from a
// repository rather than as a task's own prose claims it.
//
// It exists because "committed" and "published" were one word to this layer.
// On 2026-08-16 an alert investigation was told a task had committed f804b18c
// and ended blocked on "Publish and roll f804b18c through the governed reviewed
// deployment workflow" — three days after the same change reached blitz-infra
// main as 08f8b671. What was missing was the rollout, not the merge, and an
// operator following that sentence would have opened a duplicate pull request.
//
// The ladder deliberately stops at Merged. Ryker reads a git checkout, and
// a checkout cannot see what a cluster is running, so "merged but the deployed
// revision does not contain it" is not a state the host may assert — it is live
// evidence a turn goes and gathers. What the host owes the model is the half it
// can prove plus the plain statement that merged is not deployed, which is what
// the layer's policy text says.
type MergeState string

const (
	// MergeStateUnknown is the honest answer, and the default. The checkout is
	// missing or unreadable, the commit does not resolve in it — the ordinary
	// case for work committed in a fork — or the task named no commit at all.
	// Never a guess: a repository nobody could read must not read as unmerged.
	MergeStateUnknown MergeState = "unknown"
	// MergeStateNotMerged is a commit that is not on the repository's default
	// branch. This is the state the layer's offer was written for.
	MergeStateNotMerged MergeState = "not_merged"
	// MergeStateMerged is a commit on the default branch. It says nothing about
	// what is deployed.
	MergeStateMerged MergeState = "merged"
)

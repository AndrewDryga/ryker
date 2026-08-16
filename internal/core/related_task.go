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
	CommitSHA  string    `json:"commit_sha,omitempty"`
	UpdatedAt  time.Time `json:"updated_at"`
	ThreadLink string    `json:"thread_link,omitempty"`
}

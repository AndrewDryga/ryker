package core

import "time"

// ChangeEvent is one recorded change to the systems Responder watches.
//
// "What changed?" is the first question of every real incident, and Responder
// could not answer it. The facts were already passing through the process and
// being dropped: a deploy notification arriving on a webhook became a signal or
// nothing at all, the publication follower watched Responder's own pull
// requests merge and deploy without ledgering either, and the approval watcher
// read mutating Emisar runs to terminal state and kept only the approval row.
// Three sources Responder already sees, and no table that could be asked what
// happened in the last six hours.
//
// A change event is a HINT and never authority. It cannot trigger work, and it
// cannot carry a cause on its own: the cause-binding gate still requires
// evidence ids, so a change reaches a verdict only by being re-recorded through
// record_evidence, where it is subject to every rule other evidence is.
type ChangeEvent struct {
	ID string
	// Source names the adapter that produced the row: "webhook:<route>",
	// "publication", or "emisar".
	Source string
	// SourceIdentity is the source's own name for this exact change, and the
	// half of the idempotency key that does the work. Redelivery, restart
	// recovery and a rewound poll cursor all replay the same identity, so the
	// unique constraint on (source, source_identity) is what makes ingestion
	// safe to retry rather than something each adapter has to remember.
	SourceIdentity string
	// Kind is the bounded vocabulary: deploy, merge, infra_apply, flag, config.
	Kind       string
	OccurredAt time.Time
	// Services and Repositories are the normalized scope refs. A change with
	// neither can still be recorded — the ledger is a record, not an index —
	// but nothing will ever recall it, because scoping is the only way in.
	Services     []string
	Repositories []string
	Actor        string
	Summary      string
	// SourceRef is the permalink an operator follows to check the claim, and
	// Revision the commit, plan or run id it names.
	SourceRef string
	Revision  string
	CreatedAt time.Time
}

// RecentChange is one change event in the shape a prompt sees it.
//
// It is correlation material, not proof. The field names carry that where the
// model reads them, the same way SimilarEpisode does: a section listing a
// deploy twenty minutes before an alert is an invitation to name it as the
// cause, and naming a cause is exactly what needs evidence rather than a
// coincidence in a list.
type RecentChange struct {
	ChangeID string `json:"change_id"`
	Kind     string `json:"kind"`
	// Source is kept in the prompt because "an Emisar run Responder itself
	// approved" and "a JSON body some deploy tool posted" are different degrees
	// of confidence about the same sentence.
	Source     string `json:"source"`
	OccurredAt string `json:"occurred_at"`
	// Age is how long before this turn the change landed, in words. The model
	// gets an absolute timestamp too, but the correlation an operator actually
	// makes is "eight minutes before the alert", and arithmetic over RFC3339 is
	// a thing to get wrong rather than a thing to reason with.
	Age string `json:"age,omitempty"`
	// MatchedOn is why the host selected this change, in the host's words.
	// Without it a listed change is an assertion; with it the model can discount
	// one that matched on nothing but a repository every service shares.
	MatchedOn    []string `json:"matched_on"`
	Services     []string `json:"services,omitempty"`
	Repositories []string `json:"repositories,omitempty"`
	Actor        string   `json:"actor,omitempty"`
	Summary      string   `json:"summary,omitempty"`
	Revision     string   `json:"revision,omitempty"`
	SourceRef    string   `json:"source_ref,omitempty"`
}

package changestore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/core"
)

// publicationChangeKind maps a lifecycle transition onto the change ledger's
// vocabulary, and returns empty for the transitions that are not changes to
// anything running.
//
// Checks passing is not a change; nor is a PR being closed unmerged, a draft
// being opened, or a rollout that failed. Only these three put something
// different in front of users, and only those three belong in a section an
// incident reads to ask what changed.
func publicationChangeKind(kind, state string) string {
	switch {
	case kind == "merged" && state == "succeeded":
		return changeledger.KindMerge
	case kind == "deployment" && state == "succeeded":
		return changeledger.KindDeploy
	case kind == "terraform" && state == "succeeded":
		return changeledger.KindInfraApply
	default:
		return ""
	}
}

// FromPublicationLifecycle writes the change a lifecycle transition amounts to,
// inside the transaction that recorded the transition.
//
// Same transaction, and that is the whole point. Written afterwards the change
// event could simply be absent — a crash between the two writes leaves the task
// card saying the PR merged and the ledger saying nothing shipped, and that
// disagreement is invisible: the next incident in that repository is told there
// were no recent changes, which is a confident wrong answer rather than a
// missing one.
//
// Call it only when the lifecycle row was newly inserted, so the ledger
// inherits that row's idempotency exactly. The identity is the lifecycle
// event's own id, derived from the observed transition, so a poll cursor
// rewound by restart recovery re-observes the same merge and addresses the same
// row.
//
// It reaches into publications for the repository and the pull request URL
// because the ledger owns what a change event must carry, and the alternative —
// threading a prepared event down through two writers, an interface and a fake
// — puts that knowledge in the caller instead, where the next writer will get
// it slightly different.
//
// The scope is the repository and nothing else. Responder knows which
// repository merged; it does not know which services that repository runs as,
// and inventing a service name here would put a confident wrong scope into the
// one query this feature is built around.
func FromPublicationLifecycle(
	ctx context.Context,
	tx *sql.Tx,
	event core.PublicationLifecycleEvent,
	occurredAt time.Time,
	now time.Time,
) error {
	kind := publicationChangeKind(event.Kind, event.State)
	if kind == "" {
		return nil
	}
	var repository, prURL, mergeSHA string
	if err := tx.QueryRowContext(ctx, `
		SELECT publication.repository, publication.pr_url,
		       COALESCE(followup.merge_sha, '')
		FROM publications AS publication
		LEFT JOIN publication_followups AS followup
		  ON followup.incident_id = publication.incident_id
		WHERE publication.incident_id = ?`, event.IncidentID,
	).Scan(&repository, &prURL, &mergeSHA); err != nil {
		// A lifecycle event for an incident with no publication row is not a
		// change anybody can check, and it is not this transaction's business
		// to refuse the transition over it.
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	}
	change, ok := changeledger.Record(core.ChangeEvent{
		Source:         changeledger.SourcePublication,
		SourceIdentity: event.ID,
		Kind:           kind,
		OccurredAt:     occurredAt,
		Repositories:   []string{repository},
		Summary:        event.Summary,
		SourceRef:      prURL,
		Revision:       mergeSHA,
	})
	if !ok {
		return nil
	}
	_, err := Insert(ctx, tx, change, now)
	return err
}

// Package fixturepromotionstore remembers which approved corrections have
// already been answered for, and how.
//
// Promotion used to be a command an operator ran, so "have I promoted this
// one?" was answered by reading the corpus: a fixture carries the episode it
// came from, and a second run skipped what was already there. A job that runs
// every minute needs a stricter answer than that. The corpus is a file in a
// checkout that may be reverted, rebased, or absent, and a candidate that was
// quarantined is deliberately not in it — so a promotion drain reading only the
// corpus would retry a quarantined candidate forever, once a minute.
//
// The receipts live in audit_events because every automatic act here has to be
// auditable anyway, and because the receipt and the audit row would otherwise be
// two records of one event that can disagree. The row id is derived from the
// candidate rather than generated, so a restart between the corpus write and
// the receipt writes the same row twice and stores it once.
//
// It is a repository rather than methods on Store for the reason the other
// extractions here exist: a delegating method still counts against the store's
// method budget, so an extraction only reduces the surface if callers reach it
// through the field.
package fixturepromotionstore

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// auditKind is the kind every receipt carries. The Decisions page reads it back
// under this name, so it is the contract between the drain and the page.
const auditKind = "fixture.promotion"

const (
	// OutcomePromoted means the fixture is in the corpus.
	OutcomePromoted = "promoted"
	// OutcomeQuarantined means the fixture was built and then held back, and
	// that nothing will retry it until a human looks.
	OutcomeQuarantined = "quarantined"
)

type Repository struct {
	db *sql.DB
}

func New(db *sql.DB) *Repository { return &Repository{db: db} }

// Unsettled returns the kept corrections nothing has answered for yet, oldest
// first.
//
// The receipt is part of the query rather than a check the caller repeats per
// row, because a candidate keeps its approved status forever: it is a record of
// what an operator decided, not a queue position. A drain that read the first
// fifty approved rows and filtered afterwards would, once fifty had been
// promoted, spend every sweep re-reading the same settled fifty and never see
// the fifty-first — the loop would go quiet with a full queue behind it.
//
// A quarantined candidate is settled too. Its check will keep failing, so
// retrying would spend the week's budget on the same broken candidate and bury
// the reason under identical audit rows.
func (r *Repository) Unsettled(
	ctx context.Context,
	limit int,
) ([]core.FixtureCandidate, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT candidate.id, candidate.episode_id, candidate.run_id,
		       candidate.capability, candidate.correction_class, candidate.correction,
		       candidate.status, candidate.reviewed_by, candidate.created_at,
		       candidate.expires_at
		FROM fixture_candidates AS candidate
		WHERE candidate.status = 'approved'
		  AND NOT EXISTS (
		    SELECT 1 FROM audit_events AS receipt
		    WHERE receipt.kind = ? AND receipt.object_id = candidate.id
		  )
		ORDER BY candidate.created_at, candidate.id
		LIMIT ?`, auditKind, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.FixtureCandidate, 0)
	for rows.Next() {
		var candidate core.FixtureCandidate
		var created, expires string
		if err := rows.Scan(
			&candidate.ID, &candidate.EpisodeID, &candidate.RunID, &candidate.Capability,
			&candidate.CorrectionClass, &candidate.Correction, &candidate.Status,
			&candidate.ReviewedBy, &created, &expires,
		); err != nil {
			return nil, err
		}
		candidate.CreatedAt = sqlutil.ParseTime(created)
		candidate.ExpiresAt = sqlutil.ParseTime(expires)
		result = append(result, candidate)
	}
	return result, rows.Err()
}

// PromotedSince counts the promotions inside a window, for the rate bound.
//
// Quarantines are not counted. A candidate that never reached the corpus did
// not spend the week's allowance on a lesson, and counting it would let a run
// of bad candidates lock out the good ones behind them.
func (r *Repository) PromotedSince(ctx context.Context, since time.Time) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM audit_events
		WHERE kind = ? AND outcome = ? AND created_at >= ?`,
		auditKind, OutcomePromoted, sqlutil.TimeText(since),
	).Scan(&count)
	return count, err
}

// Record writes the receipt for one candidate, once.
//
// The identifier is derived from the candidate, so the insert is idempotent:
// a process that dies between appending the fixture and recording the receipt
// writes the same row on the next sweep rather than a second one.
func (r *Repository) Record(
	ctx context.Context,
	candidateID string,
	episodeID string,
	outcome string,
	detail string,
	now time.Time,
) error {
	if strings.TrimSpace(candidateID) == "" {
		return errors.New("a promotion receipt needs a candidate")
	}
	if outcome != OutcomePromoted && outcome != OutcomeQuarantined {
		return errors.New("a promotion is promoted or quarantined")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO audit_events
		  (id, kind, actor_id, object_id, outcome, detail, created_at)
		VALUES ('fixpromo_' || ?, ?, 'responder', ?, ?, ?, ?)
		ON CONFLICT(id) DO NOTHING`,
		candidateID, auditKind, candidateID, outcome,
		sqlutil.BoundedError(episodeID+": "+detail), sqlutil.TimeText(now),
	)
	return err
}

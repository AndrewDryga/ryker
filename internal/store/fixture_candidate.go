package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// fixtureCandidateTTL is how long an unreviewed candidate stays useful.
//
// A correction is evidence about the prompt and model that produced it. After a
// fortnight that pairing may not exist any more, and promoting the candidate
// then would encode a bug that has already been fixed — turning the corpus into
// a museum that blocks good changes rather than a net that catches bad ones.
const fixtureCandidateTTL = 14 * 24 * time.Hour

// RecordFixtureCandidate queues a correction for human review.
//
// One candidate per episode and correction class: an episode corrected three
// times for the same reason is one lesson, and queueing it three times would
// spend a reviewer's attention proving that.
func (s *Store) RecordFixtureCandidate(
	ctx context.Context,
	candidate core.FixtureCandidate,
) error {
	if strings.TrimSpace(candidate.EpisodeID) == "" ||
		strings.TrimSpace(candidate.CorrectionClass) == "" {
		return errors.New("a fixture candidate needs an episode and a correction class")
	}
	id, err := core.NewID("fixcand")
	if err != nil {
		return err
	}
	now := s.now().UTC()
	_, err = s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO fixture_candidates (
		  id, episode_id, run_id, capability, correction_class, correction,
		  status, created_at, expires_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		id, candidate.EpisodeID, candidate.RunID, candidate.Capability,
		candidate.CorrectionClass, core.BoundedText(candidate.Correction, 2000),
		sqlutil.TimeText(now), sqlutil.TimeText(now.Add(fixtureCandidateTTL)), sqlutil.TimeText(now),
	)
	return err
}

// ListPendingFixtureCandidates returns candidates still worth reviewing.
//
// Expired candidates are filtered here rather than at the caller, so a reviewer
// is never shown a lesson about a prompt that no longer exists.
func (s *Store) ListPendingFixtureCandidates(
	ctx context.Context,
	now time.Time,
	limit int,
) ([]core.FixtureCandidate, error) {
	if limit < 1 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, episode_id, run_id, capability, correction_class, correction,
		       status, reviewed_by, created_at, expires_at
		FROM fixture_candidates
		WHERE status = 'pending' AND expires_at > ?
		ORDER BY created_at DESC LIMIT ?`, sqlutil.TimeText(now), limit)
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

// ReviewFixtureCandidate records an operator's decision.
func (s *Store) ReviewFixtureCandidate(
	ctx context.Context,
	id string,
	status string,
	reviewer string,
) error {
	if status != "approved" && status != "rejected" {
		return errors.New("a fixture candidate is approved or rejected")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE fixture_candidates SET status = ?, reviewed_by = ?, updated_at = ?
		WHERE id = ? AND status = 'pending'`,
		status, reviewer, s.nowText(), id,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

// ExpireFixtureCandidates lapses candidates nobody reviewed in time.
func (s *Store) ExpireFixtureCandidates(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE fixture_candidates SET status = 'expired', updated_at = ?
		WHERE status = 'pending' AND expires_at <= ?`, s.nowText(), sqlutil.TimeText(now))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// ListApprovedFixtureCandidates returns lessons an operator kept.
//
// Approval and promotion are separate: keeping a lesson is a judgement about
// the correction, and writing it into a corpus is a change to what blocks a
// release. Splitting them means the second decision is made while looking at a
// diff rather than at a button.
func (s *Store) ListApprovedFixtureCandidates(
	ctx context.Context,
	limit int,
) ([]core.FixtureCandidate, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, episode_id, run_id, capability, correction_class, correction,
		       status, reviewed_by, created_at, expires_at
		FROM fixture_candidates
		WHERE status = 'approved'
		ORDER BY created_at LIMIT ?`, limit)
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

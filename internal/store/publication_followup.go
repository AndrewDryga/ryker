package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func (s *Store) EnsurePublicationFollowup(
	ctx context.Context,
	incidentID string,
	nextCheckAt time.Time,
) error {
	if incidentID == "" || nextCheckAt.IsZero() {
		return errors.New("publication follow-up identity and next check are required")
	}
	now := s.nowText()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO publication_followups (
		  incident_id, next_check_at, created_at, updated_at
		) VALUES (?, ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  next_check_at = MIN(publication_followups.next_check_at, excluded.next_check_at),
		  updated_at = excluded.updated_at`,
		incidentID, nextCheckAt.UTC().Format(timestampFormat), now, now,
	)
	return err
}

func (s *Store) ResetPublicationFollowup(
	ctx context.Context,
	incidentID string,
	nextCheckAt time.Time,
) error {
	if incidentID == "" || nextCheckAt.IsZero() {
		return errors.New("publication follow-up identity and next check are required")
	}
	now := s.nowText()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO publication_followups (
		  incident_id, pr_state, checks_state, next_check_at,
		  created_at, updated_at
		) VALUES (?, 'open', 'unknown', ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  pr_state = 'open', checks_state = 'unknown', merge_sha = '',
		  merged_at = NULL, next_check_at = excluded.next_check_at,
		  failure_count = 0, last_error = '', last_event_key = '',
		  updated_at = excluded.updated_at`,
		incidentID, nextCheckAt.UTC().Format(timestampFormat), now, now,
	)
	return err
}

func (s *Store) GetPublicationFollowup(
	ctx context.Context,
	incidentID string,
) (core.PublicationFollowup, error) {
	var item core.PublicationFollowup
	var merged sql.NullString
	var next, created, updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT incident_id, pr_state, checks_state, merge_sha, merged_at,
		  next_check_at, failure_count, last_error, last_event_key,
		  created_at, updated_at
		FROM publication_followups WHERE incident_id = ?`, incidentID).Scan(
		&item.IncidentID, &item.PRState, &item.ChecksState, &item.MergeSHA,
		&merged, &next, &item.FailureCount, &item.LastError,
		&item.LastEventKey, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.PublicationFollowup{}, ErrNotFound
	}
	if err != nil {
		return core.PublicationFollowup{}, err
	}
	item.MergedAt = sqlutil.ScanTime(merged)
	item.NextCheckAt = sqlutil.ParseTime(next)
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	return item, nil
}

func (s *Store) NextPublicationFollowup(
	ctx context.Context,
	now time.Time,
) (core.PublicationFollowup, core.Publication, error) {
	var followup core.PublicationFollowup
	var publication core.Publication
	var merged, published sql.NullString
	var next, followupCreated, followupUpdated, publicationCreated, publicationUpdated string
	err := s.db.QueryRowContext(ctx, `
		SELECT f.incident_id, f.pr_state, f.checks_state, f.merge_sha, f.merged_at,
		  f.next_check_at, f.failure_count, f.last_error, f.last_event_key,
		  f.created_at, f.updated_at,
		  p.repository, p.base_branch, p.head_branch, p.parent_head,
		  p.candidate_tree, p.commit_sha, p.remote_sha, p.pr_number, p.pr_url,
		  p.state, p.last_error, p.created_at, p.updated_at, p.published_at
		FROM publication_followups f
		JOIN publications p ON p.incident_id = f.incident_id
		WHERE p.state = 'published' AND f.next_check_at <= ?
		ORDER BY f.next_check_at, f.updated_at
		LIMIT 1`, now.UTC().Format(timestampFormat)).Scan(
		&followup.IncidentID, &followup.PRState, &followup.ChecksState,
		&followup.MergeSHA, &merged, &next, &followup.FailureCount,
		&followup.LastError, &followup.LastEventKey, &followupCreated,
		&followupUpdated, &publication.Repository, &publication.BaseBranch,
		&publication.HeadBranch, &publication.ParentHead,
		&publication.CandidateTree, &publication.CommitSHA,
		&publication.RemoteSHA, &publication.PRNumber, &publication.PRURL,
		&publication.State, &publication.LastError, &publicationCreated,
		&publicationUpdated, &published,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.PublicationFollowup{}, core.Publication{}, ErrNotFound
	}
	if err != nil {
		return core.PublicationFollowup{}, core.Publication{}, err
	}
	publication.IncidentID = followup.IncidentID
	followup.MergedAt = sqlutil.ScanTime(merged)
	followup.NextCheckAt = sqlutil.ParseTime(next)
	followup.CreatedAt = sqlutil.ParseTime(followupCreated)
	followup.UpdatedAt = sqlutil.ParseTime(followupUpdated)
	publication.CreatedAt = sqlutil.ParseTime(publicationCreated)
	publication.UpdatedAt = sqlutil.ParseTime(publicationUpdated)
	publication.PublishedAt = sqlutil.ScanTime(published)
	return followup, publication, nil
}

func (s *Store) SavePublicationFollowup(
	ctx context.Context,
	item core.PublicationFollowup,
) error {
	if item.IncidentID == "" || item.PRState == "" || item.ChecksState == "" ||
		item.NextCheckAt.IsZero() {
		return errors.New("complete publication follow-up state is required")
	}
	now := s.now().UTC()
	var merged any
	if !item.MergedAt.IsZero() {
		merged = item.MergedAt.UTC().Format(timestampFormat)
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE publication_followups SET
		  pr_state = ?, checks_state = ?, merge_sha = ?, merged_at = ?,
		  next_check_at = ?, failure_count = ?, last_error = ?,
		  last_event_key = ?, updated_at = ?
		WHERE incident_id = ?`,
		item.PRState, item.ChecksState, item.MergeSHA, merged,
		item.NextCheckAt.UTC().Format(timestampFormat), item.FailureCount,
		item.LastError, item.LastEventKey, now.Format(timestampFormat),
		item.IncidentID,
	)
	return sqlutil.ExpectOne(result, err, "save publication follow-up")
}

func (s *Store) RecordPublicationLifecycleEvent(
	ctx context.Context,
	item core.PublicationLifecycleEvent,
) (bool, error) {
	if item.ID == "" || item.IncidentID == "" || item.Kind == "" ||
		item.State == "" || item.Summary == "" {
		return false, errors.New("publication lifecycle event is incomplete")
	}
	if item.CreatedAt.IsZero() {
		item.CreatedAt = s.now().UTC()
	}
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO publication_lifecycle_events (
		  id, incident_id, kind, state, summary, source_channel_id,
		  source_message_ts, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		item.ID, item.IncidentID, item.Kind, item.State, item.Summary,
		item.SourceChannelID, item.SourceMessageTS,
		item.CreatedAt.UTC().Format(timestampFormat),
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	return rows == 1, err
}

func (s *Store) ListActivePublicationContexts(
	ctx context.Context,
	mergedAfter time.Time,
	limit int,
) ([]core.PublicationContext, error) {
	if limit < 1 || limit > 100 {
		return nil, fmt.Errorf("publication context limit %d is invalid", limit)
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT p.incident_id, i.repository, p.repository, i.title, p.pr_number,
		  p.pr_url, p.head_branch, p.remote_sha, f.merge_sha, f.pr_state,
		  f.checks_state,
		  COALESCE(NULLIF(i.origin_channel_id, ''), i.channel_id),
		  CASE
		    WHEN i.work_scope = 'thread' AND i.origin_thread_ts != '' THEN i.origin_thread_ts
		    ELSE i.root_ts
		  END
		FROM publication_followups f
		JOIN publications p ON p.incident_id = f.incident_id
		JOIN incidents i ON i.id = p.incident_id
		WHERE p.state = 'published'
		  AND (
		    f.pr_state NOT IN ('merged', 'closed')
		    OR (f.pr_state = 'merged' AND (f.merged_at IS NULL OR f.merged_at >= ?))
		  )
		ORDER BY p.updated_at DESC
		LIMIT ?`, mergedAfter.UTC().Format(timestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.PublicationContext
	for rows.Next() {
		var item core.PublicationContext
		if err := rows.Scan(
			&item.IncidentID, &item.RepositoryKey, &item.Repository, &item.Title,
			&item.PRNumber, &item.PRURL, &item.HeadBranch, &item.HeadSHA,
			&item.MergeSHA, &item.PRState, &item.ChecksState, &item.ChannelID,
			&item.ThreadTS,
		); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

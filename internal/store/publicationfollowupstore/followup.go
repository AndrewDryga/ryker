package publicationfollowupstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

func (r *Repository) nowText() string {
	return r.clock().UTC().Format(core.TimestampFormat)
}

func (r *Repository) Ensure(
	ctx context.Context,
	incidentID string,
	nextCheckAt time.Time,
) error {
	if incidentID == "" || nextCheckAt.IsZero() {
		return errors.New("publication follow-up identity and next check are required")
	}
	now := r.nowText()
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO publication_followups (
		  incident_id, next_check_at, created_at, updated_at
		) VALUES (?, ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  next_check_at = MIN(publication_followups.next_check_at, excluded.next_check_at),
		  updated_at = excluded.updated_at`,
		incidentID, nextCheckAt.UTC().Format(core.TimestampFormat), now, now,
	)
	return err
}

func (r *Repository) Reset(
	ctx context.Context,
	incidentID string,
	nextCheckAt time.Time,
) error {
	if incidentID == "" || nextCheckAt.IsZero() {
		return errors.New("publication follow-up identity and next check are required")
	}
	now := r.nowText()
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO publication_followups (
		  incident_id, pr_state, checks_state, next_check_at,
		  created_at, updated_at
		) VALUES (?, 'open', 'unknown', ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  pr_state = 'open', checks_state = 'unknown', merge_sha = '',
		  merged_at = NULL, next_check_at = excluded.next_check_at,
		  failure_count = 0, last_error = '', last_event_key = '',
		  updated_at = excluded.updated_at
		WHERE publication_followups.pr_state NOT IN ('merged', 'closed')`,
		incidentID, nextCheckAt.UTC().Format(core.TimestampFormat), now, now,
	)
	return err
}

func (r *Repository) Get(
	ctx context.Context,
	incidentID string,
) (core.PublicationFollowup, error) {
	var item core.PublicationFollowup
	var merged sql.NullString
	var next, created, updated string
	err := r.db.QueryRowContext(ctx, `
		SELECT incident_id, pr_state, checks_state, merge_sha, merged_at,
		  next_check_at, failure_count, last_error, last_event_key,
		  created_at, updated_at
		FROM publication_followups WHERE incident_id = ?`, incidentID).Scan(
		&item.IncidentID, &item.PRState, &item.ChecksState, &item.MergeSHA,
		&merged, &next, &item.FailureCount, &item.LastError,
		&item.LastEventKey, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.PublicationFollowup{}, core.ErrNotFound
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

func (r *Repository) Next(
	ctx context.Context,
	now time.Time,
) (core.PublicationFollowup, core.Publication, error) {
	var followup core.PublicationFollowup
	var publication core.Publication
	var merged, published sql.NullString
	var next, followupCreated, followupUpdated, publicationCreated, publicationUpdated string
	err := r.db.QueryRowContext(ctx, `
		SELECT f.incident_id, f.pr_state, f.checks_state, f.merge_sha, f.merged_at,
		  f.next_check_at, f.failure_count, f.last_error, f.last_event_key,
		  f.created_at, f.updated_at,
		  p.repository, p.base_branch, p.head_branch, p.parent_head,
		  p.candidate_tree, p.commit_sha, p.remote_sha, p.pr_number, p.pr_url,
		  p.state, p.last_error, p.created_at, p.updated_at, p.published_at
		FROM publication_followups f
		JOIN publications p ON p.incident_id = f.incident_id
		WHERE p.state IN ('published', 'stale') AND f.next_check_at <= ?
		ORDER BY f.next_check_at, f.updated_at
		LIMIT 1`, now.UTC().Format(core.TimestampFormat)).Scan(
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
		return core.PublicationFollowup{}, core.Publication{}, core.ErrNotFound
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

func (r *Repository) Save(
	ctx context.Context,
	item core.PublicationFollowup,
) error {
	_, err := r.saveTransition(ctx, nil, item, nil)
	return err
}

// SaveTransition commits one observed follow-up state and its optional
// lifecycle event together. Terminal PR states are absorbing: a delayed poll
// or post-publication reset cannot reopen a merged or closed pull request.
func (r *Repository) SaveTransition(
	ctx context.Context,
	expected core.PublicationFollowup,
	item core.PublicationFollowup,
	event *core.PublicationLifecycleEvent,
) (bool, error) {
	return r.saveTransition(ctx, &expected, item, event)
}

func (r *Repository) saveTransition(
	ctx context.Context,
	expected *core.PublicationFollowup,
	item core.PublicationFollowup,
	event *core.PublicationLifecycleEvent,
) (bool, error) {
	if item.IncidentID == "" || item.PRState == "" || item.ChecksState == "" ||
		item.NextCheckAt.IsZero() {
		return false, errors.New("complete publication follow-up state is required")
	}
	if event != nil && (event.ID == "" || event.IncidentID != item.IncidentID ||
		event.Kind == "" || event.State == "" || event.Summary == "") {
		return false, errors.New("publication lifecycle event is incomplete")
	}
	now := r.clock().UTC()
	var merged any
	if !item.MergedAt.IsZero() {
		merged = item.MergedAt.UTC().Format(core.TimestampFormat)
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var previous core.PublicationFollowup
	var previousUpdated, previousNext string
	if err := tx.QueryRowContext(ctx, `
		SELECT pr_state, checks_state, merge_sha, last_error, updated_at,
		  next_check_at, failure_count, last_event_key
		FROM publication_followups WHERE incident_id = ?`, item.IncidentID).Scan(
		&previous.PRState, &previous.ChecksState, &previous.MergeSHA, &previous.LastError,
		&previousUpdated, &previousNext, &previous.FailureCount, &previous.LastEventKey,
	); err != nil {
		return false, err
	}
	if previous.Terminal() && item.PRState != previous.PRState {
		return false, tx.Commit()
	}
	if expected == nil {
		previous.UpdatedAt = sqlutil.ParseTime(previousUpdated)
		previous.NextCheckAt = sqlutil.ParseTime(previousNext)
		expected = &previous
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE publication_followups SET
		  pr_state = ?, checks_state = ?, merge_sha = ?, merged_at = ?,
		  next_check_at = ?, failure_count = ?, last_error = ?,
		  last_event_key = ?, updated_at = ?
		WHERE incident_id = ? AND updated_at = ? AND pr_state = ?
		  AND checks_state = ? AND merge_sha = ? AND last_error = ?
		  AND last_event_key = ? AND failure_count = ? AND next_check_at = ?
		  AND (pr_state NOT IN ('merged', 'closed') OR pr_state = ?)`,
		item.PRState, item.ChecksState, item.MergeSHA, merged,
		item.NextCheckAt.UTC().Format(core.TimestampFormat), item.FailureCount,
		item.LastError, item.LastEventKey, now.Format(core.TimestampFormat),
		item.IncidentID, expected.UpdatedAt.UTC().Format(core.TimestampFormat),
		expected.PRState, expected.ChecksState, expected.MergeSHA, expected.LastError,
		expected.LastEventKey, expected.FailureCount,
		expected.NextCheckAt.UTC().Format(core.TimestampFormat), item.PRState,
	)
	if err := sqlutil.ExpectOne(result, err, "save publication follow-up"); err != nil {
		return false, err
	}
	if item.Terminal() {
		result, err = tx.ExecContext(ctx, `
			UPDATE publications SET state = 'published', failure_code = '',
			  last_error = '', updated_at = ?
			WHERE incident_id = ? AND pr_number > 0 AND published_at IS NOT NULL`,
			now.Format(core.TimestampFormat), item.IncidentID)
		if err := sqlutil.ExpectOne(result, err, "restore terminal publication receipt"); err != nil {
			return false, err
		}
	}
	inserted := false
	if event != nil {
		createdAt := event.CreatedAt
		if createdAt.IsZero() {
			createdAt = now
		}
		result, err = tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO publication_lifecycle_events (
			  id, incident_id, kind, state, summary, source_channel_id,
			  source_message_ts, created_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			event.ID, event.IncidentID, event.Kind, event.State, event.Summary,
			event.SourceChannelID, event.SourceMessageTS,
			createdAt.UTC().Format(core.TimestampFormat),
		)
		if err != nil {
			return false, err
		}
		rows, rowsErr := result.RowsAffected()
		if rowsErr != nil {
			return false, rowsErr
		}
		inserted = rows == 1
	}
	if previous.PRState != item.PRState || previous.ChecksState != item.ChecksState ||
		previous.MergeSHA != item.MergeSHA || previous.LastError != item.LastError || inserted {
		result, err = tx.ExecContext(ctx, `
			UPDATE incidents SET updated_at = ?, card_version = card_version + 1
			WHERE id = ?`, now.Format(core.TimestampFormat), item.IncidentID)
		if err := sqlutil.ExpectOne(result, err, "mark publication follow-up on incident"); err != nil {
			return false, err
		}
	}
	return inserted, tx.Commit()
}

func (r *Repository) RecordLifecycleEvent(
	ctx context.Context,
	item core.PublicationLifecycleEvent,
) (bool, error) {
	if item.ID == "" || item.IncidentID == "" || item.Kind == "" ||
		item.State == "" || item.Summary == "" {
		return false, errors.New("publication lifecycle event is incomplete")
	}
	if item.CreatedAt.IsZero() {
		item.CreatedAt = r.clock().UTC()
	}
	now := r.clock().UTC()
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO publication_lifecycle_events (
		  id, incident_id, kind, state, summary, source_channel_id,
		  source_message_ts, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		item.ID, item.IncidentID, item.Kind, item.State, item.Summary,
		item.SourceChannelID, item.SourceMessageTS,
		item.CreatedAt.UTC().Format(core.TimestampFormat),
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if rows == 0 {
		return false, tx.Commit()
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now.Format(core.TimestampFormat), item.IncidentID)
	if err := sqlutil.ExpectOne(result, err, "mark publication lifecycle event on incident"); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

func (r *Repository) LatestLifecycleEvent(
	ctx context.Context,
	incidentID string,
) (core.PublicationLifecycleEvent, error) {
	var item core.PublicationLifecycleEvent
	var created string
	err := r.db.QueryRowContext(ctx, `
		SELECT id, incident_id, kind, state, summary, source_channel_id,
		  source_message_ts, created_at
		FROM publication_lifecycle_events
		WHERE incident_id = ?
		ORDER BY created_at DESC, id DESC
		LIMIT 1`, incidentID).Scan(
		&item.ID, &item.IncidentID, &item.Kind, &item.State, &item.Summary,
		&item.SourceChannelID, &item.SourceMessageTS, &created,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.PublicationLifecycleEvent{}, core.ErrNotFound
	}
	if err != nil {
		return core.PublicationLifecycleEvent{}, err
	}
	item.CreatedAt = sqlutil.ParseTime(created)
	return item, nil
}

func (r *Repository) ListActiveContexts(
	ctx context.Context,
	mergedAfter time.Time,
	limit int,
) ([]core.PublicationContext, error) {
	if limit < 1 || limit > 100 {
		return nil, fmt.Errorf("publication context limit %d is invalid", limit)
	}
	rows, err := r.db.QueryContext(ctx, `
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
		LIMIT ?`, mergedAfter.UTC().Format(core.TimestampFormat), limit)
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

package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func (s *Store) GetPublication(ctx context.Context, incidentID string) (core.Publication, error) {
	var item core.Publication
	var created, updated string
	var published sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT incident_id, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  last_error, created_at, updated_at, published_at
		FROM publications WHERE incident_id = ?`, incidentID).Scan(
		&item.IncidentID, &item.Repository, &item.BaseBranch, &item.HeadBranch,
		&item.ParentHead, &item.CandidateTree, &item.CommitSHA, &item.RemoteSHA,
		&item.PRNumber, &item.PRURL, &item.State, &item.LastError, &created,
		&updated, &published,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.Publication{}, ErrNotFound
	}
	if err != nil {
		return core.Publication{}, err
	}
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	item.PublishedAt = scanTime(published)
	return item, nil
}

func (s *Store) SavePublication(ctx context.Context, item core.Publication) error {
	if item.IncidentID == "" || item.Repository == "" || item.BaseBranch == "" ||
		item.ParentHead == "" || item.CandidateTree == "" {
		return errors.New("publication identity, reviewed tree, and state are required")
	}
	switch item.State {
	case "publishing", "failed":
	case "published":
		if item.HeadBranch == "" || item.CommitSHA == "" || item.RemoteSHA == "" ||
			item.PRNumber < 1 || item.PRURL == "" || item.PublishedAt.IsZero() {
			return errors.New("published draft PR identity and proof are required")
		}
	default:
		return fmt.Errorf("publication state %q is invalid", item.State)
	}
	now := time.Now().UTC()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	item.UpdatedAt = now
	var published any
	if !item.PublishedAt.IsZero() {
		published = item.PublishedAt.UTC().Format(timestampFormat)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `
		INSERT INTO publications (
		  incident_id, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  last_error, created_at, updated_at, published_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  repository = excluded.repository,
		  base_branch = excluded.base_branch,
		  head_branch = excluded.head_branch,
		  parent_head = excluded.parent_head,
		  candidate_tree = excluded.candidate_tree,
		  commit_sha = excluded.commit_sha,
		  remote_sha = excluded.remote_sha,
		  pr_number = excluded.pr_number,
		  pr_url = excluded.pr_url,
		  state = excluded.state,
		  last_error = excluded.last_error,
		  updated_at = excluded.updated_at,
		  published_at = excluded.published_at`,
		item.IncidentID, item.Repository, item.BaseBranch, item.HeadBranch,
		item.ParentHead, item.CandidateTree, item.CommitSHA, item.RemoteSHA,
		item.PRNumber, item.PRURL, item.State, item.LastError,
		item.CreatedAt.UTC().Format(timestampFormat), item.UpdatedAt.Format(timestampFormat),
		published,
	)
	if err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now.Format(timestampFormat), item.IncidentID)
	if err := expectOne(result, err, "mark publication on incident"); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ScheduleCleanup(
	ctx context.Context,
	sessionID string,
	incidentID string,
	reason string,
	allowUnmerged bool,
	eligibleAt time.Time,
) error {
	if sessionID == "" || reason == "" {
		return errors.New("cleanup session and reason are required")
	}
	now := nowText()
	allow := 0
	if allowUnmerged {
		allow = 1
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
		  incident_id = CASE
		    WHEN coop_cleanup.incident_id = '' THEN excluded.incident_id
		    ELSE coop_cleanup.incident_id
		  END,
		  allow_unmerged = MAX(coop_cleanup.allow_unmerged, excluded.allow_unmerged),
		  eligible_at = MIN(coop_cleanup.eligible_at, excluded.eligible_at),
		  updated_at = excluded.updated_at
		WHERE coop_cleanup.state != 'done'`,
		sessionID, incidentID, reason, allow,
		eligibleAt.UTC().Format(timestampFormat), eligibleAt.UTC().Format(timestampFormat),
		now, now,
	)
	return err
}

func (s *Store) BackfillClosedSessionCleanup(
	ctx context.Context,
	eligibleBefore time.Time,
) (int64, error) {
	now := nowText()
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		)
		SELECT i.coop_session_id, i.id, 'closed work',
		  CASE WHEN p.state = 'published' THEN 1 ELSE 0 END,
		  'pending', i.closed_at, i.closed_at, ?, ?
		FROM incidents i
		LEFT JOIN publications p ON p.incident_id = i.id
		WHERE i.status = 'closed' AND i.coop_session_id != ''
		  AND i.closed_at IS NOT NULL AND i.closed_at <= ?`,
		now, now, eligibleBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) ScheduleExpiredChannelMemoryCleanup(
	ctx context.Context,
	startedBefore time.Time,
	eligibleAt time.Time,
) (int64, error) {
	now := nowText()
	eligible := eligibleAt.UTC().Format(timestampFormat)
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		)
		SELECT session_id, '', 'expired Slack channel memory', 0, 'pending',
		  ?, ?, ?, ?
		FROM channel_memories
		WHERE session_id != '' AND session_started_at IS NOT NULL
		  AND session_started_at <= ?`,
		eligible, eligible, now, now, startedBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) RetireActionProposals(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE action_proposals
		SET status = 'failed',
		    result = 'Operational actions are disabled in this Responder release.',
		    updated_at = ?
		WHERE status IN ('pending', 'approved', 'queued', 'running')`,
		now.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) ResponderSessionKnown(ctx context.Context, sessionID string) (bool, error) {
	if sessionID == "" {
		return false, errors.New("session ID is required")
	}
	var known int
	err := s.db.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1 FROM incidents WHERE coop_session_id = ?
		  UNION ALL
		  SELECT 1 FROM channel_memories WHERE session_id = ?
		  UNION ALL
		  SELECT 1 FROM coop_cleanup WHERE session_id = ?
		)`, sessionID, sessionID, sessionID).Scan(&known)
	return known != 0, err
}

func (s *Store) NextCleanup(ctx context.Context, now time.Time) (core.CoopCleanup, error) {
	var item core.CoopCleanup
	var allow int
	var eligible, next, created, updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT session_id, incident_id, reason, allow_unmerged, state,
		  plan_operation_id, attempts, eligible_at, next_attempt_at, last_error,
		  created_at, updated_at
		FROM coop_cleanup
		WHERE state IN ('pending', 'retry', 'planning', 'discarding')
		  AND eligible_at <= ? AND next_attempt_at <= ?
		ORDER BY eligible_at, created_at LIMIT 1`,
		now.UTC().Format(timestampFormat), now.UTC().Format(timestampFormat)).Scan(
		&item.SessionID, &item.IncidentID, &item.Reason, &allow, &item.State,
		&item.PlanOperationID, &item.Attempts, &eligible, &next, &item.LastError,
		&created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.CoopCleanup{}, ErrNotFound
	}
	if err != nil {
		return core.CoopCleanup{}, err
	}
	item.AllowUnmerged = allow != 0
	item.EligibleAt = parseTime(eligible)
	item.NextAttemptAt = parseTime(next)
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	return item, nil
}

func (s *Store) SetCleanupState(
	ctx context.Context,
	sessionID string,
	state string,
	planOperationID string,
	lastError string,
	retryAt time.Time,
) error {
	if retryAt.IsZero() {
		retryAt = time.Now().UTC()
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE coop_cleanup SET state = ?, plan_operation_id = ?, last_error = ?,
		  attempts = attempts + 1, next_attempt_at = ?, updated_at = ?
		WHERE session_id = ?`,
		state, planOperationID, lastError, retryAt.UTC().Format(timestampFormat),
		nowText(), sessionID,
	)
	if err := expectOne(result, err, "update Coop cleanup"); err != nil {
		return err
	}
	if state == "done" {
		_, err = s.db.ExecContext(ctx, `
			UPDATE incidents SET card_version = card_version + 1, updated_at = ?
			WHERE id = (
			  SELECT incident_id FROM coop_cleanup WHERE session_id = ?
			) AND id != ''`, nowText(), sessionID)
	}
	return err
}

func (s *Store) Prune(
	ctx context.Context,
	operationalBefore time.Time,
	closedBefore time.Time,
	auditBefore time.Time,
) (core.PruneResult, error) {
	var result core.PruneResult
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	deleteCount := func(query string, args ...any) (int64, error) {
		res, execErr := tx.ExecContext(ctx, query, args...)
		if execErr != nil {
			return 0, execErr
		}
		return res.RowsAffected()
	}
	operational := operationalBefore.UTC().Format(timestampFormat)
	if result.SlackInputs, err = deleteCount(`
		DELETE FROM slack_inputs WHERE state IN ('done', 'failed') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	if result.WebhookEvents, err = deleteCount(`
		DELETE FROM webhook_events WHERE state IN ('done', 'failed') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	if result.OutboxMessages, err = deleteCount(`
		DELETE FROM outbox WHERE state IN ('sent', 'failed') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	if result.TurnSubmissions, err = deleteCount(`
		DELETE FROM turn_submissions WHERE state IN ('submitted', 'failed') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	if result.EvaluationDecisions, err = deleteCount(`
		DELETE FROM evaluation_decisions WHERE created_at < ?`, operational); err != nil {
		return result, err
	}
	if result.MemoryEntries, err = deleteCount(`
		DELETE FROM memory_entries WHERE expires_at <= ?`, nowText()); err != nil {
		return result, err
	}
	if result.EmisarApprovals, err = deleteCount(`
		DELETE FROM emisar_approvals WHERE expires_at < ?`, operational); err != nil {
		return result, err
	}

	closed := closedBefore.UTC().Format(timestampFormat)
	for _, query := range []string{
		`DELETE FROM evidence WHERE incident_id = '' AND created_at < ?`,
		`DELETE FROM coverage WHERE incident_id = '' AND created_at < ?`,
		`DELETE FROM timeline_events WHERE incident_id = '' AND created_at < ?`,
	} {
		count, deleteErr := deleteCount(query, operational)
		if deleteErr != nil {
			return result, deleteErr
		}
		result.ChannelIntelligence += count
	}
	count, deleteErr := deleteCount(`
		DELETE FROM channel_memories
		WHERE updated_at < ? AND (
		  session_id = '' OR EXISTS (
		    SELECT 1 FROM coop_cleanup
		    WHERE coop_cleanup.session_id = channel_memories.session_id
		      AND coop_cleanup.state = 'done'
		  )
		)`, operational)
	if deleteErr != nil {
		return result, deleteErr
	}
	result.ChannelIntelligence += count
	if _, err = deleteCount(`
		DELETE FROM proposal_approvals WHERE proposal_id IN (
		  SELECT id FROM action_proposals
		  WHERE status IN ('rejected', 'expired', 'finished', 'failed') AND updated_at < ?
		)`, closed); err != nil {
		return result, err
	}
	if result.ActionProposals, err = deleteCount(`
		DELETE FROM action_proposals
		WHERE status IN ('rejected', 'expired', 'finished', 'failed') AND updated_at < ?`,
		closed); err != nil {
		return result, err
	}
	eligible := `
		SELECT i.id FROM incidents i
		LEFT JOIN coop_cleanup c ON c.session_id = i.coop_session_id
		WHERE i.status = 'closed' AND i.closed_at IS NOT NULL AND i.closed_at < ?
		  AND (i.coop_session_id = '' OR c.state = 'done')`
	for _, query := range []string{
		`DELETE FROM emisar_approvals WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM proposal_approvals WHERE proposal_id IN
		  (SELECT id FROM action_proposals WHERE incident_id IN (` + eligible + `))`,
		`DELETE FROM action_proposals WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM timeline_events WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM evidence WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM coverage WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM signals WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM outbox WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM turn_submissions WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM publications WHERE incident_id IN (` + eligible + `)`,
	} {
		if _, err = deleteCount(query, closed); err != nil {
			return result, fmt.Errorf("prune closed work: %w", err)
		}
	}
	if result.ClosedIncidents, err = deleteCount(
		`DELETE FROM incidents WHERE id IN (`+eligible+`)`, closed,
	); err != nil {
		return result, err
	}
	audit := auditBefore.UTC().Format(timestampFormat)
	if result.AuditEvents, err = deleteCount(`
		DELETE FROM audit_events WHERE created_at < ?`, audit); err != nil {
		return result, err
	}
	if _, err = deleteCount(`
		DELETE FROM coop_cleanup WHERE state = 'done' AND updated_at < ?`, audit); err != nil {
		return result, err
	}
	if err := tx.Commit(); err != nil {
		return result, err
	}
	if result.Total() > 0 {
		_, _ = s.db.ExecContext(ctx, `
			PRAGMA wal_checkpoint(PASSIVE);
			PRAGMA incremental_vacuum(256);
			PRAGMA optimize;
		`)
	}
	return result, nil
}

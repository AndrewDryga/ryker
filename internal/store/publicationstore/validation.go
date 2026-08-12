package publicationstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

var (
	ErrNotFound        = errors.New("publication not found")
	ErrInProgress      = errors.New("draft PR publication is already in progress")
	ErrBindingChanged  = errors.New("draft PR repository binding changed")
	ErrCoalesced       = errors.New("duplicate draft PR publication was coalesced")
	ErrAttemptLost     = errors.New("draft PR publication attempt no longer owns the record")
	ErrWorkUnavailable = errors.New("engineering task is closing or closed")
	ErrCloseConflict   = errors.New("draft PR publication is in progress")
)

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func (r *Repository) Get(ctx context.Context, incidentID string) (core.Publication, error) {
	return get(ctx, r.db, incidentID)
}

func (r *Repository) RecordFailure(
	ctx context.Context,
	incidentID string,
	attemptInputID string,
	state core.PublicationState,
	lastError string,
) error {
	if state != core.PublicationRetrying && state != core.PublicationFailed {
		return fmt.Errorf("publication failure state %q is invalid", state)
	}
	record, err := r.Get(ctx, incidentID)
	if errors.Is(err, ErrNotFound) || (err == nil && !record.InProgress()) {
		return nil
	}
	if err != nil {
		return err
	}
	if record.AttemptInputID != attemptInputID {
		return ErrAttemptLost
	}
	record.State = state
	record.FailureCode = ""
	record.LastError = lastError
	return r.Save(ctx, record)
}

func (r *Repository) Save(ctx context.Context, item core.Publication) error {
	if err := Validate(item); err != nil {
		return err
	}
	now := r.clock().UTC()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	var published any
	if !item.PublishedAt.IsZero() {
		published = item.PublishedAt.UTC().Format(core.TimestampFormat)
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT INTO publications (
		  incident_id, generation, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  failure_code, last_error, created_at, updated_at, published_at, attempt_input_id
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  repository = excluded.repository, base_branch = excluded.base_branch,
		  head_branch = excluded.head_branch, parent_head = excluded.parent_head,
		  candidate_tree = excluded.candidate_tree, commit_sha = excluded.commit_sha,
		  remote_sha = excluded.remote_sha, pr_number = excluded.pr_number,
		  pr_url = excluded.pr_url, state = excluded.state, failure_code = excluded.failure_code,
		  last_error = excluded.last_error, updated_at = excluded.updated_at,
		  published_at = excluded.published_at
		WHERE publications.attempt_input_id = excluded.attempt_input_id AND (
		  publications.attempt_input_id = '' OR publications.state = excluded.state OR
		  (excluded.failure_code = 'session_binding' AND
		    publications.state NOT IN ('reviewing', 'publishing', 'retrying', 'published', 'stale')) OR
		  (publications.state = 'reviewing' AND excluded.state IN ('publishing', 'retrying', 'failed')) OR
		  (publications.state = 'publishing' AND excluded.state IN ('retrying', 'failed', 'published')) OR
		  (publications.state = 'retrying' AND excluded.state IN ('reviewing', 'failed'))
		)`,
		item.IncidentID, item.Generation, item.Repository, item.BaseBranch, item.HeadBranch,
		item.ParentHead, item.CandidateTree, item.CommitSHA, item.RemoteSHA,
		item.PRNumber, item.PRURL, item.State, item.FailureCode, item.LastError,
		item.CreatedAt.UTC().Format(core.TimestampFormat), now.Format(core.TimestampFormat),
		published, item.AttemptInputID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows != 1 {
		return ErrAttemptLost
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now.Format(core.TimestampFormat), item.IncidentID)
	if err := sqlutil.ExpectOne(result, err, "mark publication on incident"); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Repository) MarkStale(
	ctx context.Context,
	incidentID string,
	reason string,
) (bool, error) {
	if incidentID == "" || reason == "" {
		return false, errors.New("stale publication identity and reason are required")
	}
	now := r.clock().UTC().Format(core.TimestampFormat)
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE publications SET state = 'stale', last_error = ?, updated_at = ?
		WHERE incident_id = ? AND state = 'published'`, reason, now, incidentID)
	if err != nil {
		return false, err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if changed == 0 {
		return false, tx.Commit()
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now, incidentID)
	if err := sqlutil.ExpectOne(result, err, "mark stale publication on incident"); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

// BeginClose reserves the incident lifecycle against a concurrent publication
// claim before Coop is asked to close the session.
func (r *Repository) BeginClose(
	ctx context.Context,
	incidentID string,
) (core.WorkflowState, error) {
	now := r.clock().UTC().Format(core.TimestampFormat)
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var previous core.WorkflowState
	if err := tx.QueryRowContext(
		ctx, `SELECT workflow FROM incidents WHERE id = ?`, incidentID,
	).Scan(&previous); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents SET workflow = 'closing', updated_at = ?, card_version = card_version + 1
		WHERE id = ? AND status != 'closed' AND active_turn_id = ''
		  AND workflow != 'closing' AND NOT EXISTS (
		    SELECT 1 FROM publications
		    WHERE incident_id = incidents.id
		      AND state IN ('reviewing', 'publishing', 'retrying')
		  )`, now, incidentID)
	if err != nil {
		return "", err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if rows != 1 {
		var active int
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM publications
			WHERE incident_id = ? AND state IN ('reviewing', 'publishing', 'retrying')`,
			incidentID,
		).Scan(&active); err != nil {
			return "", err
		}
		if active > 0 {
			return "", ErrCloseConflict
		}
		return "", ErrWorkUnavailable
	}
	return previous, tx.Commit()
}

func (r *Repository) RestoreClose(
	ctx context.Context,
	incidentID string,
	previous core.WorkflowState,
) error {
	if previous == "" || previous == core.WorkflowClosing || previous == core.WorkflowClosed {
		previous = core.WorkflowParked
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET workflow = ?, updated_at = ?, card_version = card_version + 1
		WHERE id = ? AND status != 'closed' AND workflow = 'closing'`,
		previous, r.clock().UTC().Format(core.TimestampFormat), incidentID)
	return sqlutil.ExpectOne(result, err, "restore interrupted incident close")
}

// RecoverInterrupted transfers ownership of an interrupted publication back
// to its durable input before the generic Slack-input recovery runs. Bound
// inputs retain automatic retry ownership; orphaned attempts become manual.
func (r *Repository) RecoverInterrupted(ctx context.Context) error {
	now := r.clock().UTC().Format(core.TimestampFormat)
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		UPDATE incidents SET workflow = 'parked', updated_at = ?,
		  card_version = card_version + 1
		WHERE status != 'closed' AND workflow = 'closing'`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id IN (
		  SELECT incident_id FROM publications
		  WHERE state IN ('reviewing', 'publishing')
		)`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE publications AS publication SET
		  state = CASE WHEN EXISTS (
		    SELECT 1 FROM slack_inputs AS input
		    WHERE input.state = 'processing'
		      AND input.id = publication.attempt_input_id
		      AND input.action_id = 'responder_publish_pr'
		      AND input.action_value = publication.incident_id
		  ) THEN 'retrying' ELSE 'failed' END,
		  last_error = CASE WHEN EXISTS (
		    SELECT 1 FROM slack_inputs AS input
		    WHERE input.state = 'processing'
		      AND input.id = publication.attempt_input_id
		      AND input.action_id = 'responder_publish_pr'
		      AND input.action_value = publication.incident_id
		  ) THEN 'Responder restarted during draft PR work; retry is scheduled'
		  ELSE 'Responder stopped during draft PR work; retry it from the task card' END,
		  updated_at = ?
		WHERE state IN ('reviewing', 'publishing')`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'retry', next_attempt_at = ?, updated_at = ?
		WHERE state = 'processing' AND action_id = 'responder_publish_pr'
		  AND EXISTS (
		    SELECT 1 FROM publications
		    WHERE publications.incident_id = slack_inputs.action_value
		      AND publications.attempt_input_id = slack_inputs.id
		      AND publications.state = 'retrying'
		  )`, now, now); err != nil {
		return err
	}
	// A terminal publication is already the authoritative result. Re-running
	// its input after a crash can force-push a different commit or repeat a
	// rejected review, so complete the input instead of replaying side effects.
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'done', updated_at = ?
		WHERE state = 'processing' AND action_id = 'responder_publish_pr'
		  AND EXISTS (
		    SELECT 1 FROM publications
		    WHERE publications.incident_id = slack_inputs.action_value
		      AND publications.attempt_input_id = slack_inputs.id
		      AND publications.state IN ('failed', 'published', 'stale')
		  )`, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO publication_followups (
		  incident_id, next_check_at, created_at, updated_at
		)
		SELECT publication.incident_id, ?, ?, ?
		FROM publications AS publication
		WHERE publication.state = 'published' AND EXISTS (
		  SELECT 1 FROM slack_inputs AS input
		  WHERE input.action_id = 'responder_publish_pr'
		    AND input.id = publication.attempt_input_id
		    AND input.action_value = publication.incident_id
		    AND input.state = 'done' AND input.updated_at = ?
		)`, now, now, now, now); err != nil {
		return err
	}
	return tx.Commit()
}

// BeginReview atomically claims one publication attempt and binds its Slack
// input to the incident so restart recovery can make the same retry decision.
func (r *Repository) BeginReview(
	ctx context.Context,
	attemptInputID string,
	slackInputID string,
	incidentID string,
	repository string,
	baseBranch string,
	target *core.PullRequestTarget,
	expectedGenerations ...int64,
) (core.Publication, error) {
	var binding core.PullRequestTarget
	if target != nil {
		if !target.Valid() {
			return core.Publication{}, errors.New("existing pull request target is incomplete")
		}
		if target.Repository != repository || target.BaseBranch != baseBranch {
			return core.Publication{}, ErrBindingChanged
		}
		binding = *target
	}
	expectedGeneration := int64(-1)
	if len(expectedGenerations) > 0 {
		expectedGeneration = expectedGenerations[0]
	}
	item := core.Publication{
		IncidentID: incidentID, Repository: repository, BaseBranch: baseBranch,
		State: core.PublicationReviewing, AttemptInputID: attemptInputID, Generation: 1,
	}
	if binding.Valid() {
		item.HeadBranch = binding.HeadBranch
		item.RemoteSHA = binding.HeadCommit
		item.PRNumber = binding.Number
		item.PRURL = binding.URL
	}
	if err := Validate(item); err != nil {
		return core.Publication{}, err
	}
	now := r.clock().UTC().Format(core.TimestampFormat)
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return core.Publication{}, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = updated_at
		WHERE id = ? AND status != 'closed' AND workflow != 'closing'`, incidentID)
	if err != nil {
		return core.Publication{}, err
	}
	if rows, rowsErr := result.RowsAffected(); rowsErr != nil {
		return core.Publication{}, rowsErr
	} else if rows != 1 {
		return core.Publication{}, ErrWorkUnavailable
	}
	result, err = tx.ExecContext(ctx, `
		INSERT INTO publications (
		  incident_id, generation, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  failure_code, last_error, created_at, updated_at, attempt_input_id
		) VALUES (?, 1, ?, ?, ?, '', '', '', ?, ?, ?, 'reviewing', '', '', ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  generation = publications.generation + 1,
		  repository = excluded.repository,
		  base_branch = excluded.base_branch,
		  head_branch = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch
		    THEN publications.head_branch ELSE excluded.head_branch END,
		  parent_head = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch
		    THEN publications.parent_head ELSE '' END,
		  candidate_tree = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch
		    THEN publications.candidate_tree ELSE '' END,
		  commit_sha = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch
		    THEN publications.commit_sha ELSE '' END,
		  remote_sha = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch
		    THEN publications.remote_sha ELSE excluded.remote_sha END,
		  pr_number = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch AND
		    publications.pr_number > 0
		    THEN publications.pr_number ELSE excluded.pr_number END,
		  pr_url = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch AND
		    publications.pr_number > 0
		    THEN publications.pr_url ELSE excluded.pr_url END,
		  published_at = CASE WHEN
		    publications.repository = excluded.repository AND
		    publications.base_branch = excluded.base_branch
		    THEN publications.published_at ELSE NULL END,
		  state = 'reviewing',
		  attempt_input_id = excluded.attempt_input_id,
		  failure_code = '',
		  last_error = '',
		  updated_at = excluded.updated_at
		WHERE (
		    publications.state NOT IN ('reviewing', 'publishing', 'retrying') OR
		    (publications.state = 'retrying' AND
		      publications.attempt_input_id = excluded.attempt_input_id)
		  )
		  AND (
		    (publications.pr_number = 0 AND publications.remote_sha = '') OR (
		      publications.repository = excluded.repository AND
		      publications.base_branch = excluded.base_branch
		    )
		  ) AND (
		    excluded.pr_number = 0 OR publications.pr_number = 0 OR (
		      publications.pr_number = excluded.pr_number AND
		      publications.pr_url = excluded.pr_url AND
		      publications.head_branch = excluded.head_branch
		    )
		  ) AND (
		    publications.attempt_input_id = excluded.attempt_input_id OR
		    NOT EXISTS (
		      SELECT 1 FROM slack_inputs AS input
		      WHERE input.id = ? AND
		        julianday(input.received_at) <= julianday(publications.updated_at)
		    )
		  ) AND (? < 0 OR publications.generation = ?)`,
		incidentID, repository, baseBranch, item.HeadBranch, item.RemoteSHA,
		item.PRNumber, item.PRURL, now, now, attemptInputID, slackInputID,
		expectedGeneration, expectedGeneration,
	)
	if err != nil {
		return core.Publication{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.Publication{}, err
	}
	if rows != 1 {
		current, readErr := get(ctx, tx, incidentID)
		if readErr != nil {
			return core.Publication{}, readErr
		}
		if (current.HasPR() || current.RemoteSHA != "") &&
			(current.Repository != repository || current.BaseBranch != baseBranch) {
			if current.State == core.PublicationRetrying &&
				(current.AttemptInputID == "" || current.AttemptInputID == attemptInputID) {
				if _, updateErr := tx.ExecContext(ctx, `
					UPDATE publications SET state = 'failed',
					  last_error = 'The configured GitHub repository or base branch changed after this PR was created.',
					  updated_at = ?
					WHERE incident_id = ? AND state = 'retrying'
					  AND attempt_input_id = ?`, now, incidentID, current.AttemptInputID); updateErr != nil {
					return core.Publication{}, updateErr
				}
				if _, updateErr := tx.ExecContext(ctx, `
					UPDATE incidents SET updated_at = ?, card_version = card_version + 1
					WHERE id = ?`, now, incidentID); updateErr != nil {
					return core.Publication{}, updateErr
				}
				if commitErr := tx.Commit(); commitErr != nil {
					return core.Publication{}, commitErr
				}
			}
			return core.Publication{}, ErrBindingChanged
		}
		if binding.Valid() && current.HasPR() &&
			(current.PRNumber != binding.Number || current.PRURL != binding.URL ||
				current.HeadBranch != binding.HeadBranch) {
			return core.Publication{}, ErrBindingChanged
		}
		if expectedGeneration >= 0 && current.Generation != expectedGeneration {
			return core.Publication{}, ErrCoalesced
		}
		if current.AttemptInputID != attemptInputID && slackInputID != "" {
			var received string
			if readErr := tx.QueryRowContext(
				ctx, `SELECT received_at FROM slack_inputs WHERE id = ?`, slackInputID,
			).Scan(&received); readErr == nil &&
				!sqlutil.ParseTime(received).After(current.UpdatedAt) {
				return core.Publication{}, ErrCoalesced
			}
		}
		return core.Publication{}, ErrInProgress
	}
	if slackInputID != "" {
		result, err = tx.ExecContext(ctx, `
			UPDATE slack_inputs
			SET action_id = 'responder_publish_pr', action_value = ?, updated_at = ?
			WHERE id = ? AND state = 'processing'`,
			incidentID, now, slackInputID,
		)
		if err := sqlutil.ExpectOne(result, err, "bind publication review input"); err != nil {
			return core.Publication{}, err
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE slack_inputs
			SET state = 'done', last_error = 'duplicate draft PR request coalesced',
			    updated_at = ?
			WHERE id != ? AND state IN ('pending', 'retry')
			  AND action_id = 'responder_publish_pr' AND action_value = ?`,
			now, slackInputID, incidentID,
		); err != nil {
			return core.Publication{}, err
		}
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE incidents
		SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now, incidentID)
	if err := sqlutil.ExpectOne(result, err, "mark publication review on incident"); err != nil {
		return core.Publication{}, err
	}
	claimed, err := get(ctx, tx, incidentID)
	if err != nil {
		return core.Publication{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.Publication{}, err
	}
	return claimed, nil
}

type queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func get(ctx context.Context, db queryer, incidentID string) (core.Publication, error) {
	var item core.Publication
	var created, updated string
	var published sql.NullString
	err := db.QueryRowContext(ctx, `
		SELECT incident_id, attempt_input_id, generation, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  failure_code, last_error, created_at, updated_at, published_at
		FROM publications WHERE incident_id = ?`, incidentID).Scan(
		&item.IncidentID, &item.AttemptInputID, &item.Generation, &item.Repository, &item.BaseBranch, &item.HeadBranch,
		&item.ParentHead, &item.CandidateTree, &item.CommitSHA, &item.RemoteSHA,
		&item.PRNumber, &item.PRURL, &item.State, &item.FailureCode, &item.LastError, &created,
		&updated, &published,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.Publication{}, ErrNotFound
		}
		return core.Publication{}, err
	}
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	item.PublishedAt = sqlutil.ScanTime(published)
	return item, nil
}

// Validate checks the durable proof required at each publication state.
func Validate(item core.Publication) error {
	if item.IncidentID == "" || item.Repository == "" || item.BaseBranch == "" {
		return errors.New("publication identity, repository, base branch, and state are required")
	}
	switch item.State {
	case core.PublicationReviewing, core.PublicationRetrying, core.PublicationFailed:
	case core.PublicationPublishing:
		if item.ParentHead == "" || item.CandidateTree == "" {
			return errors.New("reviewed tree is required before publication")
		}
	case core.PublicationPublished, core.PublicationStale:
		if item.ParentHead == "" || item.CandidateTree == "" {
			return errors.New("reviewed tree is required before publication")
		}
		if item.HeadBranch == "" || item.CommitSHA == "" || item.RemoteSHA == "" ||
			item.PRNumber < 1 || item.PRURL == "" || item.PublishedAt.IsZero() {
			return errors.New("durable draft PR identity and proof are required")
		}
	default:
		return fmt.Errorf("publication state %q is invalid", item.State)
	}
	return nil
}

package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

const commitmentProjectionColumns = `
	'commitment_' || r.id, r.id, r.channel_id, r.thread_ts, r.user_id, r.repository, c.title,
	CASE
	  WHEN r.state IN ('pending', 'preparing') THEN 'queued'
	  WHEN r.state = 'running' THEN 'working'
	  WHEN r.state IN ('applying', 'finalizing') THEN 'finishing'
	  WHEN r.state = 'completed' THEN 'done'
	  WHEN r.state = 'failed' THEN 'blocked'
	  ELSE 'cancelled'
	END,
	CASE
	  WHEN r.state IN ('pending', 'preparing') THEN 'Waiting to start'
	  WHEN r.state = 'running' THEN 'Investigating'
	  WHEN r.state IN ('applying', 'finalizing') THEN 'Preparing the Slack response'
	  WHEN r.state = 'completed' THEN 'Completed'
	  WHEN r.state = 'failed' THEN COALESCE(NULLIF(r.last_error, ''), 'Needs operator attention')
	  ELSE 'Cancelled'
	END,
	CASE
	  WHEN r.state IN ('pending', 'preparing') THEN 'Start the investigation'
	  WHEN r.state = 'running' THEN 'Finish the evidence check'
	  WHEN r.state IN ('applying', 'finalizing') THEN 'Deliver the result'
	  WHEN r.state = 'failed' THEN 'Operator review or retry'
	  ELSE ''
	END,
	r.source_kind, r.source_id, r.created_at, r.updated_at, r.completed_at`

func (s *Store) ensureCommitment(ctx context.Context, run core.AgentRun) error {
	title := strings.TrimSpace(run.CommitmentTitle)
	if title == "" {
		switch run.Mode {
		case core.AgentRunIncident:
			title = "Investigate incident"
		case core.AgentRunEngineeringTask:
			title = "Complete engineering task"
		default:
			title = "Answer Slack request"
		}
	}
	if len(title) > 240 {
		title = title[:240]
	}
	_, err := s.db.ExecContext(
		ctx,
		`INSERT OR IGNORE INTO commitments (agent_run_id, title) VALUES (?, ?)`,
		run.ID,
		title,
	)
	return err
}

func scanCommitment(row interface{ Scan(...any) error }) (core.Commitment, error) {
	var item core.Commitment
	var created, updated string
	var completed sql.NullString
	err := row.Scan(
		&item.ID,
		&item.AgentRunID,
		&item.ChannelID,
		&item.ThreadTS,
		&item.UserID,
		&item.Repository,
		&item.Title,
		&item.State,
		&item.Status,
		&item.NextAction,
		&item.SourceKind,
		&item.SourceID,
		&created,
		&updated,
		&completed,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.Commitment{}, ErrNotFound
	}
	if err != nil {
		return core.Commitment{}, err
	}
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	item.CompletedAt = scanTime(completed)
	return item, nil
}

func (s *Store) GetCommitmentByRun(
	ctx context.Context,
	runID string,
) (core.Commitment, error) {
	return scanCommitment(s.db.QueryRowContext(
		ctx,
		`SELECT `+commitmentProjectionColumns+`
		 FROM commitments AS c
		 JOIN agent_runs AS r ON r.id = c.agent_run_id
		 WHERE c.agent_run_id = ?`,
		runID,
	))
}

func (s *Store) ListActiveCommitments(
	ctx context.Context,
	limit int,
) ([]core.Commitment, error) {
	if limit < 1 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+commitmentProjectionColumns+`
		FROM commitments AS c
		JOIN agent_runs AS r ON r.id = c.agent_run_id
		WHERE r.state IN ('pending', 'preparing', 'running', 'applying', 'finalizing', 'failed')
		ORDER BY
		  CASE r.state
		    WHEN 'failed' THEN 0
		    WHEN 'running' THEN 1
		    WHEN 'applying' THEN 2
		    WHEN 'finalizing' THEN 2
		    ELSE 3
		  END,
		  r.updated_at DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.Commitment, 0)
	for rows.Next() {
		item, err := scanCommitment(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) CountActiveCommitments(ctx context.Context) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM commitments AS c
		JOIN agent_runs AS r ON r.id = c.agent_run_id
		WHERE r.state IN ('pending', 'preparing', 'running', 'applying', 'finalizing', 'failed')`,
	).Scan(&count)
	return count, err
}

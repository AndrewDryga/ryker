package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/episode"
)

const commitmentProjectionColumns = `
	'commitment_' || r.id, r.id, r.channel_id, r.thread_ts, r.user_id, r.repository, c.title,
	e.lifecycle_state,
	e.status,
	e.next_action,
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
	title = core.TruncateUTF8(title, 240)
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
	var episodeState core.WorkEpisodeState
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
		&episodeState,
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
	item.State = core.CommitmentState(
		episode.Project(core.WorkEpisode{State: episodeState}).CommitmentState,
	)
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
		 JOIN work_episodes AS e ON e.agent_run_id = r.id
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
		JOIN work_episodes AS e ON e.agent_run_id = r.id
		WHERE e.lifecycle_state IN (
		  'accepted', 'acknowledged', 'planning', 'working', 'retrying', 'verifying',
		  'waiting_operator', 'waiting_external', 'waiting_approval', 'blocked', 'failed'
		)
		ORDER BY
		  CASE e.lifecycle_state
		    WHEN 'blocked' THEN 0
		    WHEN 'failed' THEN 0
		    WHEN 'waiting_approval' THEN 1
		    WHEN 'waiting_operator' THEN 1
		    WHEN 'waiting_external' THEN 1
		    WHEN 'working' THEN 2
		    WHEN 'verifying' THEN 3
		    ELSE 3
		  END,
		  e.updated_at DESC
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
		JOIN work_episodes AS e ON e.agent_run_id = r.id
		WHERE e.lifecycle_state IN (
		  'accepted', 'acknowledged', 'planning', 'working', 'retrying', 'verifying',
		  'waiting_operator', 'waiting_external', 'waiting_approval', 'blocked', 'failed'
		)`,
	).Scan(&count)
	return count, err
}

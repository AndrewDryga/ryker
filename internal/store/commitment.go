package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const commitmentProjectionColumns = `
	'commitment_' || e.id, r.id, r.channel_id, r.thread_ts, r.user_id, r.repository, c.title,
	e.lifecycle_state,
	e.status,
	e.next_action,
	r.source_kind, r.source_id, r.created_at, r.updated_at, r.completed_at`

// ensureCommitment records the promise this work represents, keyed by episode.
//
// Keyed by episode, not by run: a commitment is a promise to a person about a
// unit of work, and a replacement attempt after a restart is the same promise.
// While it was keyed by run, a commitment made by a replacement attempt joined
// to nothing in the projection and silently disappeared from every view.
func ensureCommitmentTx(ctx context.Context, tx *sql.Tx, run core.AgentRun) error {
	if strings.TrimSpace(run.EpisodeID) == "" {
		return nil
	}
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
	_, err := tx.ExecContext(
		ctx,
		`INSERT OR IGNORE INTO commitments (episode_id, title) VALUES (?, ?)`,
		run.EpisodeID,
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
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	item.CompletedAt = sqlutil.ScanTime(completed)
	item.State = core.CommitmentState(
		episode.Project(core.WorkEpisode{State: episodeState}).CommitmentState,
	)
	return item, nil
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
		JOIN work_episodes AS e ON e.id = c.episode_id
		JOIN agent_runs AS r ON r.id = e.agent_run_id
		-- 'failed' is deliberately absent: a crash the retry machinery owns,
		-- already counted as failed work. Including it read 104 commitments
		-- when 100 were failures nobody could act on.
		WHERE e.lifecycle_state IN (
		  'accepted', 'acknowledged', 'planning', 'working', 'retrying', 'verifying',
		  'waiting_operator', 'waiting_external', 'waiting_approval', 'blocked'
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
		JOIN work_episodes AS e ON e.id = c.episode_id
		JOIN agent_runs AS r ON r.id = e.agent_run_id
		-- 'failed' is deliberately absent: a crash the retry machinery owns,
		-- already counted as failed work. Including it read 104 commitments
		-- when 100 were failures nobody could act on.
		WHERE e.lifecycle_state IN (
		  'accepted', 'acknowledged', 'planning', 'working', 'retrying', 'verifying',
		  'waiting_operator', 'waiting_external', 'waiting_approval', 'blocked'
		)`,
	).Scan(&count)
	return count, err
}

// listIncidentCommitments is every promise this incident's work created.
//
// A package function rather than a method on Store, because Store's exported
// surface is at its budget and this has exactly one caller: the remediation
// record the postmortem is rendered from. It is also the honest shape — this is
// part of loading one incident's canonical snapshot, not a general capability.
//
// Every state, including finished and cancelled ones, unlike the active list.
// A postmortem's follow-up section is a record of what was promised and what
// became of it; hiding the closed ones would turn "we said we would check the
// export job" into a blank line.
func listIncidentCommitments(
	ctx context.Context,
	db *sql.DB,
	incidentID string,
	limit int,
) ([]core.Commitment, error) {
	if strings.TrimSpace(incidentID) == "" {
		return nil, nil
	}
	rows, err := db.QueryContext(ctx, `
		SELECT `+commitmentProjectionColumns+`
		FROM commitments AS c
		JOIN work_episodes AS e ON e.id = c.episode_id
		JOIN agent_runs AS r ON r.id = e.agent_run_id
		WHERE r.incident_id = ?
		ORDER BY r.created_at ASC LIMIT ?`, incidentID, limit)
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

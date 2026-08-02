package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const workEpisodeColumns = `
	id, agent_run_id, effort, authority, state, objective,
	required_coverage_json, completion_criteria_json, phase, status, next_action,
	progress_sequence, last_progress_at, progress_due_at, created_at, updated_at,
	completed_at`

func defaultWorkEpisode(run core.AgentRun) core.WorkEpisode {
	episode := core.WorkEpisode{
		ID:         "episode_" + run.ID,
		AgentRunID: run.ID,
		Effort:     core.EffortFocusedCheck,
		Authority:  core.AuthorityReadOnly,
		State:      core.EpisodeAcknowledged,
		Objective:  strings.TrimSpace(run.CommitmentTitle),
		Phase:      "accepted",
		Status:     "Accepted",
		NextAction: "Plan the work",
	}
	if episode.Objective == "" {
		episode.Objective = strings.TrimSpace(run.Prompt)
	}
	if episode.Objective == "" {
		episode.Objective = "Complete the accepted Slack request"
	}
	switch run.Mode {
	case core.AgentRunEngineeringTask:
		episode.Effort = core.EffortEngineeringTask
		episode.Authority = core.AuthorityRepositoryWrite
	case core.AgentRunIncident:
		episode.Effort = core.EffortIncidentInvestigation
	}
	return episode
}

func normalizeWorkEpisode(run core.AgentRun) (core.WorkEpisode, error) {
	episode := defaultWorkEpisode(run)
	if run.Episode != nil {
		candidate := *run.Episode
		if candidate.ID != "" {
			episode.ID = candidate.ID
		}
		if candidate.Effort != "" {
			episode.Effort = candidate.Effort
		}
		if candidate.Authority != "" {
			episode.Authority = candidate.Authority
		}
		if strings.TrimSpace(candidate.Objective) != "" {
			episode.Objective = strings.TrimSpace(candidate.Objective)
		}
		episode.RequiredCoverage = append([]string(nil), candidate.RequiredCoverage...)
		episode.CompletionCriteria = append([]string(nil), candidate.CompletionCriteria...)
	}
	episode.AgentRunID = run.ID
	if !validEffort(effortString(episode.Effort)) {
		return core.WorkEpisode{}, fmt.Errorf("unsupported work episode effort %q", episode.Effort)
	}
	if !validAuthority(string(episode.Authority)) {
		return core.WorkEpisode{}, fmt.Errorf("unsupported work episode authority %q", episode.Authority)
	}
	episode.RequiredCoverage = normalizedUniqueStrings(episode.RequiredCoverage, 9)
	episode.CompletionCriteria = normalizedUniqueStrings(episode.CompletionCriteria, 12)
	if len(episode.Objective) > 500 {
		episode.Objective = episode.Objective[:500]
	}
	return episode, nil
}

func effortString(value core.EffortContract) string { return string(value) }

func validEffort(value string) bool {
	switch core.EffortContract(value) {
	case core.EffortConversational, core.EffortFocusedCheck,
		core.EffortOperationalAssessment, core.EffortIncidentInvestigation,
		core.EffortEngineeringTask:
		return true
	default:
		return false
	}
}

func validAuthority(value string) bool {
	switch core.AuthorityBoundary(value) {
	case core.AuthorityReadOnly, core.AuthorityRepositoryWrite,
		core.AuthorityGovernedOperation:
		return true
	default:
		return false
	}
}

func validWorkEpisodeState(value core.WorkEpisodeState) bool {
	switch value {
	case core.EpisodeAcknowledged, core.EpisodePlanning, core.EpisodeWorking,
		core.EpisodeBlocked, core.EpisodeWaitingApproval, core.EpisodeVerifying,
		core.EpisodeCompleted, core.EpisodeFailed, core.EpisodeCancelled,
		core.EpisodeSuperseded:
		return true
	default:
		return false
	}
}

func normalizedUniqueStrings(items []string, limit int) []string {
	result := make([]string, 0, min(len(items), limit))
	seen := make(map[string]struct{}, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		result = append(result, item)
		if len(result) == limit {
			break
		}
	}
	return result
}

func (s *Store) ensureWorkEpisode(ctx context.Context, run core.AgentRun) error {
	episode, err := normalizeWorkEpisode(run)
	if err != nil {
		return err
	}
	required, err := json.Marshal(episode.RequiredCoverage)
	if err != nil {
		return err
	}
	criteria, err := json.Marshal(episode.CompletionCriteria)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO work_episodes (
		  id, agent_run_id, effort, authority, state, objective,
		  required_coverage_json, completion_criteria_json,
		  phase, status, next_action, created_at, updated_at
		) VALUES (?, ?, ?, ?, 'acknowledged', ?, ?, ?, 'accepted', 'Accepted',
		          'Plan the work', ?, ?)`,
		episode.ID, run.ID, episode.Effort, episode.Authority, episode.Objective,
		required, criteria, nowText(), nowText(),
	)
	if err != nil {
		return err
	}
	created, err := result.RowsAffected()
	if err != nil || created == 0 {
		return err
	}
	now := nowText()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO work_episode_progress
		  (id, episode_id, sequence, phase, summary, created_at)
		VALUES (?, ?, 1, 'accepted', 'Accepted', ?)`,
		"episode_progress_"+episode.ID+"_000001", episode.ID, now,
	); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET progress_sequence = 1, last_progress_at = ?, updated_at = ?
		WHERE id = ?`, now, now, episode.ID); err != nil {
		return err
	}
	return tx.Commit()
}

func scanWorkEpisode(row interface{ Scan(...any) error }) (core.WorkEpisode, error) {
	var item core.WorkEpisode
	var requiredJSON, criteriaJSON string
	var lastProgress, progressDue, completed sql.NullString
	var created, updated string
	err := row.Scan(
		&item.ID, &item.AgentRunID, &item.Effort, &item.Authority, &item.State,
		&item.Objective, &requiredJSON, &criteriaJSON, &item.Phase, &item.Status,
		&item.NextAction, &item.ProgressSequence, &lastProgress, &progressDue,
		&created, &updated, &completed,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.WorkEpisode{}, ErrNotFound
	}
	if err != nil {
		return core.WorkEpisode{}, err
	}
	if err := json.Unmarshal([]byte(requiredJSON), &item.RequiredCoverage); err != nil {
		return core.WorkEpisode{}, fmt.Errorf("decode work episode coverage: %w", err)
	}
	if err := json.Unmarshal([]byte(criteriaJSON), &item.CompletionCriteria); err != nil {
		return core.WorkEpisode{}, fmt.Errorf("decode work episode criteria: %w", err)
	}
	item.LastProgressAt = scanTime(lastProgress)
	item.ProgressDueAt = scanTime(progressDue)
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	item.CompletedAt = scanTime(completed)
	return item, nil
}

func (s *Store) GetWorkEpisodeByRun(
	ctx context.Context,
	runID string,
) (core.WorkEpisode, error) {
	return scanWorkEpisode(s.db.QueryRowContext(
		ctx,
		`SELECT `+workEpisodeColumns+` FROM work_episodes WHERE agent_run_id = ?`,
		runID,
	))
}

func (s *Store) SetWorkEpisodePhase(
	ctx context.Context,
	runID string,
	state core.WorkEpisodeState,
	phase string,
	status string,
	nextAction string,
	progressDue time.Time,
) error {
	if strings.TrimSpace(phase) == "" || strings.TrimSpace(status) == "" {
		return errors.New("work episode phase and status are required")
	}
	if !validWorkEpisodeState(state) {
		return fmt.Errorf("unsupported work episode state %q", state)
	}
	completedAt := any(nil)
	if state == core.EpisodeCompleted || state == core.EpisodeFailed ||
		state == core.EpisodeCancelled || state == core.EpisodeSuperseded {
		completedAt = nowText()
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var episodeID string
	var sequence int
	if err := tx.QueryRowContext(ctx, `
		SELECT id, progress_sequence + 1
		FROM work_episodes WHERE agent_run_id = ?`, runID,
	).Scan(&episodeID, &sequence); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	now := nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET state = ?, phase = ?, status = ?, next_action = ?, progress_due_at = ?,
		    progress_sequence = ?, last_progress_at = ?,
		    completed_at = COALESCE(?, completed_at), updated_at = ?
		WHERE agent_run_id = ? AND progress_sequence = ?`,
		state, strings.TrimSpace(phase), boundedError(status),
		boundedError(nextAction), nullableTime(progressDue), sequence, now,
		completedAt, now, runID, sequence-1,
	)
	if err := expectOne(result, err, "set work episode phase"); err != nil {
		return err
	}
	progressID := fmt.Sprintf("episode_progress_%s_%06d", episodeID, sequence)
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO work_episode_progress
		  (id, episode_id, sequence, phase, summary, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		progressID, episodeID, sequence, strings.TrimSpace(phase),
		boundedError(status), now,
	); err != nil {
		return err
	}
	return tx.Commit()
}

// ResolveWaitingApprovalEpisodes closes the accepted work that reached an
// Emisar decision. A separate continuation episode then verifies the terminal
// run and any live effect without leaving the original commitment active.
func (s *Store) ResolveWaitingApprovalEpisodes(
	ctx context.Context,
	incidentID string,
	sourceInput string,
	status string,
) error {
	if strings.TrimSpace(sourceInput) == "" {
		return errors.New("approval source input is required")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT e.agent_run_id
		FROM work_episodes AS e
		JOIN agent_runs AS r ON r.id = e.agent_run_id
		WHERE e.state = 'waiting_approval'
		  AND r.source_id = ?
		  AND (? = '' OR COALESCE(r.incident_id, '') = ?)
		ORDER BY e.created_at`, sourceInput, incidentID, incidentID)
	if err != nil {
		return err
	}
	defer rows.Close()
	var runIDs []string
	for rows.Next() {
		var runID string
		if err := rows.Scan(&runID); err != nil {
			return err
		}
		runIDs = append(runIDs, runID)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, runID := range runIDs {
		if err := s.SetWorkEpisodePhase(
			ctx,
			runID,
			core.EpisodeCompleted,
			"approval_decided",
			"Emisar decision: "+boundedError(status),
			"Verify the terminal run and live effect",
			time.Time{},
		); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) RecordWorkEpisodeProgress(
	ctx context.Context,
	runID string,
	phase string,
	summary string,
	nextDue time.Time,
) (core.WorkEpisodeProgress, error) {
	phase = strings.TrimSpace(phase)
	summary = strings.TrimSpace(summary)
	if phase == "" || summary == "" {
		return core.WorkEpisodeProgress{}, errors.New("work episode progress requires phase and summary")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	defer tx.Rollback()
	var episodeID string
	var sequence int
	if err := tx.QueryRowContext(ctx, `
		SELECT id, progress_sequence + 1
		FROM work_episodes WHERE agent_run_id = ?`, runID,
	).Scan(&episodeID, &sequence); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.WorkEpisodeProgress{}, ErrNotFound
		}
		return core.WorkEpisodeProgress{}, err
	}
	id := fmt.Sprintf("episode_progress_%s_%06d", episodeID, sequence)
	now := nowText()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO work_episode_progress
		  (id, episode_id, sequence, phase, summary, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		id, episodeID, sequence, phase, boundedError(summary), now,
	); err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET phase = ?, status = ?, progress_sequence = ?, last_progress_at = ?,
		    progress_due_at = ?, updated_at = ?
		WHERE id = ? AND progress_sequence = ?`,
		phase, boundedError(summary), sequence, now, nullableTime(nextDue), now,
		episodeID, sequence-1,
	)
	if err := expectOne(result, err, "advance work episode progress"); err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	return core.WorkEpisodeProgress{
		ID: id, EpisodeID: episodeID, Sequence: sequence,
		Phase: phase, Summary: summary, CreatedAt: parseTime(now),
	}, nil
}

func (s *Store) ListWorkEpisodeProgress(
	ctx context.Context,
	runID string,
	limit int,
) ([]core.WorkEpisodeProgress, error) {
	if limit < 1 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT p.id, p.episode_id, p.sequence, p.phase, p.summary, p.created_at
		FROM work_episode_progress AS p
		JOIN work_episodes AS e ON e.id = p.episode_id
		WHERE e.agent_run_id = ?
		ORDER BY p.sequence DESC LIMIT ?`, runID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.WorkEpisodeProgress, 0)
	for rows.Next() {
		var item core.WorkEpisodeProgress
		var created string
		if err := rows.Scan(
			&item.ID, &item.EpisodeID, &item.Sequence, &item.Phase,
			&item.Summary, &created,
		); err != nil {
			return nil, err
		}
		item.CreatedAt = parseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

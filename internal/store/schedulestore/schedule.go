package schedulestore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const scheduledTaskSelect = `
	SELECT id, team_id, channel_id, thread_ts, delivery_channel_id, repository, title, prompt,
	  recurrence, start_at, interval_seconds, weekdays_json, day_of_month,
	  local_time, timezone, catch_up, enabled, actor_id, source_ref,
	  next_run_at, last_run_at, last_outcome, expires_at, created_at, updated_at
	FROM scheduled_tasks`

func (r *Repository) CreateScheduledTask(
	ctx context.Context,
	task core.ScheduledTask,
	maxTotal int,
	maxPerChannel int,
) (core.ScheduledTask, error) {
	if err := validateScheduledTask(task); err != nil {
		return core.ScheduledTask{}, err
	}
	if maxTotal < 1 || maxPerChannel < 1 || maxPerChannel > maxTotal {
		return core.ScheduledTask{}, errors.New("scheduled task limits are invalid")
	}
	now := r.now().UTC()
	if !task.ExpiresAt.After(now) || !task.NextRunAt.After(now.Add(-time.Second)) ||
		!task.NextRunAt.Before(task.ExpiresAt) {
		return core.ScheduledTask{}, errors.New("scheduled task must have a future expiry and runnable next occurrence")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	defer tx.Rollback()
	existing, existingErr := scanScheduledTask(tx.QueryRowContext(
		ctx,
		scheduledTaskSelect+` WHERE team_id = ? AND channel_id = ? AND source_ref = ?`,
		task.TeamID, task.ChannelID, task.SourceRef,
	))
	if existingErr == nil {
		return existing, nil
	}
	if !errors.Is(existingErr, core.ErrNotFound) {
		return core.ScheduledTask{}, existingErr
	}
	var total, channel int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM scheduled_tasks WHERE expires_at > ?`, now.Format(core.TimestampFormat)).Scan(&total); err != nil {
		return core.ScheduledTask{}, err
	}
	if total >= maxTotal {
		return core.ScheduledTask{}, fmt.Errorf("scheduled task capacity reached (%d unexpired tasks)", maxTotal)
	}
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM scheduled_tasks WHERE channel_id = ? AND expires_at > ?`, task.ChannelID, now.Format(core.TimestampFormat)).Scan(&channel); err != nil {
		return core.ScheduledTask{}, err
	}
	if channel >= maxPerChannel {
		return core.ScheduledTask{}, fmt.Errorf("scheduled task capacity reached for this channel (%d unexpired tasks)", maxPerChannel)
	}
	if err := insertScheduledTask(ctx, tx, &task, now); err != nil {
		return core.ScheduledTask{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.ScheduledTask{}, err
	}
	return task, nil
}

func insertScheduledTask(ctx context.Context, tx *sql.Tx, task *core.ScheduledTask, now time.Time) error {
	var err error
	if task.ID == "" {
		task.ID, err = core.NewID("schedule")
		if err != nil {
			return err
		}
	}
	task.Enabled = true
	task.CreatedAt = now
	task.UpdatedAt = now
	weekdays, err := json.Marshal(task.Weekdays)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO scheduled_tasks (
		  id, team_id, channel_id, thread_ts, delivery_channel_id, repository, title, prompt,
		  recurrence, start_at, interval_seconds, weekdays_json, day_of_month,
		  local_time, timezone, catch_up, enabled, actor_id, source_ref,
		  next_run_at, last_outcome, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, '', ?, ?, ?)`,
		task.ID, task.TeamID, task.ChannelID, task.ThreadTS,
		firstNonemptySchedule(task.DeliveryChannel, task.ChannelID), task.Repository,
		task.Title, task.Prompt, task.Recurrence,
		task.StartAt.UTC().Format(core.TimestampFormat), task.IntervalSeconds, weekdays,
		task.DayOfMonth, task.LocalTime, task.Timezone, task.CatchUp,
		task.ActorID, task.SourceRef, task.NextRunAt.UTC().Format(core.TimestampFormat),
		task.ExpiresAt.UTC().Format(core.TimestampFormat),
		task.CreatedAt.Format(core.TimestampFormat), task.UpdatedAt.Format(core.TimestampFormat),
	)
	return err
}

func validateScheduledTask(task core.ScheduledTask) error {
	for name, value := range map[string]string{
		"team": task.TeamID, "channel": task.ChannelID, "repository": task.Repository,
		"title": task.Title, "prompt": task.Prompt, "actor": task.ActorID,
		"source reference": task.SourceRef,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("scheduled task %s is required", name)
		}
	}
	if len(task.TeamID) > 64 || len(task.ChannelID) > 64 || len(task.ThreadTS) > 64 ||
		len(task.DeliveryChannel) > 64 ||
		len(task.Repository) > 63 || len(task.Title) > 160 || len(task.Prompt) > 1200 ||
		len(task.ActorID) > 64 || len(task.SourceRef) > 200 {
		return errors.New("scheduled task contains an oversized field")
	}
	switch task.Recurrence {
	case "once":
	case "interval":
		if task.IntervalSeconds < 300 || task.IntervalSeconds > int64((365*24*time.Hour)/time.Second) {
			return errors.New("scheduled task interval must be between 5 minutes and 365 days")
		}
	case "daily":
		if task.LocalTime == "" {
			return errors.New("daily schedule requires local_time")
		}
	case "weekly":
		if task.LocalTime == "" || len(task.Weekdays) == 0 || len(task.Weekdays) > 7 {
			return errors.New("weekly schedule requires local_time and weekdays")
		}
	case "monthly":
		if task.LocalTime == "" || task.DayOfMonth < 1 || task.DayOfMonth > 31 {
			return errors.New("monthly schedule requires local_time and day_of_month from 1 to 31")
		}
	default:
		return fmt.Errorf("scheduled task recurrence %q is invalid", task.Recurrence)
	}
	if task.CatchUp != "latest" && task.CatchUp != "skip" {
		return errors.New("scheduled task catch_up must be latest or skip")
	}
	if _, err := time.LoadLocation(task.Timezone); err != nil {
		return fmt.Errorf("scheduled task timezone is invalid: %w", err)
	}
	return nil
}

func (r *Repository) GetScheduledTask(ctx context.Context, id string) (core.ScheduledTask, error) {
	return scanScheduledTask(r.db.QueryRowContext(ctx, scheduledTaskSelect+` WHERE id = ?`, id))
}

func (r *Repository) ListScheduledTasksForChannel(ctx context.Context, channelID string, limit int) ([]core.ScheduledTask, error) {
	if channelID == "" || limit < 1 || limit > 100 {
		return nil, errors.New("scheduled task list requires a channel and limit between 1 and 100")
	}
	rows, err := r.db.QueryContext(ctx, scheduledTaskSelect+`
		WHERE channel_id = ? AND expires_at > ? ORDER BY updated_at DESC LIMIT ?`, channelID, r.nowText(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanScheduledTasks(rows)
}

func (r *Repository) ListDueScheduledTasks(ctx context.Context, now time.Time, limit int) ([]core.ScheduledTask, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("due scheduled task limit must be between 1 and 100")
	}
	rows, err := r.db.QueryContext(ctx, scheduledTaskSelect+`
		WHERE enabled = 1 AND next_run_at IS NOT NULL
		  AND julianday(next_run_at) <= julianday(?) AND julianday(expires_at) > julianday(?)
		ORDER BY next_run_at, id LIMIT ?`, now.UTC().Format(core.TimestampFormat), now.UTC().Format(core.TimestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanScheduledTasks(rows)
}

func (r *Repository) SetScheduledTaskEnabled(ctx context.Context, id string, enabled bool) (core.ScheduledTask, error) {
	value := 0
	if enabled {
		value = 1
	}
	query := `UPDATE scheduled_tasks SET enabled = ?, updated_at = ? WHERE id = ? AND expires_at > ?`
	if enabled {
		query += ` AND next_run_at IS NOT NULL`
	}
	result, err := r.db.ExecContext(ctx, query, value, r.nowText(), id, r.nowText())
	if err := sqlutil.ExpectOne(result, err, "set scheduled task state"); err != nil {
		return core.ScheduledTask{}, err
	}
	return r.GetScheduledTask(ctx, id)
}

func (r *Repository) DeleteScheduledTask(ctx context.Context, id string) (core.ScheduledTask, error) {
	task, err := r.GetScheduledTask(ctx, id)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	result, err := r.db.ExecContext(ctx, `DELETE FROM scheduled_tasks WHERE id = ?`, id)
	if err := sqlutil.ExpectOne(result, err, "delete scheduled task"); err != nil {
		return core.ScheduledTask{}, err
	}
	return task, nil
}

func (r *Repository) DeleteChannelSchedules(ctx context.Context, channelID string) (int64, error) {
	result, err := r.db.ExecContext(ctx, `DELETE FROM scheduled_tasks WHERE channel_id = ?`, channelID)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (r *Repository) PruneOrphanSchedules(ctx context.Context, validRepositories []string) (int64, error) {
	if len(validRepositories) == 0 {
		return 0, errors.New("valid repository list is empty")
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(validRepositories)), ",")
	args := make([]any, len(validRepositories))
	for index, repository := range validRepositories {
		args[index] = repository
	}
	result, err := r.db.ExecContext(ctx, `DELETE FROM scheduled_tasks WHERE repository NOT IN (`+placeholders+`)`, args...)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// ClaimScheduledTaskRun atomically advances the task and records one immutable occurrence.
// It returns false for a duplicate or when another occurrence is still active.
func (r *Repository) ClaimScheduledTaskRun(
	ctx context.Context,
	task core.ScheduledTask,
	scheduledFor time.Time,
	next time.Time,
	sourceInput string,
	advance bool,
	execute bool,
	skipOutcome string,
) (core.ScheduledTaskRun, bool, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return core.ScheduledTaskRun{}, false, err
	}
	defer tx.Rollback()
	var active int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM scheduled_task_runs WHERE task_id = ? AND outcome IN ('queued', 'running')`, task.ID).Scan(&active); err != nil {
		return core.ScheduledTaskRun{}, false, err
	}
	outcome := skipOutcome
	if outcome == "" {
		outcome = "skipped_missed"
	}
	if outcome != "skipped_missed" && outcome != "skipped_unauthorized" {
		return core.ScheduledTaskRun{}, false, errors.New("scheduled task skip outcome is invalid")
	}
	if execute {
		outcome = "queued"
	}
	if execute && active > 0 {
		outcome = "skipped_overlap"
		sourceInput = ""
	}
	now := r.now().UTC()
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO scheduled_task_runs
		  (task_id, scheduled_for, source_input, outcome, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`, task.ID, scheduledFor.UTC().Format(core.TimestampFormat), sourceInput, outcome, now.Format(core.TimestampFormat), now.Format(core.TimestampFormat))
	if err != nil {
		return core.ScheduledTaskRun{}, false, err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows == 0 {
		return core.ScheduledTaskRun{}, false, err
	}
	if advance {
		var nextValue any
		enabled := 1
		if !next.IsZero() && next.Before(task.ExpiresAt) {
			nextValue = next.UTC().Format(core.TimestampFormat)
		} else {
			enabled = 0
		}
		_, err = tx.ExecContext(ctx, `UPDATE scheduled_tasks SET next_run_at = ?, enabled = ?, last_run_at = ?, last_outcome = ?, updated_at = ? WHERE id = ?`, nextValue, enabled, scheduledFor.UTC().Format(core.TimestampFormat), outcome, now.Format(core.TimestampFormat), task.ID)
		if err != nil {
			return core.ScheduledTaskRun{}, false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return core.ScheduledTaskRun{}, false, err
	}
	return core.ScheduledTaskRun{TaskID: task.ID, ScheduledFor: scheduledFor.UTC(), SourceInput: sourceInput, Outcome: outcome, CreatedAt: now, UpdatedAt: now}, outcome == "queued", nil
}

func (r *Repository) LinkScheduledTaskRun(ctx context.Context, taskID string, scheduledFor time.Time, agentRunID string, episodeID string) error {
	result, err := r.db.ExecContext(ctx, `UPDATE scheduled_task_runs SET agent_run_id = ?, episode_id = ?, outcome = 'running', started_at = COALESCE(started_at, ?), updated_at = ? WHERE task_id = ? AND scheduled_for = ? AND outcome = 'queued'`, agentRunID, episodeID, r.nowText(), r.nowText(), taskID, scheduledFor.UTC().Format(core.TimestampFormat))
	return sqlutil.ExpectOne(result, err, "link scheduled task run")
}

func (r *Repository) CompleteScheduledTaskRun(ctx context.Context, taskID string, scheduledFor time.Time, outcome string, detail string) error {
	if outcome != "completed" && outcome != "failed" {
		return errors.New("scheduled task terminal outcome must be completed or failed")
	}
	now := r.nowText()
	result, err := r.db.ExecContext(ctx, `UPDATE scheduled_task_runs SET outcome = ?, last_error = ?, completed_at = ?, updated_at = ? WHERE task_id = ? AND scheduled_for = ? AND outcome IN ('queued', 'running')`, outcome, sqlutil.BoundedError(detail), now, now, taskID, scheduledFor.UTC().Format(core.TimestampFormat))
	if err := sqlutil.ExpectOne(result, err, "complete scheduled task run"); err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `UPDATE scheduled_tasks SET last_outcome = ?, updated_at = ? WHERE id = ?`, outcome, now, taskID)
	return err
}

func (r *Repository) ListActiveScheduledTaskRuns(ctx context.Context, limit int) ([]core.ScheduledTaskRun, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT task_id, scheduled_for, source_input, agent_run_id, episode_id, outcome, last_error, started_at, completed_at, created_at, updated_at FROM scheduled_task_runs WHERE outcome IN ('queued', 'running') ORDER BY created_at LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.ScheduledTaskRun
	for rows.Next() {
		var run core.ScheduledTaskRun
		var scheduled, started, completed, created, updated sql.NullString
		if err := rows.Scan(&run.TaskID, &scheduled, &run.SourceInput, &run.AgentRunID, &run.EpisodeID, &run.Outcome, &run.LastError, &started, &completed, &created, &updated); err != nil {
			return nil, err
		}
		run.ScheduledFor = parseNullTime(scheduled)
		run.StartedAt = parseNullTime(started)
		run.CompletedAt = parseNullTime(completed)
		run.CreatedAt = parseNullTime(created)
		run.UpdatedAt = parseNullTime(updated)
		result = append(result, run)
	}
	return result, rows.Err()
}

func scanScheduledTask(row sqlutil.RowScanner) (core.ScheduledTask, error) {
	var task core.ScheduledTask
	var startAt, nextRun, lastRun, expiresAt, createdAt, updatedAt sql.NullString
	var weekdays []byte
	var enabled int
	err := row.Scan(&task.ID, &task.TeamID, &task.ChannelID, &task.ThreadTS,
		&task.DeliveryChannel, &task.Repository, &task.Title, &task.Prompt,
		&task.Recurrence, &startAt, &task.IntervalSeconds, &weekdays,
		&task.DayOfMonth, &task.LocalTime, &task.Timezone, &task.CatchUp,
		&enabled, &task.ActorID, &task.SourceRef, &nextRun, &lastRun,
		&task.LastOutcome, &expiresAt, &createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ScheduledTask{}, core.ErrNotFound
	}
	if err != nil {
		return core.ScheduledTask{}, err
	}
	if err := json.Unmarshal(weekdays, &task.Weekdays); err != nil {
		return core.ScheduledTask{}, err
	}
	task.Enabled = enabled == 1
	task.StartAt = parseNullTime(startAt)
	task.NextRunAt = parseNullTime(nextRun)
	task.LastRunAt = parseNullTime(lastRun)
	task.ExpiresAt = parseNullTime(expiresAt)
	task.CreatedAt = parseNullTime(createdAt)
	task.UpdatedAt = parseNullTime(updatedAt)
	return task, nil
}

func scanScheduledTasks(rows *sql.Rows) ([]core.ScheduledTask, error) {
	var result []core.ScheduledTask
	for rows.Next() {
		task, err := scanScheduledTask(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, task)
	}
	return result, rows.Err()
}

func firstNonemptySchedule(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

package scheduleproposal

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

const timestampFormat = core.TimestampFormat

const proposalSelect = `
	SELECT id, team_id, channel_id, thread_ts, actor_id, source_ref, task_json,
	  replace_task_id, status, accepted_task_id, expires_at, created_at, updated_at
	FROM schedule_proposals`

const taskSelect = `
	SELECT id, team_id, channel_id, thread_ts, delivery_channel_id, repository, title, prompt,
	  recurrence, start_at, interval_seconds, weekdays_json, day_of_month,
	  local_time, timezone, catch_up, enabled, actor_id, source_ref,
	  next_run_at, last_run_at, last_outcome, expires_at, created_at, updated_at
	FROM scheduled_tasks`

var ErrNotFound = errors.New("schedule proposal not found")

type Repository struct {
	db  *sql.DB
	now func() time.Time
}

func New(db *sql.DB, now func() time.Time) *Repository {
	return &Repository{db: db, now: now}
}

// Create keeps the full normalized task server-side before Slack renders an
// inert confirmation control containing only the proposal ID.
func (s *Repository) Create(ctx context.Context, proposal core.ScheduleProposal) (core.ScheduleProposal, error) {
	if proposal.TeamID == "" || proposal.ChannelID == "" || proposal.ActorID == "" || proposal.SourceRef == "" {
		return core.ScheduleProposal{}, errors.New("schedule proposal identity is incomplete")
	}
	if err := validateTask(proposal.Task); err != nil {
		return core.ScheduleProposal{}, err
	}
	now := s.currentTime()
	if proposal.ExpiresAt.IsZero() {
		proposal.ExpiresAt = now.Add(24 * time.Hour)
	}
	if !proposal.ExpiresAt.After(now) {
		return core.ScheduleProposal{}, errors.New("schedule proposal expiration must be in the future")
	}
	if proposal.ID == "" {
		var err error
		proposal.ID, err = core.NewID("schedule_proposal")
		if err != nil {
			return core.ScheduleProposal{}, err
		}
	}
	proposal.Status = "pending"
	proposal.CreatedAt = now
	proposal.UpdatedAt = now
	taskJSON, err := json.Marshal(proposal.Task)
	if err != nil {
		return core.ScheduleProposal{}, err
	}
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO schedule_proposals (
		  id, team_id, channel_id, thread_ts, actor_id, source_ref, task_json,
		  replace_task_id, status, accepted_task_id, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?, ?, ?)`,
		proposal.ID, proposal.TeamID, proposal.ChannelID, proposal.ThreadTS,
		proposal.ActorID, proposal.SourceRef, taskJSON, proposal.ReplaceTaskID,
		proposal.ExpiresAt.Format(timestampFormat), now.Format(timestampFormat), now.Format(timestampFormat),
	)
	if err != nil {
		return core.ScheduleProposal{}, err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return core.ScheduleProposal{}, err
	}
	if inserted == 0 {
		return scanProposal(s.db.QueryRowContext(ctx, proposalSelect+`
			WHERE team_id = ? AND channel_id = ? AND source_ref = ?`,
			proposal.TeamID, proposal.ChannelID, proposal.SourceRef))
	}
	return proposal, nil
}

func (s *Repository) Get(ctx context.Context, id string) (core.ScheduleProposal, error) {
	return scanProposal(s.db.QueryRowContext(ctx, proposalSelect+` WHERE id = ?`, id))
}

func (s *Repository) GetPendingForConversation(
	ctx context.Context,
	teamID string,
	channelID string,
	threadTS string,
	actorID string,
) (core.ScheduleProposal, error) {
	return scanProposal(s.db.QueryRowContext(ctx, proposalSelect+`
		WHERE team_id = ? AND channel_id = ? AND thread_ts = ? AND actor_id = ?
		  AND status = 'pending' AND julianday(expires_at) > julianday(?)
		ORDER BY created_at DESC LIMIT 1`, teamID, channelID, threadTS, actorID, s.nowText()))
}

// Accept atomically activates a pending proposal. A proposal that targets an
// existing schedule updates that row in place, preserving occurrence history.
func (s *Repository) Accept(
	ctx context.Context,
	id string,
	teamID string,
	channelID string,
	actorID string,
	maxTotal int,
	maxPerChannel int,
) (core.ScheduledTask, error) {
	if maxTotal < 1 || maxPerChannel < 1 || maxPerChannel > maxTotal {
		return core.ScheduledTask{}, errors.New("scheduled task limits are invalid")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	defer tx.Rollback()
	proposal, err := scanProposal(tx.QueryRowContext(ctx, proposalSelect+` WHERE id = ?`, id))
	if err != nil {
		return core.ScheduledTask{}, err
	}
	if proposal.TeamID != teamID || proposal.ChannelID != channelID || proposal.ActorID != actorID {
		return core.ScheduledTask{}, errors.New("schedule proposal belongs to another conversation or operator")
	}
	now := s.currentTime()
	if proposal.Status == "accepted" && proposal.AcceptedTaskID != "" {
		task, getErr := scanTask(tx.QueryRowContext(ctx, taskSelect+` WHERE id = ?`, proposal.AcceptedTaskID))
		if getErr != nil {
			return core.ScheduledTask{}, getErr
		}
		return task, tx.Commit()
	}
	if proposal.Status != "pending" || !proposal.ExpiresAt.After(now) {
		return core.ScheduledTask{}, errors.New("schedule proposal is no longer pending")
	}
	task := proposal.Task
	if err := validateTask(task); err != nil {
		return core.ScheduledTask{}, err
	}
	if !task.ExpiresAt.After(now) || !task.NextRunAt.After(now.Add(-time.Second)) || !task.NextRunAt.Before(task.ExpiresAt) {
		return core.ScheduledTask{}, errors.New("scheduled task must have a future expiry and runnable next occurrence")
	}
	if proposal.ReplaceTaskID != "" {
		existing, getErr := scanTask(tx.QueryRowContext(ctx, taskSelect+` WHERE id = ?`, proposal.ReplaceTaskID))
		if getErr != nil {
			return core.ScheduledTask{}, getErr
		}
		if existing.TeamID != teamID || existing.ChannelID != channelID {
			return core.ScheduledTask{}, errors.New("replacement schedule belongs to another conversation")
		}
		if err := updateTask(ctx, tx, &task, existing, now); err != nil {
			return core.ScheduledTask{}, err
		}
	} else {
		if err := checkCapacity(ctx, tx, channelID, now, maxTotal, maxPerChannel); err != nil {
			return core.ScheduledTask{}, err
		}
		if err := insertTask(ctx, tx, &task, now); err != nil {
			return core.ScheduledTask{}, err
		}
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE schedule_proposals SET status = 'accepted', accepted_task_id = ?, updated_at = ?
		WHERE id = ? AND status = 'pending'`, task.ID, now.Format(timestampFormat), id)
	if err := sqlutil.ExpectOne(result, err, "accept schedule proposal"); err != nil {
		return core.ScheduledTask{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.ScheduledTask{}, err
	}
	return task, nil
}

func updateTask(ctx context.Context, tx *sql.Tx, task *core.ScheduledTask, existing core.ScheduledTask, now time.Time) error {
	weekdays, err := json.Marshal(task.Weekdays)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE scheduled_tasks SET
		  thread_ts = ?, delivery_channel_id = ?, repository = ?, title = ?, prompt = ?,
		  recurrence = ?, start_at = ?, interval_seconds = ?, weekdays_json = ?,
		  day_of_month = ?, local_time = ?, timezone = ?, catch_up = ?, enabled = 1,
		  actor_id = ?, source_ref = ?, next_run_at = ?, expires_at = ?, updated_at = ?
		WHERE id = ?`,
		task.ThreadTS, firstNonempty(task.DeliveryChannel, task.ChannelID), task.Repository,
		task.Title, task.Prompt, task.Recurrence, task.StartAt.UTC().Format(timestampFormat),
		task.IntervalSeconds, weekdays, task.DayOfMonth, task.LocalTime, task.Timezone,
		task.CatchUp, task.ActorID, task.SourceRef, task.NextRunAt.UTC().Format(timestampFormat),
		task.ExpiresAt.UTC().Format(timestampFormat), now.Format(timestampFormat), existing.ID,
	)
	if err != nil {
		return err
	}
	task.ID = existing.ID
	task.Enabled = true
	task.LastRunAt = existing.LastRunAt
	task.LastOutcome = existing.LastOutcome
	task.CreatedAt = existing.CreatedAt
	task.UpdatedAt = now
	return nil
}

func checkCapacity(ctx context.Context, tx *sql.Tx, channelID string, now time.Time, maxTotal, maxPerChannel int) error {
	var total, channel int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM scheduled_tasks WHERE julianday(expires_at) > julianday(?)`, now.Format(timestampFormat)).Scan(&total); err != nil {
		return err
	}
	if total >= maxTotal {
		return fmt.Errorf("scheduled task capacity reached (%d unexpired tasks)", maxTotal)
	}
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM scheduled_tasks WHERE channel_id = ? AND julianday(expires_at) > julianday(?)`, channelID, now.Format(timestampFormat)).Scan(&channel); err != nil {
		return err
	}
	if channel >= maxPerChannel {
		return fmt.Errorf("scheduled task capacity reached for this channel (%d unexpired tasks)", maxPerChannel)
	}
	return nil
}

func insertTask(ctx context.Context, tx *sql.Tx, task *core.ScheduledTask, now time.Time) error {
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
		firstNonempty(task.DeliveryChannel, task.ChannelID), task.Repository,
		task.Title, task.Prompt, task.Recurrence, task.StartAt.UTC().Format(timestampFormat),
		task.IntervalSeconds, weekdays, task.DayOfMonth, task.LocalTime, task.Timezone,
		task.CatchUp, task.ActorID, task.SourceRef, task.NextRunAt.UTC().Format(timestampFormat),
		task.ExpiresAt.UTC().Format(timestampFormat), task.CreatedAt.Format(timestampFormat),
		task.UpdatedAt.Format(timestampFormat),
	)
	return err
}

func validateTask(task core.ScheduledTask) error {
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
		len(task.DeliveryChannel) > 64 || len(task.Repository) > 63 || len(task.Title) > 160 ||
		len(task.Prompt) > 1200 || len(task.ActorID) > 64 || len(task.SourceRef) > 200 {
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

func scanProposal(row sqlutil.RowScanner) (core.ScheduleProposal, error) {
	var proposal core.ScheduleProposal
	var taskJSON []byte
	var expires, created, updated string
	if err := row.Scan(
		&proposal.ID, &proposal.TeamID, &proposal.ChannelID, &proposal.ThreadTS,
		&proposal.ActorID, &proposal.SourceRef, &taskJSON, &proposal.ReplaceTaskID,
		&proposal.Status, &proposal.AcceptedTaskID, &expires, &created, &updated,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.ScheduleProposal{}, ErrNotFound
		}
		return core.ScheduleProposal{}, err
	}
	if err := json.Unmarshal(taskJSON, &proposal.Task); err != nil {
		return core.ScheduleProposal{}, err
	}
	proposal.ExpiresAt = sqlutil.ParseTime(expires)
	proposal.CreatedAt = sqlutil.ParseTime(created)
	proposal.UpdatedAt = sqlutil.ParseTime(updated)
	return proposal, nil
}

func scanTask(row sqlutil.RowScanner) (core.ScheduledTask, error) {
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
		return core.ScheduledTask{}, ErrNotFound
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

func (s *Repository) currentTime() time.Time {
	if s.now != nil {
		return s.now().UTC()
	}
	return time.Now().UTC()
}

func (s *Repository) nowText() string {
	return s.currentTime().Format(timestampFormat)
}

func parseNullTime(value sql.NullString) time.Time {
	if !value.Valid || value.String == "" {
		return time.Time{}
	}
	return sqlutil.ParseTime(value.String)
}

func firstNonempty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

// ConflictFor builds the error a lost write returns.
//
// Exported so a test can assert the sentinel is matchable without staging a
// real race between two concurrent accepts. The shape of that error is the
// contract — a caller has to tell "someone else got there first" from a real
// failure — and it is exactly what drifted when this package grew its own copy
// of expectOne returning a formatted string.
func ConflictFor(action string) error {
	return fmt.Errorf("%s: %w", action, core.ErrConflict)
}

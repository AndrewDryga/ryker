package incidentstore

import (
	"context"
	"database/sql"
	"encoding/json"
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

func (r *Repository) BindTaskPullRequest(
	ctx context.Context,
	incidentID string,
	target core.PullRequestTarget,
) error {
	if !target.Valid() {
		return fmt.Errorf("bind engineering task pull request: invalid target")
	}
	encoded, err := json.Marshal(target)
	if err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET task_pull_request_json = ?, updated_at = ?,
		  card_version = card_version + 1
		WHERE id = ? AND work_kind = 'engineering_task' AND task_pull_request_json = ''`,
		encoded, r.clock().UTC().Format(core.TimestampFormat), incidentID,
	)
	if err != nil {
		return err
	}
	if rows, err := result.RowsAffected(); err != nil || rows == 1 {
		return err
	}
	var current string
	if err := r.db.QueryRowContext(
		ctx, `SELECT task_pull_request_json FROM incidents WHERE id = ?`, incidentID,
	).Scan(&current); err != nil {
		if err == sql.ErrNoRows {
			return core.ErrNotFound
		}
		return err
	}
	if current == string(encoded) {
		return nil
	}
	return fmt.Errorf("engineering task pull request binding: %w", core.ErrConflict)
}

// ClearChangesMessage forgets the open diff, so View diff offers to open one
// again rather than to hide a message that is no longer there.
//
// The card version moves with it because the button's label is derived from
// this column: leaving the version alone would keep "Hide diff" on a card whose
// diff has been deleted, and the next press would try to delete it twice.
//
// Idempotent by design. It is called from the two paths that can both be true
// at once — the operator pressing Close diff, and a delete that failed because
// Slack no longer had the message — and neither knows about the other.
func (r *Repository) ClearChangesMessage(ctx context.Context, incidentID string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET changes_message_ts = '', updated_at = ?,
		  card_version = card_version + 1
		WHERE id = ? AND changes_message_ts != ''`,
		r.clock().UTC().Format(core.TimestampFormat), incidentID,
	)
	return err
}

// SetChangesStat records what the last whole patch amounted to.
//
// Written only where the full patch was in hand, and written as "" when it was
// not, which is the same statement: this is what we know, and we do not guess.
// No card version bump — the stat rides a card that some other change is
// already re-rendering, and a counter is not worth a rewrite of its own.
func (r *Repository) SetChangesStat(ctx context.Context, incidentID, stat string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE incidents SET changes_stat = ?, updated_at = ?
		WHERE id = ? AND changes_stat != ?`,
		stat, r.clock().UTC().Format(core.TimestampFormat), incidentID, stat,
	)
	return err
}

const Columns = `
	id, route, repository, correlation_key, source_incident_id, title, severity,
	status, workflow, signal_count, firing_count, channel_id, channel_name, root_ts,
	coop_session_id, coop_fork_name, coop_revision, coop_event_sequence, active_turn_id,
	initial_turn_queued, card_version, card_rendered_version, last_error, latest_update,
	latest_update_run_id, latest_update_run_key,
	changes_message_ts, changes_stat,
	task_pull_request_json,
	created_at, updated_at, last_firing_at, resolve_due_at, resolved_at, closed_at,
	channel_state, channel_state_changed_at, channel_checked_at,
	work_kind, work_scope, origin_channel_id, origin_thread_ts`

func Scan(row interface{ Scan(...any) error }) (core.Incident, error) {
	var incident core.Incident
	var initial int
	var created, updated, taskPullRequestJSON string
	var firing, due, resolved, closed, channelChanged, channelChecked sql.NullString
	err := row.Scan(
		&incident.ID, &incident.Route, &incident.Repository, &incident.CorrelationKey,
		&incident.SourceIncidentID, &incident.Title, &incident.Severity, &incident.Status,
		&incident.Workflow, &incident.SignalCount, &incident.FiringCount, &incident.ChannelID,
		&incident.ChannelName, &incident.RootTS, &incident.CoopSessionID, &incident.CoopForkName,
		&incident.CoopRevision, &incident.CoopEventSequence,
		&incident.ActiveTurnID, &initial, &incident.CardVersion,
		&incident.CardRenderedVersion, &incident.LastError, &incident.LatestUpdate,
		&incident.LatestUpdateRunID, &incident.LatestUpdateRunKey,
		&incident.ChangesMessageTS, &incident.ChangesStat,
		&taskPullRequestJSON, &created, &updated, &firing, &due,
		&resolved, &closed, &incident.ChannelState, &channelChanged, &channelChecked,
		&incident.WorkKind, &incident.WorkScope, &incident.OriginChannelID,
		&incident.OriginThreadTS,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return core.Incident{}, core.ErrNotFound
		}
		return core.Incident{}, err
	}
	if taskPullRequestJSON != "" {
		var target core.PullRequestTarget
		if err := json.Unmarshal([]byte(taskPullRequestJSON), &target); err != nil || !target.Valid() {
			return core.Incident{}, fmt.Errorf("decode engineering task pull request binding")
		}
		incident.TaskPullRequest = &target
	}
	incident.InitialTurnQueued = initial != 0
	incident.CreatedAt = sqlutil.ParseTime(created)
	incident.UpdatedAt = sqlutil.ParseTime(updated)
	incident.LastFiringAt = sqlutil.ScanTime(firing)
	incident.ResolveDueAt = sqlutil.ScanTime(due)
	incident.ResolvedAt = sqlutil.ScanTime(resolved)
	incident.ClosedAt = sqlutil.ScanTime(closed)
	incident.ChannelStateChangedAt = sqlutil.ScanTime(channelChanged)
	incident.ChannelCheckedAt = sqlutil.ScanTime(channelChecked)
	return incident, nil
}

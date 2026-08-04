package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const agentRunColumns = `
	id, episode_id, attempt_id, attempt_number,
	mode, incident_id, channel_id, thread_ts, conversation_key,
	source_kind, source_id, user_id, repository, prompt, idempotency_key,
	session_id, session_generation, expected_revision, coop_turn_id,
	coop_event_sequence, context_json, result_json, terminal_state, state,
	failure_count, next_attempt_at, last_error, created_at, updated_at,
	started_at, completed_at`

func (s *Store) QueueAgentRun(
	ctx context.Context,
	run core.AgentRun,
) (core.AgentRun, bool, error) {
	if run.Mode == "" || run.SourceKind == "" || run.SourceID == "" {
		return core.AgentRun{}, false, errors.New("agent run identity is incomplete")
	}
	if run.ConversationKey == "" {
		if run.IncidentID == "" {
			return core.AgentRun{}, false, errors.New("agent run conversation is required")
		}
		run.ConversationKey = "incident:" + run.IncidentID
	}
	if run.ID == "" {
		var err error
		run.ID, err = core.NewID("run")
		if err != nil {
			return core.AgentRun{}, false, err
		}
	}
	if run.AttemptID == "" {
		run.AttemptID = "attempt_" + run.ID
	}
	if run.IdempotencyKey == "" {
		run.IdempotencyKey = "responder:run:" + run.ID
	}
	if run.State == "" {
		run.State = core.AgentRunPending
	}
	if run.State != core.AgentRunPending && run.State != core.AgentRunRunning {
		return core.AgentRun{}, false, fmt.Errorf("cannot queue agent run in state %q", run.State)
	}
	if len(run.Context) == 0 {
		run.Context = []byte("{}")
	}
	if run.Result == nil {
		run.Result = []byte{}
	}
	if len(run.Context) > 256<<10 {
		return core.AgentRun{}, false, errors.New("agent run context exceeds 256 KiB")
	}
	now := time.Now().UTC()
	if run.CreatedAt.IsZero() {
		run.CreatedAt = now
	}
	if run.NextAttemptAt.IsZero() {
		run.NextAttemptAt = now
	}
	episode, err := normalizeWorkEpisode(run)
	if err != nil {
		return core.AgentRun{}, false, fmt.Errorf("validate work episode: %w", err)
	}
	run.EpisodeID = episode.ID
	var incidentID any
	if run.IncidentID != "" {
		incidentID = run.IncidentID
	}
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO agent_runs (
		  id, episode_id, attempt_id, attempt_number,
		  mode, incident_id, channel_id, thread_ts, conversation_key,
		  source_kind, source_id, user_id, repository, prompt, idempotency_key,
		  session_id, session_generation, expected_revision, coop_turn_id,
		  coop_event_sequence, context_json, result_json, terminal_state, state,
		  failure_count, next_attempt_at, last_error, created_at, updated_at,
		  started_at, completed_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
		        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		run.ID, run.EpisodeID, run.AttemptID, run.AttemptNumber,
		run.Mode, incidentID, run.ChannelID, run.ThreadTS, run.ConversationKey,
		run.SourceKind, run.SourceID, run.UserID, run.Repository, run.Prompt,
		run.IdempotencyKey, run.SessionID, run.SessionGeneration, run.ExpectedRevision,
		run.CoopTurnID, run.CoopEventSequence, run.Context, run.Result,
		run.TerminalState, run.State, run.Failures,
		run.NextAttemptAt.UTC().Format(timestampFormat), boundedError(run.LastError),
		run.CreatedAt.UTC().Format(timestampFormat), nowText(), nullableTime(run.StartedAt),
		nullableTime(run.CompletedAt),
	)
	if err != nil {
		return core.AgentRun{}, false, fmt.Errorf("queue agent run: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.AgentRun{}, false, err
	}
	cleanupInsertedRun := func() {
		if rows == 1 {
			_, _ = s.db.ExecContext(ctx, `DELETE FROM agent_runs WHERE id = ?`, run.ID)
		}
	}
	stored, err := s.GetAgentRunBySource(ctx, run.SourceKind, run.SourceID)
	if err != nil {
		cleanupInsertedRun()
		return core.AgentRun{}, false, err
	}
	stored.CommitmentTitle = run.CommitmentTitle
	if err := s.ensureCommitment(ctx, stored); err != nil {
		cleanupInsertedRun()
		return core.AgentRun{}, false, fmt.Errorf("ensure agent commitment: %w", err)
	}
	stored.CommitmentTitle = run.CommitmentTitle
	stored.Episode = run.Episode
	if err := s.ensureWorkEpisode(ctx, stored); err != nil {
		cleanupInsertedRun()
		return core.AgentRun{}, false, fmt.Errorf("ensure work episode: %w", err)
	}
	stored, err = s.GetAgentRunBySource(ctx, run.SourceKind, run.SourceID)
	if err != nil {
		cleanupInsertedRun()
		return core.AgentRun{}, false, err
	}
	return stored, rows == 1, nil
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value.UTC().Format(timestampFormat)
}

func (s *Store) GetAgentRun(ctx context.Context, id string) (core.AgentRun, error) {
	return scanAgentRun(s.db.QueryRowContext(
		ctx, `SELECT `+agentRunColumns+` FROM agent_runs WHERE id = ?`, id,
	))
}

func (s *Store) ListAgentRunsForIncident(
	ctx context.Context,
	incidentID string,
) ([]core.AgentRun, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+agentRunColumns+`
		FROM agent_runs WHERE incident_id = ?
		ORDER BY created_at, id`, incidentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]core.AgentRun, 0)
	for rows.Next() {
		item, err := scanAgentRun(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (s *Store) GetAgentRunBySource(
	ctx context.Context,
	kind string,
	sourceID string,
) (core.AgentRun, error) {
	return scanAgentRun(s.db.QueryRowContext(
		ctx,
		`SELECT `+agentRunColumns+`
		 FROM agent_runs WHERE source_kind = ? AND source_id = ?`,
		kind,
		sourceID,
	))
}

func (s *Store) GetAgentRunByCoopTurn(
	ctx context.Context,
	coopTurnID string,
) (core.AgentRun, error) {
	if coopTurnID == "" {
		return core.AgentRun{}, errors.New("Coop turn ID is required")
	}
	return scanAgentRun(s.db.QueryRowContext(
		ctx,
		`SELECT `+agentRunColumns+` FROM agent_runs WHERE coop_turn_id = ?`,
		coopTurnID,
	))
}

func scanAgentRun(row interface{ Scan(...any) error }) (core.AgentRun, error) {
	var run core.AgentRun
	var incident sql.NullString
	var next, created, updated string
	var started, completed sql.NullString
	err := row.Scan(
		&run.ID, &run.EpisodeID, &run.AttemptID, &run.AttemptNumber,
		&run.Mode, &incident, &run.ChannelID, &run.ThreadTS,
		&run.ConversationKey, &run.SourceKind, &run.SourceID, &run.UserID,
		&run.Repository, &run.Prompt, &run.IdempotencyKey, &run.SessionID,
		&run.SessionGeneration, &run.ExpectedRevision, &run.CoopTurnID,
		&run.CoopEventSequence, &run.Context, &run.Result, &run.TerminalState,
		&run.State, &run.Failures, &next, &run.LastError, &created, &updated,
		&started, &completed,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.AgentRun{}, ErrNotFound
	}
	if err != nil {
		return core.AgentRun{}, err
	}
	run.IncidentID = incident.String
	run.NextAttemptAt = parseTime(next)
	run.CreatedAt = parseTime(created)
	run.UpdatedAt = parseTime(updated)
	run.StartedAt = scanTime(started)
	run.CompletedAt = scanTime(completed)
	return run, nil
}

func (s *Store) LeaseAgentRun(ctx context.Context) (core.AgentRun, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.AgentRun{}, err
	}
	defer tx.Rollback()
	run, err := scanAgentRun(tx.QueryRowContext(ctx, `
		SELECT `+agentRunColumns+`
		FROM agent_runs AS candidate
		WHERE candidate.state = 'pending'
		  AND julianday(candidate.next_attempt_at) <= julianday(?)
		  AND (
		    candidate.incident_id IS NULL OR EXISTS (
		      SELECT 1 FROM incidents AS incident
		      WHERE incident.id = candidate.incident_id
		        AND incident.coop_session_id != ''
		        AND incident.active_turn_id = ''
		        AND incident.workflow NOT IN ('closed', 'blocked')
		    )
		  )
			  AND NOT EXISTS (
			    SELECT 1 FROM agent_runs AS active
			    WHERE active.conversation_key = candidate.conversation_key
			      AND active.id != candidate.id
		      AND active.state IN ('preparing', 'running', 'applying', 'finalizing')
		  )
		ORDER BY
		  CASE WHEN candidate.mode = 'triage' THEN 1 ELSE 0 END,
		  candidate.created_at,
		  candidate.id
		LIMIT 1`, nowText()))
	if err != nil {
		return core.AgentRun{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs SET state = 'preparing', updated_at = ?
		WHERE id = ? AND state = 'pending'`, nowText(), run.ID)
	if err := expectOne(result, err, "lease agent run"); err != nil {
		return core.AgentRun{}, err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, run.ID, core.AttemptLeased, "", true,
	); err != nil {
		return core.AgentRun{}, err
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, run.ID, core.EpisodePlanning, "planning", "Planning the work",
		"Establish the evidence plan", time.Time{},
		fmt.Sprintf("agent-run:%s:leased:%d", run.ID, run.Failures+1),
	); err != nil {
		return core.AgentRun{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.AgentRun{}, err
	}
	run.State = core.AgentRunPreparing
	return run, nil
}

func (s *Store) LeaseAgentRunFinalization(ctx context.Context) (core.AgentRun, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.AgentRun{}, err
	}
	defer tx.Rollback()
	run, err := scanAgentRun(tx.QueryRowContext(ctx, `
		SELECT `+agentRunColumns+`
		FROM agent_runs
		WHERE state = 'applying'
		  AND julianday(next_attempt_at) <= julianday(?)
		ORDER BY updated_at, id
		LIMIT 1`, nowText()))
	if err != nil {
		return core.AgentRun{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs SET state = 'finalizing', updated_at = ?
		WHERE id = ? AND state = 'applying'`, nowText(), run.ID)
	if err := expectOne(result, err, "lease agent run finalization"); err != nil {
		return core.AgentRun{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.AgentRun{}, err
	}
	run.State = core.AgentRunFinalizing
	return run, nil
}

func (s *Store) BeginAgentRunFinalization(
	ctx context.Context,
	id string,
) (core.AgentRun, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.AgentRun{}, err
	}
	defer tx.Rollback()
	run, err := scanAgentRun(tx.QueryRowContext(
		ctx, `SELECT `+agentRunColumns+` FROM agent_runs WHERE id = ?`, id,
	))
	if err != nil {
		return core.AgentRun{}, err
	}
	if run.State == core.AgentRunFinalizing {
		return run, tx.Commit()
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs SET state = 'finalizing', updated_at = ?
		WHERE id = ? AND state = 'applying'`, nowText(), id)
	if err := expectOne(result, err, "begin agent run finalization"); err != nil {
		return core.AgentRun{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.AgentRun{}, err
	}
	run.State = core.AgentRunFinalizing
	return run, nil
}

func (s *Store) BindAgentRunSession(
	ctx context.Context,
	id string,
	sessionID string,
	generation int,
	repository string,
	eventSequence int64,
	contextJSON []byte,
) error {
	if sessionID == "" || len(contextJSON) == 0 || len(contextJSON) > 256<<10 {
		return errors.New("agent run session binding is incomplete")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET session_id = ?, session_generation = ?, repository = ?,
		    coop_event_sequence = ?, context_json = ?, updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		sessionID, generation, repository, eventSequence, contextJSON, nowText(), id)
	return expectOne(result, err, "bind agent run session")
}

func (s *Store) SetAgentRunContext(
	ctx context.Context,
	id string,
	contextJSON []byte,
) error {
	if len(contextJSON) == 0 || len(contextJSON) > 256<<10 {
		return errors.New("agent run context must be between 1 byte and 256 KiB")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs SET context_json = ?, updated_at = ?
		WHERE id = ? AND state NOT IN ('superseded')`,
		contextJSON, nowText(), id)
	return expectOne(result, err, "set agent run context")
}

func (s *Store) SetAgentRunPreparedContext(
	ctx context.Context,
	id string,
	repository string,
	contextJSON []byte,
) error {
	if len(contextJSON) == 0 || len(contextJSON) > 256<<10 {
		return errors.New("agent run context must be between 1 byte and 256 KiB")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET repository = ?, context_json = ?, updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		repository, contextJSON, nowText(), id)
	return expectOne(result, err, "set prepared agent run context")
}

func (s *Store) FreezeAgentRunRevision(
	ctx context.Context,
	id string,
	revision int64,
) (int64, error) {
	if revision <= 0 {
		return 0, errors.New("positive Coop revision is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var existing int64
	if err := tx.QueryRowContext(
		ctx, `SELECT expected_revision FROM agent_runs WHERE id = ?`, id,
	).Scan(&existing); err != nil {
		return 0, err
	}
	if existing == 0 {
		result, err := tx.ExecContext(ctx, `
			UPDATE agent_runs SET expected_revision = ?, updated_at = ?
			WHERE id = ? AND state = 'preparing' AND expected_revision = 0`,
			revision, nowText(), id)
		if err := expectOne(result, err, "freeze agent run revision"); err != nil {
			return 0, err
		}
		existing = revision
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return existing, nil
}

func (s *Store) MarkAgentRunSubmitted(
	ctx context.Context,
	id string,
	coopTurnID string,
	revision int64,
	eventSequence int64,
) error {
	if coopTurnID == "" {
		return errors.New("submitted agent run requires a Coop turn ID")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var incidentID sql.NullString
	var channelID, sessionID string
	if err := tx.QueryRowContext(
		ctx, `SELECT incident_id, channel_id, session_id FROM agent_runs WHERE id = ?`, id,
	).Scan(&incidentID, &channelID, &sessionID); err != nil {
		return err
	}
	if sessionID == "" {
		return errors.New("submitted agent run requires a bound Coop session")
	}
	now := nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'running', coop_turn_id = ?, coop_event_sequence = ?,
		    last_error = '', started_at = COALESCE(started_at, ?), updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		coopTurnID, eventSequence, now, now, id)
	if err := expectOne(result, err, "mark agent run submitted"); err != nil {
		return err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptRunning, "", false,
	); err != nil {
		return err
	}
	if incidentID.Valid {
		if _, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET active_turn_id = ?, coop_revision = ?, workflow = 'investigating',
			    updated_at = ?, card_version = card_version + 1, last_error = ''
			WHERE id = ?`,
			coopTurnID, revision, now, incidentID.String); err != nil {
			return err
		}
	} else if channelID != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE channel_memories
			SET session_revision = ?, coop_event_sequence = ?, updated_at = ?
			WHERE channel_id = ?`,
			revision, eventSequence, now, channelID); err != nil {
			return err
		}
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeWorking, "investigating", "Investigating",
		"Complete the evidence plan", time.Time{}, "agent-turn:"+coopTurnID+":started",
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) MarkTriageAgentRunSubmitted(
	ctx context.Context,
	id string,
	coopTurnID string,
	revision int64,
	eventSequence int64,
	lane string,
) error {
	if lane != "conversation" {
		return s.MarkAgentRunSubmitted(
			ctx, id, coopTurnID, revision, eventSequence,
		)
	}
	if coopTurnID == "" {
		return errors.New("submitted agent run requires a Coop turn ID")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var channelID, sessionID string
	if err := tx.QueryRowContext(
		ctx,
		`SELECT channel_id, session_id FROM agent_runs WHERE id = ?`,
		id,
	).Scan(&channelID, &sessionID); err != nil {
		return err
	}
	now := nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'running', coop_turn_id = ?, coop_event_sequence = ?,
		    last_error = '', started_at = COALESCE(started_at, ?), updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		coopTurnID, eventSequence, now, now, id,
	)
	if err := expectOne(result, err, "mark conversation run submitted"); err != nil {
		return err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptRunning, "", false,
	); err != nil {
		return err
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE conversation_sessions
		SET session_revision = ?, coop_event_sequence = ?, updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		revision, eventSequence, now, channelID, sessionID,
	)
	if err := expectOne(result, err, "advance submitted conversation session"); err != nil {
		return err
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeWorking, "investigating", "Investigating",
		"Complete the requested work", time.Time{}, "agent-turn:"+coopTurnID+":started",
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) DeferAgentRun(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		boundedError(detail), next.UTC().Format(timestampFormat), nowText(), id)
	if err := expectOne(result, err, "defer agent run"); err != nil {
		return err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "queued", boundedError(detail),
		"Resume when the dependency is ready", time.Time{},
		"agent-run:"+id+":deferred:"+next.UTC().Format(time.RFC3339Nano),
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RetryAgentRun(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	terminal bool,
) error {
	state := core.AgentRunPending
	completedAt := any(nil)
	if terminal {
		state = core.AgentRunFailed
		completedAt = nowText()
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = ?, failure_count = failure_count + 1, last_error = ?,
		    next_attempt_at = ?, completed_at = ?, updated_at = ?
		WHERE id = ? AND state IN ('preparing', 'finalizing')`,
		state, boundedError(detail), next.UTC().Format(timestampFormat),
		completedAt, nowText(), id)
	if err := expectOne(result, err, "retry agent run"); err != nil {
		return err
	}
	attemptState := core.AttemptPending
	if terminal {
		attemptState = core.AttemptFailed
	}
	if err := setEpisodeAttemptStateTx(ctx, tx, id, attemptState, detail, false); err != nil {
		return err
	}
	episodeState := core.EpisodeAcknowledged
	phase := "retrying"
	nextAction := "Retry the work from preserved context"
	if terminal {
		episodeState = core.EpisodeFailed
		phase = "failed"
		nextAction = "Review the blocker or retry"
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, episodeState, phase, boundedError(detail), nextAction,
		time.Time{}, fmt.Sprintf(
			"agent-run:%s:retry:%s:%t", id, next.UTC().Format(time.RFC3339Nano), terminal,
		),
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ListRunningAgentRuns(
	ctx context.Context,
	limit int,
) ([]core.AgentRun, error) {
	if limit < 1 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+agentRunColumns+`
		FROM agent_runs
		WHERE state = 'running'
		ORDER BY started_at, id
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.AgentRun, 0)
	for rows.Next() {
		run, err := scanAgentRun(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, run)
	}
	return result, rows.Err()
}

func (s *Store) AdvanceAgentRunEvents(
	ctx context.Context,
	id string,
	sequence int64,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET coop_event_sequence = MAX(coop_event_sequence, ?), updated_at = ?
		WHERE id = ? AND state = 'running'`,
		sequence, nowText(), id)
	if err := expectOne(result, err, "advance agent run events"); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RepairAgentRunEventCursor(
	ctx context.Context,
	id string,
	sessionID string,
	conversationLane bool,
) error {
	if id == "" || sessionID == "" {
		return errors.New("agent run event cursor repair identity is incomplete")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var incidentID sql.NullString
	var channelID string
	if err := tx.QueryRowContext(ctx, `
		SELECT incident_id, channel_id
		FROM agent_runs
		WHERE id = ? AND session_id = ? AND state = 'running'`,
		id, sessionID,
	).Scan(&incidentID, &channelID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("repair agent run event cursor: %w", ErrConflict)
		}
		return err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET coop_event_sequence = 0, updated_at = ?
		WHERE id = ? AND session_id = ? AND state = 'running'`,
		nowText(), id, sessionID,
	)
	if err := expectOne(result, err, "repair agent run event cursor"); err != nil {
		return err
	}
	if incidentID.Valid {
		_, err = tx.ExecContext(ctx, `
			UPDATE incidents SET coop_event_sequence = 0, updated_at = ?
			WHERE id = ? AND coop_session_id = ?`,
			nowText(), incidentID.String, sessionID,
		)
	} else {
		// A conversation lane can share the same Coop session with the channel
		// memory projection. A rotated session invalidates both cursors, even
		// when only one projection is active for the current run.
		_, err = tx.ExecContext(ctx, `
			UPDATE channel_memories SET coop_event_sequence = 0, updated_at = ?
			WHERE channel_id = ? AND session_id = ?`,
			nowText(), channelID, sessionID,
		)
		if err == nil && conversationLane {
			_, err = tx.ExecContext(ctx, `
				UPDATE conversation_sessions SET coop_event_sequence = 0, updated_at = ?
				WHERE channel_id = ? AND session_id = ?`,
				nowText(), channelID, sessionID,
			)
		}
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RequeueAgentRun(
	ctx context.Context,
	id string,
	detail string,
	eventSequence int64,
	next time.Time,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var incidentID sql.NullString
	var coopTurnID string
	var failures int
	if err := tx.QueryRowContext(ctx, `
		SELECT incident_id, coop_turn_id, failure_count
		FROM agent_runs
		WHERE id = ? AND state = 'running'`, id,
	).Scan(&incidentID, &coopTurnID, &failures); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("requeue agent run: %w", ErrConflict)
		}
		return err
	}
	attempt := failures + 1
	now := nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', failure_count = ?, idempotency_key = ?,
		    expected_revision = 0, coop_turn_id = '',
		    coop_event_sequence = MAX(coop_event_sequence, ?),
		    result_json = X'', terminal_state = '', last_error = ?,
		    next_attempt_at = ?, completed_at = NULL, updated_at = ?
		WHERE id = ? AND state = 'running'`,
		attempt,
		fmt.Sprintf("responder:run:%s:recovery:%d", id, attempt),
		eventSequence,
		boundedError(detail),
		next.UTC().Format(timestampFormat),
		now,
		id,
	)
	if err := expectOne(result, err, "requeue agent run"); err != nil {
		return err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if incidentID.Valid {
		result, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET active_turn_id = '', workflow = 'parked', last_error = '',
			    coop_event_sequence = MAX(coop_event_sequence, ?),
			    updated_at = ?, card_version = card_version + 1
			WHERE id = ? AND active_turn_id = ?`,
			eventSequence, now, incidentID.String, coopTurnID,
		)
		if err := expectOne(
			result, err, "release interrupted incident turn",
		); err != nil {
			return err
		}
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "continuing", boundedError(detail),
		"Continue unfinished work", time.Time{},
		fmt.Sprintf("agent-run:%s:recovery:%d", id, attempt),
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) EscalateAgentRun(
	ctx context.Context,
	id string,
	detail string,
	contextJSON []byte,
	next time.Time,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending',
		    idempotency_key = ?,
		    session_id = '',
		    session_generation = 0,
		    expected_revision = 0,
		    coop_turn_id = '',
		    coop_event_sequence = 0,
		    context_json = ?,
		    result_json = X'',
		    terminal_state = '',
		    last_error = ?,
		    next_attempt_at = ?,
		    completed_at = NULL,
		    updated_at = ?
		WHERE id = ? AND state = 'running'`,
		"responder:run:"+id+":investigation",
		contextJSON,
		boundedError(detail),
		next.UTC().Format(timestampFormat),
		nowText(),
		id,
	)
	if err := expectOne(result, err, "escalate agent run"); err != nil {
		return err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodePlanning, "expanding_scope", boundedError(detail),
		"Continue in the full investigation lane", time.Time{},
		"agent-run:"+id+":escalated",
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) StageAgentRunResult(
	ctx context.Context,
	id string,
	terminalState string,
	resultJSON []byte,
	detail string,
	eventSequence int64,
) error {
	if terminalState != "completed" && terminalState != "failed" &&
		terminalState != "cancelled" {
		return fmt.Errorf("unsupported agent run terminal state %q", terminalState)
	}
	if len(resultJSON) > 1<<20 {
		return errors.New("agent run result exceeds 1 MiB")
	}
	if resultJSON == nil {
		resultJSON = []byte{}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	update, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'applying', terminal_state = ?, result_json = ?,
		    coop_event_sequence = MAX(coop_event_sequence, ?), last_error = ?, updated_at = ?
		WHERE id = ? AND state = 'running'`,
		terminalState, resultJSON, eventSequence, boundedError(detail), nowText(), id)
	if err := expectOne(update, err, "stage agent run result"); err != nil {
		current, getErr := scanAgentRun(tx.QueryRowContext(
			ctx, `SELECT `+agentRunColumns+` FROM agent_runs WHERE id = ?`, id,
		))
		if getErr == nil && (current.State == core.AgentRunApplying ||
			current.State == core.AgentRunFinalizing ||
			current.State == core.AgentRunCompleted ||
			current.State == core.AgentRunFailed ||
			current.State == core.AgentRunCancelled) {
			return nil
		}
		return err
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeVerifying, "finalizing", "Preparing the result",
		"Validate and deliver the result", time.Time{},
		fmt.Sprintf("agent-turn:%s:terminal:%s:%d", id, terminalState, eventSequence),
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) FinishAgentRun(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var terminal, coopTurnID string
	var incidentID sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT terminal_state, coop_turn_id, incident_id
		FROM agent_runs WHERE id = ? AND state = 'finalizing'`, id).Scan(
		&terminal, &coopTurnID, &incidentID,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("finish agent run: %w", ErrConflict)
		}
		return err
	}
	finalState := core.AgentRunState(terminal)
	if finalState != core.AgentRunCompleted &&
		finalState != core.AgentRunFailed &&
		finalState != core.AgentRunCancelled {
		return fmt.Errorf("agent run has invalid terminal state %q", terminal)
	}
	now := nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = ?, completed_at = ?, updated_at = ?
		WHERE id = ? AND state = 'finalizing'`,
		finalState, now, now, id)
	if err := expectOne(result, err, "finish agent run"); err != nil {
		return err
	}
	attemptState := core.AttemptSucceeded
	if finalState == core.AgentRunFailed {
		attemptState = core.AttemptFailed
	} else if finalState == core.AgentRunCancelled {
		attemptState = core.AttemptCancelled
	}
	if err := setEpisodeAttemptStateTx(ctx, tx, id, attemptState, "", false); err != nil {
		return err
	}
	if incidentID.Valid {
		lastError := ""
		if finalState == core.AgentRunFailed {
			if err := tx.QueryRowContext(
				ctx, `SELECT last_error FROM agent_runs WHERE id = ?`, id,
			).Scan(&lastError); err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET active_turn_id = '', workflow = 'parked', last_error = ?,
			    updated_at = ?, card_version = card_version + 1
			WHERE id = ? AND active_turn_id = ?`,
			lastError, now, incidentID.String, coopTurnID); err != nil {
			return err
		}
	}
	episodeState := core.EpisodeCompleted
	episodeStatus := "Completed"
	episodeNextAction := ""
	if finalState == core.AgentRunFailed {
		episodeState = core.EpisodeFailed
		episodeStatus = "Needs operator attention"
		episodeNextAction = "Review the blocker or retry"
	} else if finalState == core.AgentRunCancelled {
		episodeState = core.EpisodeCancelled
		episodeStatus = "Cancelled"
	}
	var currentEpisodeState core.WorkEpisodeState
	if err := tx.QueryRowContext(
		ctx, `SELECT lifecycle_state FROM work_episodes WHERE id = (
		  SELECT episode_id FROM episode_attempts WHERE agent_run_id = ?
		)`, id,
	).Scan(&currentEpisodeState); err != nil {
		return err
	}
	if currentEpisodeState != core.EpisodeBlocked &&
		currentEpisodeState != core.EpisodeWaitingApproval &&
		currentEpisodeState != core.EpisodeCompleted &&
		currentEpisodeState != core.EpisodeFailed &&
		currentEpisodeState != core.EpisodeCancelled &&
		currentEpisodeState != core.EpisodeSuperseded {
		if err := setWorkEpisodePhaseTx(
			ctx, tx, id, episodeState, "finished", episodeStatus, episodeNextAction,
			time.Time{}, "agent-run:"+id+":finished:"+string(finalState),
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RetryAgentRunFinalization(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'applying', failure_count = failure_count + 1,
		    next_attempt_at = ?, last_error = ?, updated_at = ?
		WHERE id = ? AND state = 'finalizing'`,
		next.UTC().Format(timestampFormat), boundedError(detail), nowText(), id)
	return expectOne(result, err, "retry agent run finalization")
}

func (s *Store) FailAgentRunFinalization(
	ctx context.Context,
	id string,
	detail string,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET terminal_state = 'failed', last_error = ?, updated_at = ?
		WHERE id = ? AND state = 'finalizing'`,
		boundedError(detail), nowText(), id)
	return expectOne(result, err, "fail agent run finalization")
}

func (s *Store) SupersedeAgentRun(ctx context.Context, id, detail string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'superseded', last_error = ?, completed_at = ?, updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		boundedError(detail), nowText(), nowText(), id)
	if err := expectOne(result, err, "supersede agent run"); err != nil {
		return err
	}
	if err := setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptCancelled, detail, false,
	); err != nil {
		return err
	}
	if err := setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeSuperseded, "finished", boundedError(detail), "",
		time.Time{}, "agent-run:"+id+":superseded",
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) HasNewerPendingAgentRun(
	ctx context.Context,
	run core.AgentRun,
) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM agent_runs
		WHERE conversation_key = ? AND id != ?
		  AND state IN ('pending', 'preparing')
		  AND (
		    julianday(created_at) > julianday(?) OR
		    (julianday(created_at) = julianday(?) AND id > ?)
		  )`,
		run.ConversationKey, run.ID,
		run.CreatedAt.UTC().Format(timestampFormat),
		run.CreatedAt.UTC().Format(timestampFormat),
		run.ID,
	).Scan(&count)
	return count > 0, err
}

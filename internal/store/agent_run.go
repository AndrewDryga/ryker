package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/lifecyclecheck"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
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
	return s.queueAgentRun(ctx, run, "")
}

// queueAgentRun admits a transport run and its episode attempt in one write
// transaction. resumeEpisodeID additionally serializes admission against the
// episode lifecycle and projects the retrying state before the transaction is
// visible, so an older attempt can never observe a half-admitted replacement.
func (s *Store) queueAgentRun(
	ctx context.Context,
	run core.AgentRun,
	resumeEpisodeID string,
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
	now := s.now().UTC()
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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	defer tx.Rollback()
	if resumeEpisodeID != "" {
		admitted, admitErr := tx.ExecContext(ctx, `
			UPDATE work_episodes SET updated_at = updated_at
			WHERE id = ? AND lifecycle_state NOT IN
			  ('completed', 'failed', 'refused', 'cancelled', 'superseded')`, resumeEpisodeID)
		if admitErr != nil {
			return core.AgentRun{}, false, admitErr
		}
		rows, rowsErr := admitted.RowsAffected()
		if rowsErr != nil {
			return core.AgentRun{}, false, rowsErr
		}
		if rows != 1 {
			var state core.WorkEpisodeState
			if stateErr := tx.QueryRowContext(ctx,
				`SELECT lifecycle_state FROM work_episodes WHERE id = ?`, resumeEpisodeID,
			).Scan(&state); errors.Is(stateErr, sql.ErrNoRows) {
				return core.AgentRun{}, false, ErrNotFound
			} else if stateErr != nil {
				return core.AgentRun{}, false, stateErr
			}
			return core.AgentRun{}, false, fmt.Errorf(
				"cannot resume terminal episode %q in state %q", resumeEpisodeID, state,
			)
		}
	}
	result, err := tx.ExecContext(ctx, `
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
		run.NextAttemptAt.UTC().Format(timestampFormat), sqlutil.BoundedError(run.LastError),
		run.CreatedAt.UTC().Format(timestampFormat), s.nowText(), nullableTime(run.StartedAt),
		nullableTime(run.CompletedAt),
	)
	if err != nil {
		return core.AgentRun{}, false, fmt.Errorf("queue agent run: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.AgentRun{}, false, err
	}
	if rows == 1 && s.testHookAfterAgentRunInsert != nil {
		s.testHookAfterAgentRunInsert()
	}
	stored, err := getAgentRunBySourceTx(ctx, tx, run.SourceKind, run.SourceID)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	if resumeEpisodeID != "" && stored.EpisodeID != resumeEpisodeID {
		return core.AgentRun{}, false, fmt.Errorf(
			"resume episode %q: source identity belongs to episode %q: %w",
			resumeEpisodeID, stored.EpisodeID, ErrConflict)
	}
	stored.CommitmentTitle = run.CommitmentTitle
	if rows == 1 {
		stored.Episode = run.Episode
	} else {
		// The durable source identity won. Preserve the episode already bound
		// to that run even when a replay came through the generic input path
		// without the richer Episode value. Re-normalizing an idempotent run
		// from the replay used to synthesize a second episode and move the run
		// away from its existing attempt.
		stored.Episode = &core.WorkEpisode{ID: stored.EpisodeID}
	}
	if err := s.ensureWorkEpisodeTx(ctx, tx, stored); err != nil {
		return core.AgentRun{}, false, fmt.Errorf("ensure work episode: %w", err)
	}
	stored, err = getAgentRunBySourceTx(ctx, tx, run.SourceKind, run.SourceID)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	if resumeEpisodeID != "" && rows == 1 {
		if err := s.setWorkEpisodePhaseTx(
			ctx, tx, stored.ID, core.EpisodeRetrying, "resuming", "Resuming work",
			"Run the next attempt", time.Time{},
			episodeEventKey(
				"phase", resumeEpisodeID, string(core.EpisodeRetrying), "resuming",
				"Resuming work", "Run the next attempt", time.Time{}.UTC().Format(time.RFC3339Nano),
			),
		); err != nil {
			return core.AgentRun{}, false, err
		}
	}
	// After the episode, not before: the commitment is keyed by episode, so the
	// episode row has to exist for it to reference.
	stored.CommitmentTitle = run.CommitmentTitle
	if err := ensureCommitmentTx(ctx, tx, stored); err != nil {
		return core.AgentRun{}, false, fmt.Errorf("ensure agent commitment: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return core.AgentRun{}, false, err
	}
	return stored, rows == 1, nil
}

func getAgentRunBySourceTx(
	ctx context.Context,
	tx *sql.Tx,
	kind string,
	sourceID string,
) (core.AgentRun, error) {
	return scanAgentRun(tx.QueryRowContext(
		ctx,
		`SELECT `+agentRunColumns+`
		 FROM agent_runs WHERE source_kind = ? AND source_id = ?`,
		kind,
		sourceID,
	))
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

func (s *Store) GetLatestWorkEpisodeByConversationKey(
	ctx context.Context,
	conversationKey string,
) (core.WorkEpisode, error) {
	if strings.TrimSpace(conversationKey) == "" {
		return core.WorkEpisode{}, errors.New("conversation key is required")
	}
	return scanWorkEpisode(s.db.QueryRowContext(ctx, `
		SELECT `+workEpisodeColumns+`
		FROM work_episodes
		WHERE id = (
			SELECT episode_id
			FROM agent_runs
			WHERE conversation_key = ? AND episode_id != ''
			ORDER BY created_at DESC, id DESC
			LIMIT 1
		)`, conversationKey))
}

// GetLatestOperationalWorkEpisode returns the most recent episode created by
// the same Slack app in a channel. Exact alert/run correlation still owns
// deduplication; this wider relationship only shares the recent claim ledger
// across alert families that are likely part of one operational situation.
func (s *Store) GetLatestOperationalWorkEpisode(
	ctx context.Context,
	channelID string,
	actorID string,
	since time.Time,
) (core.WorkEpisode, error) {
	if strings.TrimSpace(channelID) == "" || strings.TrimSpace(actorID) == "" {
		return core.WorkEpisode{}, errors.New("operational episode channel and actor are required")
	}
	return scanWorkEpisode(s.db.QueryRowContext(ctx, `
		SELECT `+workEpisodeColumns+`
		FROM work_episodes
		WHERE id = (
			SELECT run.episode_id
			FROM agent_runs AS run
			JOIN slack_inputs AS input ON input.id = run.source_id
			WHERE run.source_kind = 'watch'
			  AND run.episode_id != ''
			  AND input.kind = 'bot_message'
			  AND input.channel_id = ?
			  AND input.user_id = ?
			  AND julianday(input.received_at) >= julianday(?)
			ORDER BY input.received_at DESC, run.created_at DESC, run.id DESC
			LIMIT 1
		)`, channelID, actorID, since.UTC().Format(timestampFormat)))
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
	run.NextAttemptAt = sqlutil.ParseTime(next)
	run.CreatedAt = sqlutil.ParseTime(created)
	run.UpdatedAt = sqlutil.ParseTime(updated)
	run.StartedAt = sqlutil.ScanTime(started)
	run.CompletedAt = sqlutil.ScanTime(completed)
	return run, nil
}

func (s *Store) LeaseAgentRun(ctx context.Context) (core.AgentRun, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.AgentRun{}, err
	}
	defer tx.Rollback()
	if err := lifecyclecheck.CancelQueuedUnderTerminalEpisodes(ctx, tx, s.nowText()); err != nil {
		return core.AgentRun{}, err
	}
	run, err := scanAgentRun(tx.QueryRowContext(ctx, `
		SELECT `+agentRunColumns+`
		FROM agent_runs AS candidate
		WHERE candidate.state = 'pending'
		  AND julianday(candidate.next_attempt_at) <= julianday(?)
		  AND EXISTS (
		    SELECT 1 FROM work_episodes AS episode
		    WHERE episode.id = candidate.episode_id
		      AND episode.lifecycle_state NOT IN (
		        'completed', 'failed', 'refused', 'cancelled', 'superseded'
		      )
		  )
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
		  CASE
		    WHEN candidate.mode != 'triage' THEN 0
		    WHEN EXISTS (
		      SELECT 1 FROM slack_inputs AS input
		      WHERE input.id = candidate.source_id
		        AND input.kind IN ('mention', 'message', 'direct', 'shortcut', 'action')
		    ) THEN 1
		    WHEN EXISTS (
		      SELECT 1 FROM slack_inputs AS input
		      WHERE input.id = candidate.source_id AND input.kind = 'bot_message'
		    ) THEN 3
		    ELSE 2
		  END,
		  candidate.created_at,
		  candidate.id
		LIMIT 1`, s.nowText()))
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			if commitErr := tx.Commit(); commitErr != nil {
				return core.AgentRun{}, commitErr
			}
		}
		return core.AgentRun{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs SET state = 'preparing', updated_at = ?
		WHERE id = ? AND state = 'pending'`, s.nowText(), run.ID)
	if err := sqlutil.ExpectOne(result, err, "lease agent run"); err != nil {
		return core.AgentRun{}, err
	}
	if err := s.setEpisodeAttemptStateTx(
		ctx, tx, run.ID, core.AttemptLeased, "", true,
	); err != nil {
		return core.AgentRun{}, err
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, run.ID, core.EpisodePlanning, "planning", "Planning the work",
		"Establish the evidence plan", time.Time{},
		episodeEventKey("agent-run-lease", run.ID, run.IdempotencyKey),
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
		LIMIT 1`, s.nowText()))
	if err != nil {
		return core.AgentRun{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs SET state = 'finalizing', updated_at = ?
		WHERE id = ? AND state = 'applying'`, s.nowText(), run.ID)
	if err := sqlutil.ExpectOne(result, err, "lease agent run finalization"); err != nil {
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
		WHERE id = ? AND state = 'applying'`, s.nowText(), id)
	if err := sqlutil.ExpectOne(result, err, "begin agent run finalization"); err != nil {
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
		sessionID, generation, repository, eventSequence, contextJSON, s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "bind agent run session")
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
		contextJSON, s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "set agent run context")
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
			revision, s.nowText(), id)
		if err := sqlutil.ExpectOne(result, err, "freeze agent run revision"); err != nil {
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
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'running', coop_turn_id = ?, coop_event_sequence = ?,
		    last_error = '', started_at = COALESCE(started_at, ?), updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		coopTurnID, eventSequence, now, now, id)
	if err := sqlutil.ExpectOne(result, err, "mark agent run submitted"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
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
	if err := s.setWorkEpisodePhaseTx(
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
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'running', coop_turn_id = ?, coop_event_sequence = ?,
		    last_error = '', started_at = COALESCE(started_at, ?), updated_at = ?
		WHERE id = ? AND state = 'preparing'`,
		coopTurnID, eventSequence, now, now, id,
	)
	if err := sqlutil.ExpectOne(result, err, "mark conversation run submitted"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
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
	if err := sqlutil.ExpectOne(result, err, "advance submitted conversation session"); err != nil {
		return err
	}
	if err := s.setWorkEpisodePhaseTx(
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
		sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat), s.nowText(), id)
	if err := sqlutil.ExpectOne(result, err, "defer agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "queued", sqlutil.BoundedError(detail),
		"Resume when the dependency is ready", time.Time{},
		// Keyed on the run alone, deliberately. Including the next attempt time
		// made every key unique, so a run polling once a second appended a
		// phase_changed event every second: 5,483 identical "waiting for the
		// previous agent run" rows, 47% of the whole episode event stream, and
		// a timeline nobody could read. Waiting is one fact however long it
		// lasts, and the UNIQUE(episode_id, idempotency_key) constraint now
		// collapses the repeats where they are written rather than where they
		// are displayed.
		"agent-run:"+id+":deferred",
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
		completedAt = s.nowText()
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
		state, sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat),
		completedAt, s.nowText(), id)
	if err := sqlutil.ExpectOne(result, err, "retry agent run"); err != nil {
		return err
	}
	attemptState := core.AttemptPending
	if terminal {
		attemptState = core.AttemptFailed
	}
	if err := s.setEpisodeAttemptStateTx(ctx, tx, id, attemptState, detail, false); err != nil {
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
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, episodeState, phase, sqlutil.BoundedError(detail), nextAction,
		time.Time{}, fmt.Sprintf(
			"agent-run:%s:retry:%s:%t", id, next.UTC().Format(time.RFC3339Nano), terminal,
		),
	); err != nil {
		return err
	}
	return tx.Commit()
}

// RetryAgentRunIfOwned keeps RetryAgentRun's compare-and-swap strict while
// treating a verified ownership handoff as success. Correlated events may
// supersede, cancel, or finish an older run while its worker is preparing a
// retry. The stale worker no longer owns that lifecycle and must not rewrite it.
func (s *Store) RetryAgentRunIfOwned(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	terminal bool,
) (bool, error) {
	err := s.RetryAgentRun(ctx, id, detail, next, terminal)
	if err == nil {
		return true, nil
	}
	if !errors.Is(err, ErrConflict) {
		return false, err
	}
	current, currentErr := s.GetAgentRun(ctx, id)
	if errors.Is(currentErr, ErrNotFound) {
		return false, nil
	}
	if currentErr != nil {
		return false, fmt.Errorf("inspect agent run after retry conflict: %w", currentErr)
	}
	if current.State != core.AgentRunPreparing && current.State != core.AgentRunFinalizing {
		return false, nil
	}
	return false, err
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
		sequence, s.nowText(), id)
	if err := sqlutil.ExpectOne(result, err, "advance agent run events"); err != nil {
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
		s.nowText(), id, sessionID,
	)
	if err := sqlutil.ExpectOne(result, err, "repair agent run event cursor"); err != nil {
		return err
	}
	if incidentID.Valid {
		_, err = tx.ExecContext(ctx, `
			UPDATE incidents SET coop_event_sequence = 0, updated_at = ?
			WHERE id = ? AND coop_session_id = ?`,
			s.nowText(), incidentID.String, sessionID,
		)
	} else {
		// A conversation lane can share the same Coop session with the channel
		// memory projection. A rotated session invalidates both cursors, even
		// when only one projection is active for the current run.
		_, err = tx.ExecContext(ctx, `
			UPDATE channel_memories SET coop_event_sequence = 0, updated_at = ?
			WHERE channel_id = ? AND session_id = ?`,
			s.nowText(), channelID, sessionID,
		)
		if err == nil && conversationLane {
			_, err = tx.ExecContext(ctx, `
				UPDATE conversation_sessions SET coop_event_sequence = 0, updated_at = ?
				WHERE channel_id = ? AND session_id = ?`,
				s.nowText(), channelID, sessionID,
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
	recoveryID, err := core.NewID("recovery")
	if err != nil {
		return fmt.Errorf("generate agent run recovery identity: %w", err)
	}
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
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', failure_count = ?, idempotency_key = ?,
		    expected_revision = 0, coop_turn_id = '',
		    coop_event_sequence = MAX(coop_event_sequence, ?),
		    result_json = X'', terminal_state = '', last_error = ?,
		    next_attempt_at = ?, completed_at = NULL, updated_at = ?
		WHERE id = ? AND state = 'running'`,
		attempt,
		fmt.Sprintf("responder:run:%s:%s", id, recoveryID),
		eventSequence,
		sqlutil.BoundedError(detail),
		next.UTC().Format(timestampFormat),
		now,
		id,
	)
	if err := sqlutil.ExpectOne(result, err, "requeue agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
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
		if err := sqlutil.ExpectOne(
			result, err, "release interrupted incident turn",
		); err != nil {
			return err
		}
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "continuing", sqlutil.BoundedError(detail),
		"Continue unfinished work", time.Time{},
		fmt.Sprintf("agent-run:%s:%s", id, recoveryID),
	); err != nil {
		return err
	}
	return tx.Commit()
}

// RequeueFailedAgentRun puts a terminally failed run back in the pending queue
// so the ordinary workers run it again, reopening its episode on the way.
//
// Only the episode's latest attempt may be requeued. Reviving an older failed
// attempt would race the newer one for the same episode, and the reducer
// enforces exactly that: a terminal episode reopens only through its latest
// attempt. The refusal names the newer attempt so the operator is told why
// this run is history rather than shown a retry that silently does nothing.
//
// The idempotency key is refreshed for the same reason RequeueAgentRun does
// it: Coop deduplicates turn submissions by key, so replaying the old key
// would return the already-failed turn instead of starting a new one.
func (s *Store) RequeueFailedAgentRun(ctx context.Context, id, detail string) error {
	recoveryID, err := core.NewID("recovery")
	if err != nil {
		return fmt.Errorf("generate agent run recovery identity: %w", err)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var state, attemptID, episodeID string
	if err := tx.QueryRowContext(ctx, `
		SELECT state, attempt_id, episode_id FROM agent_runs WHERE id = ?`, id,
	).Scan(&state, &attemptID, &episodeID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("requeue failed agent run: %w", ErrNotFound)
		}
		return err
	}
	if state != string(core.AgentRunFailed) {
		return fmt.Errorf("run is %s, not failed; only a failed run can be retried", state)
	}
	var latestAttempt string
	var episodeState core.WorkEpisodeState
	if err := tx.QueryRowContext(ctx, `
		SELECT latest_attempt_id, lifecycle_state FROM work_episodes WHERE id = ?`,
		episodeID,
	).Scan(&latestAttempt, &episodeState); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return errors.New("this run has no episode record to reopen, so there is nothing to retry into")
		}
		return err
	}
	if attemptID != latestAttempt {
		return fmt.Errorf(
			"a newer attempt (%s) has run for this episode since; this run is history and retrying it would race that attempt",
			latestAttempt,
		)
	}
	if episodeState == core.EpisodeCompleted {
		return errors.New("the episode completed on a later attempt; there is nothing left to retry")
	}
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', idempotency_key = ?,
		    expected_revision = 0, coop_turn_id = '',
		    result_json = X'', terminal_state = '', last_error = ?,
		    next_attempt_at = ?, completed_at = NULL, updated_at = ?
		WHERE id = ? AND state = 'failed'`,
		fmt.Sprintf("responder:run:%s:%s", id, recoveryID),
		sqlutil.BoundedError(detail),
		now, now, id,
	)
	if err := sqlutil.ExpectOne(result, err, "requeue failed agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "retrying", sqlutil.BoundedError(detail),
		"Retry the work from preserved context", time.Time{},
		fmt.Sprintf("agent-run:%s:%s", id, recoveryID),
	); err != nil {
		return err
	}
	return tx.Commit()
}

// DeferRunningAgentRun parks submitted work behind a shared dependency without counting the
// outage as an agent failure. A fresh idempotency key prevents the failed Coop
// turn from being replayed when the dependency becomes available again.
func (s *Store) DeferRunningAgentRun(
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
	if err := tx.QueryRowContext(ctx, `
		SELECT incident_id, coop_turn_id
		FROM agent_runs
		WHERE id = ? AND state = 'running'`, id,
	).Scan(&incidentID, &coopTurnID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("defer running agent run: %w", ErrConflict)
		}
		return err
	}
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', idempotency_key = ?,
		    expected_revision = 0, coop_turn_id = '',
		    coop_event_sequence = MAX(coop_event_sequence, ?),
		    result_json = X'', terminal_state = '', last_error = ?,
		    next_attempt_at = ?, completed_at = NULL, updated_at = ?
		WHERE id = ? AND state = 'running'`,
		fmt.Sprintf("responder:run:%s:dependency:%d", id, s.now().UnixNano()),
		eventSequence,
		sqlutil.BoundedError(detail),
		next.UTC().Format(timestampFormat),
		now,
		id,
	)
	if err := sqlutil.ExpectOne(result, err, "defer running agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
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
		if err := sqlutil.ExpectOne(
			result, err, "release dependency-blocked incident turn",
		); err != nil {
			return err
		}
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "waiting", sqlutil.BoundedError(detail),
		"Waiting for execution runtime", time.Time{},
		fmt.Sprintf("agent-run:%s:dependency:%d", id, eventSequence),
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
		sqlutil.BoundedError(detail),
		next.UTC().Format(timestampFormat),
		s.nowText(),
		id,
	)
	if err := sqlutil.ExpectOne(result, err, "escalate agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodePlanning, "expanding_scope", sqlutil.BoundedError(detail),
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
		terminalState, resultJSON, eventSequence,
		terminalResultError(terminalState, detail), s.nowText(), id)
	if err := sqlutil.ExpectOne(update, err, "stage agent run result"); err != nil {
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
	if err := s.setWorkEpisodePhaseTx(
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
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = ?, completed_at = ?,
		    last_error = CASE WHEN ? = 'completed' THEN '' ELSE last_error END,
		    updated_at = ?
		WHERE id = ? AND state = 'finalizing'`,
		finalState, now, finalState, now, id)
	if err := sqlutil.ExpectOne(result, err, "finish agent run"); err != nil {
		return err
	}
	attemptState := core.AttemptSucceeded
	if finalState == core.AgentRunFailed {
		attemptState = core.AttemptFailed
	} else if finalState == core.AgentRunCancelled {
		attemptState = core.AttemptCancelled
	}
	if err := s.setEpisodeAttemptStateTx(ctx, tx, id, attemptState, "", false); err != nil {
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
		  SELECT episode_id FROM agent_runs WHERE id = ?
		)`, id,
	).Scan(&currentEpisodeState); err != nil {
		return err
	}
	if agentRunOwnsEpisodeCompletion(currentEpisodeState) {
		if err := s.setWorkEpisodePhaseTx(
			ctx, tx, id, episodeState, "finished", episodeStatus, episodeNextAction,
			time.Time{}, "agent-run:"+id+":finished:"+string(finalState),
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// The transport attempt may finish while the accepted work remains open. Only
// active execution states are owned by FinishAgentRun; durable waiting,
// blocked, refused, and terminal states were chosen earlier by the episode
// reducer and must survive transport finalization.
func agentRunOwnsEpisodeCompletion(state core.WorkEpisodeState) bool {
	switch state {
	case core.EpisodeAccepted, core.EpisodeAcknowledged, core.EpisodePlanning,
		core.EpisodeWorking, core.EpisodeRetrying, core.EpisodeVerifying:
		return true
	default:
		return false
	}
}

func terminalResultError(terminalState string, detail string) string {
	if terminalState == "completed" {
		return ""
	}
	return sqlutil.BoundedError(detail)
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
		next.UTC().Format(timestampFormat), sqlutil.BoundedError(detail), s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "retry agent run finalization")
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
		sqlutil.BoundedError(detail), s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "fail agent run finalization")
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
		sqlutil.BoundedError(detail), s.nowText(), s.nowText(), id)
	if err := sqlutil.ExpectOne(result, err, "supersede agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptCancelled, detail, false,
	); err != nil {
		return err
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeSuperseded, "finished", sqlutil.BoundedError(detail), "",
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

// HasNewerSubstantivePendingAgentRun excludes a bare bot mention. A
// mention-only follow-up is a nudge to existing work, not a replacement
// request that may supersede the operator's earlier substantive message.
func (s *Store) HasNewerSubstantivePendingAgentRun(
	ctx context.Context,
	run core.AgentRun,
	botUserID string,
) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM agent_runs AS candidate
		LEFT JOIN slack_inputs AS input
		  ON candidate.source_kind = 'watch' AND input.id = candidate.source_id
		WHERE candidate.conversation_key = ? AND candidate.id != ?
		  AND candidate.state IN ('pending', 'preparing')
		  AND (
		    julianday(candidate.created_at) > julianday(?) OR
		    (julianday(candidate.created_at) = julianday(?) AND candidate.id > ?)
		  )
		  AND (
		    input.id IS NULL OR NOT (
		      input.kind = 'mention'
		      AND trim(replace(input.text, '<@' || ? || '>', '')) = ''
		      AND COALESCE(CAST(input.attachments_json AS TEXT), '[]') IN ('[]', 'null')
		    )
		  )`,
		run.ConversationKey, run.ID,
		run.CreatedAt.UTC().Format(timestampFormat),
		run.CreatedAt.UTC().Format(timestampFormat),
		run.ID,
		botUserID,
	).Scan(&count)
	return count > 0, err
}

// NudgeLatestAgentRun wakes existing work for one Slack conversation without
// creating a second run or replacing its original substantive request.
func (s *Store) NudgeLatestAgentRun(
	ctx context.Context,
	channelID string,
	threadTS string,
) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var id, state string
	err = tx.QueryRowContext(ctx, `
		SELECT id, state
		FROM agent_runs
		WHERE source_kind = 'watch'
		  AND channel_id = ? AND thread_ts = ?
		  AND state IN ('pending', 'preparing', 'running', 'applying', 'finalizing')
		ORDER BY created_at DESC, id DESC
		LIMIT 1`, channelID, threadTS).Scan(&id, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if state == string(core.AgentRunPending) {
		now := s.nowText()
		if _, err := tx.ExecContext(ctx, `
			UPDATE agent_runs
			SET next_attempt_at = ?, updated_at = ?
			WHERE id = ? AND state = 'pending'`, now, now, id); err != nil {
			return false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

// HasNewerOperationalAgentRun reports whether a newer app notification in the
// same channel can carry a short burst's shared context. The exact conversation
// key remains on each run for durable alert/run correlation; this query only
// prevents every notification in one burst from consuming a separate model
// turn or publishing a stale result.
func (s *Store) HasNewerOperationalAgentRun(
	ctx context.Context,
	run core.AgentRun,
	within time.Duration,
	pendingOnly bool,
) (bool, error) {
	if within <= 0 {
		return false, nil
	}
	states := "candidate.state NOT IN ('superseded', 'cancelled', 'failed')"
	if pendingOnly {
		states = "candidate.state IN ('pending', 'preparing')"
	}
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM agent_runs AS candidate
		JOIN slack_inputs AS input ON input.id = candidate.source_id
		WHERE candidate.id != ?
		  AND candidate.mode = 'triage'
		  AND candidate.source_kind = 'watch'
		  AND candidate.channel_id = ?
		  AND candidate.user_id = ?
		  AND input.kind = 'bot_message'
		  AND `+states+`
		  AND (
		    julianday(candidate.created_at) > julianday(?) OR
		    (julianday(candidate.created_at) = julianday(?) AND candidate.id > ?)
		  )
		  AND julianday(candidate.created_at) <= julianday(?)`,
		run.ID, run.ChannelID, run.UserID,
		run.CreatedAt.UTC().Format(timestampFormat),
		run.CreatedAt.UTC().Format(timestampFormat), run.ID,
		run.CreatedAt.Add(within).UTC().Format(timestampFormat),
	).Scan(&count)
	return count > 0, err
}

func (s *Store) HasNewerAgentRun(ctx context.Context, run core.AgentRun) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM agent_runs
		WHERE conversation_key = ? AND id != ?
		  AND state NOT IN ('superseded', 'cancelled', 'failed')
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

// ListStoredResults returns historical model outputs for replay, newest first.
//
// It exists so the legacy compatibility path can be measured against traffic
// that already happened rather than only by watching forward for a week. Only
// runs that produced a result are returned; a failed run has nothing to replay.
func (s *Store) ListStoredResults(
	ctx context.Context,
	since time.Time,
	limit int,
) ([]core.StoredAgentResult, error) {
	if limit < 1 || limit > 5000 {
		limit = 1000
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, mode, result_json, created_at
		FROM agent_runs
		WHERE terminal_state = 'completed'
		  AND result_json IS NOT NULL AND length(result_json) > 2
		  AND created_at >= ?
		ORDER BY created_at DESC
		LIMIT ?`, sqlutil.TimeText(since), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := make([]core.StoredAgentResult, 0, limit)
	for rows.Next() {
		var result core.StoredAgentResult
		var message []byte
		var created string
		if err := rows.Scan(&result.RunID, &result.Mode, &message, &created); err != nil {
			return nil, err
		}
		result.Message = string(message)
		result.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
		results = append(results, result)
	}
	return results, rows.Err()
}

// CorrectionRate counts corrections by class alongside the number of finished
// turns, so the two can be compared. Returning the denominator with the
// numerators is deliberate: a count of corrections on its own says nothing,
// because it moves with traffic.
func (s *Store) CorrectionRate(
	ctx context.Context,
	since time.Time,
) (map[string]int, int, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT outcome, COUNT(*) FROM audit_events
		WHERE kind = 'result.correction' AND created_at >= ?
		GROUP BY outcome`, sqlutil.TimeText(since))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	counts := make(map[string]int)
	for rows.Next() {
		var outcome string
		var count int
		if err := rows.Scan(&outcome, &count); err != nil {
			return nil, 0, err
		}
		counts[outcome] = count
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	var turns int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM agent_runs
		WHERE terminal_state != '' AND created_at >= ?`, sqlutil.TimeText(since),
	).Scan(&turns); err != nil {
		return nil, 0, err
	}
	return counts, turns, nil
}

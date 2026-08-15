package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
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
	if run.SourceKind == "watch" && strings.HasPrefix(run.SourceID, "slack_replay_") {
		var inputState, envelopeID string
		if err := tx.QueryRowContext(ctx, `
			SELECT state, envelope_id FROM slack_inputs WHERE id = ?`, run.SourceID,
		).Scan(&inputState, &envelopeID); err != nil {
			return core.AgentRun{}, false, err
		}
		if (strings.HasPrefix(envelopeID, "replay-private:") ||
			strings.HasPrefix(envelopeID, "replay-public:")) && inputState != "processing" {
			return core.AgentRun{}, false, fmt.Errorf(
				"Slack replay %s is no longer active: %w", run.SourceID, ErrConflict,
			)
		}
	}
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
		var finalizing bool
		if err := tx.QueryRowContext(ctx, `
			SELECT EXISTS (
			  SELECT 1 FROM work_episodes AS episode
			  JOIN episode_attempts AS attempt ON attempt.id = episode.latest_attempt_id
			  JOIN agent_runs AS owner ON owner.id = attempt.agent_run_id
			  WHERE episode.id = ? AND owner.state = 'finalizing'
			)`, resumeEpisodeID).Scan(&finalizing); err != nil {
			return core.AgentRun{}, false, err
		}
		if finalizing {
			return core.AgentRun{}, false, fmt.Errorf(
				"episode %q result is finalizing: %w", resumeEpisodeID, ErrConflict,
			)
		}
	} else if run.IncidentID != "" {
		var finalizing bool
		if err := tx.QueryRowContext(ctx, `
			SELECT EXISTS (
			  SELECT 1 FROM agent_runs
			  WHERE incident_id = ? AND state = 'finalizing'
			)`, run.IncidentID).Scan(&finalizing); err != nil {
			return core.AgentRun{}, false, err
		}
		if finalizing {
			return core.AgentRun{}, false, fmt.Errorf(
				"incident %q result is finalizing: %w", run.IncidentID, ErrConflict,
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

// CancelSlackReplay atomically retires the exact replay input, its current
// execution generation, episode attempt, and unsent response. It deliberately
// accepts every active run state: a CLI timeout must not leave work running
// merely because the worker crossed a preparation/finalization boundary while
// the cancellation request was in flight.
func CancelSlackReplay(
	ctx context.Context,
	s *Store,
	replayID string,
	expectedRunKey string,
	detail string,
) (core.AgentRun, bool, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.AgentRun{}, false, false, err
	}
	defer tx.Rollback()
	var envelopeID, inputState string
	if err := tx.QueryRowContext(ctx, `
		SELECT envelope_id, state FROM slack_inputs WHERE id = ?`, replayID,
	).Scan(&envelopeID, &inputState); errors.Is(err, sql.ErrNoRows) {
		return core.AgentRun{}, false, false, ErrNotFound
	} else if err != nil {
		return core.AgentRun{}, false, false, err
	}
	if !strings.HasPrefix(envelopeID, "replay-private:") &&
		!strings.HasPrefix(envelopeID, "replay-public:") {
		return core.AgentRun{}, false, false, errors.New("Slack input is not a replay")
	}
	run, err := getAgentRunBySourceTx(ctx, tx, "watch", replayID)
	if errors.Is(err, ErrNotFound) {
		result, updateErr := tx.ExecContext(ctx, `
			UPDATE slack_inputs SET state = 'done', last_error = ?, updated_at = ?
			WHERE id = ? AND state IN ('pending', 'retry', 'processing')`,
			sqlutil.BoundedError(detail), s.nowText(), replayID)
		if updateErr != nil {
			return core.AgentRun{}, false, false, updateErr
		}
		rows, rowsErr := result.RowsAffected()
		if rowsErr != nil {
			return core.AgentRun{}, false, false, rowsErr
		}
		if err := tx.Commit(); err != nil {
			return core.AgentRun{}, false, false, err
		}
		return core.AgentRun{}, rows == 1, false, nil
	}
	if err != nil {
		return core.AgentRun{}, false, false, err
	}
	if expectedRunKey != "" && run.IdempotencyKey != expectedRunKey {
		return core.AgentRun{}, false, false, fmt.Errorf(
			"replay execution changed before cancellation: %w", ErrConflict,
		)
	}
	if run.SessionID != "" {
		now := s.nowText()
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO replay_cancellations (
			  run_key, replay_id, run_id, session_id, turn_id, state,
			  next_attempt_at, created_at, updated_at
			) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)
			ON CONFLICT(run_key) DO UPDATE SET
			  turn_id = CASE WHEN excluded.turn_id != '' THEN excluded.turn_id ELSE replay_cancellations.turn_id END,
			  next_attempt_at = MIN(replay_cancellations.next_attempt_at, excluded.next_attempt_at),
			  updated_at = excluded.updated_at
			WHERE replay_cancellations.state = 'pending'`,
			run.IdempotencyKey, replayID, run.ID, run.SessionID, run.CoopTurnID,
			now, now, now,
		); err != nil {
			return core.AgentRun{}, false, false, err
		}
	}
	const deliveryUncertain = "replay cancellation raced an in-flight Slack write; delivery outcome requires reconciliation"
	var sending int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM slack_deliveries
		WHERE agent_run_id = ? AND agent_run_key = ? AND state IN ('sending', 'uncertain')`,
		run.ID, run.IdempotencyKey,
	).Scan(&sending); err != nil {
		return core.AgentRun{}, false, false, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = CASE WHEN state IN ('sending', 'uncertain') THEN 'uncertain' ELSE 'superseded' END,
		    last_error = CASE WHEN state IN ('sending', 'uncertain') THEN ? ELSE ? END,
		    updated_at = ?
		WHERE agent_run_id = ? AND agent_run_key = ?
		  AND state IN ('pending', 'sending', 'retry', 'uncertain')`,
		deliveryUncertain, sqlutil.BoundedError(detail), s.nowText(),
		run.ID, run.IdempotencyKey,
	); err != nil {
		return core.AgentRun{}, false, false, err
	}
	switch run.State {
	case core.AgentRunCompleted, core.AgentRunFailed, core.AgentRunCancelled,
		core.AgentRunSuperseded:
		if err := tx.Commit(); err != nil {
			return core.AgentRun{}, false, false, err
		}
		return run, false, sending > 0, nil
	}
	if run.EpisodeID != "" {
		var latestAttempt string
		if err := tx.QueryRowContext(ctx,
			`SELECT latest_attempt_id FROM work_episodes WHERE id = ?`, run.EpisodeID,
		).Scan(&latestAttempt); err != nil {
			return core.AgentRun{}, false, false, err
		}
		if latestAttempt != run.AttemptID {
			now := s.nowText()
			result, updateErr := tx.ExecContext(ctx, `
				UPDATE agent_runs
				SET state = 'cancelled', terminal_state = 'cancelled', completed_at = ?,
				    last_error = ?, updated_at = ?
				WHERE id = ? AND state = ?`,
				now, sqlutil.BoundedError(detail), now, run.ID, run.State,
			)
			if updateErr := sqlutil.ExpectOne(result, updateErr, "cancel stale replay run"); updateErr != nil {
				return core.AgentRun{}, false, false, updateErr
			}
			if err := s.setEpisodeAttemptStateTx(
				ctx, tx, run.ID, core.AttemptCancelled, detail, false,
			); err != nil {
				return core.AgentRun{}, false, false, err
			}
			if _, err := tx.ExecContext(ctx, `
				UPDATE slack_inputs SET state = 'done', last_error = ?, updated_at = ?
				WHERE id = ? AND state IN ('pending', 'retry', 'processing', 'done')`,
				sqlutil.BoundedError(detail), now, replayID,
			); err != nil {
				return core.AgentRun{}, false, false, err
			}
			if err := tx.Commit(); err != nil {
				return core.AgentRun{}, false, false, err
			}
			run.State = core.AgentRunCancelled
			return run, true, sending > 0, nil
		}
	}
	if err := s.finishAgentRunTx(
		ctx, tx, run, core.AgentRunCancelled, detail, nil,
	); err != nil {
		return core.AgentRun{}, false, false, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'done', last_error = ?, updated_at = ?
		WHERE id = ? AND state IN ('pending', 'retry', 'processing', 'done')`,
		sqlutil.BoundedError(detail), s.nowText(), replayID); err != nil {
		return core.AgentRun{}, false, false, err
	}
	if err := tx.Commit(); err != nil {
		return core.AgentRun{}, false, false, err
	}
	run.State = core.AgentRunCancelled
	return run, true, sending > 0, nil
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
	preferredWaitingThread string,
) (core.WorkEpisode, error) {
	if strings.TrimSpace(conversationKey) == "" {
		return core.WorkEpisode{}, errors.New("conversation key is required")
	}
	return scanWorkEpisode(s.db.QueryRowContext(ctx, `
		SELECT `+workEpisodeColumns+`
		FROM work_episodes
		WHERE id = (
			SELECT run.episode_id
			FROM agent_runs AS run
			JOIN work_episodes AS episode ON episode.id = run.episode_id
			WHERE run.conversation_key = ? AND run.episode_id != ''
			ORDER BY CASE
				WHEN ? != '' AND episode.lifecycle_state = 'waiting_operator'
				  AND episode.destination_thread_ts = ? THEN 0
				ELSE 1
			END,
			run.created_at DESC, run.id DESC
			LIMIT 1
		)`, conversationKey, preferredWaitingThread, preferredWaitingThread))
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
	if run.EpisodeID != "" {
		var latestAttempt string
		if err := tx.QueryRowContext(ctx,
			`SELECT latest_attempt_id FROM work_episodes WHERE id = ?`, run.EpisodeID,
		).Scan(&latestAttempt); err != nil {
			return core.AgentRun{}, err
		}
		if latestAttempt != run.AttemptID {
			now := s.nowText()
			result, supersedeErr := tx.ExecContext(ctx, `
			UPDATE agent_runs SET state = 'superseded', completed_at = ?,
			  last_error = 'newer episode attempt owns finalization', updated_at = ?
			WHERE id = ? AND state = 'applying'`, now, now, run.ID)
			if err := sqlutil.ExpectOne(result, supersedeErr, "supersede stale finalization"); err != nil {
				return core.AgentRun{}, err
			}
			if err := s.setEpisodeAttemptStateTx(
				ctx, tx, run.ID, core.AttemptCancelled,
				"newer episode attempt owns finalization", false,
			); err != nil {
				return core.AgentRun{}, err
			}
			if err := tx.Commit(); err != nil {
				return core.AgentRun{}, err
			}
			return core.AgentRun{}, ErrNotFound
		}
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
		WHERE id = ? AND state IN ('preparing', 'finalizing')`,
		sessionID, generation, repository, eventSequence, contextJSON, s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "bind agent run session")
}

func (s *Store) BindTriageAgentRunSession(
	ctx context.Context,
	id string,
	sessionChannelID string,
	sessionID string,
	generation int,
	conversation bool,
	repository string,
	eventSequence int64,
	contextJSON []byte,
) error {
	if sessionChannelID == "" || sessionID == "" || generation < 1 ||
		len(contextJSON) == 0 || len(contextJSON) > 256<<10 {
		return errors.New("triage agent run session binding is incomplete")
	}
	table := "channel_memories"
	if conversation {
		table = "conversation_sessions"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET session_id = ?, session_generation = ?, repository = ?,
		    coop_event_sequence = ?, context_json = ?, updated_at = ?
		WHERE id = ? AND state IN ('preparing', 'finalizing')
		  AND EXISTS (
		    SELECT 1 FROM `+table+`
		    WHERE channel_id = ? AND session_id = ? AND generation = ?
		  )
		  AND NOT EXISTS (SELECT 1 FROM coop_cleanup WHERE session_id = ?)`,
		sessionID, generation, repository, eventSequence, contextJSON, s.nowText(), id,
		sessionChannelID, sessionID, generation, sessionID)
	return sqlutil.ExpectOne(result, err, "bind triage agent run session")
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

// requeueRunColumns drops what bound a run to the attempt that failed.
const requeueRunColumns = `expected_revision = 0, coop_turn_id = '', result_json = X'', terminal_state = '', completed_at = NULL,`

// ReleaseAgentRunRevision unfreezes a preparing run's revision, so a run that
// lost a revision race stops replaying the same stale number.
func (s *Store) ReleaseAgentRunRevision(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs SET expected_revision = 0, updated_at = ?
		WHERE id = ? AND state = 'preparing'`, s.nowText(), id)
	return err
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
	if terminal {
		run, err := scanAgentRun(tx.QueryRowContext(ctx, `
			SELECT `+agentRunColumns+` FROM agent_runs WHERE id = ?`, id))
		if err != nil {
			return err
		}
		var ownsEpisode bool
		if err := tx.QueryRowContext(ctx, `
			SELECT latest_attempt_id = ? FROM work_episodes WHERE id = ?`,
			run.AttemptID, run.EpisodeID,
		).Scan(&ownsEpisode); err != nil {
			return err
		}
		if ownsEpisode {
			if err := s.setFailureMarkerTx(
				ctx, tx, run, "failure_marker_add", true, s.nowText(),
			); err != nil {
				return err
			}
		}
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

// HoldOffAgentRunPoll spaces out the polling of a run whose turn cannot be
// advanced right now, and records what stopped it. An empty detail with a
// deadline of now is how a recovered poll clears both again.
//
// next_attempt_at is free to mean this while a run is running: every path that
// sets it for scheduling — requeue, defer, escalate, rate limit — moves the run
// to pending or applying in the same statement, so nothing reads it for a
// running row. The state is deliberately left alone here. A poll that cannot
// read its events has not told us anything about the turn, which may well have
// finished; taking the run out of running on that basis would discard a real
// answer over a transient failure.
//
// failure_count is left alone for the same reason. It counts attempts at the
// work, and a poll that could not read is not an attempt the model made.
func (s *Store) HoldOffAgentRunPoll(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
) error {
	// No row matching is not an error: a run that left running while the poll
	// was failing simply has nothing left to hold off.
	_, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'running'`,
		sqlutil.BoundedError(detail),
		next.UTC().Format(timestampFormat),
		s.nowText(),
		id,
	)
	return err
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
		    `+requeueRunColumns+`
		    coop_event_sequence = MAX(coop_event_sequence, ?),
		    last_error = ?, next_attempt_at = ?, updated_at = ?
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
	// Release the frozen context envelope, because the next attempt does not
	// send the prompt this one froze. A correction retry adds a block naming
	// exactly what the host refused, and the host records a prompt only when
	// the attempt is not already pointing at a manifest — so every corrected
	// turn stored its FIRST prompt beside its SECOND turn's result, and the
	// prompt that actually produced the recorded answer was on disk nowhere.
	// Eval fixtures are harvested from that pairing, and a corrected turn is
	// exactly the kind worth replaying. Cleared here rather than in the state
	// write above, which every requeue path shares: only this one is followed
	// by a rebuilt prompt. The next prepare writes a new manifest version whose
	// parent is this one, so the lineage still shows what the attempt read on
	// the way here. updated_at is left to that state write, which stamps this
	// same row in this same transaction.
	if _, err := tx.ExecContext(ctx, `UPDATE episode_attempts
		SET context_manifest_id = '' WHERE agent_run_id = ?`, id); err != nil {
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
	var state, attemptID, episodeID, sourceID, incidentID string
	if err := tx.QueryRowContext(ctx, `
		SELECT state, attempt_id, episode_id, source_id, COALESCE(incident_id, '')
		FROM agent_runs WHERE id = ?`, id,
	).Scan(&state, &attemptID, &episodeID, &sourceID, &incidentID); err != nil {
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
	newRunKey := fmt.Sprintf("responder:run:%s:%s", id, recoveryID)
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', idempotency_key = ?,
		    `+requeueRunColumns+`
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'failed'`,
		newRunKey,
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
	if err := s.setFailureMarkerTx(ctx, tx, core.AgentRun{
		ID: id, EpisodeID: episodeID, IncidentID: incidentID,
		SourceID: sourceID, IdempotencyKey: newRunKey,
	}, "failure_marker_remove", false, now); err != nil {
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
		    `+requeueRunColumns+`
		    coop_event_sequence = MAX(coop_event_sequence, ?),
		    last_error = ?, next_attempt_at = ?, updated_at = ?
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
	run, err := scanAgentRun(tx.QueryRowContext(ctx, `
		SELECT `+agentRunColumns+` FROM agent_runs
		WHERE id = ? AND state = 'finalizing'`, id))
	if err != nil {
		return fmt.Errorf("finish agent run: %w", err)
	}
	finalState := core.AgentRunState(run.TerminalState)
	if finalState != core.AgentRunCompleted &&
		finalState != core.AgentRunFailed &&
		finalState != core.AgentRunCancelled {
		return fmt.Errorf("agent run has invalid terminal state %q", run.TerminalState)
	}
	if err := s.finishAgentRunTx(ctx, tx, run, finalState, run.LastError, nil); err != nil {
		return err
	}
	return tx.Commit()
}

// FinishAgentRunFailure commits the terminal lifecycle and its user-visible
// failure notice together. If the accepted result already staged a durable
// response root, that successful outcome wins and no contradictory failure is
// inserted. The return value is the state actually committed; applied is false
// when a newer episode attempt owns the lifecycle.
func (s *Store) FinishAgentRunFailure(
	ctx context.Context,
	id string,
	detail string,
	delivery *core.SlackDelivery,
	effects AgentRunFailureEffects,
) (finalState core.AgentRunState, applied bool, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback()
	run, err := scanAgentRun(tx.QueryRowContext(ctx, `
		SELECT `+agentRunColumns+` FROM agent_runs
		WHERE id = ? AND state IN ('preparing', 'finalizing')`, id))
	if errors.Is(err, ErrNotFound) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if run.EpisodeID != "" {
		var latestAttempt string
		if err := tx.QueryRowContext(ctx,
			`SELECT latest_attempt_id FROM work_episodes WHERE id = ?`, run.EpisodeID,
		).Scan(&latestAttempt); err != nil {
			return "", false, err
		}
		if latestAttempt != run.AttemptID {
			return "", false, nil
		}
	}
	var responseStaged bool
	if err := tx.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1 FROM slack_deliveries
		  WHERE state IN ('pending', 'sending', 'retry', 'uncertain', 'sent')
		    AND response_root = 1
		    AND id NOT LIKE 'watch_failure_%'
		    AND id NOT LIKE 'out_run_finalization_failure_%'
		    AND agent_run_id = ? AND agent_run_key = ?
		    AND (? = '' OR id != ?)
		) OR EXISTS (
		  SELECT 1 FROM incidents
		  WHERE id = ? AND latest_update_run_id = ?
		    AND latest_update_run_key = ? AND latest_update != ''
		)`, run.ID, run.IdempotencyKey, deliveryID(delivery), deliveryID(delivery),
		run.IncidentID, run.ID, run.IdempotencyKey,
	).Scan(&responseStaged); err != nil {
		return "", false, err
	}
	finalState = core.AgentRunFailed
	if run.State == core.AgentRunFinalizing &&
		run.TerminalState == string(core.AgentRunCompleted) && responseStaged {
		finalState = core.AgentRunCompleted
		delivery = nil
	}
	if err := s.finishAgentRunTx(ctx, tx, run, finalState, detail, delivery); err != nil {
		return "", false, err
	}
	if finalState == core.AgentRunFailed {
		if err := s.applyAgentRunFailureEffectsTx(ctx, tx, run, effects); err != nil {
			return "", false, err
		}
		if err := s.setFailureMarkerTx(ctx, tx, run, "failure_marker_add", true, s.nowText()); err != nil {
			return "", false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return "", false, err
	}
	return finalState, true, nil
}

const responderFailureReaction = "warning"

func failureMarkerDeliveryID(action string, run core.AgentRun) string {
	digest := sha256.Sum256([]byte(run.IdempotencyKey))
	return "delivery_" + action + "_" + run.ID + "_" + hex.EncodeToString(digest[:8])
}

// setFailureMarkerTx records the desired low-noise health marker beside the
// terminal lifecycle change that caused it. The coalesce key makes the newest
// add/remove intent authoritative across fast retry/fail cycles; a currently
// sending predecessor remains serialized by LeaseSlackDelivery.
func (s *Store) setFailureMarkerTx(
	ctx context.Context,
	tx *sql.Tx,
	run core.AgentRun,
	action string,
	bindSource bool,
	now string,
) error {
	var channelID, messageTS, envelopeID string
	if err := tx.QueryRowContext(ctx, `
		SELECT channel_id, message_ts, envelope_id FROM slack_inputs
		WHERE id = ? AND channel_id != '' AND message_ts != ''`, run.SourceID,
	).Scan(&channelID, &messageTS, &envelopeID); errors.Is(err, sql.ErrNoRows) {
		return nil
	} else if err != nil {
		return err
	}
	if strings.HasPrefix(envelopeID, "replay-private:") {
		return nil
	}
	coalesceKey := "reaction:" + channelID + ":" + messageTS + ":" + responderFailureReaction
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'superseded', last_error = 'newer reaction intent', updated_at = ?
		WHERE coalesce_key = ? AND state IN ('pending', 'retry')`, now, coalesceKey); err != nil {
		return err
	}
	sourceInputID := ""
	if bindSource {
		sourceInputID = run.SourceID
	}
	return s.insertTerminalSlackDeliveryTx(ctx, tx, core.SlackDelivery{
		ID: failureMarkerDeliveryID(action, run), IncidentID: run.IncidentID,
		EpisodeID: run.EpisodeID, AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
		SourceInputID: sourceInputID, Operation: "reaction", Kind: action,
		ChannelID: channelID, MessageTS: messageTS, Status: responderFailureReaction,
		CoalesceKey: coalesceKey,
	}, now)
}

// AgentRunFailureEffects are shared bindings that must retire in the same
// transaction as the attempt that owns the terminal failure.
type AgentRunFailureEffects struct {
	StatusChannelID     string
	StatusThreadTS      string
	SessionChannelID    string
	SessionID           string
	SessionGeneration   int
	ConversationSession bool
}

func (s *Store) applyAgentRunFailureEffectsTx(
	ctx context.Context,
	tx *sql.Tx,
	run core.AgentRun,
	effects AgentRunFailureEffects,
) error {
	now := s.nowText()
	statusOwned := true
	if effects.StatusChannelID != "" && effects.StatusThreadTS != "" {
		if err := tx.QueryRowContext(ctx, `
			SELECT NOT EXISTS (
			  SELECT 1 FROM agent_runs newer
			  WHERE newer.id != ?
			    AND newer.state IN ('pending', 'preparing', 'running', 'applying', 'finalizing')
			    AND (
			      (? != '' AND newer.incident_id = ?) OR
			      (newer.channel_id = ? AND newer.thread_ts = ?) OR
			      EXISTS (
			        SELECT 1 FROM slack_inputs input
			        WHERE input.id = newer.source_id AND input.channel_id = ?
			          AND COALESCE(NULLIF(input.thread_ts, ''), input.message_ts) = ?
			      )
			    )
			)`, run.ID, run.IncidentID, run.IncidentID,
			effects.StatusChannelID, effects.StatusThreadTS,
			effects.StatusChannelID, effects.StatusThreadTS,
		).Scan(&statusOwned); err != nil {
			return err
		}
	}
	if statusOwned && effects.StatusChannelID != "" && effects.StatusThreadTS != "" {
		var generation int64
		if err := tx.QueryRowContext(ctx, `
			INSERT INTO slack_status_generations (channel_id, thread_ts, generation, updated_at)
			VALUES (?, ?, 1, ?)
			ON CONFLICT(channel_id, thread_ts) DO UPDATE SET
			  generation = slack_status_generations.generation + 1,
			  updated_at = excluded.updated_at
			RETURNING generation`, effects.StatusChannelID, effects.StatusThreadTS, now,
		).Scan(&generation); err != nil {
			return err
		}
		status := core.SlackDelivery{
			ID: "delivery_status_clear_failure_" + run.ID, IncidentID: run.IncidentID,
			EpisodeID: run.EpisodeID, AgentRunID: run.ID, Operation: "status", Kind: "status",
			ChannelID: effects.StatusChannelID, ThreadTS: effects.StatusThreadTS,
			CoalesceKey: "status:" + effects.StatusChannelID + ":" + effects.StatusThreadTS,
			CardVersion: generation,
		}
		if err := s.insertTerminalSlackDeliveryTx(ctx, tx, status, now); err != nil {
			return err
		}
	}
	if effects.SessionID == "" || effects.SessionChannelID == "" {
		return nil
	}
	var sessionOwned bool
	if err := tx.QueryRowContext(ctx, `
		SELECT NOT EXISTS (
		  SELECT 1 FROM agent_runs
		  WHERE id != ? AND session_id = ?
		    AND state IN ('pending', 'preparing', 'running', 'applying', 'finalizing')
		)`, run.ID, effects.SessionID).Scan(&sessionOwned); err != nil {
		return err
	}
	if !sessionOwned {
		return nil
	}
	table := "channel_memories"
	if effects.ConversationSession {
		table = "conversation_sessions"
	}
	result, err := tx.ExecContext(ctx, `UPDATE `+table+` SET session_id = '',
		session_revision = 0, coop_event_sequence = 0, turn_count = 0,
		generation = generation + 1,
		session_started_at = NULL, rotated_at = updated_at, updated_at = ?
		WHERE channel_id = ? AND session_id = ? AND generation = ?`,
		now, effects.SessionChannelID, effects.SessionID, effects.SessionGeneration)
	if err != nil {
		return err
	}
	if rows, rowsErr := result.RowsAffected(); rowsErr != nil {
		return rowsErr
	} else if rows == 0 {
		return nil
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		) VALUES (?, '', 'failed Slack channel triage session', 0, 'pending', ?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
		  eligible_at = MIN(coop_cleanup.eligible_at, excluded.eligible_at),
		  next_attempt_at = MIN(coop_cleanup.next_attempt_at, excluded.next_attempt_at),
		  updated_at = excluded.updated_at
		WHERE coop_cleanup.state != 'done'`, effects.SessionID, now, now, now, now)
	return err
}

func deliveryID(delivery *core.SlackDelivery) string {
	if delivery == nil {
		return ""
	}
	return delivery.ID
}

func (s *Store) finishAgentRunTx(
	ctx context.Context,
	tx *sql.Tx,
	run core.AgentRun,
	finalState core.AgentRunState,
	detail string,
	delivery *core.SlackDelivery,
) error {
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = ?, terminal_state = ?, completed_at = ?,
		    failure_count = failure_count + CASE WHEN ? = 'failed' THEN 1 ELSE 0 END,
		    last_error = CASE WHEN ? = 'completed' THEN '' ELSE ? END,
		    updated_at = ?
		WHERE id = ? AND state = ?`,
		finalState, finalState, now, finalState, finalState, sqlutil.BoundedError(detail),
		now, run.ID, run.State)
	if err := sqlutil.ExpectOne(result, err, "finish agent run"); err != nil {
		return err
	}
	attemptState := core.AttemptSucceeded
	if finalState == core.AgentRunFailed {
		attemptState = core.AttemptFailed
	} else if finalState == core.AgentRunCancelled {
		attemptState = core.AttemptCancelled
	}
	if err := s.setEpisodeAttemptStateTx(ctx, tx, run.ID, attemptState, detail, false); err != nil {
		return err
	}
	if run.IncidentID != "" {
		lastError := ""
		if finalState == core.AgentRunFailed {
			lastError = sqlutil.BoundedError(detail)
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET active_turn_id = '', workflow = 'parked', last_error = ?,
			    updated_at = ?, card_version = card_version + 1
			WHERE id = ? AND active_turn_id = ?`,
			lastError, now, run.IncidentID, run.CoopTurnID); err != nil {
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
		)`, run.ID,
	).Scan(&currentEpisodeState); err != nil {
		return err
	}
	if agentRunOwnsEpisodeCompletion(currentEpisodeState) {
		if err := s.setWorkEpisodePhaseTx(
			ctx, tx, run.ID, episodeState, "finished", episodeStatus, episodeNextAction,
			time.Time{}, "agent-run:"+run.ID+":finished:"+string(finalState),
		); err != nil {
			return err
		}
	}
	if finalState == core.AgentRunFailed && delivery != nil {
		delivery.AgentRunID = run.ID
		if delivery.SourceInputID == "" && run.SourceKind == "watch" {
			delivery.SourceInputID = run.SourceID
		}
		if delivery.EpisodeID == "" {
			delivery.EpisodeID = run.EpisodeID
		}
		if err := s.insertTerminalSlackDeliveryTx(ctx, tx, *delivery, now); err != nil {
			return err
		}
	}
	return nil
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

func (s *Store) SupersedeAgentRun(ctx context.Context, id, detail string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'superseded', last_error = ?, completed_at = ?, updated_at = ?
		WHERE id = ? AND state IN ('preparing', 'finalizing')`,
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

func (s *Store) HasNewerAgentRun(
	ctx context.Context,
	run core.AgentRun,
	sameHumanThread bool,
) (bool, error) {
	if sameHumanThread {
		// Slack event_time is only second-resolution, so durable admission order
		// breaks ties for edits to the same message. For distinct messages the
		// Slack timestamp is the conversation's authoritative order. Do not wait
		// for the control lane to queue the correction's run: admission itself
		// makes the newer human instruction authoritative.
		var exists bool
		err := s.db.QueryRowContext(ctx, `
			SELECT EXISTS (
			  SELECT 1
			  FROM slack_inputs AS source
			  JOIN slack_inputs AS newer
			    ON newer.id != source.id
			   AND newer.channel_id = source.channel_id
			   AND COALESCE(NULLIF(newer.thread_ts, ''), newer.message_ts) =
			       COALESCE(NULLIF(source.thread_ts, ''), source.message_ts)
			   AND newer.kind IN ('message', 'mention', 'direct')
			   AND (
			     CAST(newer.message_ts AS REAL) > CAST(source.message_ts AS REAL) OR
			     (newer.message_ts = source.message_ts AND newer.rowid > source.rowid)
			   )
			  WHERE source.id = ?
			)`, run.SourceID).Scan(&exists)
		return exists, err
	}
	threadFilter := ""
	stateFilter := "AND candidate.state NOT IN ('superseded', 'cancelled', 'failed')"
	var count int
	query := `
		SELECT count(*)
		FROM agent_runs AS candidate
		WHERE candidate.conversation_key = ? AND candidate.id != ?
		  ` + stateFilter + `
		  AND (
		    julianday(candidate.created_at) > julianday(?) OR
		    (julianday(candidate.created_at) = julianday(?) AND candidate.id > ?)
		  )` + threadFilter
	args := []any{run.ConversationKey, run.ID,
		run.CreatedAt.UTC().Format(timestampFormat),
		run.CreatedAt.UTC().Format(timestampFormat),
		run.ID}
	err := s.db.QueryRowContext(ctx, query, args...).Scan(&count)
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

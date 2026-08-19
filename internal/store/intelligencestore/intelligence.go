package intelligencestore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/memorydiff"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func (r *Repository) GetChannelMemory(ctx context.Context, channelID string) (core.ChannelMemory, error) {
	var memory core.ChannelMemory
	var state []byte
	var started, rotated sql.NullString
	var updated string
	err := r.db.QueryRowContext(ctx, `
			SELECT channel_id, repository, session_id, session_revision, generation, turn_count,
			  turns_since_memory, coop_event_sequence, state_json, session_started_at, rotated_at,
			  updated_at
			FROM channel_memories WHERE channel_id = ?`, channelID).Scan(
		&memory.ChannelID, &memory.Repository, &memory.SessionID, &memory.SessionRevision,
		&memory.Generation, &memory.TurnCount, &memory.TurnsSinceMemory,
		&memory.CoopEventSequence, &state, &started, &rotated, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ChannelMemory{}, core.ErrNotFound
	}
	if err != nil {
		return core.ChannelMemory{}, err
	}
	if err := json.Unmarshal(state, &memory.State); err != nil {
		return core.ChannelMemory{}, fmt.Errorf("decode channel memory: %w", err)
	}
	memory.SessionStarted = sqlutil.ScanTime(started)
	memory.RotatedAt = sqlutil.ScanTime(rotated)
	memory.UpdatedAt = sqlutil.ParseTime(updated)
	return memory, nil
}

func (r *Repository) ListChannelSituations(
	ctx context.Context,
	limit int,
) ([]core.ChannelMemory, error) {
	if limit < 1 {
		limit = 8
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT channel_id, repository, session_id, session_revision, generation, turn_count,
		  coop_event_sequence, state_json, session_started_at, rotated_at, updated_at
		FROM channel_memories
		WHERE state_json != '{}' AND state_json != ''
		  AND channel_id NOT LIKE 'scheduled:%'
		  AND channel_id NOT LIKE 'watch-shard:%'
		ORDER BY updated_at DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.ChannelMemory, 0)
	for rows.Next() {
		var memory core.ChannelMemory
		var state []byte
		var started, rotated sql.NullString
		var updated string
		if err := rows.Scan(
			&memory.ChannelID,
			&memory.Repository,
			&memory.SessionID,
			&memory.SessionRevision,
			&memory.Generation,
			&memory.TurnCount,
			&memory.CoopEventSequence,
			&state,
			&started,
			&rotated,
			&updated,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(state, &memory.State); err != nil {
			return nil, fmt.Errorf(
				"decode channel memory %s: %w",
				memory.ChannelID,
				err,
			)
		}
		memory.SessionStarted = sqlutil.ScanTime(started)
		memory.RotatedAt = sqlutil.ScanTime(rotated)
		memory.UpdatedAt = sqlutil.ParseTime(updated)
		result = append(result, memory)
	}
	return result, rows.Err()
}

func (r *Repository) GetConversationMemory(
	ctx context.Context,
	channelID string,
	threadTS string,
) (core.ConversationMemory, error) {
	var memory core.ConversationMemory
	var state []byte
	var updated string
	err := r.db.QueryRowContext(ctx, `
		SELECT channel_id, thread_ts, repository, last_message_ts, state_json, updated_at
		FROM conversation_memories
		WHERE channel_id = ? AND thread_ts = ?`,
		channelID, threadTS,
	).Scan(
		&memory.ChannelID,
		&memory.ThreadTS,
		&memory.Repository,
		&memory.LastMessage,
		&state,
		&updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ConversationMemory{}, core.ErrNotFound
	}
	if err != nil {
		return core.ConversationMemory{}, err
	}
	if err := json.Unmarshal(state, &memory.State); err != nil {
		return core.ConversationMemory{}, fmt.Errorf("decode conversation memory: %w", err)
	}
	memory.UpdatedAt = sqlutil.ParseTime(updated)
	return memory, nil
}

func (r *Repository) UpsertConversationMemoryState(
	ctx context.Context,
	memory core.ConversationMemory,
) error {
	if memory.ChannelID == "" || memory.Repository == "" {
		return errors.New("conversation memory requires a channel and repository")
	}
	state, err := json.Marshal(memory.State)
	if err != nil {
		return err
	}
	if len(state) > 64<<10 {
		return errors.New("conversation memory exceeds 64 KiB")
	}
	if string(state) == "{}" {
		return errors.New("conversation memory state is empty")
	}
	_, err = r.db.ExecContext(ctx, `
		INSERT INTO conversation_memories (
		  channel_id, thread_ts, repository, last_message_ts, state_json, updated_at
		) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(channel_id, thread_ts) DO UPDATE SET
		  repository = excluded.repository,
		  last_message_ts = CASE
		    WHEN CAST(excluded.last_message_ts AS REAL) >=
		         CAST(conversation_memories.last_message_ts AS REAL)
		    THEN excluded.last_message_ts
		    ELSE conversation_memories.last_message_ts
		  END,
		  state_json = excluded.state_json,
		  updated_at = excluded.updated_at`,
		memory.ChannelID,
		memory.ThreadTS,
		memory.Repository,
		memory.LastMessage,
		string(state),
		r.nowText(),
	)
	return err
}

func (r *Repository) ListRelatedConversationMemories(
	ctx context.Context,
	channelID string,
	threadTS string,
	repository string,
	limit int,
) ([]core.ConversationMemory, error) {
	if channelID == "" || limit < 1 || limit > 50 {
		return nil, errors.New("related conversation memory requires a channel and limit from 1 to 50")
	}
	localLimit := max(1, limit/2)
	workspaceLimit := max(1, limit-localLimit)
	rows, err := r.db.QueryContext(ctx, `
		WITH candidates AS (
		  SELECT memory.channel_id, COALESCE(membership.channel_name, '') AS channel_name,
		    memory.thread_ts, memory.repository,
		    memory.last_message_ts, memory.state_json, memory.updated_at,
		    CASE WHEN memory.channel_id = ? THEN 0 ELSE 1 END AS bucket
		  FROM conversation_memories AS memory
		  LEFT JOIN slack_channel_memberships AS membership
		    ON membership.channel_id = memory.channel_id
		  WHERE NOT (memory.channel_id = ? AND memory.thread_ts = ?)
		    AND (
		      memory.channel_id = ? OR (
		        membership.present = 1 AND membership.private = 0
		      )
		    )
		    AND memory.state_json != '{}' AND memory.state_json != ''
		),
		ranked AS (
		  SELECT *,
		    row_number() OVER (
		      PARTITION BY bucket
		      ORDER BY
		        CASE WHEN repository = ? THEN 0 ELSE 1 END,
		        updated_at DESC
		    ) AS position
		  FROM candidates
		)
		SELECT channel_id, channel_name, thread_ts, repository,
		  last_message_ts, state_json, updated_at
		FROM ranked
		WHERE (bucket = 0 AND position <= ?)
		   OR (bucket = 1 AND position <= ?)
		ORDER BY bucket, position
		LIMIT ?`,
		channelID, channelID, threadTS, channelID, repository,
		localLimit, workspaceLimit, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.ConversationMemory, 0, limit)
	for rows.Next() {
		var memory core.ConversationMemory
		var state []byte
		var updated string
		if err := rows.Scan(
			&memory.ChannelID,
			&memory.ChannelName,
			&memory.ThreadTS,
			&memory.Repository,
			&memory.LastMessage,
			&state,
			&updated,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(state, &memory.State); err != nil {
			return nil, fmt.Errorf(
				"decode conversation memory %s/%s: %w",
				memory.ChannelID,
				memory.ThreadTS,
				err,
			)
		}
		memory.UpdatedAt = sqlutil.ParseTime(updated)
		result = append(result, memory)
	}
	return result, rows.Err()
}

func (r *Repository) BindChannelSession(
	ctx context.Context,
	channelID string,
	repository string,
	sessionID string,
	revision int64,
	generation int,
	started time.Time,
) error {
	if channelID == "" || repository == "" || sessionID == "" || generation < 1 {
		return errors.New("channel session binding is incomplete")
	}
	if started.IsZero() {
		started = r.now().UTC()
	}
	result, err := r.db.ExecContext(ctx, `
		INSERT INTO channel_memories
		  (channel_id, repository, session_id, session_revision, generation, turn_count,
		   state_json, session_started_at, updated_at)
		SELECT ?, ?, ?, ?, ?, 0, '{}', ?, ?
		WHERE NOT EXISTS (SELECT 1 FROM coop_cleanup WHERE session_id = ?)
			ON CONFLICT(channel_id) DO UPDATE SET
		  repository = excluded.repository,
		  session_id = excluded.session_id,
		  session_revision = excluded.session_revision,
			  generation = excluded.generation,
			  turn_count = 0,
			  coop_event_sequence = 0,
		  session_started_at = excluded.session_started_at,
		  rotated_at = channel_memories.updated_at,
		  updated_at = excluded.updated_at
		WHERE NOT EXISTS (SELECT 1 FROM coop_cleanup WHERE session_id = excluded.session_id)`,
		channelID, repository, sessionID, revision, generation,
		started.UTC().Format(core.TimestampFormat), r.nowText(), sessionID,
	)
	return sqlutil.ExpectOne(result, err, "bind channel session outside cleanup ownership")
}

func (r *Repository) EnsureChannelMemory(
	ctx context.Context,
	channelID string,
	repository string,
) error {
	if channelID == "" || repository == "" {
		return errors.New("channel memory identity is incomplete")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO channel_memories (
		  channel_id, repository, session_id, session_revision, generation,
		  turn_count, state_json, updated_at
		) VALUES (?, ?, '', 0, 1, 0, '{}', ?)
		ON CONFLICT(channel_id) DO NOTHING`,
		channelID, repository, r.nowText(),
	)
	return err
}

// AdvanceChannelSessionGeneration records that Coop durably rejected one
// watch-session create request. The generation is shared by every operational
// stream in the channel, so leaving it only in one run's retry context makes a
// later run replay the same terminal operation and spend its own attempt
// budget rediscovering that it failed.
func (r *Repository) AdvanceChannelSessionGeneration(
	ctx context.Context,
	channelID string,
	repository string,
	failedGeneration int,
) error {
	if channelID == "" || repository == "" || failedGeneration < 1 {
		return errors.New("channel session generation identity is incomplete")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO channel_memories (
		  channel_id, repository, generation, updated_at
		) VALUES (?, ?, ?, ?)
		ON CONFLICT(channel_id) DO UPDATE SET
		  repository = excluded.repository,
		  generation = excluded.generation,
		  updated_at = excluded.updated_at
		WHERE channel_memories.session_id = ''
		  AND channel_memories.generation <= ?`,
		channelID, repository, failedGeneration+1, r.nowText(), failedGeneration,
	)
	return err
}

func (r *Repository) DetachChannelSession(
	ctx context.Context,
	channelID string,
	sessionID string,
) (bool, error) {
	if channelID == "" || sessionID == "" {
		return false, errors.New("channel session detachment identity is incomplete")
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE channel_memories
			SET session_id = '',
			    session_revision = 0,
			    coop_event_sequence = 0,
		    turn_count = 0,
		    session_started_at = NULL,
		    rotated_at = updated_at,
		    updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		r.nowText(), channelID, sessionID,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows == 1, nil
}

func (r *Repository) AdvanceChannelEvents(
	ctx context.Context,
	channelID string,
	sessionID string,
	sequence int64,
) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE channel_memories
		SET coop_event_sequence = MAX(coop_event_sequence, ?), updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		sequence, r.nowText(), channelID, sessionID)
	return sqlutil.ExpectOne(result, err, "advance channel Coop events")
}

func (r *Repository) ApplyWatchDecision(
	ctx context.Context,
	decision core.EvaluationDecision,
	lane string,
	sessionRevision int64,
	state core.AgentMemory,
) (bool, error) {
	if decision.SourceInput == "" || decision.ChannelID == "" || decision.Mode == "" ||
		decision.Action == "" {
		return false, errors.New("watch decision identity is incomplete")
	}
	if decision.ID == "" {
		var err error
		decision.ID, err = core.NewID("eval")
		if err != nil {
			return false, err
		}
	}
	if decision.CreatedAt.IsZero() {
		decision.CreatedAt = r.now().UTC()
	}
	// The channel's own row carries no goal. Written at the one point every
	// watch decision passes through, so a future write path cannot reintroduce
	// a thread's objective as the room's.
	if decision.ThreadTS == "" {
		state = state.WithoutThreadScope()
	}
	encodedMemory, err := json.Marshal(state)
	if err != nil {
		return false, err
	}
	if len(encodedMemory) > 64<<10 {
		return false, errors.New("channel memory exceeds 64 KiB")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	insert, err := tx.ExecContext(ctx, `
		INSERT INTO evaluation_decisions
		  (id, agent_run_id, agent_run_key, channel_id, source_input, mode, action, reason, evidence_count,
		   coverage_count, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(source_input, mode) DO UPDATE SET
		  id = excluded.id, agent_run_id = excluded.agent_run_id,
		  agent_run_key = excluded.agent_run_key, action = excluded.action,
		  reason = excluded.reason, evidence_count = excluded.evidence_count,
		  coverage_count = excluded.coverage_count, created_at = excluded.created_at
		WHERE excluded.agent_run_key != ''
		  AND evaluation_decisions.agent_run_key != excluded.agent_run_key`,
		decision.ID, decision.AgentRunID, decision.AgentRunKey,
		decision.ChannelID, decision.SourceInput, decision.Mode,
		decision.Action, decision.Reason, decision.Evidence, decision.Coverage,
		decision.CreatedAt.UTC().Format(core.TimestampFormat),
	)
	if err != nil {
		return false, err
	}
	inserted, err := insert.RowsAffected()
	if err != nil {
		return false, err
	}
	if inserted == 0 {
		return false, tx.Commit()
	}
	var before core.AgentMemory
	if string(encodedMemory) != "{}" && decision.Repository != "" && decision.MessageTS != "" {
		var beforeJSON []byte
		err := tx.QueryRowContext(ctx, `
			SELECT state_json FROM conversation_memories
			WHERE channel_id = ? AND thread_ts = ?`,
			decision.ChannelID, decision.ThreadTS,
		).Scan(&beforeJSON)
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return false, err
		case len(beforeJSON) > 0:
			if err := json.Unmarshal(beforeJSON, &before); err != nil {
				return false, fmt.Errorf("decode prior conversation memory: %w", err)
			}
		}
	}
	// Both channel-memory writes carry the same empty-state guard the
	// conversation upsert below has always had. Without it, every ignore
	// decision — which marshals its memory as '{}' — erased the channel's
	// situation on arrival: all four channel_memories rows in production read
	// '{}' while the summaries they once held sat intact one table away, and
	// the App Home introduced every channel as "no current summary".
	//
	// The compared parameter binds as a string on purpose. []byte binds as a
	// BLOB, a BLOB never equals the TEXT literal '{}', and the first version
	// of this guard silently never fired — caught by its own regression test.
	switch lane {
	case "", "investigation":
		sessionChannelID := decision.SessionChannelID
		if sessionChannelID == "" {
			sessionChannelID = decision.ChannelID
		}
		update, err := tx.ExecContext(ctx, `
			UPDATE channel_memories
			SET session_revision = ?, turn_count = turn_count + 1,
			    state_json = CASE WHEN ? = '{}' THEN state_json ELSE ? END,
			    turns_since_memory = CASE WHEN ? = '{}' THEN turns_since_memory + 1 ELSE 0 END,
			    updated_at = ?
			WHERE channel_id = ?`,
			sessionRevision, string(encodedMemory), string(encodedMemory),
			string(encodedMemory), r.nowText(), sessionChannelID,
		)
		if err := sqlutil.ExpectOne(update, err, "apply watch decision memory"); err != nil {
			return false, err
		}
		if sessionChannelID != decision.ChannelID {
			// Reset but never increment: this channel is a delivery destination
			// for a turn that ran in another channel's session, so it did not
			// spend a turn of its own to fall behind by.
			update, err = tx.ExecContext(ctx, `
				UPDATE channel_memories
				SET state_json = CASE WHEN ? = '{}' THEN state_json ELSE ? END,
				    turns_since_memory = CASE WHEN ? = '{}' THEN turns_since_memory ELSE 0 END,
				    updated_at = ?
				WHERE channel_id = ?`,
				string(encodedMemory), string(encodedMemory), string(encodedMemory),
				r.nowText(), decision.ChannelID,
			)
			if err := sqlutil.ExpectOne(update, err, "apply scheduled decision channel memory"); err != nil {
				return false, err
			}
		}
	case "conversation":
		update, err := tx.ExecContext(ctx, `
			UPDATE conversation_sessions
			SET session_revision = ?, turn_count = turn_count + 1, updated_at = ?
			WHERE channel_id = ?`,
			sessionRevision, r.nowText(), decision.ChannelID,
		)
		if err := sqlutil.ExpectOne(update, err, "apply conversation decision session"); err != nil {
			return false, err
		}
		update, err = tx.ExecContext(ctx, `
			UPDATE channel_memories
			SET state_json = CASE WHEN ? = '{}' THEN state_json ELSE ? END,
			    turns_since_memory = CASE WHEN ? = '{}' THEN turns_since_memory + 1 ELSE 0 END,
			    updated_at = ?
			WHERE channel_id = ?`,
			string(encodedMemory), string(encodedMemory), string(encodedMemory),
			r.nowText(), decision.ChannelID,
		)
		if err := sqlutil.ExpectOne(update, err, "apply conversation decision memory"); err != nil {
			return false, err
		}
	default:
		return false, errors.New("unsupported watch decision lane")
	}
	if decision.Repository != "" && decision.MessageTS != "" {
		_, err = tx.ExecContext(ctx, `
			INSERT INTO conversation_memories (
			  channel_id, thread_ts, repository, last_message_ts, state_json, updated_at
			) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(channel_id, thread_ts) DO UPDATE SET
			  repository = excluded.repository,
			  last_message_ts = excluded.last_message_ts,
			  state_json = CASE
			    WHEN excluded.state_json = '{}' THEN conversation_memories.state_json
			    ELSE excluded.state_json
			  END,
			  updated_at = excluded.updated_at`,
			decision.ChannelID,
			decision.ThreadTS,
			decision.Repository,
			decision.MessageTS,
			string(encodedMemory),
			r.nowText(),
		)
		if err != nil {
			return false, err
		}
		changes := memorydiff.AgentMemory(before, state)
		if string(encodedMemory) != "{}" && len(changes) > 0 {
			changesJSON, err := json.Marshal(changes)
			if err != nil {
				return false, err
			}
			beforeJSON, err := json.Marshal(before)
			if err != nil {
				return false, err
			}
			_, err = tx.ExecContext(ctx, `
				INSERT INTO conversation_memory_changes (
				  id, episode_id, source_input, channel_id, thread_ts, repository,
				  before_json, after_json, changes_json, created_at
				) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				decision.ID+":memory", decision.EpisodeID, decision.SourceInput,
				decision.ChannelID, decision.ThreadTS, decision.Repository,
				string(beforeJSON), string(encodedMemory), string(changesJSON),
				decision.CreatedAt.UTC().Format(core.TimestampFormat),
			)
			if err != nil {
				return false, err
			}
		}
	}
	return true, tx.Commit()
}

// ApplyHandoffMemory writes what a retiring session summarized into the channel
// memory its successor reads.
//
// Deliberately narrower than ApplyWatchDecision: by the time a handoff turn
// finishes, this row has already been rebound to the NEW session, so writing a
// session revision or counting a turn here would attribute the retiring
// session's last act to a session that has not taken a turn yet — and the
// revision is the number the next submission freezes against.
func (r *Repository) ApplyHandoffMemory(
	ctx context.Context,
	channelID string,
	state core.AgentMemory,
) error {
	encoded, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if string(encoded) == "{}" {
		return nil
	}
	if len(encoded) > 64<<10 {
		return errors.New("channel memory exceeds 64 KiB")
	}
	update, err := r.db.ExecContext(ctx, `
		UPDATE channel_memories
		SET state_json = ?, turns_since_memory = 0, updated_at = ?
		WHERE channel_id = ?`,
		string(encoded), r.nowText(), channelID,
	)
	return sqlutil.ExpectOne(update, err, "apply handed-off channel memory")
}

// RecordEvaluationDecision preserves a host-effective decision without applying
// its memory or delivery side effects. Private Slack replays use this to expose
// the same post-policy action production would take while remaining private.
func (r *Repository) RecordEvaluationDecision(
	ctx context.Context,
	decision core.EvaluationDecision,
) (bool, error) {
	if decision.SourceInput == "" || decision.ChannelID == "" || decision.Mode == "" ||
		decision.Action == "" {
		return false, errors.New("watch decision identity is incomplete")
	}
	if decision.ID == "" {
		var err error
		decision.ID, err = core.NewID("eval")
		if err != nil {
			return false, err
		}
	}
	if decision.CreatedAt.IsZero() {
		decision.CreatedAt = r.now().UTC()
	}
	result, err := r.db.ExecContext(ctx, `
		INSERT INTO evaluation_decisions
		  (id, agent_run_id, agent_run_key, channel_id, source_input, mode, action, reason, evidence_count,
		   coverage_count, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(source_input, mode) DO UPDATE SET
		  id = excluded.id, agent_run_id = excluded.agent_run_id,
		  agent_run_key = excluded.agent_run_key, action = excluded.action,
		  reason = excluded.reason, evidence_count = excluded.evidence_count,
		  coverage_count = excluded.coverage_count, created_at = excluded.created_at
		WHERE excluded.agent_run_key != ''
		  AND evaluation_decisions.agent_run_key != excluded.agent_run_key`,
		decision.ID, decision.AgentRunID, decision.AgentRunKey,
		decision.ChannelID, decision.SourceInput, decision.Mode,
		decision.Action, decision.Reason, decision.Evidence, decision.Coverage,
		decision.CreatedAt.UTC().Format(core.TimestampFormat),
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	return rows == 1, err
}

func (r *Repository) GetEvaluationDecision(
	ctx context.Context,
	sourceInput string,
	mode string,
) (core.EvaluationDecision, error) {
	var decision core.EvaluationDecision
	var createdAt string
	err := r.db.QueryRowContext(ctx, `
		SELECT id, agent_run_id, agent_run_key, channel_id, source_input, mode, action, reason,
		       evidence_count, coverage_count, created_at
		FROM evaluation_decisions
		WHERE source_input = ? AND mode = ?`, sourceInput, mode).Scan(
		&decision.ID,
		&decision.AgentRunID,
		&decision.AgentRunKey,
		&decision.ChannelID,
		&decision.SourceInput,
		&decision.Mode,
		&decision.Action,
		&decision.Reason,
		&decision.Evidence,
		&decision.Coverage,
		&createdAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EvaluationDecision{}, core.ErrNotFound
	}
	if err != nil {
		return core.EvaluationDecision{}, err
	}
	decision.CreatedAt = sqlutil.ParseTime(createdAt)
	return decision, nil
}

func (r *Repository) RecordEvidence(ctx context.Context, evidence []core.Evidence) ([]core.Evidence, error) {
	if len(evidence) > 50 {
		return nil, errors.New("one response cannot record more than 50 evidence items")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	result := make([]core.Evidence, 0, len(evidence))
	for _, item := range evidence {
		item.Claim = strings.TrimSpace(item.Claim)
		item.Observation = strings.TrimSpace(item.Observation)
		item.HealthEffect = strings.ToLower(strings.TrimSpace(item.HealthEffect))
		item.SourceType = strings.TrimSpace(item.SourceType)
		item.SourceName = strings.TrimSpace(item.SourceName)
		item.ScopeNote = strings.TrimSpace(item.ScopeNote)
		if (strings.TrimSpace(item.ClaimID) == "" && item.Claim == "") ||
			(item.Observation == "" && len(item.Dimensions) == 0) ||
			item.SourceType == "" || item.SourceName == "" {
			return nil, errors.New("evidence requires claim_id or claim, observation or dimensions, source_type, and source_name")
		}
		if item.ID == "" {
			item.ID, err = core.NewID("ev")
			if err != nil {
				return nil, err
			}
		}
		if item.CreatedAt.IsZero() {
			item.CreatedAt = r.now().UTC()
		}
		metadata, err := json.Marshal(item.Metadata)
		if err != nil {
			return nil, err
		}
		dimensions, err := json.Marshal(item.Dimensions)
		if err != nil {
			return nil, err
		}
		supersedes, err := json.Marshal(item.Supersedes)
		if err != nil {
			return nil, err
		}
		relation := strings.ToLower(strings.TrimSpace(item.Relation))
		if relation == "" {
			relation = "supports"
		}
		if relation != "supports" && relation != "contradicts" {
			return nil, fmt.Errorf("unsupported evidence relation %q", item.Relation)
		}
		item.Relation = relation
		if item.HealthEffect == "" {
			item.HealthEffect = "none"
		}
		switch item.HealthEffect {
		case "none", "risk", "degraded", "unhealthy", "unknown":
		default:
			return nil, fmt.Errorf("unsupported evidence health_effect %q", item.HealthEffect)
		}
		// INSERT OR IGNORE hides a conflict on either uniqueness key this table
		// carries: the primary key, and the partial unique index over
		// (source_input, claim, source_name, target). Only the second one means
		// "this exact evidence is already stored". The first can equally mean a
		// different source input already claimed the id.
		//
		// Models name evidence with stable slugs — evidence-plan,
		// evidence-postapply-runtime — and reuse them across episodes. While the
		// recovery lookup knew only the source key, a reused slug read back
		// nothing and returned a bare "sql: no rows in result set", which rolled
		// the whole batch back and failed finalization identically on every
		// retry. The investigation had already succeeded; the answer was
		// complete, correct, and never reached Slack, because an episode from
		// the day before owned the id.
		inserted, err := insertEvidenceTx(ctx, tx, item, dimensions, metadata, supersedes)
		if err != nil {
			return nil, err
		}
		if !inserted && item.SourceInput != "" {
			_, stored, err := storedEvidenceTx(ctx, tx, item)
			if err != nil {
				return nil, err
			}
			if !stored {
				// Nothing answers the source key, so the primary key belongs to
				// another source input and this evidence is not stored yet.
				// Deriving the id from the source makes it unique per episode
				// while still landing a retry of this turn on the same row.
				item.ID = sourceScopedEvidenceID(item.SourceInput, item.ID)
				if _, err := insertEvidenceTx(ctx, tx, item, dimensions, metadata, supersedes); err != nil {
					return nil, err
				}
			}
			existing, stored, err := storedEvidenceTx(ctx, tx, item)
			if err != nil {
				return nil, err
			}
			if !stored {
				return nil, fmt.Errorf(
					"evidence %q conflicts with a stored row that no lookup key matches",
					item.ID,
				)
			}
			item.ID, item.CreatedAt = existing.ID, existing.CreatedAt
		}
		result = append(result, item)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

// insertEvidenceTx stores one evidence row and reports whether it landed. A
// false return means some uniqueness key already holds it; which one is the
// caller's question to answer.
func insertEvidenceTx(
	ctx context.Context,
	tx *sql.Tx,
	item core.Evidence,
	dimensions, metadata, supersedes []byte,
) (bool, error) {
	insert, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO evidence
		  (id, incident_id, channel_id, source_input, claim_id, claim, observation, relation, health_effect, source_type,
		   source_id, source_name, source_url, target, scope_note, freshness, confidence, observed_at,
		   valid_until, dimensions_json, metadata_json, supersedes_json, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		item.ID, item.IncidentID, item.ChannelID, item.SourceInput, item.ClaimID, item.Claim,
		item.Observation, item.Relation, item.HealthEffect, item.SourceType, item.SourceID, item.SourceName, item.SourceURL, item.Target, item.ScopeNote,
		item.Freshness, item.Confidence, sqlutil.TimeText(item.ObservedAt), sqlutil.TimeText(item.ValidUntil), dimensions, metadata, supersedes,
		item.CreatedAt.UTC().Format(core.TimestampFormat),
	)
	if err != nil {
		return false, err
	}
	rows, err := insert.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, nil
}

// storedEvidenceTx reads the row the source uniqueness index dedupes against,
// which is the only key that means the same evidence was recorded before.
func storedEvidenceTx(
	ctx context.Context,
	tx *sql.Tx,
	item core.Evidence,
) (core.Evidence, bool, error) {
	var existing core.Evidence
	var created string
	err := tx.QueryRowContext(ctx, `
		SELECT id, created_at FROM evidence
		WHERE source_input = ? AND claim = ? AND source_name = ? AND target = ?`,
		item.SourceInput, item.Claim, item.SourceName, item.Target,
	).Scan(&existing.ID, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return core.Evidence{}, false, nil
	}
	if err != nil {
		return core.Evidence{}, false, err
	}
	existing.CreatedAt = sqlutil.ParseTime(created)
	return existing, true, nil
}

// sourceScopedEvidenceID rebuilds an id that another source input already owns.
// It is derived rather than random so that replaying the same turn resolves to
// the same row instead of accumulating one per attempt.
func sourceScopedEvidenceID(sourceInput, id string) string {
	digest := sha256.Sum256([]byte(strings.Join([]string{sourceInput, id}, "\x00")))
	return "ev_" + hex.EncodeToString(digest[:16])
}

func (r *Repository) RecordCoverage(ctx context.Context, coverage []core.Coverage) error {
	if len(coverage) > 30 {
		return errors.New("one response cannot record more than 30 coverage items")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, item := range coverage {
		item.Layer = strings.TrimSpace(item.Layer)
		item.Status = strings.TrimSpace(item.Status)
		if item.Layer == "" || item.Status == "" {
			return errors.New("coverage requires layer and status")
		}
		if item.ID == "" {
			item.ID, err = core.NewID("cov")
			if err != nil {
				return err
			}
		}
		if item.CreatedAt.IsZero() {
			item.CreatedAt = r.now().UTC()
		}
		claimIDs, err := json.Marshal(item.ClaimIDs)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO coverage
			  (id, incident_id, channel_id, source_input, layer, status, source, detail,
			   observed_at, claim_ids_json, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			item.ID, item.IncidentID, item.ChannelID, item.SourceInput, item.Layer,
			item.Status, item.Source, item.Detail, sqlutil.TimeText(item.ObservedAt),
			claimIDs,
			item.CreatedAt.UTC().Format(core.TimestampFormat),
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (r *Repository) ListEvidence(
	ctx context.Context,
	incidentID string,
	channelID string,
	limit int,
) ([]core.Evidence, error) {
	if limit < 1 || limit > 200 {
		return nil, errors.New("evidence limit must be between 1 and 200")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, incident_id, channel_id, source_input, claim_id, claim, observation, relation, health_effect, source_type,
		  source_id, source_name, source_url, target, scope_note, freshness, confidence, observed_at, valid_until,
		  dimensions_json, metadata_json, supersedes_json, created_at
		FROM evidence
		WHERE (? != '' AND incident_id = ?) OR (? = '' AND channel_id = ?)
		ORDER BY created_at DESC LIMIT ?`,
		incidentID, incidentID, incidentID, channelID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Evidence
	for rows.Next() {
		var item core.Evidence
		var observed, validUntil sql.NullString
		var dimensions, metadata, supersedes []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput, &item.ClaimID, &item.Claim,
			&item.Observation, &item.Relation, &item.HealthEffect, &item.SourceType, &item.SourceID, &item.SourceName, &item.SourceURL,
			&item.Target, &item.ScopeNote, &item.Freshness, &item.Confidence, &observed, &validUntil,
			&dimensions, &metadata, &supersedes, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(dimensions, &item.Dimensions); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(metadata, &item.Metadata); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(supersedes, &item.Supersedes); err != nil {
			return nil, err
		}
		item.ObservedAt = sqlutil.ScanTime(observed)
		item.ValidUntil = sqlutil.ScanTime(validUntil)
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (r *Repository) ListCoverage(
	ctx context.Context,
	incidentID string,
	channelID string,
	limit int,
) ([]core.Coverage, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("coverage limit must be between 1 and 100")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, incident_id, channel_id, source_input, layer, status, source, detail,
		  observed_at, claim_ids_json, created_at
		FROM coverage
		WHERE (? != '' AND incident_id = ?) OR (? = '' AND channel_id = ?)
		ORDER BY created_at DESC LIMIT ?`,
		incidentID, incidentID, incidentID, channelID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Coverage
	for rows.Next() {
		var item core.Coverage
		var observed sql.NullString
		var claimIDs []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput, &item.Layer,
			&item.Status, &item.Source, &item.Detail, &observed, &claimIDs, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(claimIDs, &item.ClaimIDs); err != nil {
			return nil, err
		}
		item.ObservedAt = sqlutil.ScanTime(observed)
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

// SummarizeIncidentEvidence is what a card says about findings so far: how
// many claims the work has recorded, and the most recent one.
//
// The card needs both and needs them consistent, so they come from one
// statement. ListEvidence would answer this by returning up to two hundred
// full rows — dimensions, metadata and all — to render one sentence and a
// number, on a card that rewrites itself every fifteen seconds.
//
// The claim is stored as it was written at recording time and is returned
// unchanged: re-summarizing model text on every refresh would let a finding
// drift without anything having been found.
func (r *Repository) SummarizeIncidentEvidence(
	ctx context.Context,
	incidentID string,
) (core.IncidentEvidence, error) {
	var summary core.IncidentEvidence
	if strings.TrimSpace(incidentID) == "" {
		return summary, nil
	}
	// created_at then id, because evidence is recorded in batches that share a
	// timestamp and the tie has to break the same way twice or the card's
	// "Found so far" would alternate between two claims on consecutive edits.
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*), COALESCE((
		  SELECT claim FROM evidence WHERE incident_id = ?
		  ORDER BY created_at DESC, id DESC LIMIT 1
		), '')
		FROM evidence WHERE incident_id = ?`,
		incidentID, incidentID,
	).Scan(&summary.Count, &summary.Claim)
	if errors.Is(err, sql.ErrNoRows) {
		return core.IncidentEvidence{}, nil
	}
	return summary, err
}

// ListEpisodeEvidence returns evidence recorded by this episode and its
// correlation ancestry. Related alert updates are separate immutable episodes,
// but they reason over one accumulated claim ledger instead of repeatedly
// rediscovering (and contradicting) the same incident.
func (r *Repository) ListEpisodeEvidence(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]core.Evidence, error) {
	if strings.TrimSpace(episodeID) == "" || limit < 1 || limit > 200 {
		return nil, errors.New("episode evidence requires an episode and limit from 1 to 200")
	}
	rows, err := r.db.QueryContext(ctx, `
		WITH RECURSIVE episode_chain(id, parent_episode_id, depth) AS (
		  SELECT id, parent_episode_id, 0 FROM work_episodes WHERE id = ?
		  UNION ALL
		  SELECT episode.id, episode.parent_episode_id, child.depth + 1
		  FROM work_episodes AS episode
		  JOIN episode_chain AS child ON episode.id = child.parent_episode_id
		  WHERE child.depth < 49
		), source_inputs(id) AS (
		  SELECT source_id FROM agent_runs
		  WHERE episode_id IN (SELECT id FROM episode_chain)
		), incident_ids(id) AS (
		  -- Evidence recorded during an incident investigation is keyed by the
		  -- incident, not by the Slack input that started it, so matching on
		  -- source_input alone made an escalated episode's own findings
		  -- invisible to it. Incident scope is the right width here: the doc
		  -- above says correlated episodes exist to share one claim ledger
		  -- "instead of repeatedly rediscovering (and contradicting) the same
		  -- incident", and everything under one incident is that incident.
		  SELECT DISTINCT incident_id FROM agent_runs
		  WHERE episode_id IN (SELECT id FROM episode_chain)
		    AND incident_id IS NOT NULL AND incident_id != ''
		)
		SELECT id, incident_id, channel_id, source_input, claim_id, claim, observation,
		  relation, health_effect, source_type, source_id, source_name, source_url,
		  target, scope_note, freshness, confidence, observed_at, valid_until,
		  dimensions_json, metadata_json, supersedes_json, created_at
		FROM evidence
		WHERE source_input IN (SELECT id FROM source_inputs)
		   OR incident_id IN (SELECT id FROM incident_ids)
		ORDER BY created_at DESC, id DESC LIMIT ?`, episodeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.Evidence, 0, limit)
	for rows.Next() {
		var item core.Evidence
		var observed, validUntil sql.NullString
		var dimensions, metadata, supersedes []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput,
			&item.ClaimID, &item.Claim, &item.Observation, &item.Relation,
			&item.HealthEffect, &item.SourceType, &item.SourceID, &item.SourceName,
			&item.SourceURL, &item.Target, &item.ScopeNote, &item.Freshness,
			&item.Confidence, &observed, &validUntil, &dimensions, &metadata,
			&supersedes, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(dimensions, &item.Dimensions); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(metadata, &item.Metadata); err != nil {
			return nil, err
		}
		// The retirement has to survive the turn that declared it: the round
		// that quotes a conflict reads this list, not the model's last answer.
		if err := json.Unmarshal(supersedes, &item.Supersedes); err != nil {
			return nil, err
		}
		item.ObservedAt = sqlutil.ScanTime(observed)
		item.ValidUntil = sqlutil.ScanTime(validUntil)
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (r *Repository) ListEpisodeCoverage(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]core.Coverage, error) {
	if strings.TrimSpace(episodeID) == "" || limit < 1 || limit > 200 {
		return nil, errors.New("episode coverage requires an episode and limit from 1 to 200")
	}
	rows, err := r.db.QueryContext(ctx, `
		WITH RECURSIVE episode_chain(id, parent_episode_id, depth) AS (
		  SELECT id, parent_episode_id, 0 FROM work_episodes WHERE id = ?
		  UNION ALL
		  SELECT episode.id, episode.parent_episode_id, child.depth + 1
		  FROM work_episodes AS episode
		  JOIN episode_chain AS child ON episode.id = child.parent_episode_id
		  WHERE child.depth < 49
		), source_inputs(id) AS (
		  SELECT source_id FROM agent_runs
		  WHERE episode_id IN (SELECT id FROM episode_chain)
		), incident_ids(id) AS (
		  -- Evidence recorded during an incident investigation is keyed by the
		  -- incident, not by the Slack input that started it, so matching on
		  -- source_input alone made an escalated episode's own findings
		  -- invisible to it. Incident scope is the right width here: the doc
		  -- above says correlated episodes exist to share one claim ledger
		  -- "instead of repeatedly rediscovering (and contradicting) the same
		  -- incident", and everything under one incident is that incident.
		  SELECT DISTINCT incident_id FROM agent_runs
		  WHERE episode_id IN (SELECT id FROM episode_chain)
		    AND incident_id IS NOT NULL AND incident_id != ''
		)
		SELECT id, incident_id, channel_id, source_input, layer, status, source,
		  detail, observed_at, claim_ids_json, created_at
		FROM coverage
		WHERE source_input IN (SELECT id FROM source_inputs)
		   OR incident_id IN (SELECT id FROM incident_ids)
		ORDER BY created_at DESC, id DESC LIMIT ?`, episodeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.Coverage, 0, limit)
	for rows.Next() {
		var item core.Coverage
		var observed sql.NullString
		var claimIDs []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput,
			&item.Layer, &item.Status, &item.Source, &item.Detail, &observed,
			&claimIDs, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(claimIDs, &item.ClaimIDs); err != nil {
			return nil, err
		}
		item.ObservedAt = sqlutil.ScanTime(observed)
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (r *Repository) RecordClaimAssessments(ctx context.Context, items []core.ClaimAssessment) error {
	if len(items) > 50 {
		return errors.New("one episode cannot record more than 50 claim assessments")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, item := range items {
		if strings.TrimSpace(item.EpisodeID) == "" || strings.TrimSpace(item.ClaimID) == "" {
			return errors.New("claim assessment requires episode_id and claim_id")
		}
		switch item.Status {
		case "supported", "contradicted", "mixed", "unknown", "not_applicable":
		default:
			return fmt.Errorf("unsupported claim assessment status %q", item.Status)
		}
		if item.ID == "" {
			item.ID, err = core.NewID("claim")
			if err != nil {
				return err
			}
		}
		evidenceIDs, marshalErr := json.Marshal(item.EvidenceIDs)
		if marshalErr != nil {
			return marshalErr
		}
		contradictions, marshalErr := json.Marshal(item.ContradictionIDs)
		if marshalErr != nil {
			return marshalErr
		}
		updated := item.UpdatedAt
		if updated.IsZero() {
			updated = r.now().UTC()
		}
		_, err = tx.ExecContext(ctx, `
			INSERT INTO claim_assessments
			  (id, episode_id, claim_id, status, confidence, evidence_ids_json,
			   contradiction_ids_json, detail, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(episode_id, claim_id) DO UPDATE SET
			  status = excluded.status,
			  confidence = excluded.confidence,
			  evidence_ids_json = excluded.evidence_ids_json,
			  contradiction_ids_json = excluded.contradiction_ids_json,
			  detail = excluded.detail,
			  updated_at = excluded.updated_at`,
			item.ID, item.EpisodeID, item.ClaimID, item.Status, item.Confidence,
			evidenceIDs, contradictions, item.Detail, updated.UTC().Format(core.TimestampFormat),
		)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (r *Repository) RecordTimeline(ctx context.Context, event core.TimelineEvent) error {
	event.Title = strings.TrimSpace(event.Title)
	if event.Title == "" || event.Kind == "" {
		return errors.New("timeline event requires kind and title")
	}
	if event.ID == "" {
		var err error
		event.ID, err = core.NewID("tl")
		if err != nil {
			return err
		}
	}
	if event.CreatedAt.IsZero() {
		event.CreatedAt = r.now().UTC()
	}
	evidence, err := json.Marshal(event.EvidenceIDs)
	if err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO timeline_events
		  (id, incident_id, channel_id, kind, actor_id, title, detail,
		   evidence_ids_json, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ID, event.IncidentID, event.ChannelID, event.Kind, event.ActorID,
		event.Title, event.Detail, evidence, event.CreatedAt.UTC().Format(core.TimestampFormat),
	)
	return err
}

func (r *Repository) ListTimeline(
	ctx context.Context,
	incidentID string,
	channelID string,
	limit int,
) ([]core.TimelineEvent, error) {
	if limit < 1 || limit > 500 {
		return nil, errors.New("timeline limit must be between 1 and 500")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, incident_id, channel_id, kind, actor_id, title, detail,
		  evidence_ids_json, created_at
		FROM timeline_events
		WHERE (? != '' AND incident_id = ?) OR (? = '' AND channel_id = ?)
		ORDER BY created_at DESC LIMIT ?`,
		incidentID, incidentID, incidentID, channelID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.TimelineEvent
	for rows.Next() {
		var item core.TimelineEvent
		var evidence []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.Kind, &item.ActorID,
			&item.Title, &item.Detail, &evidence, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(evidence, &item.EvidenceIDs); err != nil {
			return nil, err
		}
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

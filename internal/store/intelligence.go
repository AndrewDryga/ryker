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

func (s *Store) GetChannelMemory(ctx context.Context, channelID string) (core.ChannelMemory, error) {
	var memory core.ChannelMemory
	var state []byte
	var started, rotated sql.NullString
	var updated string
	err := s.db.QueryRowContext(ctx, `
			SELECT channel_id, repository, session_id, session_revision, generation, turn_count,
			  coop_event_sequence, state_json, session_started_at, rotated_at, updated_at
			FROM channel_memories WHERE channel_id = ?`, channelID).Scan(
		&memory.ChannelID, &memory.Repository, &memory.SessionID, &memory.SessionRevision,
		&memory.Generation, &memory.TurnCount, &memory.CoopEventSequence,
		&state, &started, &rotated, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ChannelMemory{}, ErrNotFound
	}
	if err != nil {
		return core.ChannelMemory{}, err
	}
	if err := json.Unmarshal(state, &memory.State); err != nil {
		return core.ChannelMemory{}, fmt.Errorf("decode channel memory: %w", err)
	}
	memory.SessionStarted = scanTime(started)
	memory.RotatedAt = scanTime(rotated)
	memory.UpdatedAt = parseTime(updated)
	return memory, nil
}

func (s *Store) ListChannelSituations(
	ctx context.Context,
	limit int,
) ([]core.ChannelMemory, error) {
	if limit < 1 {
		limit = 8
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT channel_id, repository, session_id, session_revision, generation, turn_count,
		  coop_event_sequence, state_json, session_started_at, rotated_at, updated_at
		FROM channel_memories
		WHERE state_json != '{}' AND state_json != ''
		  AND channel_id NOT LIKE 'scheduled:%'
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
		memory.SessionStarted = scanTime(started)
		memory.RotatedAt = scanTime(rotated)
		memory.UpdatedAt = parseTime(updated)
		result = append(result, memory)
	}
	return result, rows.Err()
}

func (s *Store) GetConversationMemory(
	ctx context.Context,
	channelID string,
	threadTS string,
) (core.ConversationMemory, error) {
	var memory core.ConversationMemory
	var state []byte
	var updated string
	err := s.db.QueryRowContext(ctx, `
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
		return core.ConversationMemory{}, ErrNotFound
	}
	if err != nil {
		return core.ConversationMemory{}, err
	}
	if err := json.Unmarshal(state, &memory.State); err != nil {
		return core.ConversationMemory{}, fmt.Errorf("decode conversation memory: %w", err)
	}
	memory.UpdatedAt = parseTime(updated)
	return memory, nil
}

func (s *Store) ListRelatedConversationMemories(
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
	rows, err := s.db.QueryContext(ctx, `
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
		memory.UpdatedAt = parseTime(updated)
		result = append(result, memory)
	}
	return result, rows.Err()
}

func (s *Store) DeleteConversationMemories(
	ctx context.Context,
	channelID string,
) (int64, error) {
	if channelID == "" {
		return 0, errors.New("conversation memory channel is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `DELETE FROM conversation_memories WHERE channel_id = ?`, channelID)
	if err != nil {
		return 0, err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	result, err = tx.ExecContext(ctx, `
		DELETE FROM memory_rollups WHERE scope_kind = 'channel' AND scope_key = ?`, channelID)
	if err != nil {
		return 0, err
	}
	rollups, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deleted + rollups, nil
}

func (s *Store) BindChannelSession(
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
		started = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO channel_memories
		  (channel_id, repository, session_id, session_revision, generation, turn_count,
		   state_json, session_started_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 0, '{}', ?, ?)
			ON CONFLICT(channel_id) DO UPDATE SET
		  repository = excluded.repository,
		  session_id = excluded.session_id,
		  session_revision = excluded.session_revision,
			  generation = excluded.generation,
			  turn_count = 0,
			  coop_event_sequence = 0,
		  session_started_at = excluded.session_started_at,
		  rotated_at = channel_memories.updated_at,
		  updated_at = excluded.updated_at`,
		channelID, repository, sessionID, revision, generation,
		started.UTC().Format(timestampFormat), nowText(),
	)
	return err
}

func (s *Store) EnsureChannelMemory(
	ctx context.Context,
	channelID string,
	repository string,
) error {
	if channelID == "" || repository == "" {
		return errors.New("channel memory identity is incomplete")
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO channel_memories (
		  channel_id, repository, session_id, session_revision, generation,
		  turn_count, state_json, updated_at
		) VALUES (?, ?, '', 0, 1, 0, '{}', ?)
		ON CONFLICT(channel_id) DO NOTHING`,
		channelID, repository, nowText(),
	)
	return err
}

func (s *Store) DetachChannelSession(
	ctx context.Context,
	channelID string,
	sessionID string,
) (bool, error) {
	if channelID == "" || sessionID == "" {
		return false, errors.New("channel session detachment identity is incomplete")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE channel_memories
			SET session_id = '',
			    session_revision = 0,
			    coop_event_sequence = 0,
		    turn_count = 0,
		    session_started_at = NULL,
		    rotated_at = updated_at,
		    updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		nowText(), channelID, sessionID,
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

func (s *Store) AdvanceChannelMemory(
	ctx context.Context,
	channelID string,
	sessionRevision int64,
	state core.AgentMemory,
) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if len(data) > 64<<10 {
		return errors.New("channel memory exceeds 64 KiB")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE channel_memories
		SET session_revision = ?, turn_count = turn_count + 1, state_json = ?, updated_at = ?
		WHERE channel_id = ?`,
		sessionRevision, data, nowText(), channelID,
	)
	return expectOne(result, err, "advance channel memory")
}

func (s *Store) AdvanceChannelEvents(
	ctx context.Context,
	channelID string,
	sessionID string,
	sequence int64,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE channel_memories
		SET coop_event_sequence = MAX(coop_event_sequence, ?), updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		sequence, nowText(), channelID, sessionID)
	return expectOne(result, err, "advance channel Coop events")
}

func (s *Store) ApplyWatchDecision(
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
		decision.CreatedAt = time.Now().UTC()
	}
	memory, err := json.Marshal(state)
	if err != nil {
		return false, err
	}
	if len(memory) > 64<<10 {
		return false, errors.New("channel memory exceeds 64 KiB")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	insert, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO evaluation_decisions
		  (id, channel_id, source_input, mode, action, reason, evidence_count,
		   coverage_count, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		decision.ID, decision.ChannelID, decision.SourceInput, decision.Mode,
		decision.Action, decision.Reason, decision.Evidence, decision.Coverage,
		decision.CreatedAt.UTC().Format(timestampFormat),
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
	switch lane {
	case "", "investigation":
		sessionChannelID := decision.SessionChannelID
		if sessionChannelID == "" {
			sessionChannelID = decision.ChannelID
		}
		update, err := tx.ExecContext(ctx, `
			UPDATE channel_memories
			SET session_revision = ?, turn_count = turn_count + 1,
			    state_json = ?, updated_at = ?
			WHERE channel_id = ?`,
			sessionRevision, memory, nowText(), sessionChannelID,
		)
		if err := expectOne(update, err, "apply watch decision memory"); err != nil {
			return false, err
		}
		if sessionChannelID != decision.ChannelID {
			update, err = tx.ExecContext(ctx, `
				UPDATE channel_memories
				SET state_json = ?, updated_at = ?
				WHERE channel_id = ?`,
				memory, nowText(), decision.ChannelID,
			)
			if err := expectOne(update, err, "apply scheduled decision channel memory"); err != nil {
				return false, err
			}
		}
	case "conversation":
		update, err := tx.ExecContext(ctx, `
			UPDATE conversation_sessions
			SET session_revision = ?, turn_count = turn_count + 1, updated_at = ?
			WHERE channel_id = ?`,
			sessionRevision, nowText(), decision.ChannelID,
		)
		if err := expectOne(update, err, "apply conversation decision session"); err != nil {
			return false, err
		}
		update, err = tx.ExecContext(ctx, `
			UPDATE channel_memories
			SET state_json = ?, updated_at = ?
			WHERE channel_id = ?`,
			memory, nowText(), decision.ChannelID,
		)
		if err := expectOne(update, err, "apply conversation decision memory"); err != nil {
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
			string(memory),
			nowText(),
		)
		if err != nil {
			return false, err
		}
	}
	return true, tx.Commit()
}

func (s *Store) RecordEvidence(ctx context.Context, evidence []core.Evidence) ([]core.Evidence, error) {
	if len(evidence) > 50 {
		return nil, errors.New("one response cannot record more than 50 evidence items")
	}
	tx, err := s.db.BeginTx(ctx, nil)
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
			item.CreatedAt = time.Now().UTC()
		}
		metadata, err := json.Marshal(item.Metadata)
		if err != nil {
			return nil, err
		}
		dimensions, err := json.Marshal(item.Dimensions)
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
		insert, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO evidence
			  (id, incident_id, channel_id, source_input, claim_id, claim, observation, relation, health_effect, source_type,
			   source_id, source_name, source_url, target, scope_note, freshness, confidence, observed_at,
			   valid_until, dimensions_json, metadata_json, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			item.ID, item.IncidentID, item.ChannelID, item.SourceInput, item.ClaimID, item.Claim,
			item.Observation, item.Relation, item.HealthEffect, item.SourceType, item.SourceID, item.SourceName, item.SourceURL, item.Target, item.ScopeNote,
			item.Freshness, item.Confidence, timeText(item.ObservedAt), timeText(item.ValidUntil), dimensions, metadata,
			item.CreatedAt.UTC().Format(timestampFormat),
		)
		if err != nil {
			return nil, err
		}
		rows, err := insert.RowsAffected()
		if err != nil {
			return nil, err
		}
		if rows == 0 && item.SourceInput != "" {
			var created string
			if err := tx.QueryRowContext(ctx, `
				SELECT id, created_at FROM evidence
				WHERE source_input = ? AND claim = ? AND source_name = ? AND target = ?`,
				item.SourceInput, item.Claim, item.SourceName, item.Target,
			).Scan(&item.ID, &created); err != nil {
				return nil, err
			}
			item.CreatedAt = parseTime(created)
		}
		result = append(result, item)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Store) RecordCoverage(ctx context.Context, coverage []core.Coverage) error {
	if len(coverage) > 30 {
		return errors.New("one response cannot record more than 30 coverage items")
	}
	tx, err := s.db.BeginTx(ctx, nil)
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
			item.CreatedAt = time.Now().UTC()
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
			item.Status, item.Source, item.Detail, timeText(item.ObservedAt),
			claimIDs,
			item.CreatedAt.UTC().Format(timestampFormat),
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) ListEvidence(
	ctx context.Context,
	incidentID string,
	channelID string,
	limit int,
) ([]core.Evidence, error) {
	if limit < 1 || limit > 200 {
		return nil, errors.New("evidence limit must be between 1 and 200")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, incident_id, channel_id, source_input, claim_id, claim, observation, relation, health_effect, source_type,
		  source_id, source_name, source_url, target, scope_note, freshness, confidence, observed_at, valid_until,
		  dimensions_json, metadata_json, created_at
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
		var dimensions, metadata []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput, &item.ClaimID, &item.Claim,
			&item.Observation, &item.Relation, &item.HealthEffect, &item.SourceType, &item.SourceID, &item.SourceName, &item.SourceURL,
			&item.Target, &item.ScopeNote, &item.Freshness, &item.Confidence, &observed, &validUntil,
			&dimensions, &metadata, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(dimensions, &item.Dimensions); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(metadata, &item.Metadata); err != nil {
			return nil, err
		}
		item.ObservedAt = scanTime(observed)
		item.ValidUntil = scanTime(validUntil)
		item.CreatedAt = parseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) ListCoverage(
	ctx context.Context,
	incidentID string,
	channelID string,
	limit int,
) ([]core.Coverage, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("coverage limit must be between 1 and 100")
	}
	rows, err := s.db.QueryContext(ctx, `
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
		item.ObservedAt = scanTime(observed)
		item.CreatedAt = parseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) RecordClaimAssessments(ctx context.Context, items []core.ClaimAssessment) error {
	if len(items) > 50 {
		return errors.New("one episode cannot record more than 50 claim assessments")
	}
	tx, err := s.db.BeginTx(ctx, nil)
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
			updated = time.Now().UTC()
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
			evidenceIDs, contradictions, item.Detail, updated.UTC().Format(timestampFormat),
		)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) ListClaimAssessments(ctx context.Context, episodeID string) ([]core.ClaimAssessment, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, episode_id, claim_id, status, confidence, evidence_ids_json,
		  contradiction_ids_json, detail, updated_at
		FROM claim_assessments WHERE episode_id = ? ORDER BY claim_id`, episodeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.ClaimAssessment
	for rows.Next() {
		var item core.ClaimAssessment
		var evidenceIDs, contradictions []byte
		var updated string
		if err := rows.Scan(&item.ID, &item.EpisodeID, &item.ClaimID, &item.Status,
			&item.Confidence, &evidenceIDs, &contradictions, &item.Detail, &updated); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(evidenceIDs, &item.EvidenceIDs); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(contradictions, &item.ContradictionIDs); err != nil {
			return nil, err
		}
		item.UpdatedAt = parseTime(updated)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) RecordTimeline(ctx context.Context, event core.TimelineEvent) error {
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
		event.CreatedAt = time.Now().UTC()
	}
	evidence, err := json.Marshal(event.EvidenceIDs)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO timeline_events
		  (id, incident_id, channel_id, kind, actor_id, title, detail,
		   evidence_ids_json, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ID, event.IncidentID, event.ChannelID, event.Kind, event.ActorID,
		event.Title, event.Detail, evidence, event.CreatedAt.UTC().Format(timestampFormat),
	)
	return err
}

func (s *Store) ListTimeline(
	ctx context.Context,
	incidentID string,
	channelID string,
	limit int,
) ([]core.TimelineEvent, error) {
	if limit < 1 || limit > 500 {
		return nil, errors.New("timeline limit must be between 1 and 500")
	}
	rows, err := s.db.QueryContext(ctx, `
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
		item.CreatedAt = parseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) CreateActionProposals(
	ctx context.Context,
	proposals []core.ActionProposal,
) ([]core.ActionProposal, error) {
	if len(proposals) > 10 {
		return nil, errors.New("one response cannot propose more than 10 actions")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	result := make([]core.ActionProposal, 0, len(proposals))
	for _, proposal := range proposals {
		if proposal.ID == "" {
			proposal.ID, err = core.NewID("act")
			if err != nil {
				return nil, err
			}
		}
		if proposal.ActionName == "" || proposal.Title == "" || proposal.Target == "" ||
			proposal.BlastRadius == "" || proposal.Rollback == "" ||
			proposal.Verification == "" || proposal.Authority == "" {
			return nil, errors.New("action proposal is incomplete")
		}
		if proposal.Required < 1 || proposal.Required > 2 {
			return nil, errors.New("action proposal requires one or two approvals")
		}
		now := time.Now().UTC()
		if proposal.CreatedAt.IsZero() {
			proposal.CreatedAt = now
		}
		if proposal.ExpiresAt.IsZero() || !proposal.ExpiresAt.After(now) {
			return nil, errors.New("action proposal expiration must be in the future")
		}
		proposal.Status = "pending"
		proposal.UpdatedAt = now
		parameters, err := json.Marshal(proposal.Parameters)
		if err != nil {
			return nil, err
		}
		insert, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO action_proposals
			  (id, incident_id, channel_id, source_input, action_name, title, summary, target,
			   parameters_json, blast_radius, rollback, verification, authority, risk, status,
			   required_approvals, requested_by, execution_turn, result, expires_at, created_at,
			   updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, '', '', ?, ?, ?)`,
			proposal.ID, proposal.IncidentID, proposal.ChannelID, proposal.SourceInput,
			proposal.ActionName, proposal.Title, proposal.Summary, proposal.Target, parameters,
			proposal.BlastRadius, proposal.Rollback, proposal.Verification, proposal.Authority,
			proposal.Risk, proposal.Required, proposal.RequestedBy,
			proposal.ExpiresAt.UTC().Format(timestampFormat),
			proposal.CreatedAt.UTC().Format(timestampFormat), nowText(),
		)
		if err != nil {
			return nil, err
		}
		rows, err := insert.RowsAffected()
		if err != nil {
			return nil, err
		}
		if rows == 1 {
			result = append(result, proposal)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Store) GetActionProposal(ctx context.Context, id string) (core.ActionProposal, error) {
	return scanActionProposal(s.db.QueryRowContext(ctx, `
		SELECT p.id, p.incident_id, p.channel_id, p.source_input, p.action_name, p.title,
		  p.summary, p.target, p.parameters_json, p.blast_radius, p.rollback,
		  p.verification, p.authority, p.risk, p.status, p.required_approvals,
		  (SELECT count(*) FROM proposal_approvals a
		   WHERE a.proposal_id = p.id AND a.decision = 'approve'),
		  p.requested_by, p.execution_turn, p.result, p.expires_at, p.created_at, p.updated_at
		FROM action_proposals p WHERE p.id = ?`, id))
}

func (s *Store) ListActionProposalsForIncident(
	ctx context.Context,
	incidentID string,
) ([]core.ActionProposal, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT p.id, p.incident_id, p.channel_id, p.source_input, p.action_name, p.title,
		  p.summary, p.target, p.parameters_json, p.blast_radius, p.rollback,
		  p.verification, p.authority, p.risk, p.status, p.required_approvals,
		  (SELECT count(*) FROM proposal_approvals a
		   WHERE a.proposal_id = p.id AND a.decision = 'approve'),
		  p.requested_by, p.execution_turn, p.result, p.expires_at, p.created_at, p.updated_at
		FROM action_proposals p WHERE p.incident_id = ?
		ORDER BY p.created_at, p.id`, incidentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]core.ActionProposal, 0)
	for rows.Next() {
		item, err := scanActionProposal(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func scanActionProposal(row interface{ Scan(...any) error }) (core.ActionProposal, error) {
	var proposal core.ActionProposal
	var parameters []byte
	var expires, created, updated string
	err := row.Scan(
		&proposal.ID, &proposal.IncidentID, &proposal.ChannelID, &proposal.SourceInput,
		&proposal.ActionName, &proposal.Title, &proposal.Summary, &proposal.Target,
		&parameters, &proposal.BlastRadius, &proposal.Rollback, &proposal.Verification,
		&proposal.Authority, &proposal.Risk, &proposal.Status, &proposal.Required,
		&proposal.ApprovalCount, &proposal.RequestedBy, &proposal.ExecutionTurn,
		&proposal.Result, &expires, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ActionProposal{}, ErrNotFound
	}
	if err != nil {
		return core.ActionProposal{}, err
	}
	if err := json.Unmarshal(parameters, &proposal.Parameters); err != nil {
		return core.ActionProposal{}, err
	}
	proposal.ExpiresAt = parseTime(expires)
	proposal.CreatedAt = parseTime(created)
	proposal.UpdatedAt = parseTime(updated)
	return proposal, nil
}

func (s *Store) DecideActionProposal(
	ctx context.Context,
	id string,
	actorID string,
	decision string,
	now time.Time,
) (core.ActionProposal, error) {
	if actorID == "" || (decision != "approve" && decision != "reject") {
		return core.ActionProposal{}, errors.New("proposal decision is invalid")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.ActionProposal{}, err
	}
	defer tx.Rollback()
	proposal, err := scanActionProposal(tx.QueryRowContext(ctx, `
		SELECT p.id, p.incident_id, p.channel_id, p.source_input, p.action_name, p.title,
		  p.summary, p.target, p.parameters_json, p.blast_radius, p.rollback,
		  p.verification, p.authority, p.risk, p.status, p.required_approvals,
		  (SELECT count(*) FROM proposal_approvals a
		   WHERE a.proposal_id = p.id AND a.decision = 'approve'),
		  p.requested_by, p.execution_turn, p.result, p.expires_at, p.created_at, p.updated_at
		FROM action_proposals p WHERE p.id = ?`, id))
	if err != nil {
		return core.ActionProposal{}, err
	}
	if now.After(proposal.ExpiresAt) && proposal.Status == "pending" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE action_proposals SET status = 'expired', updated_at = ?
			WHERE id = ? AND status = 'pending'`, nowText(), id); err != nil {
			return core.ActionProposal{}, err
		}
		if err := tx.Commit(); err != nil {
			return core.ActionProposal{}, err
		}
		proposal.Status = "expired"
		return proposal, nil
	}
	if proposal.Status != "pending" {
		return proposal, tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO proposal_approvals
		  (proposal_id, actor_id, decision, created_at)
		VALUES (?, ?, ?, ?)`,
		id, actorID, decision, now.UTC().Format(timestampFormat),
	); err != nil {
		return core.ActionProposal{}, err
	}
	status := "pending"
	if decision == "reject" {
		status = "rejected"
	} else {
		var approvals int
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM proposal_approvals
			WHERE proposal_id = ? AND decision = 'approve'`, id).Scan(&approvals); err != nil {
			return core.ActionProposal{}, err
		}
		proposal.ApprovalCount = approvals
		if approvals >= proposal.Required {
			status = "approved"
		}
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE action_proposals SET status = ?, updated_at = ? WHERE id = ?`,
		status, nowText(), id,
	); err != nil {
		return core.ActionProposal{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.ActionProposal{}, err
	}
	proposal.Status = status
	return proposal, nil
}

func (s *Store) MarkProposalExecution(
	ctx context.Context,
	id string,
	status string,
	turnID string,
	result string,
) error {
	if status != "executing" && status != "finished" && status != "failed" {
		return errors.New("invalid proposal execution state")
	}
	update, err := s.db.ExecContext(ctx, `
		UPDATE action_proposals
		SET status = ?, execution_turn = CASE WHEN ? != '' THEN ? ELSE execution_turn END,
		  result = ?, updated_at = ?
		WHERE id = ? AND status IN ('approved', 'executing')`,
		status, turnID, turnID, boundedError(result), nowText(), id,
	)
	return expectOne(update, err, "mark proposal execution")
}

func (s *Store) RecordEvaluation(ctx context.Context, decision core.EvaluationDecision) error {
	if decision.ID == "" {
		var err error
		decision.ID, err = core.NewID("eval")
		if err != nil {
			return err
		}
	}
	if decision.CreatedAt.IsZero() {
		decision.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO evaluation_decisions
		  (id, channel_id, source_input, mode, action, reason, evidence_count,
		   coverage_count, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		decision.ID, decision.ChannelID, decision.SourceInput, decision.Mode,
		decision.Action, decision.Reason, decision.Evidence, decision.Coverage,
		decision.CreatedAt.UTC().Format(timestampFormat),
	)
	return err
}

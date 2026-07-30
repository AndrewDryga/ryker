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
	update, err := tx.ExecContext(ctx, `
		UPDATE channel_memories
		SET session_revision = ?, turn_count = turn_count + 1, state_json = ?, updated_at = ?
		WHERE channel_id = ?`,
		sessionRevision, memory, nowText(), decision.ChannelID,
	)
	if err := expectOne(update, err, "apply watch decision memory"); err != nil {
		return false, err
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
		item.SourceType = strings.TrimSpace(item.SourceType)
		item.SourceName = strings.TrimSpace(item.SourceName)
		if item.Claim == "" || item.Observation == "" ||
			item.SourceType == "" || item.SourceName == "" {
			return nil, errors.New("evidence requires claim, observation, source_type, and source_name")
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
		insert, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO evidence
			  (id, incident_id, channel_id, source_input, claim, observation, source_type,
			   source_name, source_url, target, freshness, confidence, observed_at,
			   metadata_json, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			item.ID, item.IncidentID, item.ChannelID, item.SourceInput, item.Claim,
			item.Observation, item.SourceType, item.SourceName, item.SourceURL, item.Target,
			item.Freshness, item.Confidence, timeText(item.ObservedAt), metadata,
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
		if _, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO coverage
			  (id, incident_id, channel_id, source_input, layer, status, source, detail,
			   observed_at, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			item.ID, item.IncidentID, item.ChannelID, item.SourceInput, item.Layer,
			item.Status, item.Source, item.Detail, timeText(item.ObservedAt),
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
		SELECT id, incident_id, channel_id, source_input, claim, observation, source_type,
		  source_name, source_url, target, freshness, confidence, observed_at,
		  metadata_json, created_at
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
		var observed sql.NullString
		var metadata []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput, &item.Claim,
			&item.Observation, &item.SourceType, &item.SourceName, &item.SourceURL,
			&item.Target, &item.Freshness, &item.Confidence, &observed, &metadata, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(metadata, &item.Metadata); err != nil {
			return nil, err
		}
		item.ObservedAt = scanTime(observed)
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
		  observed_at, created_at
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
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput, &item.Layer,
			&item.Status, &item.Source, &item.Detail, &observed, &created,
		); err != nil {
			return nil, err
		}
		item.ObservedAt = scanTime(observed)
		item.CreatedAt = parseTime(created)
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

package store

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
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store/attemptstore"
	"github.com/AndrewDryga/responder/internal/store/intelligencestore"
	"github.com/AndrewDryga/responder/internal/store/lifecyclecheck"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const workEpisodeColumns = `
	id, workspace_id, parent_episode_id, mode,
	platform, channel_id, thread_ts, anchor_ts, visibility,
	destination_channel_id, destination_thread_ts, destination_revision,
	latest_attempt_id, authority_snapshot_ref,
	agent_run_id, effort, authority, activity, lifecycle_state, objective,
	required_coverage_json, completion_criteria_json, phase, status, next_action,
	event_sequence, progress_sequence, last_progress_at, progress_due_at, created_at, updated_at,
	completed_at, last_activity_at`

func defaultWorkEpisode(run core.AgentRun) core.WorkEpisode {
	episode := core.WorkEpisode{
		ID:              "episode_" + run.ID,
		AgentRunID:      run.ID,
		LatestAttemptID: run.AttemptID,
		Mode:            core.EpisodeCheck,
		Conversation: core.ConversationRef{
			Platform: "slack", ChannelID: run.ChannelID, ThreadTS: run.ThreadTS,
			AnchorTS: run.SourceID, Visibility: "channel",
		},
		Destination: core.BoundDestination{
			ChannelID: run.ChannelID, ThreadTS: run.ThreadTS, Reason: "accepted",
		},
		DestinationRevision: 1,
		Effort:              core.EffortFocusedCheck,
		Authority:           core.AuthorityReadOnly,
		Activity:            core.ActivityInvestigating,
		State:               core.EpisodeAccepted,
		Objective:           strings.TrimSpace(run.CommitmentTitle),
		Phase:               "accepted",
		Status:              "Accepted",
		NextAction:          "Plan the work",
	}
	if episode.Objective == "" {
		episode.Objective = strings.TrimSpace(run.Prompt)
	}
	if episode.Objective == "" {
		episode.Objective = "Complete the accepted Slack request"
	}
	switch run.Mode {
	case core.AgentRunEngineeringTask:
		episode.Mode = core.EpisodeEngineering
		episode.Effort = core.EffortEngineeringTask
		episode.Authority = core.AuthorityRepositoryWrite
	case core.AgentRunIncident:
		episode.Mode = core.EpisodeIncident
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
		if candidate.WorkspaceID != "" {
			episode.WorkspaceID = candidate.WorkspaceID
		}
		if candidate.ParentEpisodeID != "" {
			episode.ParentEpisodeID = candidate.ParentEpisodeID
		}
		if candidate.Mode != "" {
			episode.Mode = candidate.Mode
		}
		if candidate.Conversation.Platform != "" {
			episode.Conversation = candidate.Conversation
		}
		if candidate.Destination.ChannelID != "" {
			episode.Destination = candidate.Destination
		}
		if candidate.DestinationRevision > 0 {
			episode.DestinationRevision = candidate.DestinationRevision
		}
		if candidate.AuthoritySnapshot != "" {
			episode.AuthoritySnapshot = candidate.AuthoritySnapshot
		}
		if candidate.Effort != "" {
			episode.Effort = candidate.Effort
		}
		if candidate.Authority != "" {
			episode.Authority = candidate.Authority
		}
		if candidate.Activity != "" {
			episode.Activity = candidate.Activity
		}
		if strings.TrimSpace(candidate.Objective) != "" {
			episode.Objective = strings.TrimSpace(candidate.Objective)
		}
		episode.RequiredCoverage = append([]string(nil), candidate.RequiredCoverage...)
		episode.CompletionCriteria = append([]string(nil), candidate.CompletionCriteria...)
	}
	episode.AgentRunID = run.ID
	episode.LatestAttemptID = run.AttemptID
	if !validEffort(effortString(episode.Effort)) {
		return core.WorkEpisode{}, fmt.Errorf("unsupported work episode effort %q", episode.Effort)
	}
	if !validAuthority(string(episode.Authority)) {
		return core.WorkEpisode{}, fmt.Errorf("unsupported work episode authority %q", episode.Authority)
	}
	if !validActivity(episode.Activity) {
		return core.WorkEpisode{}, fmt.Errorf("unsupported work episode activity %q", episode.Activity)
	}
	episode.RequiredCoverage = normalizedUniqueStrings(episode.RequiredCoverage, 9)
	episode.CompletionCriteria = normalizedUniqueStrings(episode.CompletionCriteria, 12)
	episode.Objective = core.TruncateUTF8(episode.Objective, 500)
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

func validActivity(value core.EpisodeActivity) bool {
	switch value {
	case core.ActivityInvestigating, core.ActivityExplaining, core.ActivityScheduling,
		core.ActivityEngineering, core.ActivityOperating:
		return true
	default:
		return false
	}
}

func validWorkEpisodeState(value core.WorkEpisodeState) bool {
	switch value {
	case core.EpisodeAccepted, core.EpisodeAcknowledged, core.EpisodePlanning,
		core.EpisodeWorking, core.EpisodeBlocked, core.EpisodeWaitingOperator,
		core.EpisodeWaitingExternal, core.EpisodeWaitingApproval,
		core.EpisodeRetrying, core.EpisodeVerifying, core.EpisodeCompleted,
		core.EpisodeFailed, core.EpisodeRefused, core.EpisodeCancelled,
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

func (s *Store) ensureWorkEpisodeTx(
	ctx context.Context,
	tx *sql.Tx,
	run core.AgentRun,
) error {
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
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO work_episodes (
		  id, workspace_id, parent_episode_id, mode,
		  platform, channel_id, thread_ts, anchor_ts, visibility,
		  destination_channel_id, destination_thread_ts, destination_revision,
		  latest_attempt_id, authority_snapshot_ref,
		  agent_run_id, effort, authority, activity, lifecycle_state, objective,
		  required_coverage_json, completion_criteria_json,
		  phase, status, next_action, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'accepted', ?,
		          ?, ?, 'accepted', 'Accepted', 'Plan the work', ?, ?)`,
		episode.ID, episode.WorkspaceID, episode.ParentEpisodeID, episode.Mode,
		episode.Conversation.Platform, episode.Conversation.ChannelID,
		episode.Conversation.ThreadTS, episode.Conversation.AnchorTS,
		episode.Conversation.Visibility, episode.Destination.ChannelID,
		episode.Destination.ThreadTS, episode.DestinationRevision, episode.LatestAttemptID,
		episode.AuthoritySnapshot, run.ID, episode.Effort, episode.Authority,
		episode.Activity, episode.Objective, required, criteria, s.nowText(), s.nowText(),
	)
	if err != nil {
		return err
	}
	created, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if err := attemptstore.Ensure(ctx, tx, episode.ID, run, s.nowText()); err != nil {
		return err
	}
	if created == 0 {
		return nil
	}
	now := s.nowText()
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
		SET event_sequence = 1, progress_sequence = 1, last_progress_at = ?, updated_at = ?
		WHERE id = ?`, now, now, episode.ID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO work_episode_events
		  (id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at)
		VALUES (?, ?, 1, ?, 'host', ?, ?, ?)`,
		"episode_event_"+episode.ID+"_000001", episode.ID, episodepkg.EventCreated,
		"created:"+episode.ID, `{"phase":"accepted","summary":"Accepted"}`, now,
	); err != nil {
		return err
	}
	return nil
}

func scanWorkEpisode(row interface{ Scan(...any) error }) (core.WorkEpisode, error) {
	var item core.WorkEpisode
	var requiredJSON, criteriaJSON string
	var lastProgress, progressDue, completed, lastActivity sql.NullString
	var created, updated string
	err := row.Scan(
		&item.ID, &item.WorkspaceID, &item.ParentEpisodeID, &item.Mode,
		&item.Conversation.Platform, &item.Conversation.ChannelID,
		&item.Conversation.ThreadTS, &item.Conversation.AnchorTS,
		&item.Conversation.Visibility, &item.Destination.ChannelID,
		&item.Destination.ThreadTS, &item.DestinationRevision,
		&item.LatestAttemptID, &item.AuthoritySnapshot,
		&item.AgentRunID, &item.Effort, &item.Authority, &item.Activity,
		&item.State,
		&item.Objective, &requiredJSON, &criteriaJSON, &item.Phase, &item.Status,
		&item.NextAction, &item.EventSequence, &item.ProgressSequence, &lastProgress, &progressDue,
		&created, &updated, &completed, &lastActivity,
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
	item.LastProgressAt = sqlutil.ScanTime(lastProgress)
	item.LastActivityAt = sqlutil.ScanTime(lastActivity)
	item.ProgressDueAt = sqlutil.ScanTime(progressDue)
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	item.CompletedAt = sqlutil.ScanTime(completed)
	item.Revision = item.EventSequence
	return item, nil
}

func (s *Store) GetWorkEpisode(ctx context.Context, episodeID string) (core.WorkEpisode, error) {
	return scanWorkEpisode(s.db.QueryRowContext(
		ctx, `SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`, episodeID,
	))
}

// GetWorkEpisodeByRun resolves the episode a run belongs to through the run's
// own episode_id.
//
// This used to try episode_attempts first and fall back to
// work_episodes.agent_run_id — the one-to-one bridge from before episodes owned
// attempts. Both branches are gone. On the deployed database all 335 runs
// resolve through their attempt, none need the fallback, and agent_runs.episode_id
// agrees with the attempt's episode in every row, so the column is the direct
// answer the two lookups were reconstructing.
func (s *Store) GetWorkEpisodeByRun(
	ctx context.Context,
	runID string,
) (core.WorkEpisode, error) {
	return scanWorkEpisode(s.db.QueryRowContext(
		ctx,
		`SELECT `+workEpisodeColumns+` FROM work_episodes
		 WHERE id = (SELECT episode_id FROM agent_runs WHERE id = ?)`,
		runID,
	))
}

func (s *Store) GetWorkEpisodeBySource(
	ctx context.Context,
	sourceID string,
) (core.WorkEpisode, error) {
	var runID string
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM agent_runs WHERE source_id = ?
		ORDER BY created_at DESC LIMIT 1`, sourceID).Scan(&runID)
	if errors.Is(err, sql.ErrNoRows) {
		return core.WorkEpisode{}, ErrNotFound
	}
	if err != nil {
		return core.WorkEpisode{}, err
	}
	return s.GetWorkEpisodeByRun(ctx, runID)
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
	payload, err := episodepkg.Encode(episodepkg.Transition{
		State: state, Phase: phase, Status: status, NextAction: nextAction,
		ProgressDue: progressDue,
	})
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if episodepkg.Terminal(state) {
		_, latestRunID, ownershipErr := workEpisodeAttemptOwnershipTx(ctx, tx, runID)
		if ownershipErr != nil {
			return ownershipErr
		}
		if latestRunID != runID {
			return nil
		}
	}
	_, err = s.appendWorkEpisodeEventTx(ctx, tx, runID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventPhaseChanged, Actor: "host",
		// Keyed on the run, because an episode has to be able to enter the same
		// phase twice.
		//
		// The key was content-addressed over the transition alone, so a later
		// attempt that reached an identical phase found its event already
		// recorded and appended nothing — and an event that is not appended is a
		// transition that never reduces. The episode kept whatever execution
		// state leasing the attempt had put it in, and FinishAgentRun then
		// completed it as ordinary finished work. That is the second half of how
		// the 2026-08-16 va1-nomad-oom-risk stream closed its episode at 19:29Z
		// with the alert still firing: attempt 1 had already parked the episode
		// in "Watching the alert stream", so attempt 2's identical park was
		// dropped on the floor. Retrying one run's finalization still dedupes,
		// which is the idempotency this key exists for.
		IdempotencyKey: episodeEventKey(
			"phase", runID, string(state), phase, status, nextAction,
			progressDue.UTC().Format(time.RFC3339Nano),
		),
		Payload: payload,
	})
	if err != nil {
		return err
	}
	if episodepkg.Terminal(state) {
		if err := lifecyclecheck.CancelWakeupsForRun(ctx, tx, runID, s.nowText()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ResolveWaitingApprovalEpisodes closes the accepted work that reached an
// Emisar decision. The same episode resumes in verification so its approval,
// execution, and post-change evidence remain one durable work history.
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
		WHERE e.lifecycle_state IN ('waiting_approval', 'waiting_external')
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
			core.EpisodeVerifying,
			"verifying_approval_result",
			"Emisar decision received: "+sqlutil.BoundedError(status),
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
	payload, err := episodepkg.Encode(episodepkg.Transition{
		Phase: phase, Summary: summary, ProgressDue: nextDue,
	})
	if err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	_, err = s.AppendWorkEpisodeEvent(ctx, runID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventProgressReported, Actor: "host",
		IdempotencyKey: episodeEventKey(
			"progress", phase, summary, nextDue.UTC().Format(time.RFC3339Nano),
		),
		Payload: payload,
	})
	if err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	progress, err := s.ListWorkEpisodeProgress(ctx, runID, 1)
	if err != nil {
		return core.WorkEpisodeProgress{}, err
	}
	if len(progress) == 0 {
		return core.WorkEpisodeProgress{}, errors.New("episode event did not project progress")
	}
	return progress[0], nil
}

func episodeEventKey(prefix string, values ...string) string {
	digest := sha256.Sum256([]byte(strings.Join(values, "\x00")))
	return prefix + ":" + hex.EncodeToString(digest[:16])
}

// AppendWorkEpisodeEvent is the single durable transition path for accepted
// work. Slack cards, commitments, and progress rows are projections of this
// ordered stream rather than independent lifecycle state.
func (s *Store) AppendWorkEpisodeEvent(
	ctx context.Context,
	runID string,
	event core.WorkEpisodeEvent,
) (core.WorkEpisodeEvent, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	defer tx.Rollback()
	event, err = s.appendWorkEpisodeEventTx(ctx, tx, runID, event)
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	return event, nil
}

// AppendEpisodeEvent appends against the aggregate identity. New lifecycle
// code should use this method; AppendWorkEpisodeEvent remains a compatibility
// adapter for callers that still hold an attempt/run ID.
func (s *Store) AppendEpisodeEvent(
	ctx context.Context,
	episodeID string,
	event core.WorkEpisodeEvent,
) (core.WorkEpisodeEvent, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	defer tx.Rollback()
	event, err = s.appendEpisodeEventTx(ctx, tx, episodeID, event)
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	return event, nil
}

func (s *Store) appendWorkEpisodeEventTx(
	ctx context.Context,
	tx *sql.Tx,
	runID string,
	event core.WorkEpisodeEvent,
) (core.WorkEpisodeEvent, error) {
	// The run's own episode_id, not a reconstruction from attempts or from the
	// legacy one-to-one work_episodes.agent_run_id. Both are gone; see
	// GetWorkEpisodeByRun for the evidence.
	var episodeID string
	err := tx.QueryRowContext(ctx, `
		SELECT episode_id FROM agent_runs WHERE id = ?`, runID).Scan(&episodeID)
	if errors.Is(err, sql.ErrNoRows) || strings.TrimSpace(episodeID) == "" {
		return core.WorkEpisodeEvent{}, ErrNotFound
	}
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	return s.appendEpisodeEventTx(ctx, tx, episodeID, event)
}

func (s *Store) appendEpisodeEventTx(
	ctx context.Context,
	tx *sql.Tx,
	episodeID string,
	event core.WorkEpisodeEvent,
) (core.WorkEpisodeEvent, error) {
	event.Kind = strings.TrimSpace(event.Kind)
	event.Actor = strings.TrimSpace(event.Actor)
	event.IdempotencyKey = strings.TrimSpace(event.IdempotencyKey)
	if event.Kind == "" || event.IdempotencyKey == "" {
		return core.WorkEpisodeEvent{}, errors.New("episode event requires kind and idempotency key")
	}
	if event.Actor == "" {
		event.Actor = "host"
	}
	current, err := scanWorkEpisode(tx.QueryRowContext(
		ctx,
		`SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`,
		episodeID,
	))
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}

	existing, err := scanWorkEpisodeEvent(tx.QueryRowContext(ctx, `
		SELECT id, episode_id, sequence, kind, actor, idempotency_key,
		       payload_json, created_at
		FROM work_episode_events
		WHERE episode_id = ? AND idempotency_key = ?`,
		current.ID, event.IdempotencyKey,
	))
	if err == nil {
		if existing.Kind != event.Kind {
			return core.WorkEpisodeEvent{}, fmt.Errorf(
				"episode idempotency key %q already belongs to %s",
				event.IdempotencyKey, existing.Kind,
			)
		}
		return existing, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return core.WorkEpisodeEvent{}, err
	}

	event.EpisodeID = current.ID
	event.Sequence = current.EventSequence + 1
	if event.ID == "" {
		event.ID = fmt.Sprintf("episode_event_%s_%06d", current.ID, event.Sequence)
	}
	if event.CreatedAt.IsZero() {
		event.CreatedAt = s.now().UTC()
	}
	if len(event.Payload) == 0 {
		event.Payload = json.RawMessage(`{}`)
	}
	next, err := episodepkg.Reduce(current, event)
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	if next.State == core.EpisodeCompleted && current.State != core.EpisodeCompleted {
		var goalID, outcome, state string
		err := tx.QueryRowContext(ctx, `
			SELECT id, requested_outcome, state
			FROM episode_goals
			WHERE episode_id = ? AND required = 1
			  AND state NOT IN ('completed', 'excluded', 'cancelled')
			ORDER BY created_at, id LIMIT 1`, current.ID,
		).Scan(&goalID, &outcome, &state)
		if err == nil {
			return core.WorkEpisodeEvent{}, fmt.Errorf(
				"episode cannot complete while required goal %s (%s) is %s: %w",
				goalID, outcome, state, ErrEpisodeGoalsOpen,
			)
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return core.WorkEpisodeEvent{}, err
		}
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO work_episode_events
		  (id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ID, event.EpisodeID, event.Sequence, event.Kind, event.Actor,
		event.IdempotencyKey, string(event.Payload), event.CreatedAt.Format(time.RFC3339Nano),
	); err != nil {
		return core.WorkEpisodeEvent{}, err
	}

	if eventProjectsProgress(event.Kind) {
		transition, err := episodepkg.DecodeTransition(event)
		if err != nil {
			return core.WorkEpisodeEvent{}, err
		}
		summary := transition.Summary
		if summary == "" {
			summary = transition.Status
		}
		next.ProgressSequence = current.ProgressSequence + 1
		next.LastProgressAt = event.CreatedAt
		progressID := fmt.Sprintf("episode_progress_%s_%06d", current.ID, next.ProgressSequence)
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO work_episode_progress
			  (id, episode_id, sequence, phase, summary, created_at)
			VALUES (?, ?, ?, ?, ?, ?)`,
			progressID, current.ID, next.ProgressSequence,
			strings.TrimSpace(transition.Phase), sqlutil.BoundedError(summary),
			event.CreatedAt.Format(time.RFC3339Nano),
		); err != nil {
			return core.WorkEpisodeEvent{}, err
		}
	}

	result, err := tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET lifecycle_state = ?, phase = ?, status = ?, next_action = ?,
		    event_sequence = ?, progress_sequence = ?, last_progress_at = ?,
		    progress_due_at = ?, completed_at = ?, updated_at = ?
		WHERE id = ? AND event_sequence = ?`,
		next.State, next.Phase,
		sqlutil.BoundedError(next.Status), sqlutil.BoundedError(next.NextAction),
		next.EventSequence, next.ProgressSequence, nullableTime(next.LastProgressAt),
		nullableTime(next.ProgressDueAt), nullableTime(next.CompletedAt),
		event.CreatedAt.Format(time.RFC3339Nano), current.ID, current.EventSequence,
	)
	if err := sqlutil.ExpectOne(result, err, "append work episode event"); err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	// The recall projection rides the transition that produced it. Written
	// afterwards it could simply be absent, and the failure is invisible: a
	// later incident is never told about this episode and nobody learns that it
	// should have been. Every state change is offered, and intelligencestore
	// decides — a conclusion is projected, anything else withdraws the row.
	if next.State != current.State {
		if err := intelligencestore.ProjectEpisodeOutcomeTx(
			ctx, tx, current.ID, string(next.State), event.CreatedAt,
		); err != nil {
			return core.WorkEpisodeEvent{}, err
		}
	}
	return event, nil
}

func (s *Store) setWorkEpisodePhaseTx(
	ctx context.Context,
	tx *sql.Tx,
	runID string,
	state core.WorkEpisodeState,
	phase string,
	status string,
	nextAction string,
	progressDue time.Time,
	idempotencyKey string,
) error {
	if strings.TrimSpace(phase) == "" || strings.TrimSpace(status) == "" {
		return errors.New("work episode phase and status are required")
	}
	if !validWorkEpisodeState(state) {
		return fmt.Errorf("unsupported work episode state %q", state)
	}
	currentState, latestRunID, err := workEpisodeAttemptOwnershipTx(ctx, tx, runID)
	if err != nil {
		return err
	}
	// An older attempt may finish after a replacement has already been queued.
	// Its own result remains durable, but it must not close the shared episode
	// and strand the newer attempt beneath a terminal projection.
	if episodepkg.Terminal(state) && latestRunID != runID {
		return nil
	}
	if episodepkg.Terminal(currentState) && !episodepkg.Terminal(state) {
		if latestRunID != runID {
			return fmt.Errorf("terminal episode's latest attempt is %q, not %q: %w",
				latestRunID, runID, ErrEpisodeAttemptSuperseded)
		}
		reopened, err := episodepkg.Encode(episodepkg.Transition{
			State: core.EpisodeAccepted, Phase: "accepted", Status: "Accepted",
			NextAction: "Continue the operational lifecycle",
		})
		if err != nil {
			return err
		}
		if _, err := s.appendWorkEpisodeEventTx(ctx, tx, runID, core.WorkEpisodeEvent{
			Kind: episodepkg.EventEpisodeReopened, Actor: "host",
			IdempotencyKey: idempotencyKey + ":reopened", Payload: reopened,
		}); err != nil {
			return err
		}
		var reopenedState core.WorkEpisodeState
		if err := tx.QueryRowContext(ctx, `
			SELECT lifecycle_state FROM work_episodes
			WHERE id = (SELECT episode_id FROM agent_runs WHERE id = ?)`,
			runID,
		).Scan(&reopenedState); err != nil {
			return err
		}
		if episodepkg.Terminal(reopenedState) {
			return fmt.Errorf(
				"episode reopen event %q was already consumed by an older run generation",
				idempotencyKey,
			)
		}
	}
	payload, err := episodepkg.Encode(episodepkg.Transition{
		State: state, Phase: phase, Status: status, NextAction: nextAction,
		ProgressDue: progressDue,
	})
	if err != nil {
		return err
	}
	_, err = s.appendWorkEpisodeEventTx(ctx, tx, runID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventPhaseChanged, Actor: "host",
		IdempotencyKey: idempotencyKey,
		Payload:        payload,
	})
	return err
}

func workEpisodeAttemptOwnershipTx(
	ctx context.Context,
	tx *sql.Tx,
	runID string,
) (core.WorkEpisodeState, string, error) {
	var currentState core.WorkEpisodeState
	var latestRunID string
	if err := tx.QueryRowContext(ctx, `
		SELECT episode.lifecycle_state, attempt.agent_run_id
		FROM work_episodes AS episode
		JOIN episode_attempts AS current ON current.agent_run_id = ?
		JOIN episode_attempts AS attempt ON attempt.id = episode.latest_attempt_id
		WHERE episode.id = current.episode_id`, runID).Scan(
		&currentState, &latestRunID,
	); err != nil {
		return "", "", err
	}
	return currentState, latestRunID, nil
}

func eventProjectsProgress(kind string) bool {
	switch kind {
	case episodepkg.EventPhaseChanged, episodepkg.EventProgressReported,
		episodepkg.EventCompletionAccepted:
		return true
	default:
		return false
	}
}

func scanWorkEpisodeEvent(row interface{ Scan(...any) error }) (core.WorkEpisodeEvent, error) {
	var event core.WorkEpisodeEvent
	var payload, created string
	err := row.Scan(
		&event.ID, &event.EpisodeID, &event.Sequence, &event.Kind, &event.Actor,
		&event.IdempotencyKey, &payload, &created,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.WorkEpisodeEvent{}, ErrNotFound
	}
	if err != nil {
		return core.WorkEpisodeEvent{}, err
	}
	event.Payload = json.RawMessage(payload)
	event.CreatedAt = sqlutil.ParseTime(created)
	return event, nil
}

func (s *Store) ListWorkEpisodeProgress(
	ctx context.Context,
	runID string,
	limit int,
) ([]core.WorkEpisodeProgress, error) {
	episode, err := s.GetWorkEpisodeByRun(ctx, runID)
	if err != nil {
		return nil, err
	}
	return s.ListEpisodeProgress(ctx, episode.ID, limit)
}

func (s *Store) ListEpisodeProgress(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]core.WorkEpisodeProgress, error) {
	if limit < 1 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT p.id, p.episode_id, p.sequence, p.phase, p.summary, p.created_at
		FROM work_episode_progress AS p
		WHERE p.episode_id = ?
		ORDER BY p.sequence DESC LIMIT ?`, episodeID, limit)
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
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

// ListOverdueEpisodes returns accepted work that has stopped reporting
// progress and has also stopped doing anything.
//
// An episode carries a progress deadline so the host can tell "still working"
// apart from "stopped". Nothing consumed that deadline, so an episode could
// stall indefinitely and the only sign would be a thread that went quiet —
// which reads to an operator as an answer that never came rather than as a
// failure. Terminal states are excluded because a finished episode has no
// progress left to owe.
//
// Two clocks, and both have to be stale. progress_due_at is a promise the model
// makes about prose, and a long turn breaks it routinely: the episode behind
// the 2026-08-13 19:57 alarm said "Still working" twice, byte for byte, then
// made 119 tool calls in silence and was accused mid-investigation.
// last_activity_at is what the turn actually did, so it is the clock that tells
// a stall from a working turn with nothing to say. NULL keeps the old
// prose-only rule: no narration was ever recorded, and missing evidence must
// not make an episode invisible to the watchdog.
//
// Filtering here rather than in the caller keeps a busy turn out of the LIMIT
// as well as out of the alarm — the batch is ordered by progress_due_at, where
// long-running work sits at the head.
func (s *Store) ListOverdueEpisodes(
	ctx context.Context,
	progressStaleBefore time.Time,
	activityStaleBefore time.Time,
	limit int,
) ([]core.WorkEpisode, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("overdue episode limit must be between 1 and 100")
	}
	progressCutoff := progressStaleBefore.UTC().Format(timestampFormat)
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+workEpisodeColumns+`
		FROM work_episodes
		WHERE completed_at IS NULL
		  AND (
		    (progress_due_at IS NOT NULL AND julianday(progress_due_at) <= julianday(?))
		    OR (progress_due_at IS NULL
		      AND lifecycle_state IN ('accepted', 'acknowledged')
		      AND julianday(updated_at) <= julianday(?)
		      AND NOT EXISTS (
		        SELECT 1 FROM agent_runs AS run
		        WHERE run.episode_id = work_episodes.id
		          AND run.state IN ('pending', 'preparing', 'running', 'applying', 'finalizing')
		      ))
		  )
		  -- The narration clock; NULL means nothing was ever recorded.
		  AND (last_activity_at IS NULL OR julianday(last_activity_at) <= julianday(?))
		  -- 'refused' is explicit because the legacy state column this replaced
		  -- collapsed refused into failed and so excluded it already.
		  AND lifecycle_state NOT IN (
		    'completed', 'cancelled', 'failed', 'refused', 'superseded')
		ORDER BY progress_due_at
		LIMIT ?`,
		progressCutoff, progressCutoff,
		activityStaleBefore.UTC().Format(timestampFormat), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.WorkEpisode, 0, limit)
	for rows.Next() {
		episode, err := scanWorkEpisode(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, episode)
	}
	return result, rows.Err()
}

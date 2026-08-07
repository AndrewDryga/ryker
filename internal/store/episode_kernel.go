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
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func attemptStateFromAgent(state core.AgentRunState) core.EpisodeAttemptState {
	switch state {
	case core.AgentRunPending:
		return core.AttemptPending
	case core.AgentRunPreparing:
		return core.AttemptLeased
	case core.AgentRunRunning, core.AgentRunApplying, core.AgentRunFinalizing:
		return core.AttemptRunning
	case core.AgentRunCompleted:
		return core.AttemptSucceeded
	case core.AgentRunCancelled, core.AgentRunSuperseded:
		return core.AttemptCancelled
	default:
		return core.AttemptFailed
	}
}

func ensureEpisodeAttemptTx(
	ctx context.Context,
	tx *sql.Tx,
	episodeID string,
	run core.AgentRun,
	now string,
) error {
	var existingID string
	err := tx.QueryRowContext(ctx,
		`SELECT id FROM episode_attempts WHERE agent_run_id = ?`, run.ID,
	).Scan(&existingID)
	if err == nil {
		_, err = tx.ExecContext(ctx, `
			UPDATE agent_runs
			SET episode_id = ?, attempt_id = ?, attempt_number = (
			  SELECT attempt_number FROM episode_attempts WHERE id = ?
			), updated_at = ?
			WHERE id = ?`, episodeID, existingID, existingID, now, run.ID)
		return err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	var number int
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(attempt_number), 0) + 1
		FROM episode_attempts WHERE episode_id = ?`, episodeID).Scan(&number); err != nil {
		return err
	}
	attemptID := strings.TrimSpace(run.AttemptID)
	if attemptID == "" {
		attemptID = "attempt_" + run.ID
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO episode_attempts (
		  id, episode_id, agent_run_id, attempt_number, state,
		  failure_generation, started_at, completed_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		attemptID, episodeID, run.ID, number, attemptStateFromAgent(run.State),
		run.Failures, nullableTime(run.StartedAt), nullableTime(run.CompletedAt),
		run.CreatedAt.UTC().Format(timestampFormat), now,
	); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET episode_id = ?, attempt_id = ?, attempt_number = ?, updated_at = ?
		WHERE id = ?`, episodeID, attemptID, number, now, run.ID); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET latest_attempt_id = ?, updated_at = ? WHERE id = ?`, attemptID, now, episodeID)
	return err
}

// QueueEpisodeAttempt resumes an existing episode with a new transport attempt.
// The episode keeps its goals, evidence, destination, and event history.
func (s *Store) QueueEpisodeAttempt(
	ctx context.Context,
	episodeID string,
	run core.AgentRun,
) (core.AgentRun, bool, error) {
	episode, err := s.GetWorkEpisode(ctx, episodeID)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	if episodepkg.Terminal(episode.State) {
		return core.AgentRun{}, false, fmt.Errorf(
			"cannot resume terminal episode %q in state %q", episodeID, episode.State,
		)
	}
	run.Episode = &episode
	run.EpisodeID = episode.ID
	run.AttemptID = ""
	run.AttemptNumber = 0
	queued, created, err := s.QueueAgentRun(ctx, run)
	if err != nil || !created {
		return queued, created, err
	}
	if err := s.SetEpisodePhase(
		ctx, episode.ID, core.EpisodeRetrying, "resuming", "Resuming work",
		"Run the next attempt", time.Time{},
	); err != nil {
		return core.AgentRun{}, false, err
	}
	return queued, true, nil
}

const episodeAttemptSelect = `
	SELECT id, episode_id, agent_run_id, attempt_number, state,
	       failure_class, failure_generation, lease_owner, fencing_token,
	       lease_expires_at, context_manifest_id, started_at, completed_at,
	       created_at, updated_at
	FROM episode_attempts `

func scanEpisodeAttempt(row interface{ Scan(...any) error }) (core.EpisodeAttempt, error) {
	var item core.EpisodeAttempt
	var leaseExpires, started, completed sql.NullString
	var created, updated string
	err := row.Scan(
		&item.ID, &item.EpisodeID, &item.AgentRunID, &item.Number, &item.State,
		&item.FailureClass, &item.FailureGeneration, &item.LeaseOwner,
		&item.FencingToken, &leaseExpires, &item.ContextManifestID, &started,
		&completed, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EpisodeAttempt{}, ErrNotFound
	}
	if err != nil {
		return core.EpisodeAttempt{}, err
	}
	item.LeaseExpiresAt = sqlutil.ScanTime(leaseExpires)
	item.StartedAt = sqlutil.ScanTime(started)
	item.CompletedAt = sqlutil.ScanTime(completed)
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	return item, nil
}

func (s *Store) GetEpisodeAttempt(ctx context.Context, attemptID string) (core.EpisodeAttempt, error) {
	return scanEpisodeAttempt(s.db.QueryRowContext(
		ctx, episodeAttemptSelect+` WHERE id = ?`, attemptID,
	))
}

func (s *Store) setEpisodeAttemptStateTx(
	ctx context.Context,
	tx *sql.Tx,
	runID string,
	state core.EpisodeAttemptState,
	failureClass string,
	lease bool,
) error {
	if state == "" {
		return errors.New("attempt state is required")
	}
	now := s.now().UTC()
	leaseOwner := ""
	leaseExpires := any(nil)
	startedAt := any(nil)
	completedAt := any(nil)
	if lease {
		leaseOwner = "agent-run-worker"
		leaseExpires = now.Add(10 * time.Minute).Format(timestampFormat)
	}
	if state == core.AttemptRunning {
		startedAt = now.Format(timestampFormat)
	}
	if state == core.AttemptSucceeded || state == core.AttemptFailed || state == core.AttemptCancelled {
		completedAt = now.Format(timestampFormat)
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE episode_attempts
		SET state = ?, failure_class = ?,
		    failure_generation = CASE WHEN ? = 'failed' THEN failure_generation + 1 ELSE failure_generation END,
		    lease_owner = ?, fencing_token = fencing_token + CASE WHEN ? THEN 1 ELSE 0 END,
		    lease_expires_at = ?, started_at = COALESCE(started_at, ?),
		    completed_at = ?, updated_at = ?
		WHERE agent_run_id = ?`,
		state, sqlutil.BoundedError(failureClass), state, leaseOwner, lease, leaseExpires,
		startedAt, completedAt, now.Format(timestampFormat), runID,
	)
	return sqlutil.ExpectOne(result, err, "set episode attempt state")
}

func (s *Store) SetEpisodePhase(
	ctx context.Context,
	episodeID string,
	state core.WorkEpisodeState,
	phase string,
	status string,
	nextAction string,
	progressDue time.Time,
) error {
	if !validWorkEpisodeState(state) || strings.TrimSpace(phase) == "" || strings.TrimSpace(status) == "" {
		return errors.New("valid episode state, phase, and status are required")
	}
	payload, err := episodepkg.Encode(episodepkg.Transition{
		State: state, Phase: phase, Status: status, NextAction: nextAction,
		ProgressDue: progressDue,
	})
	if err != nil {
		return err
	}
	_, err = s.AppendEpisodeEvent(ctx, episodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventPhaseChanged, Actor: "host",
		IdempotencyKey: episodeEventKey(
			"phase", episodeID, string(state), phase, status, nextAction,
			progressDue.UTC().Format(time.RFC3339Nano),
		),
		Payload: payload,
	})
	return err
}

func (s *Store) ChangeEpisodeDestination(
	ctx context.Context,
	episodeID string,
	destination core.BoundDestination,
	reason string,
) (core.WorkEpisode, error) {
	destination.ChannelID = strings.TrimSpace(destination.ChannelID)
	destination.ThreadTS = strings.TrimSpace(destination.ThreadTS)
	reason = strings.TrimSpace(reason)
	if destination.ChannelID == "" || reason == "" {
		return core.WorkEpisode{}, errors.New("destination channel and typed reason are required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.WorkEpisode{}, err
	}
	defer tx.Rollback()
	current, err := scanWorkEpisode(tx.QueryRowContext(
		ctx, `SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`, episodeID,
	))
	if err != nil {
		return core.WorkEpisode{}, err
	}
	payload, _ := episodepkg.Encode(map[string]any{
		"channel_id": destination.ChannelID, "thread_ts": destination.ThreadTS,
		"reason": reason, "destination_revision": current.DestinationRevision + 1,
	})
	event, err := s.appendEpisodeEventTx(ctx, tx, episodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventDestinationChanged, Actor: "host",
		IdempotencyKey: episodeEventKey(
			"destination", episodeID, destination.ChannelID, destination.ThreadTS,
			reason, fmt.Sprint(current.DestinationRevision+1),
		),
		Payload: payload,
	})
	if err != nil {
		return core.WorkEpisode{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE work_episodes
		SET destination_channel_id = ?, destination_thread_ts = ?,
		    destination_revision = destination_revision + 1, updated_at = ?
		WHERE id = ? AND event_sequence = ?`,
		destination.ChannelID, destination.ThreadTS, event.CreatedAt.Format(timestampFormat),
		episodeID, event.Sequence,
	)
	if err := sqlutil.ExpectOne(result, err, "change episode destination"); err != nil {
		return core.WorkEpisode{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.WorkEpisode{}, err
	}
	return s.GetWorkEpisode(ctx, episodeID)
}

func validGoalState(state core.EpisodeGoalState) bool {
	switch state {
	case core.GoalPlanned, core.GoalReady, core.GoalWorking, core.GoalWaiting,
		core.GoalCompleted, core.GoalBlocked, core.GoalExcluded, core.GoalCancelled:
		return true
	default:
		return false
	}
}

func (s *Store) CreateEpisodeGoal(ctx context.Context, goal core.EpisodeGoal) (core.EpisodeGoal, error) {
	goal.EpisodeID = strings.TrimSpace(goal.EpisodeID)
	goal.Kind = strings.TrimSpace(goal.Kind)
	goal.RequestedOutcome = strings.TrimSpace(goal.RequestedOutcome)
	goal.CompletionContract = strings.TrimSpace(goal.CompletionContract)
	if goal.EpisodeID == "" || goal.Kind == "" || goal.RequestedOutcome == "" || goal.CompletionContract == "" {
		return core.EpisodeGoal{}, errors.New("goal episode, kind, outcome, and completion contract are required")
	}
	if goal.ID == "" {
		var err error
		goal.ID, err = core.NewID("goal")
		if err != nil {
			return core.EpisodeGoal{}, err
		}
	}
	if goal.AuthorityRequirement == "" {
		goal.AuthorityRequirement = core.AuthorityReadOnly
	}
	if !validAuthority(string(goal.AuthorityRequirement)) {
		return core.EpisodeGoal{}, fmt.Errorf("unsupported goal authority %q", goal.AuthorityRequirement)
	}
	if goal.State == "" {
		goal.State = core.GoalPlanned
	}
	if !validGoalState(goal.State) {
		return core.EpisodeGoal{}, fmt.Errorf("unsupported goal state %q", goal.State)
	}
	goal.PrerequisiteGoalIDs = normalizedUniqueStrings(goal.PrerequisiteGoalIDs, 32)
	goal.ReadOnlyRepositories = normalizedUniqueStrings(goal.ReadOnlyRepositories, 32)
	prerequisites, _ := json.Marshal(goal.PrerequisiteGoalIDs)
	readOnly, _ := json.Marshal(goal.ReadOnlyRepositories)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.EpisodeGoal{}, err
	}
	defer tx.Rollback()
	if _, err := scanWorkEpisode(tx.QueryRowContext(
		ctx, `SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`, goal.EpisodeID,
	)); err != nil {
		return core.EpisodeGoal{}, err
	}
	for _, prerequisiteID := range goal.PrerequisiteGoalIDs {
		var count int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM episode_goals WHERE id = ? AND episode_id = ?`,
			prerequisiteID, goal.EpisodeID).Scan(&count); err != nil || count != 1 {
			if err != nil {
				return core.EpisodeGoal{}, err
			}
			return core.EpisodeGoal{}, fmt.Errorf("goal prerequisite %q is not in episode", prerequisiteID)
		}
	}
	now := s.now().UTC()
	goal.CreatedAt, goal.UpdatedAt = now, now
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO episode_goals (
		  id, episode_id, parent_goal_id, prerequisite_goal_ids_json, kind,
		  requested_outcome, completion_contract, writable_repository,
		  read_only_repositories_json, authority_requirement, required, state,
		  blocker, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		goal.ID, goal.EpisodeID, goal.ParentGoalID, prerequisites, goal.Kind,
		goal.RequestedOutcome, goal.CompletionContract, goal.WritableRepository,
		readOnly, goal.AuthorityRequirement, episodeBoolInt(goal.Required), goal.State,
		goal.Blocker, now.Format(timestampFormat), now.Format(timestampFormat),
	)
	if err != nil {
		return core.EpisodeGoal{}, err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return core.EpisodeGoal{}, err
	}
	if inserted == 0 {
		existing, existingErr := scanEpisodeGoal(tx.QueryRowContext(
			ctx, episodeGoalSelect+` WHERE id = ?`, goal.ID,
		))
		if existingErr != nil {
			return core.EpisodeGoal{}, existingErr
		}
		if existing.EpisodeID != goal.EpisodeID || existing.Kind != goal.Kind ||
			existing.RequestedOutcome != goal.RequestedOutcome ||
			existing.CompletionContract != goal.CompletionContract {
			return core.EpisodeGoal{}, fmt.Errorf("goal id %q was reused with different semantics", goal.ID)
		}
		if err := tx.Commit(); err != nil {
			return core.EpisodeGoal{}, err
		}
		return existing, nil
	}
	payload, _ := episodepkg.Encode(map[string]any{
		"goal_id": goal.ID, "kind": goal.Kind, "requested_outcome": goal.RequestedOutcome,
	})
	if _, err := s.appendEpisodeEventTx(ctx, tx, goal.EpisodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventGoalPlanned, Actor: "host",
		IdempotencyKey: "goal-planned:" + goal.ID, Payload: payload,
	}); err != nil {
		return core.EpisodeGoal{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.EpisodeGoal{}, err
	}
	return goal, nil
}

func episodeBoolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func (s *Store) SetEpisodeGoalState(
	ctx context.Context,
	goalID string,
	state core.EpisodeGoalState,
	blocker string,
) error {
	if !validGoalState(state) {
		return fmt.Errorf("unsupported goal state %q", state)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	goal, err := scanEpisodeGoal(tx.QueryRowContext(ctx, episodeGoalSelect+` WHERE id = ?`, goalID))
	if err != nil {
		return err
	}
	if state == core.GoalCompleted {
		for _, prerequisiteID := range goal.PrerequisiteGoalIDs {
			var prerequisiteState core.EpisodeGoalState
			if err := tx.QueryRowContext(ctx,
				`SELECT state FROM episode_goals WHERE id = ? AND episode_id = ?`,
				prerequisiteID, goal.EpisodeID,
			).Scan(&prerequisiteState); err != nil {
				return err
			}
			if prerequisiteState != core.GoalCompleted && prerequisiteState != core.GoalExcluded {
				return fmt.Errorf("goal %s cannot complete before prerequisite %s", goal.ID, prerequisiteID)
			}
		}
	}
	now := s.now().UTC()
	result, err := tx.ExecContext(ctx, `
		UPDATE episode_goals
		SET state = ?, blocker = ?, completed_at = ?, updated_at = ?
		WHERE id = ?`, state, sqlutil.BoundedError(blocker), terminalGoalTime(state, now),
		now.Format(timestampFormat), goal.ID)
	if err := sqlutil.ExpectOne(result, err, "set episode goal state"); err != nil {
		return err
	}
	kind := episodepkg.EventGoalStarted
	if state == core.GoalCompleted || state == core.GoalExcluded {
		kind = episodepkg.EventGoalCompleted
	} else if state == core.GoalBlocked {
		kind = episodepkg.EventGoalBlocked
	}
	payload, _ := episodepkg.Encode(map[string]any{
		"goal_id": goal.ID, "state": state, "blocker": blocker,
	})
	if _, err := s.appendEpisodeEventTx(ctx, tx, goal.EpisodeID, core.WorkEpisodeEvent{
		Kind: kind, Actor: "host",
		IdempotencyKey: episodeEventKey("goal-state", goal.ID, string(state), blocker),
		Payload:        payload,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func terminalGoalTime(state core.EpisodeGoalState, now time.Time) any {
	switch state {
	case core.GoalCompleted, core.GoalBlocked, core.GoalExcluded, core.GoalCancelled:
		return now.Format(timestampFormat)
	default:
		return nil
	}
}

const episodeGoalSelect = `
	SELECT id, episode_id, parent_goal_id, prerequisite_goal_ids_json, kind,
	       requested_outcome, completion_contract, writable_repository,
	       read_only_repositories_json, authority_requirement, required, state,
	       blocker, created_at, updated_at, completed_at
	FROM episode_goals `

func scanEpisodeGoal(row interface{ Scan(...any) error }) (core.EpisodeGoal, error) {
	var item core.EpisodeGoal
	var prerequisitesJSON, readOnlyJSON, created, updated string
	var required int
	var completed sql.NullString
	err := row.Scan(
		&item.ID, &item.EpisodeID, &item.ParentGoalID, &prerequisitesJSON,
		&item.Kind, &item.RequestedOutcome, &item.CompletionContract,
		&item.WritableRepository, &readOnlyJSON, &item.AuthorityRequirement,
		&required, &item.State, &item.Blocker, &created, &updated, &completed,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EpisodeGoal{}, ErrNotFound
	}
	if err != nil {
		return core.EpisodeGoal{}, err
	}
	if err := json.Unmarshal([]byte(prerequisitesJSON), &item.PrerequisiteGoalIDs); err != nil {
		return core.EpisodeGoal{}, err
	}
	if err := json.Unmarshal([]byte(readOnlyJSON), &item.ReadOnlyRepositories); err != nil {
		return core.EpisodeGoal{}, err
	}
	item.Required = required == 1
	item.CreatedAt, item.UpdatedAt = sqlutil.ParseTime(created), sqlutil.ParseTime(updated)
	item.CompletedAt = sqlutil.ScanTime(completed)
	return item, nil
}

func (s *Store) CreateContextManifest(
	ctx context.Context,
	manifest core.ContextManifest,
) (core.ContextManifest, error) {
	manifest.EpisodeID = strings.TrimSpace(manifest.EpisodeID)
	manifest.AttemptID = strings.TrimSpace(manifest.AttemptID)
	if manifest.EpisodeID == "" || manifest.AttemptID == "" {
		return core.ContextManifest{}, errors.New("context manifest episode and attempt are required")
	}
	if manifest.ID == "" {
		var err error
		manifest.ID, err = core.NewID("context")
		if err != nil {
			return core.ContextManifest{}, err
		}
	}
	manifest.Omissions = normalizedUniqueStrings(manifest.Omissions, 64)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.ContextManifest{}, err
	}
	defer tx.Rollback()
	var attemptEpisode string
	if err := tx.QueryRowContext(ctx,
		`SELECT episode_id FROM episode_attempts WHERE id = ?`, manifest.AttemptID,
	).Scan(&attemptEpisode); err != nil {
		return core.ContextManifest{}, err
	}
	if attemptEpisode != manifest.EpisodeID {
		return core.ContextManifest{}, errors.New("context manifest attempt belongs to another episode")
	}
	var nextVersion int
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(version), 0) + 1 FROM context_manifests WHERE episode_id = ?`,
		manifest.EpisodeID).Scan(&nextVersion); err != nil {
		return core.ContextManifest{}, err
	}
	manifest.Version = nextVersion
	if err := validateManifestLineage(ctx, tx, manifest); err != nil {
		return core.ContextManifest{}, err
	}
	omissions, _ := json.Marshal(manifest.Omissions)
	manifest.CreatedAt = s.now().UTC()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO context_manifests (
		  id, episode_id, attempt_id, parent_manifest_id, version,
		  prompt_version, contract_version, tool_schema_version, preset,
		  provider, model, reasoning_effort, omissions_json, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		manifest.ID, manifest.EpisodeID, manifest.AttemptID, manifest.ParentManifestID,
		manifest.Version, manifest.PromptVersion, manifest.ContractVersion,
		manifest.ToolSchemaVersion, manifest.Preset, manifest.Provider, manifest.Model,
		manifest.ReasoningEffort, omissions, manifest.CreatedAt.Format(timestampFormat),
	); err != nil {
		return core.ContextManifest{}, err
	}
	for index := range manifest.References {
		ref := &manifest.References[index]
		if ref.ID == "" {
			ref.ID = fmt.Sprintf("context_ref_%s_%04d", manifest.ID, index+1)
		}
		ref.ManifestID = manifest.ID
		ref.Ordinal = index + 1
		if strings.TrimSpace(ref.Kind) == "" || strings.TrimSpace(ref.Visibility) == "" ||
			(strings.TrimSpace(ref.SourceRef) == "" && strings.TrimSpace(ref.OmittedReason) == "") {
			return core.ContextManifest{}, fmt.Errorf("context reference %d is incomplete", index+1)
		}
		metadata, err := json.Marshal(ref.Metadata)
		if err != nil {
			return core.ContextManifest{}, err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO context_manifest_refs (
			  id, manifest_id, kind, source_ref, content_digest, source_revision,
			  visibility, ordinal, omitted_reason, metadata_json
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ref.ID, manifest.ID, ref.Kind, ref.SourceRef, ref.ContentDigest,
			ref.SourceRevision, ref.Visibility, ref.Ordinal, ref.OmittedReason, metadata,
		); err != nil {
			return core.ContextManifest{}, err
		}
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE episode_attempts SET context_manifest_id = ?, updated_at = ?
		WHERE id = ?`, manifest.ID, s.nowText(), manifest.AttemptID); err != nil {
		return core.ContextManifest{}, err
	}
	payload, _ := episodepkg.Encode(map[string]any{
		"manifest_id": manifest.ID, "attempt_id": manifest.AttemptID,
		"version": manifest.Version, "reference_count": len(manifest.References),
	})
	if _, err := s.appendEpisodeEventTx(ctx, tx, manifest.EpisodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventContextExtended, Actor: "host",
		IdempotencyKey: "context-manifest:" + manifest.ID, Payload: payload,
	}); err != nil {
		return core.ContextManifest{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.ContextManifest{}, err
	}
	return manifest, nil
}

func validateManifestLineage(ctx context.Context, tx *sql.Tx, manifest core.ContextManifest) error {
	if manifest.Version == 1 {
		if manifest.ParentManifestID != "" {
			return errors.New("first context manifest cannot have a parent")
		}
		return nil
	}
	if manifest.ParentManifestID == "" {
		return errors.New("continued context manifest requires its immediate parent")
	}
	var parentEpisode string
	var parentVersion int
	if err := tx.QueryRowContext(ctx, `
		SELECT episode_id, version FROM context_manifests WHERE id = ?`,
		manifest.ParentManifestID).Scan(&parentEpisode, &parentVersion); err != nil {
		return err
	}
	if parentEpisode != manifest.EpisodeID || parentVersion != manifest.Version-1 {
		return errors.New("context manifest parent is not the preceding episode version")
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT source_ref, content_digest FROM context_manifest_refs WHERE manifest_id = ?`,
		manifest.ParentManifestID)
	if err != nil {
		return err
	}
	defer rows.Close()
	newRefs := make(map[string]core.ContextReference, len(manifest.References))
	for _, ref := range manifest.References {
		newRefs[ref.SourceRef+"\x00"+ref.ContentDigest] = ref
	}
	for rows.Next() {
		var sourceRef, digest string
		if err := rows.Scan(&sourceRef, &digest); err != nil {
			return err
		}
		if _, ok := newRefs[sourceRef+"\x00"+digest]; ok {
			continue
		}
		removed := false
		for _, ref := range manifest.References {
			if ref.SourceRef == sourceRef && ref.OmittedReason != "" {
				removed = true
				break
			}
		}
		if !removed {
			return fmt.Errorf("context manifest dropped %q without an omission reason", sourceRef)
		}
	}
	return rows.Err()
}

func (s *Store) GetContextManifest(ctx context.Context, manifestID string) (core.ContextManifest, error) {
	var item core.ContextManifest
	var omissionsJSON, created string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, episode_id, attempt_id, parent_manifest_id, version,
		       prompt_version, contract_version, tool_schema_version, preset,
		       provider, model, reasoning_effort, omissions_json, created_at
		FROM context_manifests WHERE id = ?`, manifestID).Scan(
		&item.ID, &item.EpisodeID, &item.AttemptID, &item.ParentManifestID,
		&item.Version, &item.PromptVersion, &item.ContractVersion,
		&item.ToolSchemaVersion, &item.Preset, &item.Provider, &item.Model,
		&item.ReasoningEffort, &omissionsJSON, &created,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ContextManifest{}, ErrNotFound
	}
	if err != nil {
		return core.ContextManifest{}, err
	}
	if err := json.Unmarshal([]byte(omissionsJSON), &item.Omissions); err != nil {
		return core.ContextManifest{}, err
	}
	item.CreatedAt = sqlutil.ParseTime(created)
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, manifest_id, kind, source_ref, content_digest, source_revision,
		       visibility, ordinal, omitted_reason, metadata_json
		FROM context_manifest_refs WHERE manifest_id = ? ORDER BY ordinal`, manifestID)
	if err != nil {
		return core.ContextManifest{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var ref core.ContextReference
		var metadataJSON string
		if err := rows.Scan(
			&ref.ID, &ref.ManifestID, &ref.Kind, &ref.SourceRef, &ref.ContentDigest,
			&ref.SourceRevision, &ref.Visibility, &ref.Ordinal, &ref.OmittedReason,
			&metadataJSON,
		); err != nil {
			return core.ContextManifest{}, err
		}
		if err := json.Unmarshal([]byte(metadataJSON), &ref.Metadata); err != nil {
			return core.ContextManifest{}, err
		}
		item.References = append(item.References, ref)
	}
	return item, rows.Err()
}

func (s *Store) GetLatestContextManifest(
	ctx context.Context,
	episodeID string,
) (core.ContextManifest, error) {
	var manifestID string
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM context_manifests
		WHERE episode_id = ?
		ORDER BY version DESC
		LIMIT 1`, strings.TrimSpace(episodeID)).Scan(&manifestID)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ContextManifest{}, ErrNotFound
	}
	if err != nil {
		return core.ContextManifest{}, err
	}
	return s.GetContextManifest(ctx, manifestID)
}

func (s *Store) CreateEpisodeWakeup(ctx context.Context, wakeup core.EpisodeWakeup) (core.EpisodeWakeup, error) {
	wakeup.EpisodeID = strings.TrimSpace(wakeup.EpisodeID)
	wakeup.Kind = strings.TrimSpace(wakeup.Kind)
	if wakeup.EpisodeID == "" || wakeup.Kind == "" {
		return core.EpisodeWakeup{}, errors.New("wakeup episode and kind are required")
	}
	if wakeup.DueAt.IsZero() && wakeup.PollAfter.IsZero() {
		return core.EpisodeWakeup{}, errors.New("wakeup requires a due or poll time")
	}
	if !wakeup.Deadline.IsZero() {
		earliest := wakeup.DueAt
		if earliest.IsZero() || !wakeup.PollAfter.IsZero() && wakeup.PollAfter.Before(earliest) {
			earliest = wakeup.PollAfter
		}
		if wakeup.Deadline.Before(earliest) {
			return core.EpisodeWakeup{}, errors.New("wakeup deadline precedes its first observation")
		}
	}
	if wakeup.ID == "" {
		var err error
		wakeup.ID, err = core.NewID("wakeup")
		if err != nil {
			return core.EpisodeWakeup{}, err
		}
	}
	if len(wakeup.EventMatcher) == 0 {
		wakeup.EventMatcher = []byte("{}")
	}
	if !json.Valid(wakeup.EventMatcher) {
		return core.EpisodeWakeup{}, errors.New("wakeup event matcher must be JSON")
	}
	if len(wakeup.LastObservation) == 0 {
		wakeup.LastObservation = []byte("{}")
	}
	wakeup.State = core.WakeupPending
	now := s.now().UTC()
	wakeup.CreatedAt, wakeup.UpdatedAt = now, now
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	defer tx.Rollback()
	if _, err := scanWorkEpisode(tx.QueryRowContext(
		ctx, `SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`, wakeup.EpisodeID,
	)); err != nil {
		return core.EpisodeWakeup{}, err
	}
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO episode_wakeups (
		  id, episode_id, kind, event_matcher_json, due_at, poll_after, deadline,
		  state, last_observation_json, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		wakeup.ID, wakeup.EpisodeID, wakeup.Kind, wakeup.EventMatcher,
		nullableTime(wakeup.DueAt), nullableTime(wakeup.PollAfter), nullableTime(wakeup.Deadline),
		wakeup.LastObservation, now.Format(timestampFormat), now.Format(timestampFormat),
	)
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	if inserted == 0 {
		existing, existingErr := scanEpisodeWakeup(tx.QueryRowContext(
			ctx, episodeWakeupSelect+` WHERE id = ?`, wakeup.ID,
		))
		if existingErr != nil {
			return core.EpisodeWakeup{}, existingErr
		}
		if existing.EpisodeID != wakeup.EpisodeID || existing.Kind != wakeup.Kind ||
			string(existing.EventMatcher) != string(wakeup.EventMatcher) {
			return core.EpisodeWakeup{}, fmt.Errorf("wakeup id %q was reused with different semantics", wakeup.ID)
		}
		if err := tx.Commit(); err != nil {
			return core.EpisodeWakeup{}, err
		}
		return existing, nil
	}
	payload, _ := episodepkg.Encode(map[string]any{
		"wakeup_id": wakeup.ID, "kind": wakeup.Kind,
		"due_at": wakeup.DueAt, "deadline": wakeup.Deadline,
	})
	if _, err := s.appendEpisodeEventTx(ctx, tx, wakeup.EpisodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventExternalWaitStarted, Actor: "host",
		IdempotencyKey: "wakeup-created:" + wakeup.ID, Payload: payload,
	}); err != nil {
		return core.EpisodeWakeup{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.EpisodeWakeup{}, err
	}
	return wakeup, nil
}

const episodeWakeupSelect = `
	SELECT id, episode_id, kind, event_matcher_json, due_at, poll_after,
	       deadline, state, last_observation_json, lease_owner, fencing_token,
	       lease_expires_at, created_at, updated_at, resolved_at
	FROM episode_wakeups `

func scanEpisodeWakeup(row interface{ Scan(...any) error }) (core.EpisodeWakeup, error) {
	var item core.EpisodeWakeup
	var due, poll, deadline, leaseExpires, resolved sql.NullString
	var created, updated string
	err := row.Scan(
		&item.ID, &item.EpisodeID, &item.Kind, &item.EventMatcher, &due, &poll,
		&deadline, &item.State, &item.LastObservation, &item.LeaseOwner,
		&item.FencingToken, &leaseExpires, &created, &updated, &resolved,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EpisodeWakeup{}, ErrNotFound
	}
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	item.DueAt, item.PollAfter, item.Deadline = sqlutil.ScanTime(due), sqlutil.ScanTime(poll), sqlutil.ScanTime(deadline)
	item.LeaseExpiresAt, item.ResolvedAt = sqlutil.ScanTime(leaseExpires), sqlutil.ScanTime(resolved)
	item.CreatedAt, item.UpdatedAt = sqlutil.ParseTime(created), sqlutil.ParseTime(updated)
	return item, nil
}

func (s *Store) ListEpisodeWakeups(ctx context.Context, episodeID string) ([]core.EpisodeWakeup, error) {
	rows, err := s.db.QueryContext(ctx,
		episodeWakeupSelect+` WHERE episode_id = ? ORDER BY created_at`, episodeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []core.EpisodeWakeup
	for rows.Next() {
		item, err := scanEpisodeWakeup(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (s *Store) LeaseDueEpisodeWakeup(
	ctx context.Context,
	owner string,
	leaseDuration time.Duration,
) (core.EpisodeWakeup, error) {
	owner = strings.TrimSpace(owner)
	if owner == "" || leaseDuration <= 0 {
		return core.EpisodeWakeup{}, errors.New("wakeup lease owner and duration are required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	defer tx.Rollback()
	now := s.now().UTC()
	wakeup, err := scanEpisodeWakeup(tx.QueryRowContext(ctx, episodeWakeupSelect+`
		WHERE (state = 'pending' OR (state = 'leased' AND lease_expires_at <= ?))
		  AND (COALESCE(poll_after, due_at) IS NOT NULL)
		  AND COALESCE(poll_after, due_at) <= ?
		ORDER BY COALESCE(poll_after, due_at), created_at, id LIMIT 1`,
		now.Format(timestampFormat), now.Format(timestampFormat),
	))
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	if !wakeup.Deadline.IsZero() && !wakeup.Deadline.After(now) {
		if _, err := tx.ExecContext(ctx, `
			UPDATE episode_wakeups SET state = 'expired', resolved_at = ?, updated_at = ?
			WHERE id = ?`, now.Format(timestampFormat), now.Format(timestampFormat), wakeup.ID); err != nil {
			return core.EpisodeWakeup{}, err
		}
		if err := tx.Commit(); err != nil {
			return core.EpisodeWakeup{}, err
		}
		return core.EpisodeWakeup{}, ErrConflict
	}
	expires := now.Add(leaseDuration)
	result, err := tx.ExecContext(ctx, `
		UPDATE episode_wakeups
		SET state = 'leased', lease_owner = ?, fencing_token = fencing_token + 1,
		    lease_expires_at = ?, updated_at = ?
		WHERE id = ? AND (state = 'pending' OR lease_expires_at <= ?)`,
		owner, expires.Format(timestampFormat), now.Format(timestampFormat), wakeup.ID,
		now.Format(timestampFormat),
	)
	if err := sqlutil.ExpectOne(result, err, "lease episode wakeup"); err != nil {
		return core.EpisodeWakeup{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.EpisodeWakeup{}, err
	}
	items, err := s.ListEpisodeWakeups(ctx, wakeup.EpisodeID)
	if err != nil {
		return core.EpisodeWakeup{}, err
	}
	for _, item := range items {
		if item.ID == wakeup.ID {
			return item, nil
		}
	}
	return core.EpisodeWakeup{}, ErrNotFound
}

func (s *Store) ResolveEpisodeWakeup(
	ctx context.Context,
	id string,
	owner string,
	fencingToken int64,
	observation []byte,
) error {
	if len(observation) == 0 {
		observation = []byte("{}")
	}
	if !json.Valid(observation) {
		return errors.New("wakeup observation must be JSON")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	wakeup, err := scanEpisodeWakeup(tx.QueryRowContext(ctx, episodeWakeupSelect+` WHERE id = ?`, id))
	if err != nil {
		return err
	}
	now := s.now().UTC()
	result, err := tx.ExecContext(ctx, `
		UPDATE episode_wakeups
		SET state = 'resolved', last_observation_json = ?, lease_owner = '',
		    lease_expires_at = NULL, resolved_at = ?, updated_at = ?
		WHERE id = ? AND state = 'leased' AND lease_owner = ? AND fencing_token = ?`,
		observation, now.Format(timestampFormat), now.Format(timestampFormat), id,
		strings.TrimSpace(owner), fencingToken,
	)
	if err := sqlutil.ExpectOne(result, err, "resolve episode wakeup"); err != nil {
		return err
	}
	payload, _ := episodepkg.Encode(map[string]any{
		"wakeup_id": id, "kind": wakeup.Kind, "observation": json.RawMessage(observation),
	})
	if _, err := s.appendEpisodeEventTx(ctx, tx, wakeup.EpisodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventWakeupResolved, Actor: "host",
		IdempotencyKey: fmt.Sprintf("wakeup-resolved:%s:%d", id, fencingToken), Payload: payload,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RetryEpisodeWakeup(
	ctx context.Context,
	id string,
	owner string,
	fencingToken int64,
	next time.Time,
	observation []byte,
) error {
	if next.IsZero() {
		return errors.New("wakeup retry time is required")
	}
	if len(observation) == 0 {
		observation = []byte("{}")
	}
	if !json.Valid(observation) {
		return errors.New("wakeup observation must be JSON")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE episode_wakeups
		SET state = 'pending', poll_after = ?, last_observation_json = ?,
		    lease_owner = '', lease_expires_at = NULL, updated_at = ?
		WHERE id = ? AND state = 'leased' AND lease_owner = ? AND fencing_token = ?`,
		next.UTC().Format(timestampFormat), observation, s.nowText(), id,
		strings.TrimSpace(owner), fencingToken,
	)
	return sqlutil.ExpectOne(result, err, "retry episode wakeup")
}

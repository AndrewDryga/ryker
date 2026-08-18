package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store/lifecyclecheck"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// SumEpisodeStructuredCorrections totals the host corrections every run of an
// episode has spent.
//
// This is the second correction budget's measurement. It used to be the
// episode's attempt NUMBER, which was the same thing back when a re-triggered
// alert opened a new episode every time. Now that an alert stream stays one
// episode across every card and wakeup it produces, the attempt number counts
// cards, and a stream that fires all day would have been refused its first
// correction at attempt twenty-one having spent none.
//
// A run whose context envelope has no counter contributes zero, which is what a
// run that has never been corrected means.
func (s *Store) SumEpisodeStructuredCorrections(
	ctx context.Context,
	episodeID string,
) (int, error) {
	if strings.TrimSpace(episodeID) == "" {
		return 0, errors.New("episode is required")
	}
	var total int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(
		  COALESCE(json_extract(context_json, '$.structured_corrections'), 0)
		), 0)
		FROM agent_runs
		WHERE episode_id = ?`, episodeID,
	).Scan(&total); err != nil {
		return 0, err
	}
	return total, nil
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
	return s.queueAgentRun(ctx, run, episode.ID)
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
		SET channel_id = CASE WHEN channel_id = '' THEN ? ELSE channel_id END,
		    thread_ts = CASE
		      WHEN thread_ts = '' AND (channel_id = '' OR channel_id = ?) THEN ?
		      ELSE thread_ts
		    END,
		    destination_channel_id = ?, destination_thread_ts = ?,
		    destination_revision = destination_revision + 1, updated_at = ?
		WHERE id = ? AND event_sequence = ?`,
		destination.ChannelID, destination.ChannelID, destination.ThreadTS,
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
		return core.EpisodeGoal{}, fmt.Errorf("unsupported goal authority %q: %w", goal.AuthorityRequirement, ErrEpisodeOperationConflict)
	}
	if goal.State == "" {
		goal.State = core.GoalPlanned
	}
	if !validGoalState(goal.State) {
		return core.EpisodeGoal{}, fmt.Errorf("unsupported goal state %q: %w", goal.State, ErrEpisodeOperationConflict)
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
			return core.EpisodeGoal{}, fmt.Errorf("goal prerequisite %q is not in episode: %w", prerequisiteID, ErrEpisodeOperationConflict)
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
			return core.EpisodeGoal{}, fmt.Errorf("goal id %q was reused with different semantics: %w", goal.ID, ErrEpisodeOperationConflict)
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
		return fmt.Errorf("unsupported goal state %q: %w", state, ErrEpisodeOperationConflict)
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
				return fmt.Errorf("goal %s cannot complete before prerequisite %s: %w", goal.ID, prerequisiteID, ErrEpisodeOperationConflict)
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
		  provider, model, reasoning_effort, submitted_prompt, target_floor,
		  omissions_json, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		manifest.ID, manifest.EpisodeID, manifest.AttemptID, manifest.ParentManifestID,
		manifest.Version, manifest.PromptVersion, manifest.ContractVersion,
		manifest.ToolSchemaVersion, manifest.Preset, manifest.Provider, manifest.Model,
		manifest.ReasoningEffort, manifest.SubmittedPrompt, manifest.TargetFloor,
		omissions, manifest.CreatedAt.Format(timestampFormat),
	); err != nil {
		return core.ContextManifest{}, err
	}
	// The archive copy, in the same transaction as the manifest it describes so
	// a turn can never end up with one and not the other. Written only when the
	// caller sanitized something: an empty row would claim a prompt was kept and
	// found to be blank, which is a different fact from no prompt at all.
	if manifest.RetainedPrompt != "" {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO context_manifest_texts (manifest_id, prompt, created_at)
			VALUES (?, ?, ?)`,
			manifest.ID, manifest.RetainedPrompt, manifest.CreatedAt.Format(timestampFormat),
		); err != nil {
			return core.ContextManifest{}, err
		}
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
	// Only the parent's actual context has to be accounted for. The execution
	// profile describes that single attempt's route and is replaced, not
	// inherited, when a continuation moves between watch, chat, investigate or
	// engineer. Requiring it here made that legal transition look like lost
	// evidence and deterministically rejected every retry before a turn started.
	// A row carrying
	// an omission reason records something the parent attempt did NOT send, so
	// there is nothing for the child to have dropped and nothing for it to
	// explain — and requiring the child to repeat it would make every omission
	// permanent, so a layer trimmed once would read as trimmed forever even on
	// the attempts that carried it in full.
	rows, err := tx.QueryContext(ctx, `
		SELECT source_ref, content_digest FROM context_manifest_refs
		WHERE manifest_id = ? AND omitted_reason = ''
		  AND kind <> 'execution_profile'`,
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
	var queuedMS, providerMS, hostMS int64
	err := s.db.QueryRowContext(ctx, `
		SELECT id, episode_id, attempt_id, parent_manifest_id, version,
		       prompt_version, contract_version, tool_schema_version, preset,
		       provider, model, reasoning_effort, submitted_prompt, target_floor,
		       omissions_json, created_at,
		       usage_input_tokens, usage_cached_input_tokens,
		       usage_output_tokens, usage_reasoning_tokens, usage_cost_usd,
		       usage_costed_turns,
		       usage_timed_turns, usage_queued_ms, usage_provider_ms, usage_host_ms,
		       COALESCE((SELECT t.prompt FROM context_manifest_texts AS t
		                 WHERE t.manifest_id = context_manifests.id), '')
		FROM context_manifests WHERE id = ?`, manifestID).Scan(
		&item.ID, &item.EpisodeID, &item.AttemptID, &item.ParentManifestID,
		&item.Version, &item.PromptVersion, &item.ContractVersion,
		&item.ToolSchemaVersion, &item.Preset, &item.Provider, &item.Model,
		&item.ReasoningEffort, &item.SubmittedPrompt, &item.TargetFloor,
		&omissionsJSON, &created,
		&item.Usage.InputTokens, &item.Usage.CachedInputTokens,
		&item.Usage.OutputTokens, &item.Usage.ReasoningTokens,
		&item.Usage.CostUSD, &item.Usage.CostedTurns,
		&item.Latency.Turns, &queuedMS, &providerMS, &hostMS,
		&item.RetainedPrompt,
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
	item.Latency.Queued = time.Duration(queuedMS) * time.Millisecond
	item.Latency.Provider = time.Duration(providerMS) * time.Millisecond
	item.Latency.Host = time.Duration(hostMS) * time.Millisecond
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

// RecordAttemptTurnCost adds one finished Coop turn's tokens and wall-clock to
// the attempt's context manifest, which is the per-attempt row that already
// froze which model answered.
//
// Both in one statement rather than one call each, because they share the
// idempotency key below and a second UPDATE would find that key already
// written and silently drop whichever of the two went second.
//
// Either half may be absent and the other still worth keeping. Today that is
// the common case and not a hypothetical: Coop reports no usage at all on the
// ACP path, so gating the write on tokens would record no timings either, and
// the latency columns would stay as empty as the ones this is meant to fill.
//
// It adds rather than assigns because an attempt is not one turn. A result the
// host refuses is sent back to the model as a correction, and that correction
// reuses the same agent run, the same attempt and therefore the same manifest —
// attempt_id is written once when the run is created and never updated. An
// assignment would leave a three-correction attempt reporting only the tokens
// of its final turn, understating exactly the attempts worth looking at.
//
// It is keyed on the Coop turn that produced the usage, and adding the same
// turn twice does nothing. The caller records on the way out of a terminal
// turn, before the staging that follows it can fail; when that staging does
// fail the run stays running and the whole path runs again on the next poll
// with the same turn. Without the key the retry would count those tokens a
// second time, and a total that inflates on failure is worse than no total,
// because nothing distinguishes it from a real one.
//
// The manifest is reached through episode_attempts.context_manifest_id rather
// than by matching attempt_id on the manifest itself. Two manifests can carry
// the same attempt_id — an extended context writes a second version against the
// same attempt — and an UPDATE matching on it would count the same turn once
// per version. That pointer names the one manifest the attempt is actually
// using.
//
// A usage report with nothing in it, or an attempt whose manifest has gone, is
// not an error. Coop omits the usage object entirely when a provider reported
// nothing, and losing an episode between a turn finishing and this write is a
// race — neither is worth failing a finished turn over.
func (s *Store) RecordAttemptTurnCost(
	ctx context.Context,
	attemptID string,
	turnID string,
	usage core.ContextUsage,
	latency core.ContextLatency,
) error {
	attemptID, turnID = strings.TrimSpace(attemptID), strings.TrimSpace(turnID)
	if attemptID == "" || turnID == "" {
		return errors.New("attempt and coop turn are required to record what a turn cost")
	}
	if usage.CostUSD < 0 || math.IsNaN(usage.CostUSD) || math.IsInf(usage.CostUSD, 0) ||
		usage.CostedTurns < 0 {
		return errors.New("provider-reported cost is outside bounds")
	}
	if !usage.Recorded() && !usage.CostRecorded() && !latency.Recorded() {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE context_manifests SET
		  usage_input_tokens = usage_input_tokens + ?,
		  usage_cached_input_tokens = usage_cached_input_tokens + ?,
		  usage_output_tokens = usage_output_tokens + ?,
		  usage_reasoning_tokens = usage_reasoning_tokens + ?,
		  usage_cost_usd = usage_cost_usd + ?,
		  usage_costed_turns = usage_costed_turns + ?,
		  usage_timed_turns = usage_timed_turns + ?,
		  usage_queued_ms = usage_queued_ms + ?,
		  usage_provider_ms = usage_provider_ms + ?,
		  usage_host_ms = usage_host_ms + ?,
		  usage_last_turn_id = ?
		WHERE id = (SELECT context_manifest_id FROM episode_attempts WHERE id = ?)
		  AND usage_last_turn_id <> ?`,
		usage.InputTokens, usage.CachedInputTokens, usage.OutputTokens,
		usage.ReasoningTokens, usage.CostUSD, usage.CostedTurns,
		latency.Turns, latency.Queued.Milliseconds(),
		latency.Provider.Milliseconds(), latency.Host.Milliseconds(),
		turnID, attemptID, turnID)
	return err
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
		  id, episode_id, kind, verification, event_matcher_json, due_at, poll_after, deadline,
		  state, last_observation_json, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		wakeup.ID, wakeup.EpisodeID, wakeup.Kind, wakeup.Verification, wakeup.EventMatcher,
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
			existing.Verification != wakeup.Verification ||
			string(existing.EventMatcher) != string(wakeup.EventMatcher) {
			return core.EpisodeWakeup{}, fmt.Errorf("wakeup id %q was reused with different semantics: %w", wakeup.ID, ErrEpisodeOperationConflict)
		}
		if err := tx.Commit(); err != nil {
			return core.EpisodeWakeup{}, err
		}
		return existing, nil
	}
	payload, _ := episodepkg.Encode(map[string]any{"wakeup_id": wakeup.ID, "kind": wakeup.Kind, "verification": wakeup.Verification, "due_at": wakeup.DueAt, "deadline": wakeup.Deadline})
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
	SELECT id, episode_id, kind, verification, event_matcher_json, due_at, poll_after,
	       deadline, state, last_observation_json, lease_owner, fencing_token,
	       lease_expires_at, created_at, updated_at, resolved_at
	FROM episode_wakeups `

func scanEpisodeWakeup(row interface{ Scan(...any) error }) (core.EpisodeWakeup, error) {
	var item core.EpisodeWakeup
	var due, poll, deadline, leaseExpires, resolved sql.NullString
	var created, updated string
	err := row.Scan(
		&item.ID, &item.EpisodeID, &item.Kind, &item.Verification, &item.EventMatcher, &due, &poll,
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
	if err := lifecyclecheck.CancelWakeupsUnderTerminalEpisodes(ctx, tx, now.Format(timestampFormat)); err != nil {
		return core.EpisodeWakeup{}, err
	}
	wakeup, err := scanEpisodeWakeup(tx.QueryRowContext(ctx, episodeWakeupSelect+`
		WHERE (state = 'pending' OR (state = 'leased' AND lease_expires_at <= ?))
		  AND (COALESCE(poll_after, due_at) IS NOT NULL)
		  AND COALESCE(poll_after, due_at) <= ?
		ORDER BY COALESCE(poll_after, due_at), created_at, id LIMIT 1`,
		now.Format(timestampFormat), now.Format(timestampFormat),
	))
	if errors.Is(err, ErrNotFound) {
		// The reconciliation above is useful work even when it removed the only
		// row this lease could have returned. Commit it before reporting an empty
		// queue, otherwise the deferred rollback resurrects the stale wakeup.
		if commitErr := tx.Commit(); commitErr != nil {
			return core.EpisodeWakeup{}, commitErr
		}
		return core.EpisodeWakeup{}, ErrNotFound
	}
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

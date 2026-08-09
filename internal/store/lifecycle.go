package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func (s *Store) GetPublication(ctx context.Context, incidentID string) (core.Publication, error) {
	var item core.Publication
	var created, updated string
	var published sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT incident_id, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  last_error, created_at, updated_at, published_at
		FROM publications WHERE incident_id = ?`, incidentID).Scan(
		&item.IncidentID, &item.Repository, &item.BaseBranch, &item.HeadBranch,
		&item.ParentHead, &item.CandidateTree, &item.CommitSHA, &item.RemoteSHA,
		&item.PRNumber, &item.PRURL, &item.State, &item.LastError, &created,
		&updated, &published,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.Publication{}, ErrNotFound
	}
	if err != nil {
		return core.Publication{}, err
	}
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	item.PublishedAt = sqlutil.ScanTime(published)
	return item, nil
}

func (s *Store) SavePublication(ctx context.Context, item core.Publication) error {
	if item.IncidentID == "" || item.Repository == "" || item.BaseBranch == "" ||
		item.ParentHead == "" || item.CandidateTree == "" {
		return errors.New("publication identity, reviewed tree, and state are required")
	}
	switch item.State {
	case "publishing", "failed":
	case "published", "stale":
		if item.HeadBranch == "" || item.CommitSHA == "" || item.RemoteSHA == "" ||
			item.PRNumber < 1 || item.PRURL == "" || item.PublishedAt.IsZero() {
			return errors.New("durable draft PR identity and proof are required")
		}
	default:
		return fmt.Errorf("publication state %q is invalid", item.State)
	}
	now := s.now().UTC()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	item.UpdatedAt = now
	var published any
	if !item.PublishedAt.IsZero() {
		published = item.PublishedAt.UTC().Format(timestampFormat)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `
		INSERT INTO publications (
		  incident_id, repository, base_branch, head_branch, parent_head,
		  candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
		  last_error, created_at, updated_at, published_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(incident_id) DO UPDATE SET
		  repository = excluded.repository,
		  base_branch = excluded.base_branch,
		  head_branch = excluded.head_branch,
		  parent_head = excluded.parent_head,
		  candidate_tree = excluded.candidate_tree,
		  commit_sha = excluded.commit_sha,
		  remote_sha = excluded.remote_sha,
		  pr_number = excluded.pr_number,
		  pr_url = excluded.pr_url,
		  state = excluded.state,
		  last_error = excluded.last_error,
		  updated_at = excluded.updated_at,
		  published_at = excluded.published_at`,
		item.IncidentID, item.Repository, item.BaseBranch, item.HeadBranch,
		item.ParentHead, item.CandidateTree, item.CommitSHA, item.RemoteSHA,
		item.PRNumber, item.PRURL, item.State, item.LastError,
		item.CreatedAt.UTC().Format(timestampFormat), item.UpdatedAt.Format(timestampFormat),
		published,
	)
	if err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now.Format(timestampFormat), item.IncidentID)
	if err := sqlutil.ExpectOne(result, err, "mark publication on incident"); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) MarkPublicationStale(
	ctx context.Context,
	incidentID string,
	reason string,
) (bool, error) {
	if incidentID == "" || reason == "" {
		return false, errors.New("stale publication identity and reason are required")
	}
	now := s.nowText()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE publications
		SET state = 'stale', last_error = ?, updated_at = ?
		WHERE incident_id = ? AND state = 'published'`,
		reason, now, incidentID,
	)
	if err != nil {
		return false, err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if changed == 0 {
		return false, tx.Commit()
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE incidents
		SET updated_at = ?, card_version = card_version + 1
		WHERE id = ?`, now, incidentID)
	if err := sqlutil.ExpectOne(result, err, "mark stale publication on incident"); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

func (s *Store) ScheduleCleanup(
	ctx context.Context,
	sessionID string,
	incidentID string,
	reason string,
	allowUnmerged bool,
	eligibleAt time.Time,
) error {
	if sessionID == "" || reason == "" {
		return errors.New("cleanup session and reason are required")
	}
	now := s.nowText()
	allow := 0
	if allowUnmerged {
		allow = 1
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
		  incident_id = CASE
		    WHEN coop_cleanup.incident_id = '' THEN excluded.incident_id
		    ELSE coop_cleanup.incident_id
		  END,
		  allow_unmerged = MAX(coop_cleanup.allow_unmerged, excluded.allow_unmerged),
		  eligible_at = MIN(coop_cleanup.eligible_at, excluded.eligible_at),
		  updated_at = excluded.updated_at
		WHERE coop_cleanup.state != 'done'`,
		sessionID, incidentID, reason, allow,
		eligibleAt.UTC().Format(timestampFormat), eligibleAt.UTC().Format(timestampFormat),
		now, now,
	)
	return err
}

func (s *Store) BackfillClosedSessionCleanup(
	ctx context.Context,
	eligibleBefore time.Time,
) (int64, error) {
	now := s.nowText()
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		)
		SELECT i.coop_session_id, i.id, 'closed work',
		  CASE WHEN p.state = 'published' THEN 1 ELSE 0 END,
		  'pending', i.closed_at, i.closed_at, ?, ?
		FROM incidents i
		LEFT JOIN publications p ON p.incident_id = i.id
		WHERE i.status = 'closed' AND i.coop_session_id != ''
		  AND i.closed_at IS NOT NULL AND i.closed_at <= ?`,
		now, now, eligibleBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) RetireResolvedDeletedWork(
	ctx context.Context,
	deletedBefore time.Time,
) (int64, error) {
	now := s.nowText()
	cutoff := deletedBefore.UTC().Format(timestampFormat)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		)
		SELECT i.coop_session_id, i.id, 'resolved work lost its Slack channel',
		  CASE WHEN p.state = 'published' THEN 1 ELSE 0 END,
		  'pending', ?, ?, ?, ?
		FROM incidents i
		LEFT JOIN publications p ON p.incident_id = i.id
		WHERE i.status = 'resolved' AND i.channel_state = 'deleted'
		  AND i.active_turn_id = '' AND i.coop_session_id != ''
		  AND COALESCE(i.channel_state_changed_at, i.resolved_at, i.updated_at) <= ?`,
		now, now, now, now, cutoff,
	); err != nil {
		return 0, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents
		SET status = 'closed', workflow = 'closed', closed_at = ?,
		  updated_at = ?, card_version = card_version + 1,
		  last_error = CASE
		    WHEN coop_session_id = '' THEN ''
		    ELSE 'Slack room was deleted after the incident resolved; retained work is queued for ownership-checked cleanup.'
		  END
		WHERE status = 'resolved' AND channel_state = 'deleted'
		  AND active_turn_id = ''
		  AND COALESCE(channel_state_changed_at, resolved_at, updated_at) <= ?`,
		now, now, cutoff,
	)
	if err != nil {
		return 0, err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return count, nil
}

func (s *Store) ScheduleExpiredChannelMemoryCleanup(
	ctx context.Context,
	startedBefore time.Time,
	eligibleAt time.Time,
) (int64, error) {
	now := s.nowText()
	eligible := eligibleAt.UTC().Format(timestampFormat)
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		)
		SELECT session_id, '', 'expired Slack channel memory', 0, 'pending',
		  ?, ?, ?, ?
		FROM channel_memories
		WHERE session_id != '' AND session_started_at IS NOT NULL
		  AND session_started_at <= ?`,
		eligible, eligible, now, now, startedBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	channelCount, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	result, err = s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO coop_cleanup (
		  session_id, incident_id, reason, allow_unmerged, state,
		  eligible_at, next_attempt_at, created_at, updated_at
		)
		SELECT session_id, '', 'expired Slack conversation session', 0, 'pending',
		  ?, ?, ?, ?
		FROM conversation_sessions
		WHERE session_id != '' AND session_started_at IS NOT NULL
		  AND session_started_at <= ?`,
		eligible, eligible, now, now, startedBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	conversationCount, err := result.RowsAffected()
	return channelCount + conversationCount, err
}

func (s *Store) RetireActionProposals(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE action_proposals
		SET status = 'failed',
		    result = 'Operational actions are disabled in this Responder release.',
		    updated_at = ?
		WHERE status IN ('pending', 'approved', 'queued', 'running')`,
		now.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) ResponderSessionKnown(ctx context.Context, sessionID string) (bool, error) {
	if sessionID == "" {
		return false, errors.New("session ID is required")
	}
	var known int
	err := s.db.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1 FROM incidents WHERE coop_session_id = ?
		  UNION ALL
		  SELECT 1 FROM channel_memories WHERE session_id = ?
		  UNION ALL
		  SELECT 1 FROM conversation_sessions WHERE session_id = ?
		  UNION ALL
		  SELECT 1 FROM coop_cleanup WHERE session_id = ?
		)`, sessionID, sessionID, sessionID, sessionID).Scan(&known)
	return known != 0, err
}

func (s *Store) NextCleanup(ctx context.Context, now time.Time) (core.CoopCleanup, error) {
	var item core.CoopCleanup
	var allow int
	var eligible, next, created, updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT session_id, incident_id, reason, allow_unmerged, state,
		  plan_operation_id, attempts, eligible_at, next_attempt_at, last_error,
		  created_at, updated_at
		FROM coop_cleanup
		WHERE state IN ('pending', 'retry', 'planning', 'discarding')
		  AND eligible_at <= ? AND next_attempt_at <= ?
		ORDER BY eligible_at, created_at LIMIT 1`,
		now.UTC().Format(timestampFormat), now.UTC().Format(timestampFormat)).Scan(
		&item.SessionID, &item.IncidentID, &item.Reason, &allow, &item.State,
		&item.PlanOperationID, &item.Attempts, &eligible, &next, &item.LastError,
		&created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.CoopCleanup{}, ErrNotFound
	}
	if err != nil {
		return core.CoopCleanup{}, err
	}
	item.AllowUnmerged = allow != 0
	item.EligibleAt = sqlutil.ParseTime(eligible)
	item.NextAttemptAt = sqlutil.ParseTime(next)
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	return item, nil
}

func (s *Store) SetCleanupState(
	ctx context.Context,
	sessionID string,
	state string,
	planOperationID string,
	lastError string,
	retryAt time.Time,
) error {
	if retryAt.IsZero() {
		retryAt = s.now().UTC()
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE coop_cleanup SET state = ?, plan_operation_id = ?, last_error = ?,
		  attempts = attempts + 1, next_attempt_at = ?, updated_at = ?
		WHERE session_id = ?`,
		state, planOperationID, lastError, retryAt.UTC().Format(timestampFormat),
		s.nowText(), sessionID,
	)
	if err := sqlutil.ExpectOne(result, err, "update Coop cleanup"); err != nil {
		return err
	}
	if state == "done" {
		_, err = s.db.ExecContext(ctx, `
			UPDATE incidents SET card_version = card_version + 1, updated_at = ?
			WHERE id = (
			  SELECT incident_id FROM coop_cleanup WHERE session_id = ?
			) AND id != ''`, s.nowText(), sessionID)
	}
	return err
}

// RequeueBlockedCleanup puts one operator-held cleanup row back in front of
// the janitor, which re-runs every safety check and deletes nothing a check
// refuses. Attempts and the recorded refusal are kept: they are the history
// of why the row was held, and the next pass overwrites them with its own
// outcome. Only blocked rows qualify — requeueing a row the janitor already
// owns would just double its schedule.
func (s *Store) RequeueBlockedCleanup(ctx context.Context, sessionID string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE coop_cleanup SET state = 'retry', next_attempt_at = ?, updated_at = ?
		WHERE session_id = ? AND state = 'blocked'`,
		s.nowText(), s.nowText(), sessionID)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return errors.New("this workspace is not operator-held; it is already queued, running, or reclaimed")
	}
	return nil
}

// terminalEpisodeStates is the lifecycle boundary retention is allowed to act
// on, spelled as SQL because these predicates run inside DELETE statements.
// It matches episode.Terminal exactly; a state missing here would be an episode
// this package quietly refuses to expire, and a state wrongly added would be
// live work deleted underneath a running turn.
const terminalEpisodeStates = `('completed', 'failed', 'refused', 'cancelled', 'superseded')`

const terminalAgentRunStates = `('completed', 'failed', 'cancelled', 'superseded')`

// pinnedEpisode is true while something still depends on episode e, and it has
// nothing to do with age. Retention consults it on every path that could reach
// episode history, whatever horizon that path is applying:
//
//   - a pending or approved correction is a lesson somebody queued or kept, and
//     the episode is the evidence it will be reviewed and promoted against. An
//     approved candidate pins its episode indefinitely and deliberately, until
//     it is promoted or rejected, because deleting it would destroy the exact
//     thing an operator said to keep. This is what makes the fourteen-day
//     fixture TTL safe against any retention horizon anyone configures;
//   - open feedback is a person's unanswered complaint about this episode;
//   - a live wakeup means the episode is scheduled to resume, whatever its
//     recorded lifecycle state says.
//
// All three are checked explicitly rather than trusted to foreign keys, because
// not one of the three tables has one pointing here.
//
// Correlated on an episode aliased e.
const pinnedEpisode = `
	EXISTS (
	  SELECT 1 FROM fixture_candidates f
	  WHERE f.episode_id = e.id AND f.status IN ('pending', 'approved')
	)
	OR EXISTS (
	  SELECT 1 FROM feedback_items b
	  WHERE b.episode_id = e.id AND b.status = 'open'
	)
	OR EXISTS (
	  SELECT 1 FROM episode_wakeups w
	  WHERE w.episode_id = e.id AND w.state IN ('pending', 'leased')
	)`

// expirableEpisodes selects finished episodes nothing is still waiting on.
//
// Beyond the pins above, three more refusals, each naming something that would
// break if the episode disappeared underneath it: a non-terminal child episode
// still refers to this one as its parent; a run that is not terminal is work
// still executing; and an open incident still displays this history on its own
// page.
//
// work_episode_events, progress, attempts, manifests, refs, claims, goals,
// wakeups and commitments all reference work_episodes ON DELETE CASCADE, so
// deleting the episode row collects every one of them and this query does not
// mention them. That is also why retention is episode-granular and never
// deletes events out from under a surviving episode: the event stream is the
// aggregate's own history, and thinning it in place would leave a record of the
// work that is missing the parts nobody thought were interesting.
const expirableEpisodes = `
	SELECT e.id FROM work_episodes e
	WHERE e.lifecycle_state IN ` + terminalEpisodeStates + `
	  AND e.updated_at < ?
	  AND NOT (` + pinnedEpisode + `)
	  AND NOT EXISTS (
	    SELECT 1 FROM work_episodes child
	    WHERE child.parent_episode_id = e.id
	      AND child.lifecycle_state NOT IN ` + terminalEpisodeStates + `
	  )
	  AND NOT EXISTS (
	    SELECT 1 FROM agent_runs r
	    WHERE (r.episode_id = e.id OR r.id = e.agent_run_id)
	      AND r.state NOT IN ` + terminalAgentRunStates + `
	  )
	  AND NOT EXISTS (
	    SELECT 1 FROM agent_runs r
	    JOIN incidents i ON i.id = r.incident_id
	    WHERE (r.episode_id = e.id OR r.id = e.agent_run_id)
	      AND i.status != 'closed'
	  )`

// incidentHoldsPinnedEpisode is the same refusal reached from the other side.
//
// Closing an incident eventually deletes its agent runs, and work_episodes
// references agent_runs ON DELETE CASCADE, so the closed-work sweep destroys
// episode history too — on the closed-work horizon, which is seven days, which
// is shorter than the fourteen-day fixture TTL. A correction queued on a closed
// incident's episode could therefore be reviewed against nothing at all, and
// the episode-history guards above would never have been consulted.
//
// Correlated on an incident aliased i.
const incidentHoldsPinnedEpisode = `
	EXISTS (
	  SELECT 1 FROM work_episodes e
	  JOIN agent_runs r ON (r.episode_id = e.id OR r.id = e.agent_run_id)
	  WHERE r.incident_id = i.id AND (` + pinnedEpisode + `)
	)`

func (s *Store) Prune(
	ctx context.Context,
	operationalBefore time.Time,
	conversationBefore time.Time,
	closedBefore time.Time,
	episodeHistoryBefore time.Time,
	auditBefore time.Time,
) (core.PruneResult, error) {
	var result core.PruneResult
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	deleteCount := func(query string, args ...any) (int64, error) {
		res, execErr := tx.ExecContext(ctx, query, args...)
		if execErr != nil {
			return 0, execErr
		}
		return res.RowsAffected()
	}
	operational := operationalBefore.UTC().Format(timestampFormat)
	if result.SlackInputs, err = deleteCount(`
		DELETE FROM slack_inputs WHERE state IN ('done', 'failed') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	if result.WebhookEvents, err = deleteCount(`
		DELETE FROM webhook_events WHERE state IN ('done', 'failed') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	if result.SlackDeliveries, err = deleteCount(`
		DELETE FROM slack_deliveries
		WHERE state IN ('sent', 'failed', 'superseded') AND updated_at < ?`,
		operational); err != nil {
		return result, err
	}
	// Episode history expires on its own, much longer clock, and it runs before
	// the agent_runs sweep below on purpose — see the comment there.
	if result.Episodes, err = deleteCount(
		`DELETE FROM work_episodes WHERE id IN (`+expirableEpisodes+`)`,
		episodeHistoryBefore.UTC().Format(timestampFormat),
	); err != nil {
		return result, fmt.Errorf("prune expired episode history: %w", err)
	}
	// The two NOT EXISTS clauses read like a no-op and are the opposite of one.
	//
	// work_episodes.agent_run_id references this table ON DELETE CASCADE, so
	// deleting an aged run does not leave an orphaned episode — it deletes the
	// episode, its event stream, its attempts, its manifests and its evidence.
	// Without these clauses this statement would expire every episode in the
	// database at the operational horizon, which is twenty-four hours, and the
	// deletion would be invisible because the count reported is of runs.
	//
	// They did make the statement unreachable, which is the bug they got
	// reported as: every episode-driven run writes an attempt row, so all 428
	// runs on the deployed database were unprunable and every prune logged
	// "agent_runs":0 forever. The fix is not to weaken the guard. It is that
	// nothing ever expired the episodes, so the condition could never come true.
	// It can now: the sweep above removes finished episode history on its own
	// horizon, and the runs it leaves behind are collected here in the same
	// pass, in the correct order, still refusing to touch a run any episode
	// record still points at.
	if result.AgentRuns, err = deleteCount(`
		DELETE FROM agent_runs
		WHERE state IN `+terminalAgentRunStates+`
		  AND updated_at < ?
		  AND NOT EXISTS (
		    SELECT 1 FROM episode_attempts
		    WHERE episode_attempts.agent_run_id = agent_runs.id
		  )
		  AND NOT EXISTS (
		    SELECT 1 FROM work_episodes
		    WHERE work_episodes.agent_run_id = agent_runs.id
		  )`,
		operational); err != nil {
		return result, err
	}
	// What is left is the assembled prompt input on runs that are over: 9.7 MB
	// of the 11.9 MB agent_runs occupies on the deployed database, averaging
	// 23.6 KB a row. Emptying the blob rather than deleting the row is the whole
	// point — the row is the episode's transport record and its attempt history
	// hangs off it, so deleting it would take the account of the work with it,
	// while the assembled context is the one part that is genuinely spent.
	//
	// It expires on the operational horizon because that is what it is: channel
	// memory, recent messages and matched rules, gathered to run one turn.
	// architecture-next §29 draws exactly this line — message bodies expire
	// before the episode events do.
	//
	// Two things can still read it back, and both are excluded rather than
	// hoped about. A wakeup resumes a non-terminal episode by copying the
	// previous run's context into the new attempt's frozen input. And an
	// operator can retry a failed run from the control plane, which reuses the
	// same row — "retry the work from preserved context" is what that path
	// tells them — as long as it is still the episode's latest attempt and the
	// episode has not completed on another one. A run neither of those can
	// reach is a run whose context nothing will ever read again.
	if result.AgentRunContexts, err = deleteCount(`
		UPDATE agent_runs SET context_json = X''
		WHERE state IN `+terminalAgentRunStates+`
		  AND updated_at < ?
		  AND length(context_json) > 0
		  AND NOT EXISTS (
		    SELECT 1 FROM work_episodes e
		    WHERE (e.id = agent_runs.episode_id OR e.agent_run_id = agent_runs.id)
		      AND (
		        e.lifecycle_state NOT IN `+terminalEpisodeStates+`
		        OR (
		          agent_runs.state = 'failed'
		          AND agent_runs.attempt_id = e.latest_attempt_id
		          AND e.lifecycle_state != 'completed'
		        )
		      )
		  )`,
		operational); err != nil {
		return result, fmt.Errorf("empty spent agent run context: %w", err)
	}
	if result.EvaluationDecisions, err = deleteCount(`
		DELETE FROM evaluation_decisions WHERE created_at < ?`, operational); err != nil {
		return result, err
	}
	if result.ConversationMemories, err = deleteCount(`
		DELETE FROM conversation_memories WHERE updated_at < ?`,
		conversationBefore.UTC().Format(timestampFormat),
	); err != nil {
		return result, err
	}
	if result.MemoryEntries, err = deleteCount(`
		DELETE FROM memory_entries WHERE expires_at <= ?`, s.nowText()); err != nil {
		return result, err
	}
	if result.MemoryRollups, err = deleteCount(`
		DELETE FROM memory_rollups WHERE expires_at <= ?`, s.nowText()); err != nil {
		return result, err
	}
	if result.StandingRuleRuns, err = deleteCount(`
		DELETE FROM standing_rule_runs WHERE created_at < ?`, operational); err != nil {
		return result, err
	}
	if result.Preferences, err = deleteCount(`
		DELETE FROM responder_preferences WHERE expires_at <= ?`, s.nowText()); err != nil {
		return result, err
	}
	if result.StandingRules, err = deleteCount(`
		DELETE FROM standing_rules WHERE expires_at <= ?`, s.nowText()); err != nil {
		return result, err
	}
	if result.ScheduledTaskRuns, err = deleteCount(`
		DELETE FROM scheduled_task_runs
		WHERE outcome IN ('completed', 'failed', 'skipped_missed', 'skipped_overlap', 'skipped_unauthorized')
		  AND updated_at < ?`, operational); err != nil {
		return result, err
	}
	if result.ScheduledTasks, err = deleteCount(`
		DELETE FROM scheduled_tasks WHERE expires_at <= ?`, s.nowText()); err != nil {
		return result, err
	}
	if result.EmisarApprovals, err = deleteCount(`
		DELETE FROM emisar_approvals WHERE expires_at < ?`, operational); err != nil {
		return result, err
	}
	if result.ConfigurationSessions, err = deleteCount(`
		DELETE FROM configuration_sessions
		WHERE (status IN ('saved', 'cancelled', 'expired') AND updated_at < ?)
		   OR expires_at < ?`,
		operational, operational); err != nil {
		return result, err
	}
	if result.MemoryReviews, err = deleteCount(`
		DELETE FROM memory_review_items
		WHERE (status != 'pending' AND updated_at < ?)
		   OR (status = 'pending' AND NOT EXISTS (
		     SELECT 1 FROM json_each(memory_review_items.entry_ids_json) AS ref
		     JOIN memory_entries ON memory_entries.id = ref.value
		   ))`, auditBefore.UTC().Format(timestampFormat)); err != nil {
		return result, err
	}
	if result.MemorySupersessions, err = deleteCount(`
		DELETE FROM memory_supersessions WHERE created_at < ?`,
		auditBefore.UTC().Format(timestampFormat)); err != nil {
		return result, err
	}

	closed := closedBefore.UTC().Format(timestampFormat)
	for _, query := range []string{
		`DELETE FROM evidence WHERE incident_id = '' AND created_at < ?`,
		`DELETE FROM coverage WHERE incident_id = '' AND created_at < ?`,
		`DELETE FROM timeline_events WHERE incident_id = '' AND created_at < ?`,
	} {
		count, deleteErr := deleteCount(query, operational)
		if deleteErr != nil {
			return result, deleteErr
		}
		result.ChannelIntelligence += count
	}
	count, deleteErr := deleteCount(`
		DELETE FROM channel_memories
		WHERE updated_at < ? AND (
		  session_id = '' OR EXISTS (
		    SELECT 1 FROM coop_cleanup
		    WHERE coop_cleanup.session_id = channel_memories.session_id
		      AND coop_cleanup.state = 'done'
		  )
		)`, operational)
	if deleteErr != nil {
		return result, deleteErr
	}
	result.ChannelIntelligence += count
	count, deleteErr = deleteCount(`
		DELETE FROM conversation_sessions
		WHERE updated_at < ? AND (
		  session_id = '' OR EXISTS (
		    SELECT 1 FROM coop_cleanup
		    WHERE coop_cleanup.session_id = conversation_sessions.session_id
		      AND coop_cleanup.state = 'done'
		  )
		)`, operational)
	if deleteErr != nil {
		return result, deleteErr
	}
	result.ChannelIntelligence += count
	count, deleteErr = deleteCount(
		`DELETE FROM conversation_routes WHERE updated_at < ?`,
		conversationBefore.UTC().Format(timestampFormat),
	)
	if deleteErr != nil {
		return result, deleteErr
	}
	result.ChannelIntelligence += count
	if _, err = deleteCount(`
		DELETE FROM proposal_approvals WHERE proposal_id IN (
		  SELECT id FROM action_proposals
		  WHERE status IN ('rejected', 'expired', 'finished', 'failed') AND updated_at < ?
		)`, closed); err != nil {
		return result, err
	}
	if result.ActionProposals, err = deleteCount(`
		DELETE FROM action_proposals
		WHERE status IN ('rejected', 'expired', 'finished', 'failed') AND updated_at < ?`,
		closed); err != nil {
		return result, err
	}
	eligible := `
		SELECT i.id FROM incidents i
		LEFT JOIN coop_cleanup c ON c.session_id = i.coop_session_id
		WHERE i.status = 'closed' AND i.closed_at IS NOT NULL AND i.closed_at < ?
		  AND (i.coop_session_id = '' OR c.state = 'done')
		  AND NOT ` + incidentHoldsPinnedEpisode
	for _, query := range []string{
		`DELETE FROM emisar_approvals WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM proposal_approvals WHERE proposal_id IN
		  (SELECT id FROM action_proposals WHERE incident_id IN (` + eligible + `))`,
		`DELETE FROM action_proposals WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM timeline_events WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM evidence WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM coverage WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM signals WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM slack_deliveries WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM agent_runs WHERE incident_id IN (` + eligible + `)`,
		`DELETE FROM publications WHERE incident_id IN (` + eligible + `)`,
	} {
		if _, err = deleteCount(query, closed); err != nil {
			return result, fmt.Errorf("prune closed work: %w", err)
		}
	}
	if result.ClosedIncidents, err = deleteCount(
		`DELETE FROM incidents WHERE id IN (`+eligible+`)`, closed,
	); err != nil {
		return result, err
	}
	audit := auditBefore.UTC().Format(timestampFormat)
	if result.AuditEvents, err = deleteCount(`
		DELETE FROM audit_events WHERE created_at < ?`, audit); err != nil {
		return result, err
	}
	if _, err = deleteCount(`
		DELETE FROM coop_cleanup WHERE state = 'done' AND updated_at < ?`, audit); err != nil {
		return result, err
	}
	if err := tx.Commit(); err != nil {
		return result, err
	}
	if result.Total() > 0 {
		_, _ = s.db.ExecContext(ctx, `
			PRAGMA wal_checkpoint(PASSIVE);
			PRAGMA incremental_vacuum(256);
			PRAGMA optimize;
		`)
	}
	return result, nil
}

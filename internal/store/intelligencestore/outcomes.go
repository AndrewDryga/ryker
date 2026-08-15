package intelligencestore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/recall"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// Fingerprint sources, recorded per row so a recall can never quietly rank a
// truncated headline as if it were what the operator wrote. See migrationddl.V75.
const (
	FingerprintFromTrigger   = "trigger_text"
	FingerprintFromControl   = "trigger_control"
	FingerprintFromAlert     = "alert_labels"
	FingerprintFromObjective = "objective"
)

// RecallableTerminalState decides which finished episodes become recall
// sources.
//
// completed is the obvious one. blocked is included and labelled unverified,
// because an episode that reached an exact external blocker diagnosed
// something real on the way — "the pool was exhausted and I could not restart
// it" is the analogue a later incident wants, and refusing it would throw away
// most of what the corpus knows about causes.
//
// cancelled, refused and superseded are excluded on purpose. None of them
// concluded anything: a cancelled episode was stopped, a refused one was never
// started, and a superseded one was replaced by the episode that actually did
// the work. Projecting them would fill the corpus with rows whose root_cause
// column is empty by construction. failed is excluded for the same reason —
// what it records is that the host could not finish the turn, which says
// nothing about the incident.
func RecallableTerminalState(state string) bool {
	return state == string(core.EpisodeCompleted) || state == string(core.EpisodeBlocked)
}

// completionPayload is the shape this package reads out of a
// completion_submitted event. Declared here rather than imported from
// internal/investigation so persistence does not gain a dependency on the
// result contract; only these five strings are load-bearing, and a field the
// model stops sending simply reads empty.
type completionPayload struct {
	Completion struct {
		AlertAssessment struct {
			Cause            string `json:"cause"`
			ImmediateAction  string `json:"immediate_action"`
			Verification     string `json:"verification"`
			LongTermSolution string `json:"long_term_solution"`
		} `json:"alert_assessment"`
		Completion struct {
			Status  string `json:"status"`
			Verdict string `json:"verdict"`
			Summary string `json:"summary"`
			Blocker string `json:"blocker"`
		} `json:"completion"`
	} `json:"completion"`
}

// ProjectEpisodeOutcomeTx writes the flat recall row for one episode inside the
// transaction that just made it terminal.
//
// Same transaction on purpose. A projection written afterwards is a projection
// that can be missing, and the failure mode is silent: recall would simply
// never mention the episode, and nobody would know to look. Returning nil for
// a state that is not a recall source keeps the policy in one place instead of
// spread across every caller that appends an event.
func ProjectEpisodeOutcomeTx(
	ctx context.Context,
	tx *sql.Tx,
	episodeID string,
	terminalState string,
	terminalAt time.Time,
) error {
	if !RecallableTerminalState(terminalState) {
		// A reopened episode is working again, and the row saying what it
		// concluded is now a claim about a past that has been withdrawn. Left
		// in place it would offer a live investigation to the next incident as
		// a resolved one, which is the failure this whole feature exists to
		// avoid making. Deleting on every non-recall transition is a no-op for
		// the episodes that never had a row.
		_, err := tx.ExecContext(
			ctx, `DELETE FROM episode_outcomes WHERE episode_id = ?`, episodeID,
		)
		return err
	}
	outcome, err := buildEpisodeOutcome(ctx, tx, episodeID, terminalState, terminalAt)
	if err != nil {
		return err
	}
	return writeEpisodeOutcome(ctx, tx, outcome)
}

type rowQuerier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func buildEpisodeOutcome(
	ctx context.Context,
	db rowQuerier,
	episodeID string,
	terminalState string,
	terminalAt time.Time,
) (core.EpisodeOutcome, error) {
	outcome := core.EpisodeOutcome{
		EpisodeID: episodeID, TerminalState: terminalState, TerminalAt: terminalAt.UTC(),
	}
	var sourceInput, incidentID, createdAt string
	err := db.QueryRowContext(ctx, `
		SELECT episode.workspace_id, episode.channel_id, episode.mode, episode.effort,
		       episode.objective, episode.created_at,
		       COALESCE(run.repository, ''), COALESCE(run.source_id, ''),
		       COALESCE(run.incident_id, '')
		FROM work_episodes AS episode
		LEFT JOIN agent_runs AS run ON run.id = episode.agent_run_id
		WHERE episode.id = ?`, episodeID,
	).Scan(
		&outcome.WorkspaceID, &outcome.ChannelID, &outcome.Mode, &outcome.Effort,
		&outcome.Objective, &createdAt, &outcome.Repository, &sourceInput, &incidentID,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.EpisodeOutcome{}, core.ErrNotFound
	}
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	if started := sqlutil.ParseTime(createdAt); !started.IsZero() &&
		outcome.TerminalAt.After(started) {
		outcome.TimeToDecision = outcome.TerminalAt.Sub(started)
	}
	symptom, source, err := episodeSymptom(ctx, db, sourceInput, incidentID, outcome.Objective)
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	outcome.SymptomFingerprint, outcome.FingerprintSource = recall.SymptomFingerprint(symptom), source
	if incidentID != "" {
		if err := db.QueryRowContext(ctx, `
			SELECT COALESCE(source_incident_id, '') FROM incidents WHERE id = ?`, incidentID,
		).Scan(&outcome.AlertGroupKey); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return core.EpisodeOutcome{}, err
		}
	}
	if outcome.Services, err = episodeServices(ctx, db, episodeID); err != nil {
		return core.EpisodeOutcome{}, err
	}
	closing, err := episodeClosingPayload(ctx, db, episodeID)
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	assessment := closing.Completion.AlertAssessment
	outcome.RootCause = core.BoundedText(core.FirstNonempty(
		assessment.Cause, closing.Completion.Completion.Summary, outcome.Objective,
	), 600)
	outcome.Verification = core.BoundedText(assessment.Verification, 400)
	remediation, err := episodeRemediation(ctx, db, sourceInput, incidentID)
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	outcome.Remediation = core.BoundedText(strings.TrimSpace(strings.Join(append([]string{
		strings.TrimSpace(assessment.ImmediateAction),
		strings.TrimSpace(assessment.LongTermSolution),
	}, remediation...), "\n")), 600)
	// Verified means the model recorded a verification step on an episode that
	// then completed. It is not independent proof, and the recall preamble says
	// so — but a closing assessment that named how the fix was checked is a
	// materially different artefact from one that did not, and ranking them the
	// same is how "we restarted it" outranks "we restarted it and watched the
	// error rate return to baseline".
	outcome.Verified = outcome.Verification != "" &&
		terminalState == string(core.EpisodeCompleted)
	return outcome, nil
}

// episodeSymptom recovers what the episode was actually about, and says which
// source it had to settle for.
//
// The objective is the last resort, never the first: it is a display headline
// truncated at 180 bytes, and three of the first four replay fixtures recorded
// it instead of the trigger and became unanswerable questions. A webhook alert
// has no slack_inputs row at all — its run is filed under the event and the
// incident — and retention deletes finished Slack inputs on the operational
// horizon, so a backfilled episode frequently has nothing better than the
// alert's own labels. That is a usable fingerprint and a weaker one, which is
// exactly why the row records which of the four it used.
func episodeSymptom(
	ctx context.Context,
	db rowQuerier,
	sourceInput string,
	incidentID string,
	objective string,
) (string, string, error) {
	if sourceInput != "" {
		var text, actionID string
		err := db.QueryRowContext(ctx, `
			SELECT text, action_id FROM slack_inputs WHERE id = ?`, sourceInput,
		).Scan(&text, &actionID)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return "", "", err
		}
		if strings.TrimSpace(text) != "" {
			return text, FingerprintFromTrigger, nil
		}
		if strings.TrimSpace(actionID) != "" {
			return actionID + " " + objective, FingerprintFromControl, nil
		}
	}
	if incidentID != "" {
		var title, labels string
		err := db.QueryRowContext(ctx, `
			SELECT incident.title, COALESCE((
			  SELECT signal.labels_json FROM signals AS signal
			  WHERE signal.incident_id = incident.id
			  ORDER BY signal.received_at DESC LIMIT 1
			), '{}')
			FROM incidents AS incident WHERE incident.id = ?`, incidentID,
		).Scan(&title, &labels)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return "", "", err
		}
		if strings.TrimSpace(title) != "" {
			return title + " " + labelWords(labels), FingerprintFromAlert, nil
		}
	}
	return objective, FingerprintFromObjective, nil
}

// labelWords flattens an alert's label map to the words a fingerprint is made
// of. Values only: the keys are Prometheus vocabulary ("alertname",
// "namespace") shared by every alert ever fired, so scoring on them would make
// every alert look like every other alert.
func labelWords(encoded string) string {
	var labels map[string]string
	if json.Unmarshal([]byte(encoded), &labels) != nil {
		return ""
	}
	words := make([]string, 0, len(labels))
	for _, value := range labels {
		words = append(words, value)
	}
	return strings.Join(words, " ")
}

// episodeServices resolves the systems an episode implicated through the same
// join the trace page uses. Evidence is keyed by source_input for a watch turn
// and by incident for an escalated investigation; a projection that invented a
// third mapping would disagree with the page an operator opens to check it.
func episodeServices(ctx context.Context, db rowQuerier, episodeID string) ([]string, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT DISTINCT target FROM evidence
		WHERE target != '' AND (
		  source_input IN (SELECT source_id FROM agent_runs WHERE episode_id = ?)
		  OR (incident_id != '' AND incident_id IN (
		    SELECT incident_id FROM agent_runs
		    WHERE episode_id = ? AND incident_id IS NOT NULL AND incident_id != ''
		  ))
		)
		ORDER BY target LIMIT 12`, episodeID, episodeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	services := make([]string, 0, 12)
	for rows.Next() {
		var target string
		if err := rows.Scan(&target); err != nil {
			return nil, err
		}
		services = append(services, core.BoundedText(target, 120))
	}
	return services, rows.Err()
}

func episodeClosingPayload(
	ctx context.Context,
	db rowQuerier,
	episodeID string,
) (completionPayload, error) {
	var payload completionPayload
	var raw []byte
	err := db.QueryRowContext(ctx, `
		SELECT payload_json FROM work_episode_events
		WHERE episode_id = ? AND kind = 'completion_submitted'
		ORDER BY sequence DESC LIMIT 1`, episodeID,
	).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return payload, nil
	}
	if err != nil {
		return payload, err
	}
	// A payload this package cannot read is a recall row with less in it, never
	// a failed episode transition: the terminal write is the important one.
	_ = json.Unmarshal(raw, &payload)
	return payload, nil
}

// episodeRemediation collects what was actually done, as refs rather than
// prose: the Emisar actions that succeeded and the pull request that shipped.
func episodeRemediation(
	ctx context.Context,
	db rowQuerier,
	sourceInput string,
	incidentID string,
) ([]string, error) {
	if sourceInput == "" && incidentID == "" {
		return nil, nil
	}
	rows, err := db.QueryContext(ctx, `
		SELECT 'emisar action ' || action_id FROM emisar_approvals
		WHERE status = 'success'
		  AND ((? != '' AND source_input = ?) OR (? != '' AND incident_id = ?))
		UNION
		SELECT 'pull request ' || pr_url FROM publications
		WHERE ? != '' AND incident_id = ? AND pr_url != ''
		ORDER BY 1 LIMIT 8`,
		sourceInput, sourceInput, incidentID, incidentID, incidentID, incidentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var refs []string
	for rows.Next() {
		var ref string
		if err := rows.Scan(&ref); err != nil {
			return nil, err
		}
		refs = append(refs, ref)
	}
	return refs, rows.Err()
}

func writeEpisodeOutcome(ctx context.Context, db rowQuerier, outcome core.EpisodeOutcome) error {
	services, err := json.Marshal(outcome.Services)
	if err != nil {
		return err
	}
	stamp := outcome.TerminalAt.UTC().Format(core.TimestampFormat)
	_, err = db.ExecContext(ctx, `
		INSERT INTO episode_outcomes (
		  episode_id, workspace_id, channel_id, repository, mode, effort,
		  terminal_state, terminal_at, objective, symptom_fingerprint,
		  fingerprint_source, alert_group_key, services_json, root_cause,
		  remediation, verification, verified, time_to_decision_seconds, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(episode_id) DO UPDATE SET
		  terminal_state = excluded.terminal_state, terminal_at = excluded.terminal_at,
		  symptom_fingerprint = excluded.symptom_fingerprint,
		  fingerprint_source = excluded.fingerprint_source,
		  alert_group_key = excluded.alert_group_key, services_json = excluded.services_json,
		  root_cause = excluded.root_cause, remediation = excluded.remediation,
		  verification = excluded.verification, verified = excluded.verified,
		  time_to_decision_seconds = excluded.time_to_decision_seconds`,
		outcome.EpisodeID, outcome.WorkspaceID, outcome.ChannelID, outcome.Repository,
		outcome.Mode, outcome.Effort, outcome.TerminalState, stamp,
		core.BoundedText(outcome.Objective, 400), outcome.SymptomFingerprint,
		outcome.FingerprintSource, outcome.AlertGroupKey, string(services),
		outcome.RootCause, outcome.Remediation, outcome.Verification,
		boolInt(outcome.Verified), int(outcome.TimeToDecision/time.Second), stamp,
	)
	return err
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

// Qualified because the recall query joins the membership roster, which has a
// channel_id of its own.
const outcomeColumns = `outcome.episode_id, outcome.workspace_id, outcome.channel_id,
	outcome.repository, outcome.mode, outcome.effort, outcome.terminal_state,
	outcome.terminal_at, outcome.objective, outcome.symptom_fingerprint,
	outcome.fingerprint_source, outcome.alert_group_key, outcome.services_json,
	outcome.root_cause, outcome.remediation, outcome.verification, outcome.verified,
	outcome.time_to_decision_seconds, outcome.created_at`

// ProjectEpisodeOutcome rebuilds one episode's recall row outside a lifecycle
// transition. Backfill is its only caller; the live path goes through the
// terminal transaction so the row cannot go missing.
func (r *Repository) ProjectEpisodeOutcome(
	ctx context.Context,
	episodeID string,
	terminalState string,
	terminalAt time.Time,
) (core.EpisodeOutcome, error) {
	if !RecallableTerminalState(terminalState) {
		return core.EpisodeOutcome{}, nil
	}
	outcome, err := buildEpisodeOutcome(ctx, r.db, episodeID, terminalState, terminalAt)
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	return outcome, writeEpisodeOutcome(ctx, r.db, outcome)
}

// ListEpisodesAwaitingOutcome names the finished episodes with no recall row.
func (r *Repository) ListEpisodesAwaitingOutcome(
	ctx context.Context,
	limit int,
) ([]core.WorkEpisode, error) {
	if limit < 1 || limit > 20000 {
		return nil, errors.New("outcome backfill limit must be between 1 and 20000")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT episode.id, episode.lifecycle_state,
		       COALESCE(episode.completed_at, episode.updated_at)
		FROM work_episodes AS episode
		LEFT JOIN episode_outcomes AS outcome ON outcome.episode_id = episode.id
		WHERE outcome.episode_id IS NULL
		  AND episode.lifecycle_state IN ('completed', 'blocked')
		ORDER BY episode.updated_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	episodes := make([]core.WorkEpisode, 0, limit)
	for rows.Next() {
		var episode core.WorkEpisode
		var completed string
		if err := rows.Scan(&episode.ID, &episode.State, &completed); err != nil {
			return nil, err
		}
		episode.CompletedAt = sqlutil.ParseTime(completed)
		episodes = append(episodes, episode)
	}
	return episodes, rows.Err()
}

// ListSimilarEpisodeCandidates returns the recall window relevance chooses
// from: recent finished episodes this conversation is allowed to see.
//
// The visibility rule is the one conversation summaries already use — this
// channel always, and another channel only when Responder is present in it and
// it is public. A private-channel incident must never surface its symptom, its
// cause or its remediation in a room whose members were not in it, and the
// LEFT JOIN's missing row reads as private rather than as public.
func (r *Repository) ListSimilarEpisodeCandidates(
	ctx context.Context,
	workspaceID string,
	channelID string,
	excludeEpisodeID string,
	limit int,
) ([]core.EpisodeOutcome, error) {
	if limit < 1 || limit > 500 {
		return nil, errors.New("similar episode candidates require a limit from 1 to 500")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+outcomeColumns+`
		FROM episode_outcomes AS outcome
		LEFT JOIN slack_channel_memberships AS membership
		  ON membership.channel_id = outcome.channel_id
		WHERE outcome.episode_id != ?
		  AND (? = '' OR outcome.workspace_id = '' OR outcome.workspace_id = ?)
		  AND (outcome.channel_id = ? OR (membership.present = 1 AND membership.private = 0))
		ORDER BY outcome.terminal_at DESC, outcome.episode_id LIMIT ?`,
		excludeEpisodeID, workspaceID, workspaceID, channelID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEpisodeOutcomes(rows, limit)
}

// GetEpisodeOutcome reads one recall row, for the trace page and for tests.
func (r *Repository) GetEpisodeOutcome(
	ctx context.Context,
	episodeID string,
) (core.EpisodeOutcome, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+outcomeColumns+`
		 FROM episode_outcomes AS outcome WHERE outcome.episode_id = ?`, episodeID)
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	defer rows.Close()
	outcomes, err := scanEpisodeOutcomes(rows, 1)
	if err != nil {
		return core.EpisodeOutcome{}, err
	}
	if len(outcomes) == 0 {
		return core.EpisodeOutcome{}, core.ErrNotFound
	}
	return outcomes[0], nil
}

func scanEpisodeOutcomes(rows *sql.Rows, limit int) ([]core.EpisodeOutcome, error) {
	result := make([]core.EpisodeOutcome, 0, limit)
	for rows.Next() {
		var outcome core.EpisodeOutcome
		var services []byte
		var terminalAt, createdAt string
		var verified, seconds int
		if err := rows.Scan(
			&outcome.EpisodeID, &outcome.WorkspaceID, &outcome.ChannelID,
			&outcome.Repository, &outcome.Mode, &outcome.Effort, &outcome.TerminalState,
			&terminalAt, &outcome.Objective, &outcome.SymptomFingerprint,
			&outcome.FingerprintSource, &outcome.AlertGroupKey, &services,
			&outcome.RootCause, &outcome.Remediation, &outcome.Verification,
			&verified, &seconds, &createdAt,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(services, &outcome.Services); err != nil {
			return nil, err
		}
		outcome.Verified = verified != 0
		outcome.TimeToDecision = time.Duration(seconds) * time.Second
		outcome.TerminalAt = sqlutil.ParseTime(terminalAt)
		outcome.CreatedAt = sqlutil.ParseTime(createdAt)
		result = append(result, outcome)
	}
	return result, rows.Err()
}

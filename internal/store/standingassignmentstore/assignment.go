package standingassignmentstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// maxPathGlobs bounds how many paths one assignment covers. An assignment
// listing dozens of globs is not scoped; it is a repository grant written the
// long way.
const maxPathGlobs = 10

// ErrBudgetSpent means the assignment already did today's work.
var ErrBudgetSpent = errors.New("standing assignment budget spent for today")

// ErrAlreadyActed means this assignment already handled this issue.
var ErrAlreadyActed = errors.New("standing assignment already acted on this signal")

// ErrGrantWithheld refuses to create an assignment that may act unattended.
//
// The shadow period exists because the eligibility gate leans on
// completion.status == decision_ready with zero material gaps, and that
// contract was the largest single source of defects on 2026-08-09. The evidence
// that it holds across real traffic is exactly what the shadow audit is being
// collected to produce, so there is deliberately no creation path that skips
// it: the flag can only be cleared against an assignment that already exists
// and already has an audit to argue with.
var ErrGrantWithheld = errors.New(
	"a standing assignment is created in shadow: it is evaluated by the real gate and " +
		"records what it would have done, but opens nothing. Clearing the flag is a separate " +
		"decision that waits on the shadow audit having enough real signals to argue with",
)

func validate(assignment core.StandingAssignment) error {
	switch {
	case strings.TrimSpace(assignment.ChannelID) == "":
		return errors.New("a standing assignment needs a channel to watch")
	case strings.TrimSpace(assignment.SignalPattern) == "":
		return errors.New("a standing assignment needs a signal to look for")
	case strings.TrimSpace(assignment.Repository) == "":
		return errors.New("a standing assignment needs a repository to change")
	case !slices.Contains(core.StandingAssignmentChangeClasses, assignment.ChangeClass):
		return errors.New(
			"change class must be one of: " +
				strings.Join(core.StandingAssignmentChangeClasses, ", "),
		)
	case assignment.DailyBudget < 1 || assignment.DailyBudget > 20:
		return errors.New("daily budget must be between 1 and 20")
	case strings.TrimSpace(assignment.ActorID) == "":
		return errors.New("a standing assignment records who confirmed it")
	case assignment.ExpiresAt.IsZero():
		return errors.New(
			"a standing assignment must expire; authority that never lapses is not scoped",
		)
	case len(assignment.PathGlobs) > maxPathGlobs:
		return errors.New("a standing assignment covers at most 10 path patterns")
	}
	for _, glob := range assignment.PathGlobs {
		if strings.TrimSpace(glob) == "" || strings.Contains(glob, "..") {
			return errors.New("path patterns must be non-empty and may not traverse upward")
		}
	}
	// Last, and by value rather than by omission. A Go bool zero-values to
	// false, so a caller that simply forgot the field is asking for live
	// authority without having said so; refusing here means the only way to get
	// it is to have written it down.
	if !assignment.Shadow {
		return ErrGrantWithheld
	}
	return nil
}

// Create records scoped authority an operator has confirmed.
func (r *Repository) Create(
	ctx context.Context,
	assignment core.StandingAssignment,
) (core.StandingAssignment, error) {
	if err := validate(assignment); err != nil {
		return core.StandingAssignment{}, err
	}
	if strings.TrimSpace(assignment.ID) == "" {
		id, err := core.NewID("assign")
		if err != nil {
			return core.StandingAssignment{}, err
		}
		assignment.ID = id
	}
	globs, err := json.Marshal(assignment.PathGlobs)
	if err != nil {
		return core.StandingAssignment{}, err
	}
	now := r.nowText()
	if _, err := r.db.ExecContext(ctx, `
		INSERT INTO standing_assignments (
		  id, channel_id, signal_pattern, repository, path_globs_json, change_class,
		  daily_budget, actor_id, enabled, shadow, confirmed_at, expires_at,
		  created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?, ?, ?, ?)`,
		assignment.ID, assignment.ChannelID, assignment.SignalPattern, assignment.Repository,
		string(globs), assignment.ChangeClass, assignment.DailyBudget, assignment.ActorID,
		now, sqlutil.TimeText(assignment.ExpiresAt), now, now,
	); err != nil {
		return core.StandingAssignment{}, err
	}
	return r.Get(ctx, assignment.ID)
}

const assignmentColumns = `
	id, channel_id, signal_pattern, repository, path_globs_json, change_class,
	daily_budget, actor_id, enabled, shadow, confirmed_at, expires_at, created_at, updated_at`

func scanAssignment(
	row interface{ Scan(...any) error },
) (core.StandingAssignment, error) {
	var assignment core.StandingAssignment
	var globs, confirmed, expires, created, updated string
	var enabled, shadow int
	if err := row.Scan(
		&assignment.ID, &assignment.ChannelID, &assignment.SignalPattern,
		&assignment.Repository, &globs, &assignment.ChangeClass, &assignment.DailyBudget,
		&assignment.ActorID, &enabled, &shadow, &confirmed, &expires, &created, &updated,
	); err != nil {
		return core.StandingAssignment{}, err
	}
	_ = json.Unmarshal([]byte(globs), &assignment.PathGlobs)
	assignment.Enabled = enabled == 1
	assignment.Shadow = shadow == 1
	assignment.ConfirmedAt = sqlutil.ParseTime(confirmed)
	assignment.ExpiresAt = sqlutil.ParseTime(expires)
	assignment.CreatedAt = sqlutil.ParseTime(created)
	assignment.UpdatedAt = sqlutil.ParseTime(updated)
	return assignment, nil
}

func (r *Repository) Get(
	ctx context.Context,
	id string,
) (core.StandingAssignment, error) {
	assignment, err := scanAssignment(r.db.QueryRowContext(
		ctx, `SELECT `+assignmentColumns+` FROM standing_assignments WHERE id = ?`, id,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return core.StandingAssignment{}, core.ErrNotFound
	}
	if err != nil {
		return core.StandingAssignment{}, err
	}
	return assignment, nil
}

// ListLive returns the assignments that may act in a channel.
//
// Expired and disabled assignments are filtered here rather than at the caller,
// so no caller can forget to and act on lapsed authority. Shadowed assignments
// are returned: they are live for the purpose of being evaluated, and the
// withholding happens after the gate has spoken.
func (r *Repository) ListLive(
	ctx context.Context,
	channelID string,
	now time.Time,
) ([]core.StandingAssignment, error) {
	return r.list(ctx, `
		SELECT `+assignmentColumns+` FROM standing_assignments
		WHERE channel_id = ? AND enabled = 1 AND expires_at > ?
		ORDER BY created_at`, channelID, sqlutil.TimeText(now))
}

// ListForChannel returns every assignment in a channel, paused and expired
// included.
//
// A management surface has to show the ones that cannot act. Listing only the
// live ones makes a paused assignment indistinguishable from a deleted one, and
// the operator who paused it has no way back to it.
func (r *Repository) ListForChannel(
	ctx context.Context,
	channelID string,
	limit int,
) ([]core.StandingAssignment, error) {
	if limit <= 0 {
		limit = 20
	}
	return r.list(ctx, `
		SELECT `+assignmentColumns+` FROM standing_assignments
		WHERE channel_id = ?
		ORDER BY created_at DESC LIMIT ?`, channelID, limit)
}

func (r *Repository) list(
	ctx context.Context,
	query string,
	args ...any,
) ([]core.StandingAssignment, error) {
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.StandingAssignment, 0)
	for rows.Next() {
		assignment, err := scanAssignment(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, assignment)
	}
	return result, rows.Err()
}

func (r *Repository) SetEnabled(
	ctx context.Context,
	id string,
	enabled bool,
) error {
	value := 0
	if enabled {
		value = 1
	}
	result, err := r.db.ExecContext(ctx,
		`UPDATE standing_assignments SET enabled = ?, updated_at = ? WHERE id = ?`,
		value, r.nowText(), id,
	)
	return sqlutil.ExpectOne(result, err, "set standing assignment enabled")
}

// SetShadow grants or withholds the authority an assignment describes.
//
// There is deliberately no operator surface for this — no slash subcommand, no
// control-plane button. Clearing the flag is the decision the shadow audit is
// being collected to inform, and a one-click grant on a loopback dashboard with
// no authentication is the wrong shape for it. What this method is for today is
// keeping the withheld path reachable: the claim, the budget and the
// deduplication are the invariants that make autonomous work survivable, and a
// path no test can reach is a path that rots until the day it is switched on.
func (r *Repository) SetShadow(ctx context.Context, id string, shadow bool) error {
	value := 0
	if shadow {
		value = 1
	}
	result, err := r.db.ExecContext(ctx,
		`UPDATE standing_assignments SET shadow = ?, updated_at = ? WHERE id = ?`,
		value, r.nowText(), id,
	)
	return sqlutil.ExpectOne(result, err, "set standing assignment shadow")
}

func (r *Repository) Delete(ctx context.Context, id string) error {
	result, err := r.db.ExecContext(ctx, `DELETE FROM standing_assignments WHERE id = ?`, id)
	return sqlutil.ExpectOne(result, err, "delete standing assignment")
}

// ClaimAction reserves the right to act on one signal.
//
// The two failure modes it rules out are the ones that would make proactive
// work intolerable: acting twice on the same issue, and acting without limit
// during an incident that produces the same signal repeatedly. Both are
// enforced by the table rather than by the caller remembering — the unique
// constraint is the deduplication, and counting today's rows is the budget.
//
// Claiming before acting rather than recording after is deliberate. A crash
// between the action and its record would otherwise let the next run act again.
func (r *Repository) ClaimAction(
	ctx context.Context,
	assignmentID string,
	correlationKey string,
	now time.Time,
) (string, error) {
	if strings.TrimSpace(correlationKey) == "" {
		return "", errors.New("a standing assignment action needs a correlation key")
	}
	assignment, err := r.Get(ctx, assignmentID)
	if err != nil {
		return "", err
	}
	if !assignment.Live(now) {
		return "", errors.New("standing assignment is disabled or expired")
	}
	// Nothing may claim under a withheld grant. The service checks the flag
	// before it gets here, and this is the second lock on the same door: a
	// claim is the step that spends budget and marks the signal handled, so a
	// caller that reached it while shadowed has already lost the invariant.
	if assignment.Shadow {
		return "", ErrGrantWithheld
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	var spentToday int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM standing_assignment_actions
		WHERE assignment_id = ? AND created_at >= ?`,
		assignmentID, sqlutil.TimeText(now.Add(-24*time.Hour)),
	).Scan(&spentToday); err != nil {
		return "", err
	}
	if spentToday >= assignment.DailyBudget {
		return "", ErrBudgetSpent
	}
	id, err := core.NewID("assignact")
	if err != nil {
		return "", err
	}
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO standing_assignment_actions (
		  id, assignment_id, correlation_key, outcome, created_at
		) VALUES (?, ?, ?, 'claimed', ?)`,
		id, assignmentID, correlationKey, sqlutil.TimeText(now),
	)
	if err != nil {
		return "", err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if rows == 0 {
		return "", ErrAlreadyActed
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return id, nil
}

// CompleteAction records what the claimed action became.
func (r *Repository) CompleteAction(
	ctx context.Context,
	actionID string,
	episodeID string,
	outcome string,
) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE standing_assignment_actions
		SET episode_id = ?, outcome = ? WHERE id = ?`,
		episodeID, outcome, actionID,
	)
	return err
}

// CountCorrelatedEpisodes reports how many times this signal has been seen.
//
// It is the difference between a pattern and a coincidence. A transient error
// during a deploy, a one-off timeout, an alert that resolved itself — each is
// indistinguishable from a real problem at the moment it arrives, and only
// repetition separates them. This is what stops proactive work from reacting
// to the first sighting of anything.
func (r *Repository) CountCorrelatedEpisodes(
	ctx context.Context,
	conversationKey string,
	since time.Time,
) (int, error) {
	if strings.TrimSpace(conversationKey) == "" {
		return 0, nil
	}
	// The key lives on agent_runs, not on work_episodes — episodes reach it
	// through their runs. Counting DISTINCT episodes rather than runs matters:
	// a single problem investigated over three retries is one occurrence, and
	// counting retries would let a flaky provider manufacture a "pattern".
	var count int
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(DISTINCT episode_id) FROM agent_runs
		WHERE conversation_key = ? AND episode_id != '' AND created_at >= ?`,
		conversationKey, sqlutil.TimeText(since),
	).Scan(&count)
	return count, err
}

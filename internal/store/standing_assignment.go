package store

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

// maxStandingAssignmentPathGlobs bounds how many paths one assignment covers.
// An assignment listing dozens of globs is not scoped; it is a repository grant
// written the long way.
const maxStandingAssignmentPathGlobs = 10

// ErrAssignmentBudgetSpent means the assignment already did today's work.
var ErrAssignmentBudgetSpent = errors.New("standing assignment budget spent for today")

// ErrAssignmentAlreadyActed means this assignment already handled this issue.
var ErrAssignmentAlreadyActed = errors.New("standing assignment already acted on this signal")

func validateStandingAssignment(assignment core.StandingAssignment) error {
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
	case len(assignment.PathGlobs) > maxStandingAssignmentPathGlobs:
		return errors.New("a standing assignment covers at most 10 path patterns")
	}
	for _, glob := range assignment.PathGlobs {
		if strings.TrimSpace(glob) == "" || strings.Contains(glob, "..") {
			return errors.New("path patterns must be non-empty and may not traverse upward")
		}
	}
	return nil
}

// CreateStandingAssignment records scoped authority an operator has confirmed.
func (s *Store) CreateStandingAssignment(
	ctx context.Context,
	assignment core.StandingAssignment,
) (core.StandingAssignment, error) {
	if err := validateStandingAssignment(assignment); err != nil {
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
	now := s.nowText()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO standing_assignments (
		  id, channel_id, signal_pattern, repository, path_globs_json, change_class,
		  daily_budget, actor_id, enabled, confirmed_at, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)`,
		assignment.ID, assignment.ChannelID, assignment.SignalPattern, assignment.Repository,
		string(globs), assignment.ChangeClass, assignment.DailyBudget, assignment.ActorID,
		now, timeText(assignment.ExpiresAt), now, now,
	); err != nil {
		return core.StandingAssignment{}, err
	}
	return s.GetStandingAssignment(ctx, assignment.ID)
}

const standingAssignmentColumns = `
	id, channel_id, signal_pattern, repository, path_globs_json, change_class,
	daily_budget, actor_id, enabled, confirmed_at, expires_at, created_at, updated_at`

func scanStandingAssignment(
	row interface{ Scan(...any) error },
) (core.StandingAssignment, error) {
	var assignment core.StandingAssignment
	var globs, confirmed, expires, created, updated string
	var enabled int
	if err := row.Scan(
		&assignment.ID, &assignment.ChannelID, &assignment.SignalPattern,
		&assignment.Repository, &globs, &assignment.ChangeClass, &assignment.DailyBudget,
		&assignment.ActorID, &enabled, &confirmed, &expires, &created, &updated,
	); err != nil {
		return core.StandingAssignment{}, err
	}
	_ = json.Unmarshal([]byte(globs), &assignment.PathGlobs)
	assignment.Enabled = enabled == 1
	assignment.ConfirmedAt = sqlutil.ParseTime(confirmed)
	assignment.ExpiresAt = sqlutil.ParseTime(expires)
	assignment.CreatedAt = sqlutil.ParseTime(created)
	assignment.UpdatedAt = sqlutil.ParseTime(updated)
	return assignment, nil
}

func (s *Store) GetStandingAssignment(
	ctx context.Context,
	id string,
) (core.StandingAssignment, error) {
	assignment, err := scanStandingAssignment(s.db.QueryRowContext(
		ctx, `SELECT `+standingAssignmentColumns+` FROM standing_assignments WHERE id = ?`, id,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return core.StandingAssignment{}, ErrNotFound
	}
	if err != nil {
		return core.StandingAssignment{}, err
	}
	return assignment, nil
}

// ListLiveStandingAssignments returns the assignments that may act in a channel.
//
// Expired and disabled assignments are filtered here rather than at the caller,
// so no caller can forget to and act on lapsed authority.
func (s *Store) ListLiveStandingAssignments(
	ctx context.Context,
	channelID string,
	now time.Time,
) ([]core.StandingAssignment, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+standingAssignmentColumns+` FROM standing_assignments
		WHERE channel_id = ? AND enabled = 1 AND expires_at > ?
		ORDER BY created_at`, channelID, timeText(now))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.StandingAssignment, 0)
	for rows.Next() {
		assignment, err := scanStandingAssignment(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, assignment)
	}
	return result, rows.Err()
}

func (s *Store) SetStandingAssignmentEnabled(
	ctx context.Context,
	id string,
	enabled bool,
) error {
	value := 0
	if enabled {
		value = 1
	}
	_, err := s.db.ExecContext(ctx,
		`UPDATE standing_assignments SET enabled = ?, updated_at = ? WHERE id = ?`,
		value, s.nowText(), id,
	)
	return err
}

func (s *Store) DeleteStandingAssignment(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM standing_assignments WHERE id = ?`, id)
	return err
}

// ClaimStandingAssignmentAction reserves the right to act on one signal.
//
// The two failure modes it rules out are the ones that would make proactive
// work intolerable: acting twice on the same issue, and acting without limit
// during an incident that produces the same signal repeatedly. Both are
// enforced by the table rather than by the caller remembering — the unique
// constraint is the deduplication, and counting today's rows is the budget.
//
// Claiming before acting rather than recording after is deliberate. A crash
// between the action and its record would otherwise let the next run act again.
func (s *Store) ClaimStandingAssignmentAction(
	ctx context.Context,
	assignmentID string,
	correlationKey string,
	now time.Time,
) (string, error) {
	if strings.TrimSpace(correlationKey) == "" {
		return "", errors.New("a standing assignment action needs a correlation key")
	}
	assignment, err := s.GetStandingAssignment(ctx, assignmentID)
	if err != nil {
		return "", err
	}
	if !assignment.Live(now) {
		return "", errors.New("standing assignment is disabled or expired")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	var spentToday int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM standing_assignment_actions
		WHERE assignment_id = ? AND created_at >= ?`,
		assignmentID, timeText(now.Add(-24*time.Hour)),
	).Scan(&spentToday); err != nil {
		return "", err
	}
	if spentToday >= assignment.DailyBudget {
		return "", ErrAssignmentBudgetSpent
	}
	id, err := core.NewID("assignact")
	if err != nil {
		return "", err
	}
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO standing_assignment_actions (
		  id, assignment_id, correlation_key, outcome, created_at
		) VALUES (?, ?, ?, 'claimed', ?)`,
		id, assignmentID, correlationKey, timeText(now),
	)
	if err != nil {
		return "", err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if rows == 0 {
		return "", ErrAssignmentAlreadyActed
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return id, nil
}

// CompleteStandingAssignmentAction records what the claimed action became.
func (s *Store) CompleteStandingAssignmentAction(
	ctx context.Context,
	actionID string,
	episodeID string,
	outcome string,
) error {
	_, err := s.db.ExecContext(ctx, `
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
func (s *Store) CountCorrelatedEpisodes(
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
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(DISTINCT episode_id) FROM agent_runs
		WHERE conversation_key = ? AND episode_id != '' AND created_at >= ?`,
		conversationKey, timeText(since),
	).Scan(&count)
	return count, err
}

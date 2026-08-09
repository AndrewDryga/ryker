package store

// Product feedback.
//
// This lived in its own SQLite file beside the main database, which put it
// outside the schema baseline, outside the verified pre-migration backup, and
// outside every cross-table transaction — so the one kind of state whose whole
// purpose is to survive long enough for someone to act on it had the weakest
// durability guarantees in the system. It is now an ordinary table.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type FeedbackContextMessage struct {
	MessageTS   string                      `json:"message_ts,omitempty"`
	ThreadTS    string                      `json:"thread_ts,omitempty"`
	MessageLink string                      `json:"message_link,omitempty"`
	SenderID    string                      `json:"sender_id,omitempty"`
	SenderType  string                      `json:"sender_type,omitempty"`
	Text        string                      `json:"text,omitempty"`
	Attachments []FeedbackContextAttachment `json:"attachments,omitempty"`
}

type FeedbackContextAttachment struct {
	Name      string `json:"name,omitempty"`
	MediaType string `json:"media_type,omitempty"`
	Size      int64  `json:"size,omitempty"`
}

type FeedbackItem struct {
	ID              string
	WorkspaceID     string
	ChannelID       string
	ThreadTS        string
	MessageTS       string
	TargetMessageTS string
	UserID          string
	Source          string
	Category        string
	Sentiment       string
	Summary         string
	Details         string
	Context         []FeedbackContextMessage
	EpisodeID       string
	AgentRunID      string
	SourceRef       string
	Status          string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

func (s *Store) RecordFeedback(ctx context.Context, item FeedbackItem) (FeedbackItem, error) {
	if err := validateFeedback(item); err != nil {
		return FeedbackItem{}, err
	}
	contextJSON, err := json.Marshal(item.Context)
	if err != nil {
		return FeedbackItem{}, err
	}
	now := s.now().UTC()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	item.UpdatedAt = now
	// Praise is recorded as settled, everything else as work.
	//
	// Every item used to be forced open, which is right for a complaint —
	// somebody has to decide what to do about it — and wrong for a thumbs-up.
	// Putting praise in the queue that means "a person must act" would fill
	// that queue with rows whose only correct action is to dismiss them, and
	// the App Home list that renders it is titled "awaiting a decision".
	// Noted keeps it counted, readable and available to anything assembling
	// examples of the target behaviour, without calling it work.
	if item.Status != "noted" {
		item.Status = "open"
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO feedback_items (
		  id, workspace_id, channel_id, thread_ts, message_ts, target_message_ts,
		  user_id, source, category, sentiment, summary, details, context_json,
		  episode_id, agent_run_id, source_ref, status, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
		  category = excluded.category,
		  sentiment = excluded.sentiment,
		  summary = excluded.summary,
		  details = excluded.details,
		  context_json = excluded.context_json,
		  episode_id = excluded.episode_id,
		  agent_run_id = excluded.agent_run_id,
		  source_ref = excluded.source_ref,
		  status = excluded.status,
		  updated_at = excluded.updated_at`,
		item.ID, item.WorkspaceID, item.ChannelID, item.ThreadTS, item.MessageTS,
		item.TargetMessageTS, item.UserID, item.Source, item.Category, item.Sentiment,
		item.Summary, item.Details, contextJSON, item.EpisodeID, item.AgentRunID,
		item.SourceRef, item.Status, item.CreatedAt.Format(timestampFormat),
		item.UpdatedAt.Format(timestampFormat),
	)
	if err != nil {
		return FeedbackItem{}, err
	}
	return item, nil
}

func (s *Store) WithdrawFeedback(ctx context.Context, id string) error {
	if strings.TrimSpace(id) == "" {
		return errors.New("feedback id is required")
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE feedback_items
		SET status = 'withdrawn', updated_at = ?
		WHERE id = ?`, s.now().UTC().Format(timestampFormat), id)
	return err
}

func (s *Store) ListOpenFeedback(ctx context.Context, workspaceID string, limit int) ([]FeedbackItem, error) {
	if strings.TrimSpace(workspaceID) == "" || limit < 1 || limit > 100 {
		return nil, errors.New("feedback list requires a workspace and limit between 1 and 100")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, workspace_id, channel_id, thread_ts, message_ts, target_message_ts,
		  user_id, source, category, sentiment, summary, details, context_json,
		  episode_id, agent_run_id, source_ref, status, created_at, updated_at
		FROM feedback_items
		WHERE workspace_id = ? AND status = 'open'
		ORDER BY updated_at DESC, id DESC
		LIMIT ?`, workspaceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]FeedbackItem, 0, limit)
	for rows.Next() {
		item, err := scanFeedback(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func validateFeedback(item FeedbackItem) error {
	for name, value := range map[string]string{
		"id": item.ID, "workspace": item.WorkspaceID, "channel": item.ChannelID,
		"user": item.UserID, "source": item.Source, "category": item.Category,
		"sentiment": item.Sentiment, "summary": item.Summary,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("feedback %s is required", name)
		}
	}
	if len(item.ID) > 160 || len(item.Summary) > 500 || len(item.Details) > 4000 || len(item.Context) > 30 {
		return errors.New("feedback item exceeds its bounded size")
	}
	return nil
}

type feedbackScanner interface {
	Scan(...any) error
}

func scanFeedback(row feedbackScanner) (FeedbackItem, error) {
	var item FeedbackItem
	var contextJSON []byte
	var createdAt, updatedAt string
	err := row.Scan(
		&item.ID, &item.WorkspaceID, &item.ChannelID, &item.ThreadTS, &item.MessageTS,
		&item.TargetMessageTS, &item.UserID, &item.Source, &item.Category,
		&item.Sentiment, &item.Summary, &item.Details, &contextJSON, &item.EpisodeID,
		&item.AgentRunID, &item.SourceRef, &item.Status, &createdAt, &updatedAt,
	)
	if err != nil {
		return FeedbackItem{}, err
	}
	if err := json.Unmarshal(contextJSON, &item.Context); err != nil {
		return FeedbackItem{}, err
	}
	item.CreatedAt, err = time.Parse(timestampParseFormat, createdAt)
	if err != nil {
		return FeedbackItem{}, err
	}
	item.UpdatedAt, err = time.Parse(timestampParseFormat, updatedAt)
	return item, err
}

// ResolveFeedback records what an operator decided about a feedback item.
//
// Capturing feedback and never acting on it is worse than not capturing it:
// the operator sees their input accepted and nothing change. A resolution is
// how an item leaves the open queue — either dismissed, or converted into
// durable guidance that actually steers future behaviour.
func (s *Store) ResolveFeedback(ctx context.Context, id, status, actor string) error {
	if strings.TrimSpace(id) == "" {
		return errors.New("feedback id is required")
	}
	switch status {
	case "dismissed", "converted":
	default:
		return fmt.Errorf("feedback resolution %q is not supported", status)
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE feedback_items
		SET status = ?, resolved_by = ?, updated_at = ?
		WHERE id = ? AND status = 'open'`,
		status, strings.TrimSpace(actor), s.now().UTC().Format(timestampFormat), id,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows != 1 {
		return ErrFeedbackNotOpen
	}
	return nil
}

// ErrFeedbackNotOpen reports a resolution against an item that was already resolved,
// which happens whenever two operators press a button at the same time.
var ErrFeedbackNotOpen = errors.New("feedback item is not open")

// GetFeedback returns one item regardless of status.
func (s *Store) GetFeedback(ctx context.Context, id string) (FeedbackItem, error) {
	return scanFeedback(s.db.QueryRowContext(ctx, `
		SELECT id, workspace_id, channel_id, thread_ts, message_ts, target_message_ts,
		  user_id, source, category, sentiment, summary, details, context_json,
		  episode_id, agent_run_id, source_ref, status, created_at, updated_at
		FROM feedback_items WHERE id = ?`, id))
}

// AdoptLegacyFeedback moves rows from the standalone feedback database that
// earlier builds wrote beside this one.
//
// It runs once at startup and is idempotent: rows already present win, because
// the main database is authoritative from the moment the migration created the
// table. The old file is left in place rather than deleted — an operator who
// needs to check what was carried across should be able to, and nothing reads
// it after this.
func (s *Store) AdoptLegacyFeedback(ctx context.Context, stateDir string) (int, error) {
	path := filepath.Join(stateDir, "feedback.db")
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	legacy, err := sql.Open("sqlite", path)
	if err != nil {
		return 0, fmt.Errorf("open legacy feedback database: %w", err)
	}
	defer legacy.Close()
	legacy.SetMaxOpenConns(1)
	rows, err := legacy.QueryContext(ctx, `
		SELECT id, workspace_id, channel_id, thread_ts, message_ts, target_message_ts,
		  user_id, source, category, sentiment, summary, details, context_json,
		  episode_id, agent_run_id, source_ref, status, created_at, updated_at
		FROM feedback_items`)
	if err != nil {
		// A file that is not the schema we expect is not worth failing startup
		// over; the table is empty and the service is otherwise fine.
		return 0, nil
	}
	defer rows.Close()
	items := make([]FeedbackItem, 0)
	for rows.Next() {
		item, scanErr := scanFeedback(rows)
		if scanErr != nil {
			return 0, scanErr
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	adopted := 0
	for _, item := range items {
		if _, err := s.GetFeedback(ctx, item.ID); err == nil {
			continue
		}
		if _, err := s.RecordFeedback(ctx, item); err != nil {
			return adopted, err
		}
		if item.Status != "open" {
			if err := s.ResolveFeedback(ctx, item.ID, item.Status, ""); err != nil &&
				!errors.Is(err, ErrFeedbackNotOpen) {
				return adopted, err
			}
		}
		adopted++
	}
	return adopted, nil
}

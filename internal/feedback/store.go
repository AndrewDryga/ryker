package feedback

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

	_ "modernc.org/sqlite"
)

const timestampFormat = time.RFC3339Nano

type ContextMessage struct {
	MessageTS   string              `json:"message_ts,omitempty"`
	ThreadTS    string              `json:"thread_ts,omitempty"`
	MessageLink string              `json:"message_link,omitempty"`
	SenderID    string              `json:"sender_id,omitempty"`
	SenderType  string              `json:"sender_type,omitempty"`
	Text        string              `json:"text,omitempty"`
	Attachments []ContextAttachment `json:"attachments,omitempty"`
}

type ContextAttachment struct {
	Name      string `json:"name,omitempty"`
	MediaType string `json:"media_type,omitempty"`
	Size      int64  `json:"size,omitempty"`
}

type Item struct {
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
	Context         []ContextMessage
	EpisodeID       string
	AgentRunID      string
	SourceRef       string
	Status          string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

type Store struct {
	db    *sql.DB
	clock func() time.Time
}

// now is the store clock. Retention and digest windows read it, so a test can
// move time instead of waiting for it.
func (s *Store) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

// SetClock replaces the store clock. It exists for tests.
func (s *Store) SetClock(clock func() time.Time) {
	if clock != nil {
		s.clock = clock
	}
}

func Open(stateDir string) (*Store, error) {
	if strings.TrimSpace(stateDir) == "" || !filepath.IsAbs(stateDir) {
		return nil, errors.New("feedback store requires an absolute state directory")
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "feedback.db"))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	store := &Store{db: db}
	if err := store.initialize(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	if err := os.Chmod(filepath.Join(stateDir, "feedback.db"), 0o600); err != nil {
		db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) initialize(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		PRAGMA journal_mode = DELETE;
		PRAGMA busy_timeout = 5000;
		PRAGMA temp_store = MEMORY;
		CREATE TABLE IF NOT EXISTS feedback_items (
		  id TEXT PRIMARY KEY,
		  workspace_id TEXT NOT NULL,
		  channel_id TEXT NOT NULL,
		  thread_ts TEXT NOT NULL DEFAULT '',
		  message_ts TEXT NOT NULL DEFAULT '',
		  target_message_ts TEXT NOT NULL DEFAULT '',
		  user_id TEXT NOT NULL,
		  source TEXT NOT NULL,
		  category TEXT NOT NULL,
		  sentiment TEXT NOT NULL,
		  summary TEXT NOT NULL,
		  details TEXT NOT NULL DEFAULT '',
		  context_json BLOB NOT NULL,
		  episode_id TEXT NOT NULL DEFAULT '',
		  agent_run_id TEXT NOT NULL DEFAULT '',
		  source_ref TEXT NOT NULL DEFAULT '',
		  status TEXT NOT NULL,
		  resolved_by TEXT NOT NULL DEFAULT '',
		  created_at TEXT NOT NULL,
		  updated_at TEXT NOT NULL
		);
		CREATE INDEX IF NOT EXISTS feedback_items_workspace_status_updated
		  ON feedback_items(workspace_id, status, updated_at DESC);
	`)
	if err != nil {
		return err
	}
	// An existing feedback database predates the resolution column. SQLite has
	// no IF NOT EXISTS for ADD COLUMN, so a duplicate error here is success.
	if _, err := s.db.ExecContext(
		ctx, `ALTER TABLE feedback_items ADD COLUMN resolved_by TEXT NOT NULL DEFAULT ''`,
	); err != nil && !strings.Contains(err.Error(), "duplicate column name") {
		return err
	}
	return nil
}

func (s *Store) Record(ctx context.Context, item Item) (Item, error) {
	if err := validate(item); err != nil {
		return Item{}, err
	}
	contextJSON, err := json.Marshal(item.Context)
	if err != nil {
		return Item{}, err
	}
	now := s.now().UTC()
	if item.CreatedAt.IsZero() {
		item.CreatedAt = now
	}
	item.UpdatedAt = now
	item.Status = "open"
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
		  status = 'open',
		  updated_at = excluded.updated_at`,
		item.ID, item.WorkspaceID, item.ChannelID, item.ThreadTS, item.MessageTS,
		item.TargetMessageTS, item.UserID, item.Source, item.Category, item.Sentiment,
		item.Summary, item.Details, contextJSON, item.EpisodeID, item.AgentRunID,
		item.SourceRef, item.Status, item.CreatedAt.Format(timestampFormat),
		item.UpdatedAt.Format(timestampFormat),
	)
	if err != nil {
		return Item{}, err
	}
	return item, nil
}

func (s *Store) Withdraw(ctx context.Context, id string) error {
	if strings.TrimSpace(id) == "" {
		return errors.New("feedback id is required")
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE feedback_items
		SET status = 'withdrawn', updated_at = ?
		WHERE id = ?`, s.now().UTC().Format(timestampFormat), id)
	return err
}

func (s *Store) ListOpen(ctx context.Context, workspaceID string, limit int) ([]Item, error) {
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
	items := make([]Item, 0, limit)
	for rows.Next() {
		item, err := scan(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func validate(item Item) error {
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

type scanner interface {
	Scan(...any) error
}

func scan(row scanner) (Item, error) {
	var item Item
	var contextJSON []byte
	var createdAt, updatedAt string
	err := row.Scan(
		&item.ID, &item.WorkspaceID, &item.ChannelID, &item.ThreadTS, &item.MessageTS,
		&item.TargetMessageTS, &item.UserID, &item.Source, &item.Category,
		&item.Sentiment, &item.Summary, &item.Details, &contextJSON, &item.EpisodeID,
		&item.AgentRunID, &item.SourceRef, &item.Status, &createdAt, &updatedAt,
	)
	if err != nil {
		return Item{}, err
	}
	if err := json.Unmarshal(contextJSON, &item.Context); err != nil {
		return Item{}, err
	}
	item.CreatedAt, err = time.Parse(timestampFormat, createdAt)
	if err != nil {
		return Item{}, err
	}
	item.UpdatedAt, err = time.Parse(timestampFormat, updatedAt)
	return item, err
}

// Resolve records what an operator decided about a feedback item.
//
// Capturing feedback and never acting on it is worse than not capturing it:
// the operator sees their input accepted and nothing change. A resolution is
// how an item leaves the open queue — either dismissed, or converted into
// durable guidance that actually steers future behaviour.
func (s *Store) Resolve(ctx context.Context, id, status, actor string) error {
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
		return ErrNotOpen
	}
	return nil
}

// ErrNotOpen reports a resolution against an item that was already resolved,
// which happens whenever two operators press a button at the same time.
var ErrNotOpen = errors.New("feedback item is not open")

// Get returns one item regardless of status.
func (s *Store) Get(ctx context.Context, id string) (Item, error) {
	return scan(s.db.QueryRowContext(ctx, `
		SELECT id, workspace_id, channel_id, thread_ts, message_ts, target_message_ts,
		  user_id, source, category, sentiment, summary, details, context_json,
		  episode_id, agent_run_id, source_ref, status, created_at, updated_at
		FROM feedback_items WHERE id = ?`, id))
}

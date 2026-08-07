package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/scheduleproposal"
	_ "modernc.org/sqlite"
)

// Timestamps are stored as TEXT and compared lexicographically by SQLite, so
// their text order has to match their chronological order. It does, because
// every stored value is written at a fixed width — see core.TimestampFormat
// for why that is load-bearing and what it replaced.

// Both point at core so the two packages that write timestamps cannot drift
// apart. See core.TimestampFormat for why the read and write formats differ.
const timestampFormat = core.TimestampFormat

const timestampParseFormat = core.TimestampParseFormat

const migrationBackupRetention = 3

var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("conflict")
	ErrCapacity = errors.New("incident capacity reached")
)

type Store struct {
	db                *sql.DB
	clock             func() time.Time
	ScheduleProposals *scheduleproposal.Repository
}

type Metrics struct {
	IncidentsOpen          int `json:"incidents_open"`
	IncidentsTotal         int `json:"incidents_total"`
	SessionsOpen           int `json:"sessions_open"`
	PublishedPRs           int `json:"published_prs"`
	CleanupPending         int `json:"cleanup_pending"`
	CleanupBlocked         int `json:"cleanup_blocked"`
	WebhooksPending        int `json:"webhooks_pending"`
	SlackPending           int `json:"slack_pending"`
	SlackDeliveriesPending int `json:"slack_deliveries_pending"`
	AgentRunsPending       int `json:"agent_runs_pending"`
	WorkFailed             int `json:"work_failed"`
	MemoryActive           int `json:"memory_active"`
	MemoryExpired          int `json:"memory_expired"`
	MemoryRollups          int `json:"memory_rollups"`
	MemoryReviewsPending   int `json:"memory_reviews_pending"`
	ConversationMemories   int `json:"conversation_memories"`
	PreferencesActive      int `json:"preferences_active"`
	PreferencesDisabled    int `json:"preferences_disabled"`
	RulesActive            int `json:"rules_active"`
	RulesDisabled          int `json:"rules_disabled"`
	SchedulesActive        int `json:"schedules_active"`
	SchedulesPaused        int `json:"schedules_paused"`
	ScheduleRunsActive     int `json:"schedule_runs_active"`
	EpisodesOverdue        int `json:"episodes_overdue"`
}

type FailedWork struct {
	Kind      string    `json:"kind"`
	ID        string    `json:"id"`
	Reference string    `json:"reference,omitempty"`
	Retryable bool      `json:"retryable"`
	Attempts  int       `json:"attempts"`
	LastError string    `json:"last_error"`
	UpdatedAt time.Time `json:"updated_at"`
}

type SlackSetting struct {
	Scope     string
	ChannelID string
	Name      string
	Value     string
	ActorID   string
	UpdatedAt time.Time
}

func Open(stateDir string) (*Store, error) {
	if err := ensurePrivateDir(stateDir); err != nil {
		return nil, err
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	store := &Store{db: db}
	store.ScheduleProposals = scheduleproposal.New(db, func() time.Time { return store.now() })
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("open database: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		db.Close()
		return nil, fmt.Errorf("protect database: %w", err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		db.Close()
		return nil, fmt.Errorf("configure database connection: %w", err)
	}
	version, err := schemaVersion(db)
	if err != nil {
		db.Close()
		return nil, err
	}
	if version == 0 {
		if _, err := db.Exec(`PRAGMA auto_vacuum = INCREMENTAL;`); err != nil {
			db.Close()
			return nil, fmt.Errorf("configure incremental database vacuum: %w", err)
		}
	}
	if version > currentSchemaVersion {
		db.Close()
		return nil, fmt.Errorf(
			"database schema version %d is newer than supported version %d",
			version, currentSchemaVersion,
		)
	}
	if version > 0 && version < currentSchemaVersion {
		if err := backupBeforeMigration(db, stateDir, version); err != nil {
			db.Close()
			return nil, err
		}
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureIncrementalVacuum(db); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec(persistentPragmas); err != nil {
		db.Close()
		return nil, fmt.Errorf("configure database durability: %w", err)
	}
	return store, nil
}

func backupBeforeMigration(db *sql.DB, stateDir string, sourceVersion int) error {
	backupDir := filepath.Join(stateDir, "backups")
	if err := ensurePrivateDir(backupDir); err != nil {
		return fmt.Errorf("prepare migration backup directory: %w", err)
	}
	name := fmt.Sprintf(
		"responder-v%d-to-v%d-%s.db",
		sourceVersion,
		currentSchemaVersion,
		time.Now().UTC().Format("20060102T150405.000000000Z"),
	)
	path := filepath.Join(backupDir, name)
	if _, err := db.Exec(`VACUUM INTO ?`, path); err != nil {
		return fmt.Errorf("create migration backup: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("protect migration backup: %w", err)
	}
	if err := verifyMigrationBackup(path, sourceVersion); err != nil {
		return err
	}
	if err := pruneMigrationBackups(backupDir, migrationBackupRetention); err != nil {
		return err
	}
	return nil
}

func verifyMigrationBackup(path string, sourceVersion int) error {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return fmt.Errorf("open migration backup for verification: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	defer db.Close()
	if _, err := db.Exec(connectionPragmas + "\nPRAGMA query_only = ON;"); err != nil {
		return fmt.Errorf("configure migration backup verification: %w", err)
	}
	version, err := schemaVersion(db)
	if err != nil {
		return fmt.Errorf("verify migration backup schema: %w", err)
	}
	if version != sourceVersion {
		return fmt.Errorf(
			"migration backup schema version is %d, want %d",
			version,
			sourceVersion,
		)
	}
	rows, err := db.Query(`PRAGMA quick_check`)
	if err != nil {
		return fmt.Errorf("verify migration backup integrity: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var result string
		if err := rows.Scan(&result); err != nil {
			return fmt.Errorf("verify migration backup integrity: %w", err)
		}
		if result != "ok" {
			return fmt.Errorf("migration backup quick check failed: %s", boundedError(result))
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("verify migration backup integrity: %w", err)
	}
	return nil
}

func pruneMigrationBackups(dir string, keep int) error {
	paths, err := filepath.Glob(filepath.Join(dir, "responder-v*-to-v*.db"))
	if err != nil {
		return fmt.Errorf("list migration backups: %w", err)
	}
	type candidate struct {
		path    string
		modTime time.Time
	}
	candidates := make([]candidate, 0, len(paths))
	for _, path := range paths {
		info, err := os.Lstat(path)
		if err != nil {
			return fmt.Errorf("inspect migration backup: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			continue
		}
		candidates = append(candidates, candidate{path: path, modTime: info.ModTime()})
	}
	slices.SortFunc(candidates, func(a, b candidate) int {
		if order := b.modTime.Compare(a.modTime); order != 0 {
			return order
		}
		return strings.Compare(b.path, a.path)
	})
	retained := max(keep, 0)
	if retained > len(candidates) {
		retained = len(candidates)
	}
	for _, item := range candidates[retained:] {
		if err := os.Remove(item.path); err != nil {
			return fmt.Errorf("remove expired migration backup: %w", err)
		}
	}
	return nil
}

func ensureIncrementalVacuum(db *sql.DB) error {
	var mode int
	if err := db.QueryRow(`PRAGMA auto_vacuum;`).Scan(&mode); err != nil {
		return fmt.Errorf("inspect database vacuum mode: %w", err)
	}
	if mode == 2 {
		return nil
	}
	if _, err := db.Exec(`PRAGMA auto_vacuum = INCREMENTAL; VACUUM;`); err != nil {
		return fmt.Errorf("enable incremental database vacuum: %w", err)
	}
	if err := db.QueryRow(`PRAGMA auto_vacuum;`).Scan(&mode); err != nil {
		return fmt.Errorf("verify database vacuum mode: %w", err)
	}
	if mode != 2 {
		return fmt.Errorf("database auto_vacuum mode is %d after migration, want 2", mode)
	}
	return nil
}

// OpenCurrent opens an existing database for inspection without changing its
// schema or persistent settings. It is safe to use while Responder is running.
func OpenCurrent(stateDir string) (*Store, error) {
	return openCurrent(stateDir, true)
}

// OpenLive opens an existing database for a bounded local control operation
// without migrating it or changing persistent settings. The caller must first
// confirm that the owning Responder process is running.
func OpenLive(stateDir string) (*Store, error) {
	return openCurrent(stateDir, false)
}

func openCurrent(stateDir string, readOnly bool) (*Store, error) {
	if !filepath.IsAbs(stateDir) || filepath.Clean(stateDir) != stateDir {
		return nil, errors.New("state directory must be an absolute clean path")
	}
	info, err := os.Lstat(stateDir)
	if err != nil {
		return nil, fmt.Errorf("inspect state directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, errors.New("state path must be a real directory")
	}
	path := filepath.Join(stateDir, "responder.db")
	info, err = os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect database: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, errors.New("database must be a regular file")
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	store := &Store{db: db}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("open database: %w", err)
	}
	pragmas := connectionPragmas
	if readOnly {
		pragmas += "\nPRAGMA query_only = ON;"
	}
	if _, err := db.Exec(pragmas); err != nil {
		db.Close()
		return nil, fmt.Errorf("configure current database: %w", err)
	}
	version, err := schemaVersion(db)
	if err != nil {
		db.Close()
		return nil, err
	}
	if version != currentSchemaVersion {
		db.Close()
		return nil, fmt.Errorf(
			"database schema version %d requires an offline upgrade to version %d",
			version, currentSchemaVersion,
		)
	}
	return store, nil
}

func schemaVersion(db *sql.DB) (int, error) {
	var versionTableCount int
	if err := db.QueryRow(`
		SELECT count(*) FROM sqlite_master
		WHERE type = 'table' AND name = 'schema_version'`).Scan(&versionTableCount); err != nil {
		return 0, fmt.Errorf("inspect schema version: %w", err)
	}
	version := 0
	if versionTableCount == 0 {
		var existingTables int
		if err := db.QueryRow(`
			SELECT count(*) FROM sqlite_master
			WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`).Scan(&existingTables); err != nil {
			return 0, fmt.Errorf("inspect database schema: %w", err)
		}
		if existingTables != 0 {
			return 0, errors.New("database has tables but no schema version")
		}
	} else {
		var count int
		if err := db.QueryRow(`SELECT count(*), min(version) FROM schema_version`).Scan(&count, &version); err != nil {
			return 0, fmt.Errorf("read schema version: %w", err)
		}
		if count != 1 || version < 1 {
			return 0, errors.New("invalid schema version")
		}
	}
	return version, nil
}

func migrate(db *sql.DB) error {
	version, err := schemaVersion(db)
	if err != nil {
		return err
	}
	if version > currentSchemaVersion {
		return fmt.Errorf(
			"database schema version %d is newer than supported version %d",
			version, currentSchemaVersion,
		)
	}
	if version == 0 {
		if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
			return err
		}
		version = baselineSchemaVersion
	}
	if version < minimumUpgradableVersion {
		return fmt.Errorf(
			"database schema version %d predates the supported baseline; "+
				"upgrade with a release that supports version %d first",
			version, minimumUpgradableVersion,
		)
	}
	for version < currentSchemaVersion {
		next := version + 1
		statement, ok := migrations[next]
		if !ok || strings.TrimSpace(statement) == "" {
			return fmt.Errorf("database migration %d is unavailable", next)
		}
		if err := applySchemaStep(db, statement, version, next); err != nil {
			return err
		}
		version = next
	}
	return nil
}

// applySchemaStep applies one schema statement and records the resulting
// version in the same transaction, so an interrupted upgrade can never leave a
// database whose recorded version disagrees with its shape.
func applySchemaStep(db *sql.DB, statement string, from, to int) error {
	if tableRebuildMigrations[to] {
		// A migration that rebuilds a table has to run with foreign keys off,
		// and the pragma is a no-op inside a transaction — so it is set here,
		// around the transaction, rather than in the migration text where it
		// would silently do nothing.
		//
		// This is not a convenience. work_episodes is referenced by eight
		// tables with ON DELETE CASCADE, so the ordinary rebuild recipe —
		// create, copy, DROP TABLE, rename — deletes every attempt, commitment
		// and episode event on the way past. Measured on a copy of the deployed
		// database: 352 attempts, 332 commitments and 9934 events destroyed,
		// with the migration reporting success.
		if _, err := db.Exec(`PRAGMA foreign_keys = OFF`); err != nil {
			return fmt.Errorf("disable foreign keys for migration %d: %w", to, err)
		}
		defer db.Exec(`PRAGMA foreign_keys = ON`)
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin database migration %d: %w", to, err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(statement); err != nil {
		return fmt.Errorf("apply database migration %d: %w", to, err)
	}
	if from == 0 {
		_, err = tx.Exec(`INSERT INTO schema_version(version) VALUES (?)`, to)
	} else {
		var result sql.Result
		result, err = tx.Exec(`UPDATE schema_version SET version = ? WHERE version = ?`, to, from)
		if err == nil {
			err = expectOne(result, nil, fmt.Sprintf("record database migration %d", to))
		}
	}
	if err != nil {
		return fmt.Errorf("record database migration %d: %w", to, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit database migration %d: %w", to, err)
	}
	if tableRebuildMigrations[to] {
		// Foreign keys were off for the rebuild, so nothing checked them. This
		// is where that debt is paid: a rebuild that dropped rows some child
		// still points at must fail loudly here rather than leave a database
		// that looks migrated and has dangling references.
		return verifyForeignKeys(db, to)
	}
	return nil
}

// tableRebuildMigrations names the migrations that rebuild a table and so must
// run with foreign keys disabled.
//
// Opt-in per migration rather than always on: every other migration benefits
// from the constraints being enforced while it runs, and a rebuild is rare
// enough that turning them off should be a deliberate, listed decision.
var tableRebuildMigrations = map[int]bool{}

// verifyForeignKeys fails if a migration left a reference pointing at nothing.
func verifyForeignKeys(db *sql.DB, migration int) error {
	rows, err := db.Query(`PRAGMA foreign_key_check`)
	if err != nil {
		return fmt.Errorf("check foreign keys after migration %d: %w", migration, err)
	}
	defer rows.Close()
	var broken []string
	for rows.Next() {
		var (
			table, parent string
			rowID, fkID   sql.NullInt64
		)
		if err := rows.Scan(&table, &rowID, &parent, &fkID); err != nil {
			return fmt.Errorf("read foreign key check after migration %d: %w", migration, err)
		}
		broken = append(broken, table+" -> "+parent)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(broken) > 0 {
		return fmt.Errorf(
			"database migration %d left %d dangling references (%s); "+
				"the database has been left at the pre-migration version",
			migration, len(broken), strings.Join(broken, ", "),
		)
	}
	return nil
}

func (s *Store) RecoverInterrupted(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		  SET session_id = (
		    SELECT incidents.coop_session_id
		    FROM incidents
		    WHERE incidents.id = agent_runs.incident_id
		  ),
		  updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
		  WHERE incident_id IS NOT NULL
		    AND session_id = ''
		    AND state IN ('preparing', 'running', 'applying', 'finalizing')
		    AND EXISTS (
		      SELECT 1 FROM incidents
		      WHERE incidents.id = agent_runs.incident_id
		        AND incidents.coop_session_id != ''
		    );
		UPDATE webhook_events SET state = 'retry', next_attempt_at = updated_at
		  WHERE state = 'processing';
		UPDATE slack_inputs SET state = 'retry', next_attempt_at = updated_at
		  WHERE state = 'processing';
			UPDATE agent_runs SET state = 'pending', next_attempt_at = updated_at
			  WHERE state = 'preparing';
			UPDATE agent_runs SET state = 'applying', next_attempt_at = updated_at
			  WHERE state = 'finalizing';
		UPDATE slack_deliveries
		  SET state = CASE WHEN operation = 'post' THEN 'uncertain' ELSE 'retry' END,
		      last_error = 'process stopped during Slack delivery',
		      next_attempt_at = updated_at
		  WHERE state = 'sending';
		UPDATE publications SET state = 'failed',
		  last_error = 'Responder stopped during draft PR publication',
		  updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
		  WHERE state = 'publishing';
	`); err != nil {
		return fmt.Errorf("recover interrupted work: %w", err)
	}
	if err := s.RecoverWorkLeases(ctx, s.now().UTC()); err != nil {
		return fmt.Errorf("recover scheduled work: %w", err)
	}
	return nil
}

func ensurePrivateDir(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("state directory must be an absolute clean path")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errors.New("state path must be a real directory")
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect state directory: %w", err)
	} else if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return fmt.Errorf("protect state directory: %w", err)
	}
	return nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s *Store) SetSlackSetting(
	ctx context.Context,
	scope, channelID, name, value, actorID string,
) error {
	if err := validateSlackSettingKey(scope, channelID, name); err != nil {
		return err
	}
	if strings.TrimSpace(value) == "" || strings.TrimSpace(actorID) == "" {
		return errors.New("Slack setting value and actor are required")
	}
	if len(value) > 1024 || len(actorID) > 64 {
		return errors.New("Slack setting field exceeds its limit")
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO slack_settings (scope, channel_id, name, value, actor_id, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(scope, channel_id, name) DO UPDATE SET
		  value = excluded.value,
		  actor_id = excluded.actor_id,
		  updated_at = excluded.updated_at`,
		scope, channelID, name, value, actorID, s.nowText())
	return err
}

func (s *Store) DeleteSlackSetting(
	ctx context.Context,
	scope, channelID, name string,
) error {
	if err := validateSlackSettingKey(scope, channelID, name); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM slack_settings
		WHERE scope = ? AND channel_id = ? AND name = ?`,
		scope, channelID, name)
	return err
}

func (s *Store) DeleteSlackChannelSettings(ctx context.Context, channelID string) (int64, error) {
	if strings.TrimSpace(channelID) == "" || len(channelID) > 64 {
		return 0, errors.New("Slack channel ID is invalid")
	}
	result, err := s.db.ExecContext(ctx, `
		DELETE FROM slack_settings
		WHERE scope = 'channel' AND channel_id = ?`,
		channelID,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) GetSlackSetting(
	ctx context.Context,
	scope, channelID, name string,
) (SlackSetting, error) {
	if err := validateSlackSettingKey(scope, channelID, name); err != nil {
		return SlackSetting{}, err
	}
	var setting SlackSetting
	var updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT scope, channel_id, name, value, actor_id, updated_at
		FROM slack_settings
		WHERE scope = ? AND channel_id = ? AND name = ?`,
		scope, channelID, name).Scan(
		&setting.Scope, &setting.ChannelID, &setting.Name,
		&setting.Value, &setting.ActorID, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return SlackSetting{}, ErrNotFound
	}
	if err != nil {
		return SlackSetting{}, err
	}
	setting.UpdatedAt = parseTime(updated)
	return setting, nil
}

func validateSlackSettingKey(scope, channelID, name string) error {
	if scope != "global" && scope != "channel" {
		return errors.New("Slack setting scope must be global or channel")
	}
	if (scope == "global" && channelID != "") || (scope == "channel" && channelID == "") {
		return errors.New("Slack setting channel does not match its scope")
	}
	if strings.TrimSpace(name) == "" {
		return errors.New("Slack setting name is required")
	}
	if len(name) > 64 || len(channelID) > 64 {
		return errors.New("Slack setting field exceeds its limit")
	}
	return nil
}

func (s *Store) Check(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA quick_check`)
	if err != nil {
		return fmt.Errorf("check database: %w", err)
	}
	defer rows.Close()
	var problems []string
	for rows.Next() {
		var result string
		if err := rows.Scan(&result); err != nil {
			return fmt.Errorf("check database: %w", err)
		}
		if result != "ok" {
			problems = append(problems, result)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("check database: %w", err)
	}
	if len(problems) > 0 {
		return fmt.Errorf("database quick check failed: %s", boundedError(strings.Join(problems, "; ")))
	}
	return nil
}

func (s *Store) Metrics(ctx context.Context) (Metrics, error) {
	var result Metrics
	queries := []struct {
		target *int
		query  string
	}{
		{&result.IncidentsOpen, `SELECT count(*) FROM incidents WHERE status != 'closed'`},
		{&result.IncidentsTotal, `SELECT count(*) FROM incidents`},
		{&result.SessionsOpen, `SELECT count(*) FROM incidents WHERE coop_session_id != '' AND workflow != 'closed'`},
		{&result.PublishedPRs, `SELECT count(*) FROM publications WHERE state = 'published'`},
		{&result.CleanupPending, `SELECT count(*) FROM coop_cleanup WHERE state IN ('pending', 'retry', 'planning', 'discarding')`},
		{&result.CleanupBlocked, `SELECT count(*) FROM coop_cleanup WHERE state = 'blocked'`},
		{&result.WebhooksPending, `SELECT count(*) FROM webhook_events WHERE state IN ('pending', 'retry', 'processing')`},
		{&result.SlackPending, `SELECT count(*) FROM slack_inputs WHERE state IN ('pending', 'retry', 'processing')`},
		{&result.SlackDeliveriesPending, `SELECT count(*) FROM slack_deliveries WHERE state IN ('pending', 'retry', 'sending', 'uncertain')`},
		{&result.AgentRunsPending, `SELECT count(*) FROM agent_runs WHERE state IN ('pending', 'preparing', 'running', 'applying', 'finalizing')`},
		{&result.MemoryActive, `SELECT count(*) FROM memory_entries WHERE julianday(expires_at) > julianday('now')`},
		{&result.MemoryExpired, `SELECT count(*) FROM memory_entries WHERE julianday(expires_at) <= julianday('now')`},
		{&result.MemoryRollups, `SELECT count(*) FROM memory_rollups WHERE julianday(expires_at) > julianday('now')`},
		{&result.MemoryReviewsPending, `SELECT count(*) FROM memory_review_items WHERE status = 'pending'`},
		{&result.ConversationMemories, `SELECT count(*) FROM conversation_memories`},
		{&result.PreferencesActive, `SELECT count(*) FROM responder_preferences WHERE enabled = 1 AND julianday(expires_at) > julianday('now')`},
		{&result.PreferencesDisabled, `SELECT count(*) FROM responder_preferences WHERE enabled = 0 AND julianday(expires_at) > julianday('now')`},
		{&result.RulesActive, `SELECT count(*) FROM standing_rules WHERE enabled = 1 AND julianday(expires_at) > julianday('now')`},
		{&result.RulesDisabled, `SELECT count(*) FROM standing_rules WHERE enabled = 0 AND julianday(expires_at) > julianday('now')`},
		{&result.SchedulesActive, `SELECT count(*) FROM scheduled_tasks WHERE enabled = 1 AND julianday(expires_at) > julianday('now')`},
		{&result.SchedulesPaused, `SELECT count(*) FROM scheduled_tasks WHERE enabled = 0 AND next_run_at IS NOT NULL AND julianday(expires_at) > julianday('now')`},
		{&result.ScheduleRunsActive, `SELECT count(*) FROM scheduled_task_runs WHERE outcome IN ('queued', 'running')`},
		{&result.EpisodesOverdue, `SELECT count(*) FROM work_episodes
		  WHERE completed_at IS NULL AND progress_due_at IS NOT NULL
		    AND julianday(progress_due_at) <= julianday('now')
		    AND state NOT IN ('completed', 'cancelled', 'failed', 'superseded')`},
		{&result.WorkFailed, `
			SELECT
			  (SELECT count(*) FROM webhook_events WHERE state = 'failed') +
			  (SELECT count(*) FROM slack_inputs WHERE state = 'failed') +
			  (SELECT count(*) FROM slack_deliveries WHERE state = 'failed') +
			  (SELECT count(*) FROM agent_runs WHERE state = 'failed') +
			  (SELECT count(*) FROM work_items WHERE state = 'failed') +
			  (SELECT count(*) FROM publications WHERE state = 'failed') +
			  (SELECT count(*) FROM coop_cleanup WHERE state = 'blocked')`},
	}
	for _, item := range queries {
		if err := s.db.QueryRowContext(ctx, item.query).Scan(item.target); err != nil {
			return Metrics{}, err
		}
	}
	return result, nil
}

func (s *Store) EnsureIncidentCardRevision(
	ctx context.Context,
	revision string,
) (bool, error) {
	revision = strings.TrimSpace(revision)
	if revision == "" || len(revision) > 128 {
		return false, errors.New("incident card revision is invalid")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var current string
	err = tx.QueryRowContext(
		ctx,
		`SELECT value FROM responder_state WHERE key = 'incident_card_revision'`,
	).Scan(&current)
	if err == nil && current == revision {
		return false, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	now := s.nowText()
	if _, err := tx.ExecContext(ctx, `
		UPDATE incidents
		SET card_version = card_version + 1, updated_at = ?
		WHERE root_ts != '' AND channel_state = 'active'`,
		now,
	); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO responder_state (key, value, updated_at)
		VALUES ('incident_card_revision', ?, ?)
		ON CONFLICT(key) DO UPDATE SET
		  value = excluded.value,
		  updated_at = excluded.updated_at`,
		revision,
		now,
	); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

func (s *Store) ListFailedWork(ctx context.Context, limit int) ([]FailedWork, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT kind, id, reference, retryable, attempts, last_error, updated_at
		FROM (
			SELECT 'webhook' AS kind, id, incident_ids_json AS reference, 1 AS retryable,
			       attempts, last_error, updated_at
			FROM webhook_events WHERE state = 'failed'
			UNION ALL
			SELECT 'slack', id, channel_id, 1, attempts, last_error, updated_at
			FROM slack_inputs WHERE state = 'failed'
			UNION ALL
			SELECT 'delivery', id, COALESCE(incident_id, channel_id), 1,
			       failure_count, last_error, updated_at
			FROM slack_deliveries WHERE state = 'failed'
			UNION ALL
			SELECT 'agent_run', id, COALESCE(incident_id, conversation_key),
			       CASE WHEN coop_turn_id = '' THEN 1 ELSE 0 END,
			       failure_count, last_error, updated_at
			FROM agent_runs WHERE state = 'failed'
			UNION ALL
			SELECT 'publication', incident_id, head_branch, 0, 1, last_error, updated_at
			FROM publications WHERE state = 'failed'
			UNION ALL
			SELECT 'cleanup', session_id, incident_id, 0, attempts, last_error, updated_at
			FROM coop_cleanup WHERE state = 'blocked'
		)
		ORDER BY updated_at DESC, kind, id
		LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("list failed work: %w", err)
	}
	defer rows.Close()
	result := make([]FailedWork, 0)
	for rows.Next() {
		var item FailedWork
		var retryable int
		var updated string
		if err := rows.Scan(
			&item.Kind, &item.ID, &item.Reference, &retryable, &item.Attempts,
			&item.LastError, &updated,
		); err != nil {
			return nil, fmt.Errorf("scan failed work: %w", err)
		}
		item.Retryable = retryable != 0
		item.UpdatedAt = parseTime(updated)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) RetryFailedWork(ctx context.Context, kind, id string) (FailedWork, error) {
	target, ok := map[string][2]string{
		"webhook":   {"webhook_events", "incident_ids_json"},
		"slack":     {"slack_inputs", "channel_id"},
		"delivery":  {"slack_deliveries", "COALESCE(incident_id, channel_id)"},
		"outbox":    {"slack_deliveries", "COALESCE(incident_id, channel_id)"},
		"agent_run": {"agent_runs", "COALESCE(incident_id, conversation_key)"},
		"turn":      {"agent_runs", "COALESCE(incident_id, conversation_key)"},
	}[kind]
	if !ok {
		return FailedWork{}, fmt.Errorf("unknown work kind %q", kind)
	}
	table, referenceColumn := target[0], target[1]
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return FailedWork{}, err
	}
	defer tx.Rollback()
	item := FailedWork{Kind: kind, ID: id}
	var updated string
	attemptColumn := "attempts"
	if kind == "turn" || kind == "agent_run" ||
		kind == "outbox" || kind == "delivery" {
		attemptColumn = "failure_count"
	}
	query := fmt.Sprintf(
		`SELECT %s, %s, last_error, updated_at FROM %s WHERE id = ? AND state = 'failed'`,
		referenceColumn, attemptColumn, table,
	)
	if err := tx.QueryRowContext(ctx, query, id).Scan(
		&item.Reference, &item.Attempts, &item.LastError, &updated,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return FailedWork{}, fmt.Errorf("%s %q is not failed: %w", kind, id, ErrNotFound)
		}
		return FailedWork{}, err
	}
	item.UpdatedAt = parseTime(updated)
	item.Retryable = true
	if kind == "turn" || kind == "agent_run" {
		var coopTurnID string
		if err := tx.QueryRowContext(ctx, `
			SELECT coop_turn_id FROM agent_runs
			WHERE id = ? AND state = 'failed'`, id).Scan(&coopTurnID); err != nil {
			return FailedWork{}, err
		}
		if coopTurnID != "" {
			return FailedWork{}, fmt.Errorf(
				"agent run %q already reached terminal Coop turn %q; submit a new Slack message instead",
				id, coopTurnID,
			)
		}
	}
	now := s.nowText()
	retryState := "retry"
	if kind == "outbox" || kind == "delivery" {
		var operation string
		if err := tx.QueryRowContext(
			ctx,
			`SELECT operation FROM slack_deliveries WHERE id = ?`,
			id,
		).Scan(&operation); err != nil {
			return FailedWork{}, err
		}
		if operation == "post" {
			retryState = "uncertain"
		}
	}
	if kind == "turn" || kind == "agent_run" {
		retryState = "pending"
		attemptColumn = "failure_count"
	}
	update := fmt.Sprintf(`
		UPDATE %s
		SET state = ?, %s = 0, next_attempt_at = ?,
		    last_error = '', updated_at = ?
		WHERE id = ? AND state = 'failed'`, table, attemptColumn)
	result, err := tx.ExecContext(ctx, update, retryState, now, now, id)
	if err := expectOne(result, err, "retry failed "+kind); err != nil {
		return FailedWork{}, err
	}
	auditID, err := core.NewID("audit")
	if err != nil {
		return FailedWork{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO audit_events
		  (id, incident_id, kind, actor_id, object_id, outcome, detail, created_at)
		VALUES (?, '', 'operator.work.retried', 'local-cli', ?, 'succeeded', ?, ?)`,
		auditID, kind+":"+id, boundedError(item.LastError), now); err != nil {
		return FailedWork{}, fmt.Errorf("record retry audit event: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return FailedWork{}, err
	}
	return item, nil
}

// now is the store clock. Lease expiry, retry windows, correlation windows,
// and every persisted timestamp read it, so a test can move time instead of
// sleeping through a real backoff.
func (s *Store) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

func (s *Store) nowText() string {
	return s.now().UTC().Format(timestampFormat)
}

// SetClock replaces the store clock. It exists for tests.
func (s *Store) SetClock(clock func() time.Time) {
	if clock != nil {
		s.clock = clock
	}
}

func timeText(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(timestampFormat)
}

func parseTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	parsed, _ := time.Parse(timestampParseFormat, value)
	return parsed
}

func scanTime(value sql.NullString) time.Time {
	if !value.Valid {
		return time.Time{}
	}
	return parseTime(value.String)
}

func (s *Store) AdmitWebhook(ctx context.Context, route, dedupeKey, bodyDigest string, signals []core.Signal) (core.WebhookEvent, bool, error) {
	id, err := core.NewID("hook")
	if err != nil {
		return core.WebhookEvent{}, false, err
	}
	data, err := json.Marshal(signals)
	if err != nil {
		return core.WebhookEvent{}, false, fmt.Errorf("encode normalized signals: %w", err)
	}
	now := s.nowText()
	result, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO webhook_events
		  (id, route, dedupe_key, body_digest, signals_json, state, next_attempt_at, received_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		id, route, dedupeKey, bodyDigest, data, now, now, now)
	if err != nil {
		return core.WebhookEvent{}, false, fmt.Errorf("admit webhook: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.WebhookEvent{}, false, err
	}
	event, err := s.GetWebhookByKey(ctx, route, dedupeKey)
	return event, rows == 1, err
}

func (s *Store) GetWebhookByKey(ctx context.Context, route, dedupeKey string) (core.WebhookEvent, error) {
	return scanWebhook(s.db.QueryRowContext(ctx, `
		SELECT id, route, dedupe_key, body_digest, signals_json, incident_ids_json,
		       applied, state, attempts,
		       next_attempt_at, last_error, received_at
		FROM webhook_events WHERE route = ? AND dedupe_key = ?`, route, dedupeKey))
}

func scanWebhook(row interface{ Scan(...any) error }) (core.WebhookEvent, error) {
	var event core.WebhookEvent
	var signals, incidentIDs []byte
	var applied int
	var next, received string
	if err := row.Scan(&event.ID, &event.Route, &event.DedupeKey, &event.BodyDigest, &signals,
		&incidentIDs, &applied, &event.State, &event.Attempts, &next, &event.LastError, &received); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.WebhookEvent{}, ErrNotFound
		}
		return core.WebhookEvent{}, err
	}
	if err := json.Unmarshal(signals, &event.Signals); err != nil {
		return core.WebhookEvent{}, fmt.Errorf("decode stored signals: %w", err)
	}
	if err := json.Unmarshal(incidentIDs, &event.IncidentIDs); err != nil {
		return core.WebhookEvent{}, fmt.Errorf("decode affected incidents: %w", err)
	}
	event.Applied = applied != 0
	event.NextAttemptAt = parseTime(next)
	event.ReceivedAt = parseTime(received)
	return event, nil
}

func (s *Store) LeaseWebhook(ctx context.Context) (core.WebhookEvent, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.WebhookEvent{}, err
	}
	defer tx.Rollback()
	now := s.nowText()
	event, err := scanWebhook(tx.QueryRowContext(ctx, `
		SELECT id, route, dedupe_key, body_digest, signals_json, incident_ids_json,
		       applied, state, attempts,
		       next_attempt_at, last_error, received_at
		FROM webhook_events
		WHERE state IN ('pending', 'retry')
		  AND julianday(next_attempt_at) <= julianday(?)
		ORDER BY received_at LIMIT 1`, now))
	if err != nil {
		return core.WebhookEvent{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE webhook_events
		SET state = 'processing', attempts = attempts + 1, updated_at = ?
		WHERE id = ? AND state IN ('pending', 'retry')`, now, event.ID)
	if err != nil {
		return core.WebhookEvent{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return core.WebhookEvent{}, ErrConflict
	}
	if err := tx.Commit(); err != nil {
		return core.WebhookEvent{}, err
	}
	event.State = "processing"
	event.Attempts++
	return event, nil
}

func (s *Store) FinishWebhook(ctx context.Context, id string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE webhook_events SET state = 'done', last_error = '', updated_at = ?
		WHERE id = ? AND state = 'processing'`, s.nowText(), id)
	return expectOne(result, err, "finish webhook")
}

func (s *Store) RetryWebhook(ctx context.Context, id, detail string, next time.Time, terminal bool) error {
	state := "retry"
	if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE webhook_events SET state = ?, last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'processing'`,
		state, boundedError(detail), next.UTC().Format(timestampFormat), s.nowText(), id)
	return expectOne(result, err, "retry webhook")
}

func expectOne(result sql.Result, err error, action string) error {
	if err != nil {
		return fmt.Errorf("%s: %w", action, err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s: %w", action, err)
	}
	if rows != 1 {
		return fmt.Errorf("%s: %w", action, ErrConflict)
	}
	return nil
}

func boundedError(value string) string {
	return core.BoundedText(value, 1000)
}

func (s *Store) ApplySignals(
	ctx context.Context,
	event core.WebhookEvent,
	correlationWindow, resolveAfter time.Duration,
	maxOpenIncidents int,
) ([]core.Incident, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	now := s.now().UTC()
	affected := append([]string(nil), event.IncidentIDs...)
	var capacityErr error
	for _, signal := range event.Signals {
		incidentID, changed, err := applySignal(
			ctx, tx, signal, now, correlationWindow, maxOpenIncidents,
		)
		if errors.Is(err, ErrCapacity) {
			capacityErr = err
			continue
		}
		if err != nil {
			return nil, err
		}
		if incidentID == "" || !changed {
			continue
		}
		if !slices.Contains(affected, incidentID) {
			affected = append(affected, incidentID)
		}
		if err := refreshIncident(ctx, tx, incidentID, now, resolveAfter); err != nil {
			return nil, err
		}
	}
	if event.ID != "" {
		encoded, err := json.Marshal(affected)
		if err != nil {
			return nil, err
		}
		applied := 1
		if capacityErr != nil {
			applied = 0
		}
		result, err := tx.ExecContext(ctx, `
			UPDATE webhook_events SET applied = ?, incident_ids_json = ?, updated_at = ?
			WHERE id = ? AND state = 'processing'`,
			applied, encoded, now.Format(timestampFormat), event.ID)
		if err := expectOne(result, err, "record applied webhook"); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	result := make([]core.Incident, 0, len(affected))
	for _, id := range affected {
		incident, err := s.GetIncident(ctx, id)
		if err != nil {
			return nil, err
		}
		result = append(result, incident)
	}
	return result, capacityErr
}

func applySignal(
	ctx context.Context,
	tx *sql.Tx,
	signal core.Signal,
	now time.Time,
	correlationWindow time.Duration,
	maxOpenIncidents int,
) (string, bool, error) {
	var existing sql.NullString
	var previousEventID, previousStatus, previousTitle, previousSeverity, previousSummary, previousURL string
	err := tx.QueryRowContext(ctx, `
		SELECT incident_id, event_id, status, title, severity, summary, source_url
		FROM signals WHERE route = ? AND source_id = ?`,
		signal.Route, signal.SourceID).Scan(
		&existing, &previousEventID, &previousStatus, &previousTitle,
		&previousSeverity, &previousSummary, &previousURL)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	isNew := errors.Is(err, sql.ErrNoRows)
	incidentID := existing.String
	suppressRefresh := false
	if incidentID != "" {
		var incidentStatus, incidentUpdated string
		if err := tx.QueryRowContext(ctx, `
			SELECT status, updated_at FROM incidents WHERE id = ?`, incidentID).
			Scan(&incidentStatus, &incidentUpdated); err != nil {
			return "", false, err
		}
		tooOld := parseTime(incidentUpdated).Before(now.Add(-correlationWindow))
		endedOccurrence := incidentStatus == string(core.IncidentClosed) ||
			(incidentStatus == string(core.IncidentResolved) && tooOld)
		if endedOccurrence {
			if signal.Status == core.SignalFiring {
				incidentID = ""
			} else {
				suppressRefresh = true
			}
		}
	}
	if incidentID == "" && signal.Status == core.SignalFiring {
		cutoff := now.Add(-correlationWindow).Format(timestampFormat)
		err = tx.QueryRowContext(ctx, `
			SELECT id FROM incidents
			WHERE route = ? AND repository = ? AND correlation_key = ?
			  AND status != 'closed' AND updated_at >= ?
			ORDER BY updated_at DESC LIMIT 1`,
			signal.Route, signal.Repository, signal.CorrelationKey, cutoff).Scan(&incidentID)
		if errors.Is(err, sql.ErrNoRows) {
			if err := requireOpenIncidentSlot(ctx, tx, maxOpenIncidents); err != nil {
				return "", false, err
			}
			incidentID, err = core.NewID("inc")
			if err != nil {
				return "", false, err
			}
			_, err = tx.ExecContext(ctx, `
				INSERT INTO incidents
				  (id, route, repository, correlation_key, source_incident_id, title, severity,
				   status, workflow, created_at, updated_at, last_firing_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, 'active', 'provisioning_channel', ?, ?, ?)`,
				incidentID, signal.Route, signal.Repository, signal.CorrelationKey,
				signal.SourceIncidentID, signal.Title, signal.Severity,
				now.Format(timestampFormat), now.Format(timestampFormat), now.Format(timestampFormat))
		}
		if err != nil {
			return "", false, err
		}
	}
	labels, _ := json.Marshal(signal.Labels)
	annotations, _ := json.Marshal(signal.Annotations)
	var incidentValue any
	if incidentID != "" {
		incidentValue = incidentID
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO signals
		  (route, source_id, incident_id, source_incident_id, event_id, repository,
		   correlation_key, status, title, severity, summary, source_url, labels_json,
		   annotations_json, starts_at, ends_at, received_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(route, source_id) DO UPDATE SET
		  incident_id = excluded.incident_id,
		  source_incident_id = excluded.source_incident_id,
		  event_id = excluded.event_id,
		  status = excluded.status,
		  title = excluded.title,
		  severity = excluded.severity,
		  summary = excluded.summary,
		  source_url = excluded.source_url,
		  labels_json = excluded.labels_json,
		  annotations_json = excluded.annotations_json,
		  starts_at = excluded.starts_at,
		  ends_at = excluded.ends_at,
		  received_at = excluded.received_at,
		  updated_at = excluded.updated_at`,
		signal.Route, signal.SourceID, incidentValue, signal.SourceIncidentID, signal.EventID,
		signal.Repository, signal.CorrelationKey, signal.Status, signal.Title, signal.Severity,
		signal.Summary, signal.SourceURL, labels, annotations, timeText(signal.StartsAt),
		timeText(signal.EndsAt), signal.ReceivedAt.UTC().Format(timestampFormat), now.Format(timestampFormat))
	changed := isNew ||
		incidentID != existing.String ||
		previousEventID != signal.EventID ||
		previousStatus != string(signal.Status) ||
		previousTitle != signal.Title ||
		previousSeverity != signal.Severity ||
		previousSummary != signal.Summary ||
		previousURL != signal.SourceURL
	if suppressRefresh {
		return "", false, err
	}
	return incidentID, changed, err
}

func requireOpenIncidentSlot(ctx context.Context, tx *sql.Tx, maximum int) error {
	if maximum < 1 {
		return fmt.Errorf("invalid open incident limit %d: %w", maximum, ErrCapacity)
	}
	var count int
	if err := tx.QueryRowContext(ctx, `
		SELECT count(*) FROM incidents WHERE status != 'closed'`).Scan(&count); err != nil {
		return err
	}
	if count >= maximum {
		return fmt.Errorf("open incident limit %d reached: %w", maximum, ErrCapacity)
	}
	return nil
}

func enforceOpenIncidentCapacity(ctx context.Context, tx *sql.Tx, maximum int) error {
	if maximum < 1 {
		return fmt.Errorf("invalid open incident limit %d: %w", maximum, ErrCapacity)
	}
	var count int
	if err := tx.QueryRowContext(ctx, `
		SELECT count(*) FROM incidents WHERE status != 'closed'`).Scan(&count); err != nil {
		return err
	}
	if count > maximum {
		return fmt.Errorf("open incident limit %d reached: %w", maximum, ErrCapacity)
	}
	return nil
}

func refreshIncident(ctx context.Context, tx *sql.Tx, incidentID string, now time.Time, resolveAfter time.Duration) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT status, title, severity, received_at
		FROM signals WHERE incident_id = ? ORDER BY received_at`, incidentID)
	if err != nil {
		return err
	}
	defer rows.Close()
	count, firing := 0, 0
	title, severity := "", ""
	var lastFiring time.Time
	for rows.Next() {
		var status, candidateTitle, candidateSeverity, received string
		if err := rows.Scan(&status, &candidateTitle, &candidateSeverity, &received); err != nil {
			return err
		}
		count++
		if severityRank(candidateSeverity) > severityRank(severity) {
			severity = candidateSeverity
		}
		if status == string(core.SignalFiring) {
			firing++
			title = candidateTitle
			lastFiring = parseTime(received)
		} else if title == "" {
			title = candidateTitle
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	status := core.IncidentActive
	var due, resolved any
	if firing == 0 {
		if resolveAfter == 0 {
			status = core.IncidentResolved
			resolved = now.Format(timestampFormat)
		} else {
			status = core.IncidentMonitoring
			due = now.Add(resolveAfter).Format(timestampFormat)
		}
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE incidents SET title = ?, severity = ?, status = ?, signal_count = ?,
		  firing_count = ?, updated_at = ?, last_firing_at = COALESCE(?, last_firing_at),
		  resolve_due_at = ?, resolved_at = ?, card_version = card_version + 1
		WHERE id = ?`,
		title, severity, status, count, firing, now.Format(timestampFormat),
		timeText(lastFiring), due, resolved, incidentID)
	return err
}

func severityRank(value string) int {
	switch strings.ToLower(value) {
	case "critical", "p0", "sev0":
		return 5
	case "high", "error", "p1", "sev1":
		return 4
	case "warning", "warn", "medium", "p2", "sev2":
		return 3
	case "low", "info", "p3", "sev3":
		return 2
	default:
		return 1
	}
}

const incidentColumns = `
	id, route, repository, correlation_key, source_incident_id, title, severity,
	status, workflow, signal_count, firing_count, channel_id, channel_name, root_ts,
	coop_session_id, coop_fork_name, coop_revision, coop_event_sequence, active_turn_id,
	initial_turn_queued, card_version, card_rendered_version, last_error,
	created_at, updated_at, last_firing_at, resolve_due_at, resolved_at, closed_at,
	channel_state, channel_state_changed_at, channel_checked_at,
	work_kind, work_scope, origin_channel_id, origin_thread_ts`

func scanIncident(row interface{ Scan(...any) error }) (core.Incident, error) {
	var incident core.Incident
	var initial int
	var created, updated string
	var firing, due, resolved, closed, channelChanged, channelChecked sql.NullString
	err := row.Scan(
		&incident.ID, &incident.Route, &incident.Repository, &incident.CorrelationKey,
		&incident.SourceIncidentID, &incident.Title, &incident.Severity, &incident.Status,
		&incident.Workflow, &incident.SignalCount, &incident.FiringCount, &incident.ChannelID,
		&incident.ChannelName, &incident.RootTS, &incident.CoopSessionID, &incident.CoopForkName,
		&incident.CoopRevision, &incident.CoopEventSequence,
		&incident.ActiveTurnID, &initial, &incident.CardVersion,
		&incident.CardRenderedVersion, &incident.LastError, &created, &updated, &firing, &due,
		&resolved, &closed, &incident.ChannelState, &channelChanged, &channelChecked,
		&incident.WorkKind, &incident.WorkScope, &incident.OriginChannelID,
		&incident.OriginThreadTS,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return core.Incident{}, ErrNotFound
		}
		return core.Incident{}, err
	}
	incident.InitialTurnQueued = initial != 0
	incident.CreatedAt = parseTime(created)
	incident.UpdatedAt = parseTime(updated)
	incident.LastFiringAt = scanTime(firing)
	incident.ResolveDueAt = scanTime(due)
	incident.ResolvedAt = scanTime(resolved)
	incident.ClosedAt = scanTime(closed)
	incident.ChannelStateChangedAt = scanTime(channelChanged)
	incident.ChannelCheckedAt = scanTime(channelChecked)
	return incident, nil
}

func (s *Store) GetIncident(ctx context.Context, id string) (core.Incident, error) {
	return scanIncident(s.db.QueryRowContext(ctx, `SELECT `+incidentColumns+` FROM incidents WHERE id = ?`, id))
}

func (s *Store) FindIncidentByChannel(ctx context.Context, channelID string) (core.Incident, error) {
	return scanIncident(s.db.QueryRowContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents WHERE channel_id = ? AND work_scope = 'room' AND status != 'closed'
		ORDER BY updated_at DESC LIMIT 1`, channelID))
}

func (s *Store) FindLatestIncidentByChannel(
	ctx context.Context,
	channelID string,
) (core.Incident, error) {
	return scanIncident(s.db.QueryRowContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents WHERE channel_id = ? AND work_scope = 'room'
		ORDER BY updated_at DESC LIMIT 1`, channelID))
}

func (s *Store) IsIncidentChannel(ctx context.Context, channelID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*) FROM incidents
		WHERE channel_id = ? AND work_scope = 'room'`,
		channelID,
	).Scan(&count)
	return count > 0, err
}

func (s *Store) FindIncidentForConversation(
	ctx context.Context,
	channelID string,
	threadTS string,
) (core.Incident, error) {
	return scanIncident(s.db.QueryRowContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents
		WHERE status != 'closed' AND (
		  (work_scope = 'room' AND channel_id = ?)
		  OR
		  (work_scope = 'thread' AND origin_channel_id = ? AND origin_thread_ts = ?)
		)
		ORDER BY updated_at DESC LIMIT 1`, channelID, channelID, threadTS))
}

func (s *Store) ListIncidents(ctx context.Context, limit int) ([]core.Incident, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Incident
	for rows.Next() {
		incident, err := scanIncident(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, incident)
	}
	return result, rows.Err()
}

func (s *Store) ListIncidentPage(
	ctx context.Context,
	openOnly bool,
	limit int,
	offset int,
) ([]core.Incident, int, error) {
	if limit <= 0 || limit > 100 || offset < 0 {
		return nil, 0, errors.New("incident page requires limit 1..100 and non-negative offset")
	}
	where := ""
	if openOnly {
		where = " WHERE status != 'closed'"
	}
	var total int
	if err := s.db.QueryRowContext(
		ctx, `SELECT COUNT(*) FROM incidents`+where,
	).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.db.QueryContext(
		ctx,
		`SELECT `+incidentColumns+` FROM incidents`+where+
			` ORDER BY created_at DESC LIMIT ? OFFSET ?`,
		limit,
		offset,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	result := make([]core.Incident, 0, min(limit, total))
	for rows.Next() {
		incident, err := scanIncident(rows)
		if err != nil {
			return nil, 0, err
		}
		result = append(result, incident)
	}
	return result, total, rows.Err()
}

func (s *Store) ListSignals(ctx context.Context, incidentID string) ([]core.Signal, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT route, source_id, source_incident_id, event_id, repository, correlation_key,
		  status, title, severity, summary, source_url, labels_json, annotations_json,
		  starts_at, ends_at, received_at
		FROM signals WHERE incident_id = ? ORDER BY received_at`, incidentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Signal
	for rows.Next() {
		var signal core.Signal
		var labels, annotations []byte
		var starts, ends sql.NullString
		var received string
		if err := rows.Scan(&signal.Route, &signal.SourceID, &signal.SourceIncidentID,
			&signal.EventID, &signal.Repository, &signal.CorrelationKey, &signal.Status,
			&signal.Title, &signal.Severity, &signal.Summary, &signal.SourceURL, &labels,
			&annotations, &starts, &ends, &received); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(labels, &signal.Labels); err != nil {
			return nil, fmt.Errorf("decode signal labels: %w", err)
		}
		if err := json.Unmarshal(annotations, &signal.Annotations); err != nil {
			return nil, fmt.Errorf("decode signal annotations: %w", err)
		}
		signal.StartsAt = scanTime(starts)
		signal.EndsAt = scanTime(ends)
		signal.ReceivedAt = parseTime(received)
		result = append(result, signal)
	}
	return result, rows.Err()
}

func (s *Store) ListChannelWork(ctx context.Context, limit int) ([]core.Incident, error) {
	return s.listIncidentsWhere(ctx, `channel_id = '' AND workflow = 'provisioning_channel'`, limit)
}

func (s *Store) ListRootWork(ctx context.Context, limit int) ([]core.Incident, error) {
	return s.listIncidentsWhere(ctx, `channel_id != '' AND channel_state = 'active'
		AND root_ts = '' AND workflow = 'provisioning_channel'`, limit)
}

func (s *Store) ListSessionWork(ctx context.Context, limit int) ([]core.Incident, error) {
	return s.listIncidentsWhere(ctx, `root_ts != '' AND channel_state = 'active'
		AND coop_session_id = '' AND workflow IN ('provisioning_session', 'holding')`, limit)
}

func (s *Store) ListBoundIncidents(ctx context.Context, limit int) ([]core.Incident, error) {
	return s.listIncidentsWhere(ctx, `coop_session_id != '' AND status != 'closed'`, limit)
}

func (s *Store) ListDirtyCards(ctx context.Context, limit int) ([]core.Incident, error) {
	return s.listIncidentsWhere(ctx, `root_ts != '' AND channel_state = 'active'
		AND card_version > card_rendered_version`, limit)
}

func (s *Store) listIncidentsWhere(ctx context.Context, where string, limit int) ([]core.Incident, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents WHERE `+where+` ORDER BY created_at LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Incident
	for rows.Next() {
		item, err := scanIncident(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) SetChannel(ctx context.Context, id, channelID, channelName string) error {
	now := s.nowText()
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET channel_id = ?, channel_name = ?, workflow = 'provisioning_channel',
		  channel_state = 'active', channel_state_changed_at = ?, channel_checked_at = ?,
		  updated_at = ?, card_version = card_version + 1, last_error = ''
		WHERE id = ? AND channel_id = ''`, channelID, channelName, now, now, now, id)
	return expectOne(result, err, "bind incident channel")
}

func (s *Store) BindThreadWork(ctx context.Context, id string) error {
	now := s.nowText()
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET channel_id = origin_channel_id, workflow = 'provisioning_channel',
		  channel_state = 'active', channel_state_changed_at = ?, channel_checked_at = ?,
		  updated_at = ?, card_version = card_version + 1, last_error = ''
		WHERE id = ? AND work_scope = 'thread' AND channel_id = ''
		  AND origin_channel_id != '' AND origin_thread_ts != ''`,
		now, now, now, id)
	return expectOne(result, err, "bind thread work conversation")
}

func (s *Store) ListChannelReconciliationWork(
	ctx context.Context,
	limit int,
) ([]core.Incident, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents
		WHERE channel_id != '' AND status != 'closed'
		  AND channel_state IN ('active', 'archived', 'unreachable')
		ORDER BY COALESCE(channel_checked_at, created_at), created_at
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Incident
	for rows.Next() {
		incident, err := scanIncident(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, incident)
	}
	return result, rows.Err()
}

func (s *Store) SetIncidentChannelState(
	ctx context.Context,
	channelID string,
	state core.ChannelState,
	observedAt time.Time,
) ([]core.Incident, error) {
	if channelID == "" {
		return nil, errors.New("incident channel ID is required")
	}
	switch state {
	case core.ChannelActive, core.ChannelArchived, core.ChannelDeleted, core.ChannelUnreachable:
	default:
		return nil, fmt.Errorf("invalid incident channel state %q", state)
	}
	if observedAt.IsZero() {
		observedAt = s.now().UTC()
	}
	observed := observedAt.UTC().Format(timestampFormat)
	roomDetail := channelStateError(state, false)
	threadDetail := channelStateError(state, true)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE incidents
		SET channel_state_changed_at = CASE
		      WHEN channel_state != ? THEN ? ELSE channel_state_changed_at END,
		  channel_checked_at = ?,
		  workflow = CASE
		    WHEN status = 'closed' THEN workflow
		    WHEN ? != 'active' THEN 'blocked'
		    WHEN channel_state != 'active' THEN CASE
		      WHEN coop_session_id = '' AND root_ts = '' THEN 'provisioning_channel'
		      WHEN coop_session_id = '' THEN 'provisioning_session'
		      WHEN active_turn_id != '' THEN 'investigating'
		      ELSE 'parked'
		    END
		    ELSE workflow
		  END,
		  last_error = CASE
		    WHEN status = 'closed' THEN last_error
		    WHEN ? != 'active' AND work_scope = 'thread' THEN ?
		    WHEN ? != 'active' THEN ?
		    WHEN channel_state != 'active' AND (
		      last_error LIKE 'Slack incident room%'
		      OR last_error LIKE 'The Slack channel containing this task thread%'
		    ) THEN ''
		    ELSE last_error
		  END,
		  card_version = card_version + CASE WHEN channel_state != ? THEN 1 ELSE 0 END,
		  updated_at = CASE WHEN channel_state != ? THEN ? ELSE updated_at END,
		  channel_state = ?
		WHERE channel_id = ?
		  AND (channel_state_changed_at IS NULL OR channel_state_changed_at <= ?)
		  AND NOT (channel_state = 'deleted' AND ? != 'deleted')`,
		state, observed, observed,
		state, state, threadDetail, state, roomDetail,
		state, state, observed, state, channelID, observed, state,
	)
	if err != nil {
		return nil, err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return nil, err
	}
	if count == 0 {
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, nil
	}
	rows, err := tx.QueryContext(
		ctx, `SELECT `+incidentColumns+` FROM incidents WHERE channel_id = ? ORDER BY created_at`,
		channelID,
	)
	if err != nil {
		return nil, err
	}
	var incidents []core.Incident
	for rows.Next() {
		incident, scanErr := scanIncident(rows)
		if scanErr != nil {
			rows.Close()
			return nil, scanErr
		}
		incidents = append(incidents, incident)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return incidents, nil
}

func channelStateError(state core.ChannelState, threadScoped bool) string {
	if threadScoped {
		switch state {
		case core.ChannelArchived:
			return "The Slack channel containing this task thread was archived. The Coop session and isolated fork are preserved; unarchive the channel to continue."
		case core.ChannelDeleted:
			return "The Slack channel containing this task thread was deleted. The Coop session and isolated fork are preserved, but this thread can no longer continue."
		case core.ChannelUnreachable:
			return "The Slack channel containing this task thread is unavailable to Responder. Restore channel access to continue; the Coop session and isolated fork are preserved."
		default:
			return ""
		}
	}
	switch state {
	case core.ChannelArchived:
		return "Slack incident room was archived. The Coop session and isolated fork are preserved; unarchive the room to continue."
	case core.ChannelDeleted:
		return "Slack incident room was deleted. The Coop session and isolated fork are preserved; create or rebind a room before continuing."
	case core.ChannelUnreachable:
		return "Slack incident room is unavailable to Responder. The room may be inaccessible or deleted; restore access or rebind a room before continuing."
	default:
		return ""
	}
}

func (s *Store) CreateManualIncident(
	ctx context.Context,
	repository, sourceID, title, summary, userID string,
	originChannelID, originThreadTS string,
	maxOpenIncidents int,
) (core.Incident, bool, error) {
	return s.createManualWork(
		ctx, repository, sourceID, title, summary, userID,
		originChannelID, originThreadTS, maxOpenIncidents, false,
	)
}

func (s *Store) CreateEngineeringTask(
	ctx context.Context,
	repository, sourceID, title, summary, userID string,
	originChannelID, originThreadTS string,
	maxOpenIncidents int,
) (core.Incident, bool, error) {
	return s.createManualWork(
		ctx, repository, sourceID, title, summary, userID,
		originChannelID, originThreadTS, maxOpenIncidents, true,
	)
}

func (s *Store) createManualWork(
	ctx context.Context,
	repository, sourceID, title, summary, userID string,
	originChannelID, originThreadTS string,
	maxOpenIncidents int,
	engineeringTask bool,
) (core.Incident, bool, error) {
	workKind := "incident"
	workScope := "room"
	if engineeringTask {
		sourceID = "task:" + sourceID
		workKind = "engineering_task"
		workScope = "thread"
	}
	id, err := core.NewID("inc")
	if err != nil {
		return core.Incident{}, false, err
	}
	now := s.now().UTC()
	correlation := "manual:" + sourceID
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.Incident{}, false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO incidents
		  (id, route, repository, correlation_key, source_incident_id, title, severity,
		   status, workflow, signal_count, firing_count, work_kind, work_scope,
		   origin_channel_id, origin_thread_ts, created_at, updated_at, last_firing_at)
		VALUES (?, 'manual', ?, ?, ?, ?, '', 'active', 'provisioning_channel', 1, 1,
		  ?, ?, ?, ?, ?, ?, ?)`,
		id, repository, correlation, sourceID, title, workKind, workScope,
		originChannelID, originThreadTS,
		now.Format(timestampFormat), now.Format(timestampFormat), now.Format(timestampFormat))
	if err != nil {
		return core.Incident{}, false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return core.Incident{}, false, err
	}
	if rows == 1 {
		if err := enforceOpenIncidentCapacity(ctx, tx, maxOpenIncidents); err != nil {
			return core.Incident{}, false, err
		}
		labels, _ := json.Marshal(map[string]string{
			"slack_user":           userID,
			"slack_origin_channel": originChannelID,
			"slack_origin_thread":  originThreadTS,
			"work_kind":            workKind,
		})
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO signals
			  (route, source_id, incident_id, source_incident_id, event_id, repository,
			   correlation_key, status, title, summary, labels_json, annotations_json, received_at, updated_at)
			VALUES ('manual', ?, ?, ?, ?, ?, ?, 'firing', ?, ?, ?, '{}', ?, ?)`,
			sourceID, id, sourceID, sourceID, repository, correlation, title, summary, labels,
			now.Format(timestampFormat), now.Format(timestampFormat)); err != nil {
			return core.Incident{}, false, err
		}
		if err := tx.Commit(); err != nil {
			return core.Incident{}, false, err
		}
		incident, err := s.GetIncident(ctx, id)
		return incident, true, err
	}
	if err := tx.Rollback(); err != nil {
		return core.Incident{}, false, err
	}
	incident, err := scanIncident(s.db.QueryRowContext(ctx, `SELECT `+incidentColumns+`
		FROM incidents WHERE route = 'manual' AND correlation_key = ?`, correlation))
	return incident, false, err
}

func (s *Store) SetCoopSession(ctx context.Context, id, sessionID, forkName string, revision int64) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET coop_session_id = ?, coop_fork_name = ?, coop_revision = ?, workflow = 'investigating',
		  updated_at = ?, card_version = card_version + 1, last_error = ''
		WHERE id = ? AND root_ts != '' AND coop_session_id = ''`,
		sessionID, forkName, revision, s.nowText(), id)
	return expectOne(result, err, "bind Coop session")
}

func (s *Store) UpdateCoopState(ctx context.Context, id string, revision, cursor int64, activeTurnID string, workflow core.WorkflowState) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET card_version = card_version + CASE
		    WHEN coop_revision != ? OR coop_event_sequence != ? OR active_turn_id != ? OR workflow != ?
		    THEN 1 ELSE 0 END,
		  coop_revision = ?, coop_event_sequence = ?, active_turn_id = ?,
		  workflow = ?, updated_at = ?,
		  last_error = CASE WHEN ? != '' THEN '' ELSE last_error END
		WHERE id = ?`,
		revision, cursor, activeTurnID, workflow,
		revision, cursor, activeTurnID, workflow, s.nowText(), activeTurnID, id)
	return err
}

func (s *Store) SetIncidentError(ctx context.Context, id string, workflow core.WorkflowState, detail string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET workflow = ?, last_error = ?, updated_at = ?,
		  card_version = card_version + 1 WHERE id = ?`,
		workflow, boundedError(detail), s.nowText(), id)
	return err
}

func (s *Store) CountOpenSessions(ctx context.Context) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*) FROM incidents
		WHERE coop_session_id != '' AND workflow != 'closed'`).Scan(&count)
	return count, err
}

func (s *Store) ResolveDueIncidents(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET status = 'resolved', resolved_at = ?, resolve_due_at = NULL,
		  updated_at = ?, card_version = card_version + 1
		WHERE status = 'monitoring' AND firing_count = 0
		  AND resolve_due_at IS NOT NULL AND resolve_due_at <= ?`,
		now.UTC().Format(timestampFormat), now.UTC().Format(timestampFormat), now.UTC().Format(timestampFormat))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) CloseIncident(ctx context.Context, id string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET status = 'closed', workflow = 'closed', closed_at = ?,
		  updated_at = ?, card_version = card_version + 1, active_turn_id = ''
		WHERE id = ? AND status != 'closed'`, s.nowText(), s.nowText(), id)
	return expectOne(result, err, "close incident")
}

func (s *Store) MarkInitialTurnQueued(ctx context.Context, id string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET initial_turn_queued = 1, updated_at = ?
		WHERE id = ? AND initial_turn_queued = 0`, s.nowText(), id)
	return expectOne(result, err, "mark initial turn queued")
}

func (s *Store) AdmitSlackInput(ctx context.Context, input core.SlackInput) (bool, error) {
	return admitSlackInput(ctx, s.db, input, s.nowText())
}

func admitSlackInput(
	ctx context.Context,
	executor interface {
		ExecContext(context.Context, string, ...any) (sql.Result, error)
	},
	input core.SlackInput,
	now string,
) (bool, error) {
	if input.ID == "" {
		var err error
		input.ID, err = core.NewID("slack")
		if err != nil {
			return false, err
		}
	}
	attachments, err := json.Marshal(input.Attachments)
	if err != nil {
		return false, fmt.Errorf("encode Slack input attachments: %w", err)
	}
	received := input.ReceivedAt
	if received.IsZero() {
		received = parseTime(now)
	}
	result, err := executor.ExecContext(ctx, `
		INSERT OR IGNORE INTO slack_inputs
		  (id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
		   user_id, text, action_id, action_value, attachments_json, state, next_attempt_at,
		   received_at, updated_at)
		SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?
		WHERE ? = 0 OR NOT EXISTS (
		  SELECT 1
		  FROM slack_inputs AS existing
		  -- Slack can deliver one visible message through multiple event kinds.
		  -- Its content identity is independent of the subscription transport.
		  WHERE existing.team_id = ?
		    AND existing.channel_id = ?
		    AND existing.message_ts = ?
		    AND existing.user_id = ?
		    AND existing.text = ?
		    AND existing.attachments_json = ?
		)`,
		input.ID, input.EnvelopeID, input.EventID, input.Kind, input.TeamID, input.ChannelID,
		input.ThreadTS, input.MessageTS, input.UserID, input.Text, input.ActionID,
		input.ActionValue, attachments, now, received.UTC().Format(timestampFormat), now,
		boolInt(deduplicateSlackMessageInput(input)), input.TeamID, input.ChannelID,
		input.MessageTS, input.UserID, input.Text, attachments)
	if err != nil {
		return false, fmt.Errorf("admit Slack input: %w", err)
	}
	rows, err := result.RowsAffected()
	return rows == 1, err
}

func deduplicateSlackMessageInput(input core.SlackInput) bool {
	if input.ChannelID == "" || input.MessageTS == "" {
		return false
	}
	// Explicit CLI replays intentionally process the same saved message again.
	// cloneSlackReplay marks that transport so live idempotency remains strict.
	if strings.HasPrefix(input.EnvelopeID, "replay:") ||
		strings.HasPrefix(input.EnvelopeID, "replay-private:") ||
		strings.HasPrefix(input.EnvelopeID, "replay-public:") {
		return false
	}
	switch input.Kind {
	case "message", "mention", "direct", "bot_message":
		return true
	default:
		return false
	}
}

func (s *Store) LeaseSlackInput(ctx context.Context) (core.SlackInput, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.SlackInput{}, err
	}
	defer tx.Rollback()
	now := s.nowText()
	input, err := scanSlackInput(tx.QueryRowContext(ctx, `
			SELECT candidate.id, candidate.envelope_id, candidate.event_id, candidate.kind,
			  candidate.team_id, candidate.channel_id, candidate.thread_ts, candidate.message_ts,
			  candidate.user_id, candidate.text, candidate.action_id, candidate.action_value,
			  candidate.attachments_json, candidate.frozen_json, candidate.state, candidate.attempts,
			  candidate.failure_count, candidate.received_at
			FROM slack_inputs AS candidate
			WHERE candidate.state IN ('pending', 'retry')
			  AND julianday(candidate.next_attempt_at) <= julianday(?)
		  AND (
		    candidate.kind IN ('slash', 'action') OR
			    NOT EXISTS (
			      SELECT 1 FROM slack_inputs AS earlier
			      WHERE earlier.channel_id = candidate.channel_id
			        AND earlier.state = 'processing'
		        AND (
		          (
		            earlier.message_ts != '' AND candidate.message_ts != '' AND (
		              earlier.message_ts < candidate.message_ts OR
		              (
		                earlier.message_ts = candidate.message_ts AND (
			                  julianday(earlier.received_at) < julianday(candidate.received_at) OR
			                  (
			                    julianday(earlier.received_at) = julianday(candidate.received_at)
			                    AND earlier.id < candidate.id
			                  )
		                )
		              )
		            )
		          ) OR (
		            (earlier.message_ts = '' OR candidate.message_ts = '') AND (
			              julianday(earlier.received_at) < julianday(candidate.received_at) OR
			              (
			                julianday(earlier.received_at) = julianday(candidate.received_at)
			                AND earlier.id < candidate.id
			              )
		            )
		          )
		        )
		    )
		  )
			ORDER BY
			  CASE WHEN candidate.kind IN ('slash', 'action') THEN 0 ELSE 1 END,
			  CASE
			    WHEN candidate.message_ts = '' THEN
			      (julianday(candidate.received_at) - 2440587.5) * 86400.0
			    ELSE CAST(candidate.message_ts AS REAL)
			  END,
			  julianday(candidate.received_at),
			  candidate.id
		LIMIT 1`, now))
	if err != nil {
		return core.SlackInput{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'processing', attempts = attempts + 1, updated_at = ?
		WHERE id = ? AND state IN ('pending', 'retry')`, now, input.ID)
	if err := expectOne(result, err, "lease Slack input"); err != nil {
		return core.SlackInput{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.SlackInput{}, err
	}
	input.State = "processing"
	input.Attempts++
	return input, nil
}

// RecoverStaleSlackInputs releases inputs whose worker deadline elapsed before
// it could record a retry. Without this, one interrupted input can preserve
// per-channel ordering by blocking every later message indefinitely.
func (s *Store) RecoverStaleSlackInputs(
	ctx context.Context,
	staleBefore time.Time,
) (int64, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_inputs
		SET state = 'retry', next_attempt_at = ?,
		    last_error = CASE WHEN last_error = ''
		      THEN 'Slack input worker stopped before completion'
		      ELSE last_error END,
		    updated_at = ?
		WHERE state = 'processing' AND julianday(updated_at) <= julianday(?)`,
		s.nowText(), s.nowText(), staleBefore.UTC().Format(timestampFormat),
	)
	if err != nil {
		return 0, fmt.Errorf("recover stale Slack inputs: %w", err)
	}
	return result.RowsAffected()
}

func (s *Store) GetSlackInput(ctx context.Context, id string) (core.SlackInput, error) {
	return scanSlackInput(s.db.QueryRowContext(ctx, `
		SELECT id, envelope_id, event_id, kind, team_id, channel_id, thread_ts,
		  message_ts, user_id, text, action_id, action_value, attachments_json,
		  frozen_json, state, attempts, failure_count, received_at
		FROM slack_inputs WHERE id = ?`, id))
}

func (s *Store) GetSlackInputForMessage(
	ctx context.Context,
	channelID string,
	messageTS string,
) (core.SlackInput, error) {
	if channelID == "" || messageTS == "" {
		return core.SlackInput{}, ErrNotFound
	}
	return scanSlackInput(s.db.QueryRowContext(ctx, `
		SELECT id, envelope_id, event_id, kind, team_id, channel_id, thread_ts,
		  message_ts, user_id, text, action_id, action_value, attachments_json,
		  frozen_json, state, attempts, failure_count, received_at
		FROM slack_inputs
		WHERE channel_id = ? AND message_ts = ?
		  AND kind IN ('message', 'bot_message', 'mention', 'direct', 'shortcut')
		ORDER BY CASE WHEN event_id LIKE 'replay%' THEN 1 ELSE 0 END,
		  received_at DESC, id DESC
		LIMIT 1`, channelID, messageTS))
}

func (s *Store) ListLatestSlackInputsByKind(
	ctx context.Context,
	kind string,
	since time.Time,
	limit int,
) ([]core.SlackInput, error) {
	if kind == "" || limit < 1 || limit > 1000 {
		return nil, errors.New("Slack input kind and limit between 1 and 1000 are required")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT input.id, input.envelope_id, input.event_id, input.kind, input.team_id,
		  input.channel_id, input.thread_ts, input.message_ts, input.user_id, input.text,
		  input.action_id, input.action_value, input.attachments_json, input.frozen_json,
		  input.state, input.attempts, input.failure_count, input.received_at
		FROM slack_inputs AS input
		WHERE input.kind = ? AND input.message_ts != ''
		  AND julianday(input.received_at) >= julianday(?)
		  AND NOT EXISTS (
		    SELECT 1 FROM slack_inputs AS newer
		    WHERE newer.kind = input.kind
		      AND newer.channel_id = input.channel_id
		      AND newer.message_ts = input.message_ts
		      AND (
		        julianday(newer.received_at) > julianday(input.received_at) OR
		        (newer.received_at = input.received_at AND newer.id > input.id)
		      )
		  )
		ORDER BY julianday(input.received_at) DESC, input.id DESC
		LIMIT ?`, kind, since.UTC().Format(timestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.SlackInput, 0)
	for rows.Next() {
		input, scanErr := scanSlackInput(rows)
		if scanErr != nil {
			return nil, scanErr
		}
		result = append(result, input)
	}
	return result, rows.Err()
}

func (s *Store) ListRecentWatchMessages(
	ctx context.Context,
	channelID string,
	limit int,
) ([]core.SlackInput, error) {
	if channelID == "" || limit < 1 || limit > 100 {
		return nil, errors.New("recent Slack context requires a channel and limit between 1 and 100")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT input.id, input.envelope_id, input.event_id, input.kind, input.team_id,
		  input.channel_id, input.thread_ts, input.message_ts, input.user_id, input.text,
			  input.action_id, input.action_value, input.attachments_json, input.frozen_json, input.state,
			  input.attempts, input.failure_count, input.received_at
		FROM slack_inputs AS input
		WHERE input.channel_id = ?
		  AND input.message_ts != ''
		  AND input.kind IN (
		    'message', 'bot_message', 'mention', 'direct', 'shortcut',
		    'reaction_added', 'reaction_removed'
		  )
			  AND (
			    input.state IN ('pending', 'retry', 'processing', 'done') OR
		    EXISTS (
		      SELECT 1 FROM audit_events AS audit
		      WHERE audit.kind = 'slack.watch' AND audit.object_id = input.id
		    )
		  )
		ORDER BY input.message_ts DESC, input.received_at DESC, input.id DESC
		LIMIT ?`,
		channelID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.SlackInput, 0, limit)
	for rows.Next() {
		input, err := scanSlackInput(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, input)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	slices.Reverse(result)
	return result, nil
}

func (s *Store) LatestSlackConversationAt(
	ctx context.Context,
	channelID string,
) (time.Time, error) {
	if channelID == "" {
		return time.Time{}, errors.New("Slack conversation channel is required")
	}
	var latest sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT MAX(received_at)
		FROM slack_inputs
		WHERE channel_id = ?
		  AND kind IN ('message', 'bot_message', 'mention', 'direct', 'shortcut')
		  AND state IN ('pending', 'retry', 'processing')`,
		channelID,
	).Scan(&latest)
	if err != nil {
		return time.Time{}, err
	}
	if !latest.Valid || latest.String == "" {
		return time.Time{}, ErrNotFound
	}
	return parseTime(latest.String), nil
}

func (s *Store) HasNewerWatchDecision(
	ctx context.Context,
	channelID string,
	messageTS string,
) (bool, error) {
	if channelID == "" || messageTS == "" {
		return false, nil
	}
	var exists bool
	err := s.db.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1
		  FROM slack_inputs AS input
		  JOIN audit_events AS audit
		    ON audit.kind = 'slack.watch' AND audit.object_id = input.id
		  WHERE input.channel_id = ?
			    AND input.kind IN ('message', 'bot_message', 'mention', 'direct', 'shortcut')
		    AND input.message_ts > ?
		)`,
		channelID, messageTS,
	).Scan(&exists)
	return exists, err
}

func (s *Store) HasRecentWatchReply(
	ctx context.Context,
	channelID string,
	threadTS string,
	beforeMessageTS string,
	since time.Time,
) (bool, error) {
	if channelID == "" || beforeMessageTS == "" {
		return false, nil
	}
	sinceText := ""
	if !since.IsZero() {
		sinceText = since.UTC().Format(timestampFormat)
	}
	var exists bool
	err := s.db.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1
		  FROM slack_deliveries AS delivery
		  JOIN agent_runs AS run
		    ON run.source_kind = 'watch'
		   AND delivery.id = 'watch_reply_' || run.source_id
		  WHERE delivery.operation = 'post'
		    AND delivery.state = 'sent'
		    AND delivery.channel_id = ?
		    AND (
		      delivery.thread_ts = ?
		      OR (
		        ? != ''
		        AND delivery.thread_ts = ''
		        AND delivery.message_ts = ?
		      )
		    )
		    AND delivery.message_ts != ''
		    AND CAST(delivery.message_ts AS REAL) < CAST(? AS REAL)
		    AND (? = '' OR delivery.updated_at >= ?)
		)`,
		channelID,
		threadTS,
		threadTS,
		threadTS,
		beforeMessageTS,
		sinceText,
		sinceText,
	).Scan(&exists)
	return exists, err
}

func scanSlackInput(row interface{ Scan(...any) error }) (core.SlackInput, error) {
	var input core.SlackInput
	var received string
	var attachments []byte
	err := row.Scan(
		&input.ID, &input.EnvelopeID, &input.EventID, &input.Kind, &input.TeamID,
		&input.ChannelID, &input.ThreadTS, &input.MessageTS, &input.UserID, &input.Text,
		&input.ActionID, &input.ActionValue, &attachments, &input.Frozen, &input.State, &input.Attempts,
		&input.Failures, &received,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.SlackInput{}, ErrNotFound
	}
	if err != nil {
		return core.SlackInput{}, err
	}
	if len(attachments) > 0 {
		if err := json.Unmarshal(attachments, &input.Attachments); err != nil {
			return core.SlackInput{}, fmt.Errorf("decode Slack input attachments: %w", err)
		}
	}
	input.ReceivedAt = parseTime(received)
	return input, nil
}

func (s *Store) FinishSlackInput(ctx context.Context, id string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_inputs SET state = 'done', last_error = '', updated_at = ?
		WHERE id = ? AND state = 'processing'`, s.nowText(), id)
	return expectOne(result, err, "finish Slack input")
}

func (s *Store) RetrySlackInput(ctx context.Context, id, detail string, next time.Time, terminal bool) error {
	state := "retry"
	if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_inputs SET state = ?, last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'processing'`,
		state, boundedError(detail), next.UTC().Format(timestampFormat), s.nowText(), id)
	return expectOne(result, err, "retry Slack input")
}

func (s *Store) RetrySlackInputFailure(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	terminal bool,
) error {
	state := "retry"
	if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_inputs
		SET state = ?, failure_count = failure_count + 1, last_error = ?,
		    next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'processing'`,
		state, boundedError(detail), next.UTC().Format(timestampFormat), s.nowText(), id)
	return expectOne(result, err, "retry failed Slack input")
}

func (s *Store) FreezeSlackInput(ctx context.Context, id string, frozen []byte) ([]byte, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var existing []byte
	if err := tx.QueryRowContext(ctx, `SELECT frozen_json FROM slack_inputs WHERE id = ?`, id).Scan(&existing); err != nil {
		return nil, err
	}
	if len(existing) == 0 {
		if len(frozen) == 0 {
			return nil, errors.New("frozen Slack action is empty")
		}
		if _, err := tx.ExecContext(ctx, `UPDATE slack_inputs SET frozen_json = ?, updated_at = ? WHERE id = ?`,
			frozen, s.nowText(), id); err != nil {
			return nil, err
		}
		existing = append([]byte(nil), frozen...)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return existing, nil
}

func (s *Store) SetSlackInputFrozen(ctx context.Context, id string, frozen []byte) error {
	if len(frozen) == 0 {
		return errors.New("Slack input state is empty")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_inputs SET frozen_json = ?, updated_at = ?
		WHERE id = ? AND state = 'processing'`, frozen, s.nowText(), id)
	return expectOne(result, err, "set Slack input state")
}

func (s *Store) Audit(ctx context.Context, event core.AuditEvent) error {
	if event.ID == "" {
		var err error
		event.ID, err = core.NewID("audit")
		if err != nil {
			return err
		}
	}
	if event.CreatedAt.IsZero() {
		event.CreatedAt = s.now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO audit_events
		  (id, incident_id, kind, actor_id, object_id, outcome, detail, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ID, event.IncidentID, event.Kind, event.ActorID, event.ObjectID,
		event.Outcome, boundedError(event.Detail), event.CreatedAt.Format(timestampFormat))
	return err
}

func FileOwner(path string) (uint32, os.FileMode, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, 0, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, errors.New("file ownership is unavailable")
	}
	return stat.Uid, info.Mode().Perm(), nil
}

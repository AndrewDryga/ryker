package memorystore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func (r *Repository) UpsertMemoryEntry(
	ctx context.Context,
	entry core.MemoryEntry,
	maxTotal int,
	maxPerScope int,
) (core.MemoryEntry, bool, error) {
	if err := validateMemoryEntry(entry); err != nil {
		return core.MemoryEntry{}, false, err
	}
	if maxTotal < 1 || maxPerScope < 1 || maxPerScope > maxTotal {
		return core.MemoryEntry{}, false, errors.New("memory entry limits are invalid")
	}
	valueJSON, err := json.Marshal(entry.Value)
	if err != nil {
		return core.MemoryEntry{}, false, err
	}
	digest := sha256.Sum256(valueJSON)
	entry.ValueHash = hex.EncodeToString(digest[:])
	now := r.now().UTC()
	if entry.ExpiresAt.IsZero() || !entry.ExpiresAt.After(now) {
		return core.MemoryEntry{}, false, errors.New("memory entry expiry must be in the future")
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return core.MemoryEntry{}, false, err
	}
	defer tx.Rollback()
	var existingID, createdAt, existingHash string
	err = tx.QueryRowContext(ctx, `
		SELECT id, created_at, value_hash
		FROM memory_entries
		WHERE scope_kind = ? AND scope_key = ? AND subject_key = ? AND predicate = ?`,
		entry.ScopeKind, entry.ScopeKey, entry.SubjectKey, entry.Predicate,
	).Scan(&existingID, &createdAt, &existingHash)
	replaced := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return core.MemoryEntry{}, false, err
	}
	if !replaced {
		var total, scoped int
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM memory_entries WHERE expires_at > ?`,
			now.Format(core.TimestampFormat),
		).Scan(&total); err != nil {
			return core.MemoryEntry{}, false, err
		}
		if total >= maxTotal {
			return core.MemoryEntry{}, false, fmt.Errorf(
				"memory capacity reached (%d active entries)", maxTotal,
			)
		}
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM memory_entries
			WHERE scope_kind = ? AND scope_key = ? AND expires_at > ?`,
			entry.ScopeKind, entry.ScopeKey, now.Format(core.TimestampFormat),
		).Scan(&scoped); err != nil {
			return core.MemoryEntry{}, false, err
		}
		if scoped >= maxPerScope {
			return core.MemoryEntry{}, false, fmt.Errorf(
				"memory capacity reached for %s scope %q (%d active entries)",
				entry.ScopeKind, entry.ScopeKey, maxPerScope,
			)
		}
		entry.ID, err = core.NewID("mem")
		if err != nil {
			return core.MemoryEntry{}, false, err
		}
		entry.CreatedAt = now
	} else {
		entry.ID = existingID
		entry.CreatedAt = sqlutil.ParseTime(createdAt)
	}
	entry.UpdatedAt = now
	entry.LastReviewedAt = now
	_, err = tx.ExecContext(ctx, `
		INSERT INTO memory_entries (
		  id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
		  source_ref, source_revision, actor_id, visibility_kind, visibility_id,
		  expires_at, last_reviewed_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(scope_kind, scope_key, subject_key, predicate) DO UPDATE SET
		  value_json = excluded.value_json,
		  value_hash = excluded.value_hash,
		  source_ref = excluded.source_ref,
		  source_revision = excluded.source_revision,
		  actor_id = excluded.actor_id,
		  visibility_kind = excluded.visibility_kind,
		  visibility_id = excluded.visibility_id,
		  expires_at = excluded.expires_at,
		  last_recalled_at = CASE
		    WHEN memory_entries.value_hash = excluded.value_hash
		    THEN memory_entries.last_recalled_at ELSE NULL END,
		  recall_count = CASE
		    WHEN memory_entries.value_hash = excluded.value_hash
		    THEN memory_entries.recall_count ELSE 0 END,
		  last_reviewed_at = excluded.updated_at,
		  updated_at = excluded.updated_at`,
		entry.ID, entry.ScopeKind, entry.ScopeKey, entry.SubjectKey, entry.Predicate,
		string(valueJSON), entry.ValueHash, entry.SourceRef, entry.SourceRevision,
		entry.ActorID, entry.VisibilityKind, entry.VisibilityID,
		entry.ExpiresAt.UTC().Format(core.TimestampFormat),
		entry.LastReviewedAt.UTC().Format(core.TimestampFormat),
		entry.CreatedAt.UTC().Format(core.TimestampFormat), entry.UpdatedAt.Format(core.TimestampFormat),
	)
	if err != nil {
		return core.MemoryEntry{}, false, err
	}
	if replaced && existingHash != entry.ValueHash {
		supersessionID, idErr := core.NewID("memsup")
		if idErr != nil {
			return core.MemoryEntry{}, false, idErr
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO memory_supersessions (
			  id, entry_id, previous_value_hash, replacement_value_hash, reason, created_at
			) VALUES (?, ?, ?, ?, 'operator replacement', ?)`,
			supersessionID, entry.ID, existingHash, entry.ValueHash, r.nowText(),
		); err != nil {
			return core.MemoryEntry{}, false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return core.MemoryEntry{}, false, err
	}
	return entry, replaced, nil
}

func validateMemoryEntry(entry core.MemoryEntry) error {
	switch entry.ScopeKind {
	case "workspace", "channel", "repository":
	default:
		return fmt.Errorf("memory scope %q is invalid", entry.ScopeKind)
	}
	switch entry.Predicate {
	case "alias_of", "repository_for_channel", "evidence_route",
		"entity_relationship_correction", "guidance":
	default:
		return fmt.Errorf("memory predicate %q is invalid", entry.Predicate)
	}
	// The last gate before the row exists, and the only one the dashboard's
	// feedback-to-guidance path passes through. The reason names the way out,
	// because a model that reads it has to be able to fix the offer.
	if core.IsPermanentExpiry(entry.ExpiresAt) && !core.PredicateMayBePermanent(entry.Predicate) {
		return fmt.Errorf(
			"memory predicate %q cannot be permanent because it describes a system that can "+
				"change without telling Responder; give it 7d, 30d, 90d, or 365d, or offer it "+
				"as guidance if it is advice rather than a fact",
			entry.Predicate,
		)
	}
	switch entry.VisibilityKind {
	case "workspace", "channel", "operator":
	default:
		return fmt.Errorf("memory visibility %q is invalid", entry.VisibilityKind)
	}
	for name, value := range map[string]string{
		"scope key": entry.ScopeKey, "subject": entry.SubjectKey, "value": entry.Value,
		"source reference": entry.SourceRef, "actor": entry.ActorID,
		"visibility ID": entry.VisibilityID,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("memory %s is required", name)
		}
	}
	if len(entry.ScopeKey) > 200 || len(entry.SubjectKey) > 200 ||
		len(entry.Value) > 1000 || len(entry.SourceRef) > 200 ||
		len(entry.SourceRevision) > 200 || len(entry.ActorID) > 64 ||
		len(entry.VisibilityID) > 200 {
		return errors.New("memory entry contains an oversized field")
	}
	return nil
}

func (r *Repository) GetMemoryEntry(ctx context.Context, id string) (core.MemoryEntry, error) {
	row := r.db.QueryRowContext(ctx, memorySelect+` WHERE id = ?`, id)
	return scanMemoryEntry(row)
}

func (r *Repository) ListMemoryForHome(
	ctx context.Context,
	workspaceID string,
	operatorID string,
	limit int,
) ([]core.MemoryEntry, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("home memory limit must be between 1 and 100")
	}
	rows, err := r.db.QueryContext(ctx, memorySelect+`
		WHERE expires_at > ?
		  AND (
		    (visibility_kind = 'workspace' AND visibility_id = ?) OR
		    (visibility_kind = 'operator' AND visibility_id = ?)
		  )
		ORDER BY updated_at DESC
		LIMIT ?`,
		r.nowText(), workspaceID, operatorID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMemoryEntries(rows)
}

func (r *Repository) CountMemoryForHome(
	ctx context.Context,
	workspaceID string,
	operatorID string,
) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM memory_entries
		WHERE expires_at > ?
		  AND (
		    (visibility_kind = 'workspace' AND visibility_id = ?) OR
		    (visibility_kind = 'operator' AND visibility_id = ?)
		  )`,
		r.nowText(), workspaceID, operatorID,
	).Scan(&count)
	return count, err
}

func (r *Repository) ListMemoryForContext(
	ctx context.Context,
	workspaceID string,
	channelID string,
	repository string,
	operatorID string,
	limit int,
) ([]core.MemoryEntry, error) {
	if limit < 1 || limit > 200 {
		return nil, errors.New("memory context limit must be between 1 and 200")
	}
	rows, err := r.db.QueryContext(ctx, memorySelect+`
		WHERE expires_at > ?
		  AND (
		    (scope_kind = 'workspace' AND scope_key = ?) OR
		    (scope_kind = 'channel' AND scope_key = ?) OR
		    (scope_kind = 'repository' AND scope_key = ?)
		  )
		  AND (
		    (visibility_kind = 'workspace' AND visibility_id = ?) OR
		    (visibility_kind = 'channel' AND visibility_id = ?) OR
		    (visibility_kind = 'operator' AND visibility_id = ?)
		  )
		ORDER BY
		  CASE scope_kind WHEN 'channel' THEN 0 WHEN 'repository' THEN 1 ELSE 2 END,
		  updated_at DESC
		LIMIT ?`,
		r.nowText(), workspaceID, channelID, repository,
		workspaceID, channelID, operatorID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMemoryEntries(rows)
}

// ListMemoryEntriesBySourceRef finds every current row derived from one source.
// More than one can exist while a legacy guidance row is being migrated to its
// narrower scope and stable subject.
func (r *Repository) ListMemoryEntriesBySourceRef(
	ctx context.Context,
	sourceRef string,
) ([]core.MemoryEntry, error) {
	rows, err := r.db.QueryContext(ctx, memorySelect+`
		WHERE source_ref = ?
		ORDER BY id`, strings.TrimSpace(sourceRef))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMemoryEntries(rows)
}

// ListRepositoryContents reads the one durable sentence per repository that
// says which part of the product lives there, keyed by repository alias.
//
// It is fetched for the whole set at once because the repository map is
// rendered for the whole set at once: sixteen single-row lookups per turn to
// build one list is a cost with no reader.
func (r *Repository) ListRepositoryContents(ctx context.Context) (map[string]string, error) {
	rows, err := r.db.QueryContext(ctx, memorySelect+`
		WHERE scope_kind = 'repository'
		  AND subject_key = ?
		  AND predicate = 'guidance'
		  AND expires_at > ?`,
		core.RepositoryContentsSubject, r.nowText(),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	entries, err := scanMemoryEntries(rows)
	if err != nil {
		return nil, err
	}
	contents := make(map[string]string, len(entries))
	for _, entry := range entries {
		contents[entry.ScopeKey] = entry.Value
	}
	return contents, nil
}

func (r *Repository) GetChannelRepositoryBinding(
	ctx context.Context,
	workspaceID string,
	channelID string,
	operatorID string,
) (core.MemoryEntry, error) {
	row := r.db.QueryRowContext(ctx, memorySelect+`
		WHERE scope_kind = 'channel'
		  AND scope_key = ?
		  AND subject_key = ?
		  AND predicate = 'repository_for_channel'
		  AND expires_at > ?
		  AND (
		    (visibility_kind = 'workspace' AND visibility_id = ?) OR
		    (visibility_kind = 'channel' AND visibility_id = ?) OR
		    (visibility_kind = 'operator' AND visibility_id = ?)
		  )
		LIMIT 1`,
		channelID, "channel:"+channelID, r.nowText(),
		workspaceID, channelID, operatorID,
	)
	return scanMemoryEntry(row)
}

func (r *Repository) DeleteMemoryEntry(ctx context.Context, id string) (core.MemoryEntry, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return core.MemoryEntry{}, err
	}
	defer tx.Rollback()
	entry, err := scanMemoryEntry(tx.QueryRowContext(ctx, memorySelect+` WHERE id = ?`, id))
	if err != nil {
		return core.MemoryEntry{}, err
	}
	result, err := tx.ExecContext(ctx, `DELETE FROM memory_entries WHERE id = ?`, id)
	if err := sqlutil.ExpectOne(result, err, "delete memory entry"); err != nil {
		return core.MemoryEntry{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.MemoryEntry{}, err
	}
	return entry, nil
}

func (r *Repository) DeleteChannelMemoryEntries(ctx context.Context, channelID string) (int64, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		DELETE FROM memory_entries
		WHERE (scope_kind = 'channel' AND scope_key = ?)
		   OR (visibility_kind = 'channel' AND visibility_id = ?)`,
		channelID, channelID,
	)
	if err != nil {
		return 0, err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE memory_review_items SET status = 'dismissed', updated_at = ?
		WHERE status = 'pending' AND NOT EXISTS (
		  SELECT 1 FROM json_each(memory_review_items.entry_ids_json) AS ref
		  JOIN memory_entries ON memory_entries.id = ref.value
		)`, r.nowText()); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deleted, nil
}

func (r *Repository) PruneOrphanMemoryEntries(
	ctx context.Context,
	validRepositories []string,
) (int64, error) {
	if len(validRepositories) == 0 {
		return 0, errors.New("valid repository list is empty")
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(validRepositories)), ",")
	args := make([]any, 0, len(validRepositories)*2)
	for _, repository := range validRepositories {
		args = append(args, repository)
	}
	for _, repository := range validRepositories {
		args = append(args, repository)
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		DELETE FROM memory_entries
		WHERE (scope_kind = 'repository' AND scope_key NOT IN (`+placeholders+`))
		   OR (
		     predicate = 'repository_for_channel'
		     AND json_extract(value_json, '$') NOT IN (`+placeholders+`)
		   )`,
		args...,
	)
	if err != nil {
		return 0, err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	rollupArgs := make([]any, 0, len(validRepositories))
	for _, repository := range validRepositories {
		rollupArgs = append(rollupArgs, repository)
	}
	result, err = tx.ExecContext(ctx, `
		DELETE FROM memory_rollups
		WHERE scope_kind = 'repository' AND scope_key NOT IN (`+placeholders+`)`, rollupArgs...)
	if err != nil {
		return 0, err
	}
	rollups, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE memory_review_items SET status = 'dismissed', updated_at = ?
		WHERE status = 'pending' AND NOT EXISTS (
		  SELECT 1 FROM json_each(memory_review_items.entry_ids_json) AS ref
		  JOIN memory_entries ON memory_entries.id = ref.value
		)`, r.nowText()); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deleted + rollups, nil
}

func (r *Repository) ListRecentChannelEvidence(
	ctx context.Context,
	channelID string,
	excludeSourceInput string,
	limit int,
) ([]core.Evidence, error) {
	if channelID == "" || limit < 1 || limit > 50 {
		return nil, errors.New("channel evidence query is invalid")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, incident_id, channel_id, source_input, claim, observation, source_type,
		  source_name, source_url, target, freshness, confidence, observed_at,
		  metadata_json, created_at
		FROM evidence
		WHERE channel_id = ? AND source_input != ?
		ORDER BY created_at DESC LIMIT ?`,
		channelID, excludeSourceInput, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.Evidence
	for rows.Next() {
		var item core.Evidence
		var observed sql.NullString
		var metadata []byte
		var created string
		if err := rows.Scan(
			&item.ID, &item.IncidentID, &item.ChannelID, &item.SourceInput, &item.Claim,
			&item.Observation, &item.SourceType, &item.SourceName, &item.SourceURL,
			&item.Target, &item.Freshness, &item.Confidence, &observed, &metadata, &created,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(metadata, &item.Metadata); err != nil {
			return nil, err
		}
		item.ObservedAt = sqlutil.ScanTime(observed)
		item.CreatedAt = sqlutil.ParseTime(created)
		result = append(result, item)
	}
	return result, rows.Err()
}

const memorySelect = `
	SELECT id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
	  source_ref, source_revision, actor_id, visibility_kind, visibility_id,
	  expires_at, last_recalled_at, recall_count, last_reviewed_at,
	  created_at, updated_at
	FROM memory_entries`

func scanMemoryEntry(row sqlutil.RowScanner) (core.MemoryEntry, error) {
	var entry core.MemoryEntry
	var valueJSON, expires, created, updated string
	var recalled, reviewed sql.NullString
	err := row.Scan(
		&entry.ID, &entry.ScopeKind, &entry.ScopeKey, &entry.SubjectKey,
		&entry.Predicate, &valueJSON, &entry.ValueHash, &entry.SourceRef,
		&entry.SourceRevision, &entry.ActorID, &entry.VisibilityKind,
		&entry.VisibilityID, &expires, &recalled, &entry.RecallCount, &reviewed,
		&created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.MemoryEntry{}, core.ErrNotFound
	}
	if err != nil {
		return core.MemoryEntry{}, err
	}
	if err := json.Unmarshal([]byte(valueJSON), &entry.Value); err != nil {
		return core.MemoryEntry{}, fmt.Errorf("decode memory value: %w", err)
	}
	entry.ExpiresAt = sqlutil.ParseTime(expires)
	entry.LastRecalledAt = sqlutil.ScanTime(recalled)
	entry.LastReviewedAt = sqlutil.ScanTime(reviewed)
	entry.CreatedAt = sqlutil.ParseTime(created)
	entry.UpdatedAt = sqlutil.ParseTime(updated)
	return entry, nil
}

func (r *Repository) MarkMemoryEntriesRecalled(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, id := range ids {
		if strings.TrimSpace(id) == "" {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE memory_entries
			SET last_recalled_at = ?, recall_count = recall_count + 1
			WHERE id = ?`, r.nowText(), id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func scanMemoryEntries(rows *sql.Rows) ([]core.MemoryEntry, error) {
	var entries []core.MemoryEntry
	for rows.Next() {
		entry, err := scanMemoryEntry(rows)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

package memorystore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const memoryDreamingStateKey = "memory_dreaming_last_run"

type ConversationMemoryCandidate struct {
	Memory  core.ConversationMemory
	Private bool
}

func (r *Repository) MemoryDreamingDue(ctx context.Context, now time.Time, interval time.Duration) (bool, error) {
	var value string
	err := r.db.QueryRowContext(ctx, `SELECT value FROM responder_state WHERE key = ?`, memoryDreamingStateKey).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	last := sqlutil.ParseTime(value)
	return last.IsZero() || !last.Add(interval).After(now), nil
}

func (r *Repository) MarkMemoryDreamed(ctx context.Context, now time.Time) error {
	value := now.UTC().Format(core.TimestampFormat)
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO responder_state (key, value, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		memoryDreamingStateKey, value, value,
	)
	return err
}

func (r *Repository) CountConversationMemories(ctx context.Context) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, `SELECT count(*) FROM conversation_memories`).Scan(&count)
	return count, err
}

func (r *Repository) ListConversationMemoryCandidates(
	ctx context.Context,
	before time.Time,
	limit int,
) ([]ConversationMemoryCandidate, error) {
	if limit < 1 || limit > 10000 {
		return nil, errors.New("conversation memory candidate limit must be between 1 and 10000")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT memory.channel_id, COALESCE(membership.channel_name, ''),
		  memory.thread_ts, memory.repository, memory.last_message_ts,
		  memory.state_json, memory.last_recalled_at, memory.recall_count,
		  memory.updated_at, COALESCE(membership.private, 1)
		FROM conversation_memories AS memory
		LEFT JOIN slack_channel_memberships AS membership
		  ON membership.channel_id = memory.channel_id
		WHERE memory.updated_at < ?
		  AND memory.state_json != '{}' AND memory.state_json != ''
		ORDER BY memory.updated_at ASC
		LIMIT ?`, before.UTC().Format(core.TimestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]ConversationMemoryCandidate, 0, limit)
	for rows.Next() {
		var item ConversationMemoryCandidate
		var state []byte
		var recalled sql.NullString
		var updated string
		var private int
		if err := rows.Scan(
			&item.Memory.ChannelID, &item.Memory.ChannelName, &item.Memory.ThreadTS,
			&item.Memory.Repository, &item.Memory.LastMessage, &state, &recalled,
			&item.Memory.RecallCount, &updated, &private,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(state, &item.Memory.State); err != nil {
			return nil, fmt.Errorf("decode conversation memory candidate: %w", err)
		}
		item.Memory.LastRecalledAt = sqlutil.ScanTime(recalled)
		item.Memory.UpdatedAt = sqlutil.ParseTime(updated)
		item.Private = private == 1
		result = append(result, item)
	}
	return result, rows.Err()
}

func (r *Repository) GetMemoryRollup(
	ctx context.Context,
	scopeKind string,
	scopeKey string,
	periodStart time.Time,
) (core.MemoryRollup, error) {
	return scanMemoryRollup(r.db.QueryRowContext(ctx, memoryRollupSelect+`
		WHERE scope_kind = ? AND scope_key = ? AND period_start = ?`,
		scopeKind, scopeKey, periodStart.UTC().Format(core.TimestampFormat)))
}

func (r *Repository) GetMemoryRollupByID(ctx context.Context, id string) (core.MemoryRollup, error) {
	return scanMemoryRollup(r.db.QueryRowContext(ctx, memoryRollupSelect+` WHERE id = ?`, id))
}

func (r *Repository) DeleteMemoryRollup(ctx context.Context, id string) (core.MemoryRollup, error) {
	rollup, err := r.GetMemoryRollupByID(ctx, id)
	if err != nil {
		return core.MemoryRollup{}, err
	}
	result, err := r.db.ExecContext(ctx, `DELETE FROM memory_rollups WHERE id = ?`, id)
	if err := sqlutil.ExpectOne(result, err, "delete memory rollup"); err != nil {
		return core.MemoryRollup{}, err
	}
	return rollup, nil
}

func (r *Repository) CompactConversationMemories(
	ctx context.Context,
	rollup core.MemoryRollup,
	sources []core.ConversationMemory,
) error {
	if len(sources) == 0 || rollup.ScopeKey == "" || rollup.Repository == "" ||
		(rollup.ScopeKind != "channel" && rollup.ScopeKind != "repository") {
		return errors.New("memory rollup is incomplete")
	}
	state, err := json.Marshal(rollup.State)
	if err != nil {
		return err
	}
	refs, err := json.Marshal(rollup.SourceRefs)
	if err != nil {
		return err
	}
	if len(state) > 64<<10 || len(refs) > 64<<10 {
		return errors.New("memory rollup exceeds 64 KiB")
	}
	now := r.now().UTC()
	if rollup.ID == "" {
		rollup.ID, err = core.NewID("dream")
		if err != nil {
			return err
		}
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `
		INSERT INTO memory_rollups (
		  id, scope_kind, scope_key, repository, period_start, period_end,
		  state_json, source_refs_json, source_count, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(scope_kind, scope_key, period_start) DO UPDATE SET
		  repository = excluded.repository,
		  period_end = excluded.period_end,
		  state_json = excluded.state_json,
		  source_refs_json = excluded.source_refs_json,
		  source_count = excluded.source_count,
		  expires_at = excluded.expires_at,
		  updated_at = excluded.updated_at`,
		rollup.ID, rollup.ScopeKind, rollup.ScopeKey, rollup.Repository,
		rollup.PeriodStart.UTC().Format(core.TimestampFormat),
		rollup.PeriodEnd.UTC().Format(core.TimestampFormat), string(state), string(refs),
		rollup.SourceCount, rollup.ExpiresAt.UTC().Format(core.TimestampFormat),
		now.Format(core.TimestampFormat), now.Format(core.TimestampFormat),
	)
	if err != nil {
		return err
	}
	for _, source := range sources {
		if _, err := tx.ExecContext(ctx, `
			DELETE FROM conversation_memories
			WHERE channel_id = ? AND thread_ts = ? AND updated_at = ?`,
			source.ChannelID, source.ThreadTS,
			source.UpdatedAt.UTC().Format(core.TimestampFormat)); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (r *Repository) ListMemoryRollupsForContext(
	ctx context.Context,
	channelID string,
	repository string,
	limit int,
) ([]core.MemoryRollup, error) {
	if limit < 1 || limit > 20 {
		return nil, errors.New("memory rollup context limit must be between 1 and 20")
	}
	rows, err := r.db.QueryContext(ctx, memoryRollupSelect+`
		WHERE expires_at > ? AND (
		  (scope_kind = 'channel' AND scope_key = ?) OR
		  (scope_kind = 'repository' AND scope_key = ?)
		)
		ORDER BY CASE scope_kind WHEN 'channel' THEN 0 ELSE 1 END, period_end DESC
		LIMIT ?`, r.nowText(), channelID, repository, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.MemoryRollup
	for rows.Next() {
		item, err := scanMemoryRollup(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (r *Repository) MarkMemoryRollupsRecalled(ctx context.Context, ids []string) error {
	for _, id := range ids {
		if _, err := r.db.ExecContext(ctx, `
			UPDATE memory_rollups SET last_recalled_at = ?, recall_count = recall_count + 1
			WHERE id = ?`, r.nowText(), id); err != nil {
			return err
		}
	}
	return nil
}

func (r *Repository) MarkConversationMemoriesRecalled(
	ctx context.Context,
	memories []core.ConversationMemory,
) error {
	for _, memory := range memories {
		if _, err := r.db.ExecContext(ctx, `
			UPDATE conversation_memories
			SET last_recalled_at = ?, recall_count = recall_count + 1
			WHERE channel_id = ? AND thread_ts = ?`,
			r.nowText(), memory.ChannelID, memory.ThreadTS); err != nil {
			return err
		}
	}
	return nil
}

func (r *Repository) PruneMemoryRollups(ctx context.Context, max int) (int64, error) {
	result, err := r.db.ExecContext(ctx, `DELETE FROM memory_rollups WHERE expires_at <= ?`, r.nowText())
	if err != nil {
		return 0, err
	}
	deleted, _ := result.RowsAffected()
	if max < 1 {
		return deleted, nil
	}
	result, err = r.db.ExecContext(ctx, `
		DELETE FROM memory_rollups WHERE id IN (
		  SELECT id FROM memory_rollups
		  ORDER BY period_end DESC
		  LIMIT -1 OFFSET ?
		)`, max)
	if err != nil {
		return deleted, err
	}
	more, _ := result.RowsAffected()
	return deleted + more, nil
}

func (r *Repository) RefreshMemoryReviewQueue(ctx context.Context, staleBefore time.Time) error {
	rows, err := r.db.QueryContext(ctx, memorySelect+`
		WHERE expires_at > ? AND updated_at < ?
		  AND (last_recalled_at IS NULL OR last_recalled_at < ?)
		  AND (last_reviewed_at IS NULL OR last_reviewed_at < ?)`,
		r.nowText(), staleBefore.UTC().Format(core.TimestampFormat),
		staleBefore.UTC().Format(core.TimestampFormat), staleBefore.UTC().Format(core.TimestampFormat))
	if err != nil {
		return err
	}
	entries, err := scanMemoryEntries(rows)
	rows.Close()
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := r.ensureMemoryReview(ctx, "stale", []core.MemoryEntry{entry},
			"This memory has not been recalled or reviewed recently."); err != nil {
			return err
		}
	}

	rows, err = r.db.QueryContext(ctx, memorySelect+`
		WHERE predicate = 'guidance' AND expires_at > ?
		ORDER BY scope_kind, scope_key, visibility_kind, visibility_id, value_hash, updated_at DESC`,
		r.nowText())
	if err != nil {
		return err
	}
	all, err := scanMemoryEntries(rows)
	rows.Close()
	if err != nil {
		return err
	}
	groups := map[string][]core.MemoryEntry{}
	for _, entry := range all {
		key := strings.Join([]string{entry.ScopeKind, entry.ScopeKey, entry.VisibilityKind,
			entry.VisibilityID, entry.ValueHash}, "\x00")
		groups[key] = append(groups[key], entry)
	}
	for _, group := range groups {
		if len(group) < 2 {
			continue
		}
		if err := r.ensureMemoryReview(ctx, "duplicate", group,
			"These guidance entries have the same remembered value in the same scope."); err != nil {
			return err
		}
	}
	return nil
}

func (r *Repository) ensureMemoryReview(
	ctx context.Context,
	kind string,
	entries []core.MemoryEntry,
	reason string,
) error {
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	ids := make([]string, 0, len(entries))
	identity := []string{kind}
	for _, entry := range entries {
		ids = append(ids, entry.ID)
		identity = append(identity, entry.ID, entry.UpdatedAt.UTC().Format(core.TimestampFormat))
		if kind == "stale" {
			identity = append(identity, entry.LastReviewedAt.UTC().Format(core.TimestampFormat))
		}
	}
	digestBytes := sha256.Sum256([]byte(strings.Join(identity, "\x00")))
	digest := hex.EncodeToString(digestBytes[:])
	data, err := json.Marshal(ids)
	if err != nil {
		return err
	}
	id, err := core.NewID("memreview")
	if err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO memory_review_items (
		  id, kind, entry_ids_json, reason, source_digest, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, kind, string(data), reason, digest, r.nowText(), r.nowText())
	return err
}

func (r *Repository) ListPendingMemoryReviews(ctx context.Context, limit int) ([]core.MemoryReviewItem, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("memory review limit must be between 1 and 100")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, kind, entry_ids_json, reason, source_digest, status,
		  reviewed_by, reviewed_at, created_at, updated_at
		FROM memory_review_items WHERE status = 'pending'
		ORDER BY created_at ASC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []core.MemoryReviewItem
	for rows.Next() {
		var item core.MemoryReviewItem
		var ids string
		var reviewed sql.NullString
		var created, updated string
		if err := rows.Scan(&item.ID, &item.Kind, &ids, &item.Reason, &item.SourceDigest,
			&item.Status, &item.ReviewedBy, &reviewed, &created, &updated); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(ids), &item.EntryIDs); err != nil {
			return nil, err
		}
		item.ReviewedAt = sqlutil.ScanTime(reviewed)
		item.CreatedAt = sqlutil.ParseTime(created)
		item.UpdatedAt = sqlutil.ParseTime(updated)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (r *Repository) ResolveMemoryReview(
	ctx context.Context,
	id string,
	action string,
	actor string,
) ([]core.MemoryEntry, error) {
	var kind, idsJSON, status string
	if err := r.db.QueryRowContext(ctx, `
		SELECT kind, entry_ids_json, status FROM memory_review_items WHERE id = ?`, id,
	).Scan(&kind, &idsJSON, &status); errors.Is(err, sql.ErrNoRows) {
		return nil, core.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if status != "pending" {
		return nil, core.ErrConflict
	}
	var ids []string
	if err := json.Unmarshal([]byte(idsJSON), &ids); err != nil {
		return nil, err
	}
	entries := make([]core.MemoryEntry, 0, len(ids))
	for _, entryID := range ids {
		entry, err := r.GetMemoryEntry(ctx, entryID)
		if errors.Is(err, core.ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	now := r.nowText()
	newStatus := "kept"
	switch action {
	case "keep", "dismiss":
		if action == "dismiss" {
			newStatus = "dismissed"
		}
		for _, entry := range entries {
			if _, err := tx.ExecContext(ctx, `UPDATE memory_entries SET last_reviewed_at = ? WHERE id = ?`, now, entry.ID); err != nil {
				return nil, err
			}
		}
	case "forget":
		newStatus = "applied"
		for _, entry := range entries {
			if _, err := tx.ExecContext(ctx, `DELETE FROM memory_entries WHERE id = ?`, entry.ID); err != nil {
				return nil, err
			}
		}
	case "merge":
		if kind != "duplicate" || len(entries) < 2 {
			return nil, errors.New("memory review cannot be merged")
		}
		newStatus = "applied"
		sort.Slice(entries, func(i, j int) bool { return entries[i].UpdatedAt.After(entries[j].UpdatedAt) })
		keep := entries[0]
		if _, err := tx.ExecContext(ctx, `UPDATE memory_entries SET last_reviewed_at = ? WHERE id = ?`, now, keep.ID); err != nil {
			return nil, err
		}
		for _, entry := range entries[1:] {
			supersessionID, idErr := core.NewID("memsup")
			if idErr != nil {
				return nil, idErr
			}
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO memory_supersessions (
				  id, entry_id, previous_value_hash, replacement_value_hash, reason, created_at
				) VALUES (?, ?, ?, ?, 'duplicate merge', ?)`,
				supersessionID, keep.ID, entry.ValueHash, keep.ValueHash, now); err != nil {
				return nil, err
			}
			if _, err := tx.ExecContext(ctx, `DELETE FROM memory_entries WHERE id = ?`, entry.ID); err != nil {
				return nil, err
			}
		}
	default:
		return nil, errors.New("unsupported memory review action")
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE memory_review_items SET status = ?, reviewed_by = ?, reviewed_at = ?, updated_at = ?
		WHERE id = ? AND status = 'pending'`, newStatus, actor, now, now, id)
	if err := sqlutil.ExpectOne(result, err, "resolve memory review"); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE memory_review_items
		SET status = 'dismissed', reviewed_by = ?, reviewed_at = ?, updated_at = ?
		WHERE status = 'pending' AND NOT EXISTS (
		  SELECT 1 FROM json_each(memory_review_items.entry_ids_json) AS ref
		  JOIN memory_entries ON memory_entries.id = ref.value
		)`, actor, now, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return entries, nil
}

func (r *Repository) MemoryHealth(ctx context.Context) (core.MemoryHealth, error) {
	var health core.MemoryHealth
	now := r.nowText()
	queries := []struct {
		target *int
		query  string
		args   []any
	}{
		{&health.ExplicitActive, `SELECT count(*) FROM memory_entries WHERE expires_at > ?`, []any{now}},
		{&health.ExplicitRecalled, `SELECT count(*) FROM memory_entries WHERE expires_at > ? AND recall_count > 0`, []any{now}},
		{&health.ConversationSummaries, `SELECT count(*) FROM conversation_memories`, nil},
		{&health.Rollups, `SELECT count(*) FROM memory_rollups WHERE expires_at > ?`, []any{now}},
		{&health.PendingReviews, `SELECT count(*) FROM memory_review_items WHERE status = 'pending'`, nil},
	}
	for _, query := range queries {
		if err := r.db.QueryRowContext(ctx, query.query, query.args...).Scan(query.target); err != nil {
			return core.MemoryHealth{}, err
		}
	}
	var dreamed string
	if err := r.db.QueryRowContext(ctx, `SELECT value FROM responder_state WHERE key = ?`, memoryDreamingStateKey).Scan(&dreamed); err == nil {
		health.LastDreamedAt = sqlutil.ParseTime(dreamed)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return core.MemoryHealth{}, err
	}
	return health, nil
}

const memoryRollupSelect = `
	SELECT id, scope_kind, scope_key, repository, period_start, period_end,
	  state_json, source_refs_json, source_count, last_recalled_at, recall_count,
	  expires_at, created_at, updated_at
	FROM memory_rollups`

func scanMemoryRollup(row sqlutil.RowScanner) (core.MemoryRollup, error) {
	var item core.MemoryRollup
	var start, end, state, refs, expires, created, updated string
	var recalled sql.NullString
	err := row.Scan(&item.ID, &item.ScopeKind, &item.ScopeKey, &item.Repository,
		&start, &end, &state, &refs, &item.SourceCount, &recalled, &item.RecallCount,
		&expires, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return core.MemoryRollup{}, core.ErrNotFound
	}
	if err != nil {
		return core.MemoryRollup{}, err
	}
	if err := json.Unmarshal([]byte(state), &item.State); err != nil {
		return core.MemoryRollup{}, err
	}
	if err := json.Unmarshal([]byte(refs), &item.SourceRefs); err != nil {
		return core.MemoryRollup{}, err
	}
	item.PeriodStart = sqlutil.ParseTime(start)
	item.PeriodEnd = sqlutil.ParseTime(end)
	item.LastRecalledAt = sqlutil.ScanTime(recalled)
	item.ExpiresAt = sqlutil.ParseTime(expires)
	item.CreatedAt = sqlutil.ParseTime(created)
	item.UpdatedAt = sqlutil.ParseTime(updated)
	return item, nil
}

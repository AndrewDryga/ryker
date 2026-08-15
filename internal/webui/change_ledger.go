package webui

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

// The manifest kind and prompt layer internal/service writes when it shows a
// turn what changed. Spelled out here rather than imported for the same reason
// the recall constants beside them are: the dashboard reads the database and
// never the service package, so a rename on that side has to reach this string
// through the manifests already on disk, which keep the old one.
const (
	recentChangeRefKind = "recent_change"
	recentChangesLayer  = "recent_changes"
)

// recordedChangeName says which recorded change a reference points at.
//
// "change:chg_9e713bcd…" is a coordinate nobody can read. This row is the only
// place the trace explains why a prompt spent budget on a deploy, and the
// question a reader arrives with — "which change did it see, and can I go look
// at it" — is answered by the summary and the revision, not the digest.
//
// Read-only and tolerant of an absent row on purpose: retention prunes the
// ledger on the episode-history horizon while the manifest reference citing it
// is kept, so an old trace pointing at a pruned change must still render.
func (r *Reader) recordedChangeName(ctx context.Context, changeID, kind string) string {
	summary := truncate(r.recordedChangeSummary(ctx, changeID), 110)
	if summary == "" {
		summary = "change " + truncate(changeID, 16)
	}
	if kind != "" {
		summary = kind + ": " + summary
	}
	return summary
}

func (r *Reader) recordedChangeSummary(ctx context.Context, changeID string) string {
	if changeID == "" || !r.live() {
		return ""
	}
	if cached, ok := r.changes.Load(changeID); ok {
		summary, _ := cached.(string)
		return summary
	}
	var summary, revision, actor string
	err := r.db.QueryRowContext(ctx, `
	  SELECT summary, revision, actor FROM change_events WHERE id = ?`,
		changeID).Scan(&summary, &revision, &actor)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return ""
	}
	headline := strings.TrimSpace(fallback(summary, fallback(revision, actor)))
	r.changes.Store(changeID, headline)
	return headline
}

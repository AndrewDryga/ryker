// Package feedbackguidance builds durable memory from operator feedback for
// every surface that can approve it.
package feedbackguidance

import (
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
)

// Entry preserves distinct rules in their original channel. Category alone is
// not an identity: a workspace can legitimately hold several correctness rules.
func Entry(
	workspaceID, channelID, category, summary, sourceRef, actor string,
	now time.Time,
) core.MemoryEntry {
	scopeKind, scopeKey := "workspace", workspaceID
	if channelID != "" {
		scopeKind, scopeKey = "channel", channelID
	}
	return core.MemoryEntry{
		ScopeKind: scopeKind, ScopeKey: scopeKey,
		SubjectKey: memorypkg.NormalizeGuidanceSubject(category + " " + summary),
		Predicate:  "guidance", Value: core.BoundedText(summary, 1000),
		VisibilityKind: scopeKind, VisibilityID: scopeKey,
		ExpiresAt: memorypkg.ExpiryFrom(now.UTC(), memorypkg.PermanentTTL),
		SourceRef: sourceRef, ActorID: actor,
	}
}

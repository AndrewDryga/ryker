package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

const (
	responderPromptVersion       = "responder-prompt-v2"
	investigationContractVersion = "investigation-contract-v1"
	resultOperationsVersion      = "result-operations-v2"
)

// ensureAttemptContextManifest freezes the exact context envelope used by a
// Coop attempt. Retries of the same attempt reuse it; a replacement attempt
// extends the previous manifest rather than silently dropping eligible input.
func (s *Service) ensureAttemptContextManifest(
	ctx context.Context,
	run core.AgentRun,
	session coop.Session,
	prompt string,
	artifacts []coop.InputArtifact,
) (core.ContextManifest, error) {
	attempt, err := s.store.GetEpisodeAttempt(ctx, run.AttemptID)
	if err != nil {
		return core.ContextManifest{}, fmt.Errorf("load episode attempt context: %w", err)
	}
	if attempt.ContextManifestID != "" {
		return s.store.GetContextManifest(ctx, attempt.ContextManifestID)
	}

	manifest := core.ContextManifest{
		EpisodeID:         run.EpisodeID,
		AttemptID:         run.AttemptID,
		PromptVersion:     responderPromptVersion,
		ContractVersion:   investigationContractVersion,
		ToolSchemaVersion: resultOperationsVersion,
		Preset:            session.Policy,
		References: []core.ContextReference{
			contextReference("source_input", run.SourceKind+":"+run.SourceID, nil, "eligible", map[string]string{
				"channel_id": run.ChannelID,
				"thread_ts":  run.ThreadTS,
			}),
			contextReference("compiled_prompt", "agent-run:"+run.ID+":prompt", []byte(prompt), "private", nil),
			contextReference("assembled_context", "agent-run:"+run.ID+":context", run.Context, "private", nil),
		},
	}
	if session.BaseCommit != "" || run.Repository != "" {
		manifest.References = append(manifest.References, core.ContextReference{
			Kind: "repository", SourceRef: "repository:" + run.Repository,
			SourceRevision: session.BaseCommit, Visibility: "eligible",
		})
	}
	if session.PolicyDigest != "" {
		manifest.References = append(manifest.References, core.ContextReference{
			Kind: "execution_policy", SourceRef: "coop-policy:" + session.Policy,
			ContentDigest: session.PolicyDigest, Visibility: "private",
		})
	}
	for index, artifact := range artifacts {
		digest := strings.TrimSpace(artifact.SHA256)
		if digest == "" {
			sum := sha256.Sum256(artifact.Data)
			digest = hex.EncodeToString(sum[:])
		}
		manifest.References = append(manifest.References, core.ContextReference{
			Kind: "artifact", SourceRef: fmt.Sprintf("artifact:%s:%d", artifact.Name, index),
			ContentDigest: digest, Visibility: "eligible",
			Metadata: map[string]string{"name": artifact.Name, "media_type": artifact.MediaType},
		})
	}

	previous, previousErr := s.store.GetLatestContextManifest(ctx, run.EpisodeID)
	switch {
	case previousErr == nil:
		manifest.ParentManifestID = previous.ID
		manifest.References = mergeContextReferences(previous.References, manifest.References)
	case errors.Is(previousErr, store.ErrNotFound):
	default:
		return core.ContextManifest{}, previousErr
	}
	return s.store.CreateContextManifest(ctx, manifest)
}

func contextReference(
	kind string,
	source string,
	content []byte,
	visibility string,
	metadata map[string]string,
) core.ContextReference {
	ref := core.ContextReference{
		Kind: kind, SourceRef: source, Visibility: visibility, Metadata: metadata,
	}
	if content != nil {
		sum := sha256.Sum256(content)
		ref.ContentDigest = hex.EncodeToString(sum[:])
	}
	return ref
}

func mergeContextReferences(
	previous []core.ContextReference,
	current []core.ContextReference,
) []core.ContextReference {
	merged := make([]core.ContextReference, 0, len(previous)+len(current))
	seen := make(map[string]struct{}, len(previous)+len(current))
	add := func(ref core.ContextReference) {
		ref.ID, ref.ManifestID, ref.Ordinal = "", "", 0
		key := ref.Kind + "\x00" + ref.SourceRef + "\x00" + ref.ContentDigest + "\x00" + ref.SourceRevision
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		merged = append(merged, ref)
	}
	for _, ref := range previous {
		add(ref)
	}
	for _, ref := range current {
		add(ref)
	}
	return merged
}

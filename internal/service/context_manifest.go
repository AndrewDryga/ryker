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
	"github.com/AndrewDryga/responder/internal/taskpr"
)

const (
	responderPromptVersion       = "responder-prompt-v3"
	investigationContractVersion = "investigation-contract-v1"
	resultOperationsVersion      = "result-operations-v2"
)

// ensureAttemptContextManifest freezes the exact context envelope used by a
// Coop attempt. Retries of the same attempt reuse it; a replacement attempt
// extends the previous manifest rather than silently dropping eligible input.
//
// omissions is what the caller assembled and then could not send. It is
// recorded beside what was sent because the two answer different questions and
// only one of them was ever being asked: the references say what the model
// read, and "what was NOT in the prompt" is usually the answer to "why did it
// say that". Every manifest and every reference row on the deployed databases
// reports that nothing has ever been left out of any prompt, which is not what
// happened — the budget path has been trimming context for as long as it has
// existed, and no path recorded a word of it.
func (s *Service) ensureAttemptContextManifest(
	ctx context.Context,
	run core.AgentRun,
	session coop.Session,
	prompt string,
	artifacts []coop.InputArtifact,
	omissions []core.ContextOmission,
) (core.ContextManifest, error) {
	attempt, err := s.store.GetEpisodeAttempt(ctx, run.AttemptID)
	if err != nil {
		return core.ContextManifest{}, fmt.Errorf("load episode attempt context: %w", err)
	}
	if attempt.ContextManifestID != "" {
		return s.store.GetContextManifest(ctx, attempt.ContextManifestID)
	}

	provider, model, effort := targetParts(session.Target)
	// The transport cuts the middle out of an oversized prompt, and until now
	// the only trace was a process-local counter that knew how many prompts had
	// been elided and never which episode's — so an operator holding one bad
	// answer could not find out whether its prompt had been cut in half. The
	// host has both the prompt and the cap right here, before it sends.
	omissions = core.AppendElidedPrompt(
		omissions, "agent-run:"+run.ID+":prompt", len(prompt), coop.MaxPromptBytes,
	)
	manifest := core.ContextManifest{
		EpisodeID:         run.EpisodeID,
		AttemptID:         run.AttemptID,
		PromptVersion:     responderPromptVersion,
		ContractVersion:   investigationContractVersion,
		ToolSchemaVersion: resultOperationsVersion,
		Preset:            session.Policy,
		// The EFFECTIVE target, after any rotation Coop performed: a ladder that
		// moved codex to claude mid-incident must record what ran, not what was
		// configured. These columns existed from the start and nothing assigned
		// them, so all 57 rows read empty.
		Provider:        provider,
		Model:           model,
		ReasoningEffort: effort,
		SubmittedPrompt: prompt,
		Omissions:       core.ContextOmissionReasons(omissions),
		References: []core.ContextReference{
			contextReference("source_input", run.SourceKind+":"+run.SourceID, nil, "eligible", map[string]string{
				"channel_id": run.ChannelID,
				"thread_ts":  run.ThreadTS,
			}),
			contextReference("compiled_prompt", "agent-run:"+run.ID+":prompt", []byte(prompt), "private", nil),
			contextReference("assembled_context", "agent-run:"+run.ID+":context", run.Context, "private", nil),
		},
	}
	sourceRevision := taskpr.SessionHead(session)
	if sourceRevision != "" || run.Repository != "" {
		manifest.References = append(manifest.References, core.ContextReference{
			Kind: "repository", SourceRef: "repository:" + run.Repository,
			SourceRevision: sourceRevision, Visibility: "eligible",
		})
	}
	manifest.References = append(manifest.References, taskpr.CompanionReferences(session, run.Repository)...)
	if session.PolicyDigest != "" {
		manifest.References = append(manifest.References, core.ContextReference{
			Kind: "execution_policy", SourceRef: "coop-policy:" + session.Policy,
			ContentDigest: session.PolicyDigest, Visibility: "private",
		})
	}
	artifactRefs, retained := taskpr.ArtifactReferences(artifacts)
	manifest.References = append(manifest.References, artifactRefs...)
	if len(retained) > 0 {
		if err := s.store.Artifacts.Save(ctx, retained); err != nil {
			return core.ContextManifest{}, fmt.Errorf("retain input artifacts: %w", err)
		}
	}

	manifest.References = append(manifest.References, core.OmittedContextReferences(omissions)...)

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
	// An omission is a fact about the attempt that made it, not part of the
	// context envelope, so it does not travel forward. Carried over, a layer
	// trimmed once would read as trimmed on every later attempt, including the
	// ones that had room for it in full — which turns the record of what was
	// missing into a reason to distrust the record.
	for _, ref := range previous {
		if ref.OmittedReason == "" {
			add(ref)
		}
	}
	for _, ref := range current {
		add(ref)
	}
	return merged
}

// A Coop target is provider[:model][/effort][@credential], split in that order:
// taking the colon first reads "claude/high" as a provider named "claude/high".
// Parsed here rather than imported, so a target this cannot read leaves a blank
// field instead of failing an episode over another repository's separator.
func targetParts(target string) (provider, model, effort string) {
	name, _, _ := strings.Cut(strings.TrimSpace(target), "@")
	head, effort, _ := strings.Cut(name, "/")
	provider, model, _ = strings.Cut(head, ":")
	return strings.TrimSpace(provider), strings.TrimSpace(model), strings.TrimSpace(effort)
}

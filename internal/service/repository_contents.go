package service

import (
	"context"
	"regexp"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// repositoryScopeKeyPattern is the alias shape Coop policies and repository
// configuration both use.
var repositoryScopeKeyPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,62}$`)

// repositoryContentsForPrompt reads the durable one-line description of every
// repository, falling back to the configured description where an agent has not
// written one yet.
//
// A failure here returns an empty map rather than an error. The map decorates
// the repository set; the set itself comes from the session's pins and is what
// an agent actually needs to find code. Losing a sentence must not lose a turn.
func (s *Service) repositoryContentsForPrompt(ctx context.Context) map[string]string {
	contents := make(map[string]string, len(s.cfg.Repositories))
	for name, repository := range s.cfg.Repositories {
		if described := strings.TrimSpace(repository.Description); described != "" {
			contents[name] = described
		}
	}
	stored, err := s.store.Memory.ListRepositoryContents(ctx)
	if err != nil {
		if s.log != nil {
			s.log.Warn("could not read repository descriptions", "error", trimError(err))
		}
		return contents
	}
	// Stored last: what an agent read from the repository supersedes what the
	// configuration guessed about it.
	for name, value := range stored {
		if described := strings.TrimSpace(value); described != "" {
			contents[name] = described
		}
	}
	return contents
}

// applyRepositoryContents saves what a turn learned about which part of the
// product a repository holds.
//
// This is the only memory Responder writes without an operator confirming it,
// and the exemption is narrow by construction rather than by intention: one
// subject per repository, a bounded single sentence, a configured repository
// only, and the same credential and multiline rejection every other memory
// passes through. What it describes — which code lives where — is checkable by
// reading the repository, so a wrong sentence is corrected by the next agent
// that looks rather than by an operator who has to notice.
//
// Every write is audited with the value, because "no confirmation" and "no
// record" are different things and only the first one was chosen.
func (s *Service) applyRepositoryContents(
	ctx context.Context,
	run core.AgentRun,
	decision decisionpkg.WatchDecision,
) error {
	for _, operation := range decision.RepositoryContents {
		name := strings.TrimSpace(operation.Repository)
		// Deliberately not checked against cfg.Repositories. A Coop policy's
		// companions and the Slack-visible repository contexts are two different
		// lists: the emisar deployment mounts `coop` and `responder` as
		// companions while configuring neither, and requiring configuration here
		// would have made those two permanently undescribable — the exact repos
		// an agent working in that workspace reads most.
		//
		// A name nothing mounts is inert rather than dangerous: RepositorySet
		// renders from the session's own companions, so a row keyed to a name no
		// policy pins is never shown to anyone. The shape check is what keeps
		// the scope key a key.
		if !repositoryScopeKeyPattern.MatchString(name) {
			s.audit(ctx, core.AuditEvent{
				Kind: "memory.repository_contents", ActorID: "responder", ObjectID: name,
				Outcome: "rejected", Detail: "repository name is not a usable scope key",
			})
			continue
		}
		entry := core.MemoryEntry{
			ScopeKind: "repository", ScopeKey: name,
			SubjectKey: core.RepositoryContentsSubject,
			Predicate:  "guidance",
			Value: core.BoundedText(
				strings.Join(strings.Fields(operation.Contents), " "),
				investigation.MaxRepositoryContentsBytes,
			),
			VisibilityKind: "workspace", VisibilityID: s.cfg.Slack.TeamID,
			// Never expires. A repository's purpose does not lapse on a timer,
			// and an entry that vanished would take the map's only description
			// with it until an agent happened to read that repository again.
			ExpiresAt: core.PermanentExpiry,
			SourceRef: "run:" + run.ID,
			ActorID:   "responder",
		}
		if err := s.validateMemoryValue(&entry); err != nil {
			s.audit(ctx, core.AuditEvent{
				Kind: "memory.repository_contents", ActorID: "responder", ObjectID: name,
				Outcome: "rejected", Detail: s.cleanStructuredField(err.Error(), 500),
			})
			continue
		}
		saved, replaced, err := s.store.Memory.UpsertMemoryEntry(
			ctx, entry, s.cfg.Limits.MaxMemoryEntries, s.cfg.Limits.MaxMemoryEntriesPerScope,
		)
		if err != nil {
			// A full memory table must not fail an otherwise finished turn. The
			// audit says the description was lost; the reply still goes out.
			s.audit(ctx, core.AuditEvent{
				Kind: "memory.repository_contents", ActorID: "responder", ObjectID: name,
				Outcome: "failed", Detail: s.cleanStructuredField(trimError(err), 500),
			})
			continue
		}
		outcome := "recorded"
		if replaced {
			outcome = "replaced"
		}
		s.audit(ctx, core.AuditEvent{
			Kind: "memory.repository_contents", ActorID: "responder", ObjectID: name,
			Outcome: outcome,
			Detail:  s.cleanStructuredField(saved.Value, 500),
		})
	}
	return nil
}

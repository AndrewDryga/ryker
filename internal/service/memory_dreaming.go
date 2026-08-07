package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/store"
)

func (s *Service) maintainMemory(ctx context.Context, now time.Time) error {
	if !s.cfg.Memory.DreamingEnabled {
		return nil
	}
	due, err := s.store.MemoryDreamingDue(
		ctx, now, s.cfg.Memory.DreamingInterval.Duration,
	)
	if err != nil || !due {
		return err
	}
	count, err := s.store.CountConversationMemories(ctx)
	if err != nil {
		return err
	}
	pressure := count*100 >= s.cfg.Memory.MaxConversationSummaries*s.cfg.Memory.PressurePercent
	cutoff := now.Add(-s.cfg.Memory.CompactAfter.Duration)
	limit := 1000
	if pressure {
		// Keep very recent conversation summaries intact even under pressure.
		cutoff = now.Add(-time.Hour)
		target := s.cfg.Memory.MaxConversationSummaries * s.cfg.Memory.TargetPercent / 100
		limit = min(max(count-target, 1), 10000)
	}
	candidates, err := s.store.ListConversationMemoryCandidates(ctx, cutoff, limit)
	if err != nil {
		return err
	}
	groups := memorypkg.GroupMemoryRollups(candidates)
	compacted := 0
	for _, group := range groups {
		if len(group.Sources) < s.cfg.Memory.MinRollupSources && !pressure {
			continue
		}
		rollup, err := s.buildMemoryRollup(ctx, group, now)
		if err != nil {
			return err
		}
		if err := s.store.CompactConversationMemories(ctx, rollup, group.Sources); err != nil {
			return err
		}
		compacted += len(group.Sources)
	}
	if _, err := s.store.PruneMemoryRollups(ctx, s.cfg.Memory.MaxRollups); err != nil {
		return err
	}
	if err := s.store.RefreshMemoryReviewQueue(
		ctx, now.Add(-s.cfg.Memory.ReviewStaleAfter.Duration),
	); err != nil {
		return err
	}
	if err := s.store.MarkMemoryDreamed(ctx, now); err != nil {
		return err
	}
	if compacted > 0 {
		s.log.Info(
			"consolidated conversation memory",
			"summaries", compacted,
			"rollups", len(groups),
			"pressure", pressure,
		)
	}
	return nil
}

func (s *Service) buildMemoryRollup(
	ctx context.Context,
	group memorypkg.MemoryRollupGroup,
	now time.Time,
) (core.MemoryRollup, error) {
	states := make([]core.AgentMemory, 0, len(group.Sources)+1)
	refs := make([]string, 0, len(group.Sources)+20)
	periodEnd := group.Period
	count := 0
	existing, err := s.store.GetMemoryRollup(
		ctx, group.ScopeKind, group.ScopeKey, group.Period,
	)
	if err == nil {
		periodEnd = existing.PeriodEnd
		count = existing.SourceCount
	} else if !errors.Is(err, store.ErrNotFound) {
		return core.MemoryRollup{}, err
	}
	// Newer summaries win ordering when the bounded union removes duplicates.
	slices.SortFunc(group.Sources, func(a, b core.ConversationMemory) int {
		return b.UpdatedAt.Compare(a.UpdatedAt)
	})
	for _, source := range group.Sources {
		states = append(states, source.State)
		refs = append(refs, fmt.Sprintf(
			"slack:%s:%s@%s",
			source.ChannelID,
			displayOr(source.ThreadTS, "channel"),
			source.UpdatedAt.UTC().Format(time.RFC3339),
		))
		periodEnd = memorypkg.MaxTime(periodEnd, source.UpdatedAt)
		count++
	}
	if existing.ID != "" {
		states = append(states, existing.State)
		refs = append(refs, existing.SourceRefs...)
	}
	refs = memorypkg.BoundedUnique(refs, 50, 200)
	return core.MemoryRollup{
		ID:          existing.ID,
		ScopeKind:   group.ScopeKind,
		ScopeKey:    group.ScopeKey,
		Repository:  group.Repository,
		PeriodStart: group.Period,
		PeriodEnd:   periodEnd,
		State:       memorypkg.MergeAgentMemories(states),
		SourceRefs:  refs,
		SourceCount: count,
		ExpiresAt:   periodEnd.Add(s.cfg.Retention.ConversationMemory.Duration),
		CreatedAt:   now,
		UpdatedAt:   now,
	}, nil
}

package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

type memoryRollupGroup struct {
	ScopeKind  string
	ScopeKey   string
	Repository string
	Period     time.Time
	Sources    []core.ConversationMemory
}

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
	groups := groupMemoryRollups(candidates)
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

func groupMemoryRollups(candidates []store.ConversationMemoryCandidate) []memoryRollupGroup {
	groups := map[string]*memoryRollupGroup{}
	order := make([]string, 0)
	for _, candidate := range candidates {
		memory := candidate.Memory
		period := startOfUTCWeek(memory.UpdatedAt)
		scopeKind := "repository"
		scopeKey := memory.Repository
		if candidate.Private {
			scopeKind = "channel"
			scopeKey = memory.ChannelID
		}
		key := strings.Join([]string{
			scopeKind, scopeKey, period.Format(time.RFC3339),
		}, "\x00")
		group := groups[key]
		if group == nil {
			group = &memoryRollupGroup{
				ScopeKind: scopeKind, ScopeKey: scopeKey,
				Repository: memory.Repository, Period: period,
			}
			groups[key] = group
			order = append(order, key)
		}
		group.Sources = append(group.Sources, memory)
	}
	result := make([]memoryRollupGroup, 0, len(groups))
	for _, key := range order {
		result = append(result, *groups[key])
	}
	return result
}

func (s *Service) buildMemoryRollup(
	ctx context.Context,
	group memoryRollupGroup,
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
		periodEnd = maxTime(periodEnd, source.UpdatedAt)
		count++
	}
	if existing.ID != "" {
		states = append(states, existing.State)
		refs = append(refs, existing.SourceRefs...)
	}
	refs = boundedUnique(refs, 50, 200)
	return core.MemoryRollup{
		ID:          existing.ID,
		ScopeKind:   group.ScopeKind,
		ScopeKey:    group.ScopeKey,
		Repository:  group.Repository,
		PeriodStart: group.Period,
		PeriodEnd:   periodEnd,
		State:       mergeAgentMemories(states),
		SourceRefs:  refs,
		SourceCount: count,
		ExpiresAt:   periodEnd.Add(s.cfg.Retention.ConversationMemory.Duration),
		CreatedAt:   now,
		UpdatedAt:   now,
	}, nil
}

func mergeAgentMemories(states []core.AgentMemory) core.AgentMemory {
	var result core.AgentMemory
	for _, state := range states {
		state = sanitizeMemory(state)
		if result.Goal == "" {
			result.Goal = state.Goal
		}
		if result.ChannelPurpose == "" {
			result.ChannelPurpose = state.ChannelPurpose
		}
		if result.SituationSummary == "" {
			result.SituationSummary = state.SituationSummary
		}
		result.ActiveTopics = append(result.ActiveTopics, state.ActiveTopics...)
		result.OpenLoops = append(result.OpenLoops, state.OpenLoops...)
		result.Topology = append(result.Topology, state.Topology...)
		result.Decisions = append(result.Decisions, state.Decisions...)
		result.UnresolvedQuestions = append(
			result.UnresolvedQuestions, state.UnresolvedQuestions...,
		)
		result.EvidenceRefs = append(result.EvidenceRefs, state.EvidenceRefs...)
	}
	result.ActiveTopics = boundedUnique(result.ActiveTopics, 12, 240)
	result.OpenLoops = boundedUnique(result.OpenLoops, 20, 400)
	result.Topology = boundedUnique(result.Topology, 30, 400)
	result.Decisions = boundedUnique(result.Decisions, 30, 400)
	result.UnresolvedQuestions = boundedUnique(result.UnresolvedQuestions, 30, 400)
	result.EvidenceRefs = boundedUnique(result.EvidenceRefs, 50, 120)
	return sanitizeMemory(result)
}

func boundedUnique(values []string, limit int, maxBytes int) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, min(len(values), limit))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if len(value) > maxBytes {
			value = value[:maxBytes]
		}
		key := strings.ToLower(value)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, value)
		if len(result) == limit {
			break
		}
	}
	return result
}

func startOfUTCWeek(value time.Time) time.Time {
	value = value.UTC()
	day := time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, time.UTC)
	daysSinceMonday := (int(day.Weekday()) + 6) % 7
	return day.AddDate(0, 0, -daysSinceMonday)
}

func maxTime(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

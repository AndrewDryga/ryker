package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/recall"
	"github.com/AndrewDryga/responder/internal/store"
)

type agentReport struct {
	Message           string                          `json:"message"`
	FollowupMessages  []string                        `json:"followup_messages,omitempty"`
	Visuals           []core.GeneratedVisual          `json:"visuals,omitempty"`
	Evidence          []core.Evidence                 `json:"evidence,omitempty"`
	Coverage          []core.Coverage                 `json:"coverage,omitempty"`
	Memory            core.AgentMemory                `json:"memory,omitempty"`
	MemoryOffer       *core.MemoryOffer               `json:"memory_offer,omitempty"`
	PreferenceOffer   *core.PreferenceOffer           `json:"preference_offer,omitempty"`
	RuleOffer         *core.RuleOffer                 `json:"rule_offer,omitempty"`
	ScheduleOffer     *core.ScheduleOffer             `json:"schedule_offer,omitempty"`
	PendingApproval   *core.EmisarApproval            `json:"pending_approval,omitempty"`
	Proposals         []core.ActionProposal           `json:"proposals,omitempty"`
	Completion        *completionAssessment           `json:"completion,omitempty"`
	Operations        []investigation.ResultOperation `json:"operations,omitempty"`
	AppliedOperations []investigation.ResultOperation `json:"-"`

	// LegacyFallback records that the typed fold failed and the older
	// free-text reading was used instead; FallbackReason is why. LegacyShape
	// records a response that never used the typed protocol at all. Both exist
	// to answer one question before the legacy path is deleted: does anything
	// still depend on it?
	LegacyFallback bool   `json:"-"`
	FallbackReason string `json:"-"`
	LegacyShape    bool   `json:"-"`
}

const (
	maxFollowupMessages   = 5
	maxReplyPartBytes     = 12 << 10
	maxReplySequenceBytes = 48 << 10
)

func normalizeReplySequence(message string, followups []string) (string, []string, error) {
	message = strings.TrimSpace(message)
	if message == "" {
		return "", nil, errors.New("structured agent response has no message")
	}
	if len(followups) > maxFollowupMessages {
		return "", nil, fmt.Errorf(
			"structured agent response has more than %d follow-up messages",
			maxFollowupMessages,
		)
	}
	total := len(message)
	if len(message) > maxReplyPartBytes {
		return "", nil, errors.New("structured agent response message exceeds 12 KiB")
	}
	normalized := make([]string, 0, len(followups))
	for _, followup := range followups {
		followup = strings.TrimSpace(followup)
		if followup == "" {
			return "", nil, errors.New("structured agent response has an empty follow-up message")
		}
		if len(followup) > maxReplyPartBytes {
			return "", nil, errors.New("structured agent response follow-up exceeds 12 KiB")
		}
		total += len(followup)
		if total > maxReplySequenceBytes {
			return "", nil, errors.New("structured agent response sequence exceeds 48 KiB")
		}
		normalized = append(normalized, followup)
	}
	return message, normalized, nil
}

func replySequence(message string, followups []string) []string {
	result := make([]string, 0, 1+len(followups))
	result = append(result, message)
	return append(result, followups...)
}

func replySequenceDeliveryID(base string, index int, total int) string {
	if total <= 1 {
		return base
	}
	if index == total-1 {
		return base + "_part_999"
	}
	return fmt.Sprintf("%s_part_%03d", base, index+1)
}

func parseAgentReport(message string) (agentReport, bool, error) {
	trimmed := strings.TrimSpace(message)
	if trimmed == "" {
		return agentReport{}, false, errors.New("agent response is empty")
	}
	if err := rejectMultipleJSONObjects(trimmed); err != nil {
		return agentReport{}, true, err
	}
	if strings.HasPrefix(trimmed, "{") {
		report, err := decodeAgentReport(trimmed)
		if err == nil {
			return report, true, nil
		}
		if object, objectErr := firstJSONObject(trimmed); objectErr == nil {
			if recovered, recoverErr := decodeAgentReport(object); recoverErr == nil {
				return recovered, true, nil
			}
		}
		if recovered, recoverErr := decodeAgentMessage(trimmed); recoverErr == nil {
			return agentReport{Message: recovered}, false, nil
		}
		return agentReport{}, true, err
	}
	// Prose-wrapped structured output must recover the outer result object. A
	// backwards scan can otherwise decode an inner completion payload as a full
	// report and silently lose its evidence and typed operation stream.
	if start := strings.Index(trimmed, "{"); start >= 0 {
		if object, objectErr := firstJSONObject(trimmed[start:]); objectErr == nil {
			if recovered, recoverErr := decodeAgentReport(object); recoverErr == nil {
				return recovered, true, nil
			}
		}
	}
	var candidateErr error
	for end := len(trimmed); end > 0; {
		index := strings.LastIndex(trimmed[:end], "{")
		if index < 0 {
			break
		}
		candidate := strings.TrimSpace(trimmed[index:])
		report, err := decodeAgentReport(candidate)
		if err == nil {
			return report, true, nil
		}
		if object, objectErr := firstJSONObject(candidate); objectErr == nil {
			if recovered, recoverErr := decodeAgentReport(object); recoverErr == nil {
				return recovered, true, nil
			}
		}
		if recovered, recoverErr := decodeAgentMessage(candidate); recoverErr == nil {
			return agentReport{Message: recovered}, false, nil
		}
		if strings.Contains(candidate, `"message"`) {
			candidateErr = err
		}
		end = index
	}
	if candidateErr != nil {
		return agentReport{}, true, candidateErr
	}
	return agentReport{Message: trimmed}, false, nil
}

func firstJSONObject(message string) (string, error) {
	decoder := json.NewDecoder(strings.NewReader(message))
	var value json.RawMessage
	if err := decoder.Decode(&value); err != nil {
		return "", err
	}
	remainder := strings.TrimSpace(message[decoder.InputOffset():])
	if strings.HasPrefix(remainder, "{") || strings.HasPrefix(remainder, "[") {
		return "", errors.New("response contains multiple JSON values")
	}
	trimmed := bytes.TrimSpace(value)
	if len(trimmed) == 0 || trimmed[0] != '{' || !json.Valid(trimmed) {
		return "", errors.New("first JSON value is not an object")
	}
	return string(trimmed), nil
}

func rejectMultipleJSONObjects(message string) error {
	start := strings.Index(message, "{")
	if start < 0 {
		return nil
	}
	_, err := firstJSONObject(message[start:])
	if err != nil && strings.Contains(err.Error(), "multiple JSON values") {
		return err
	}
	return nil
}

func decodeAgentReport(message string) (agentReport, error) {
	normalized, err := normalizeEmptyStructuredTimestamps(message)
	if err != nil {
		return agentReport{}, fmt.Errorf("decode structured agent response: %w", err)
	}
	var report agentReport
	if err := decodeStrictJSON(normalized, &report); err != nil {
		return agentReport{}, fmt.Errorf("decode structured agent response: %w", err)
	}
	if err := applyAgentResultOperations(&report); err != nil {
		return agentReport{}, err
	}
	report.Message, report.FollowupMessages, err = normalizeReplySequence(
		report.Message,
		report.FollowupMessages,
	)
	if err != nil {
		return agentReport{}, err
	}
	if report.Message == noConversationReply && len(report.FollowupMessages) > 0 {
		return agentReport{}, errors.New(
			"structured agent response cannot combine no-reply with follow-up messages",
		)
	}
	offerCount := 0
	for _, present := range []bool{
		report.MemoryOffer != nil,
		report.PreferenceOffer != nil,
		report.RuleOffer != nil,
		report.ScheduleOffer != nil,
	} {
		if present {
			offerCount++
		}
	}
	if offerCount > 0 && len(report.Visuals) > 0 {
		return agentReport{}, errors.New("structured agent response cannot combine a durable behavior offer with generated visuals")
	}
	if err := validateCompletionAssessment(report.Completion); err != nil {
		return agentReport{}, err
	}
	if err := validateCapabilityGapEvidence(report.Completion, report.Evidence); err != nil {
		return agentReport{}, err
	}
	report.Message, report.FollowupMessages = appendCapabilityGuidance(
		report.Message,
		report.FollowupMessages,
		report.Completion,
	)
	report.Message, report.FollowupMessages, err = normalizeReplySequence(
		report.Message,
		report.FollowupMessages,
	)
	if err != nil {
		return agentReport{}, err
	}
	return report, nil
}

func normalizeEmptyStructuredTimestamps(message string) ([]byte, error) {
	decoder := json.NewDecoder(strings.NewReader(message))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	// `verdict` belongs to completion (or alert_assessment), not the response
	// envelope. Older prompts and some models occasionally emit it at the root.
	// It carries no additional authority there, so discard it rather than
	// retrying an otherwise valid result until the episode disappears.
	if root, ok := value.(map[string]any); ok {
		delete(root, "verdict")
	}
	var visit func(any)
	visit = func(current any) {
		switch typed := current.(type) {
		case map[string]any:
			for key, child := range typed {
				if (key == "observed_at" || key == "created_at" || key == "expires_at") &&
					child == "" {
					delete(typed, key)
					continue
				}
				visit(child)
			}
		case []any:
			for _, child := range typed {
				visit(child)
			}
		}
	}
	visit(value)
	return json.Marshal(value)
}

func decodeAgentMessage(message string) (string, error) {
	var fields map[string]json.RawMessage
	decoder := json.NewDecoder(strings.NewReader(message))
	if err := decoder.Decode(&fields); err != nil {
		return "", err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return "", errors.New("multiple JSON values")
		}
		return "", err
	}
	var result string
	if err := json.Unmarshal(fields["message"], &result); err != nil {
		return "", err
	}
	result = strings.TrimSpace(result)
	if result == "" {
		return "", errors.New("structured agent response has no message")
	}
	return result, nil
}

// recordResultProtocol notes whether a model result actually used the typed
// operation protocol.
//
// The legacy free-text reading is still accepted, and when the typed fold fails
// the older shape is silently used instead — so the same turn can be read two
// ways with nobody told which happened. These counters exist to answer one
// question before that path is deleted: does anything still depend on it? A
// week of zeros is the evidence; deleting first and watching afterwards inverts
// the risk.
func (s *Service) recordResultProtocol(
	ctx context.Context,
	runID string,
	fallback bool,
	legacyShape bool,
	reason string,
) {
	switch {
	case fallback:
		s.log.Warn(
			"model result fell back to the legacy reading",
			"run", runID,
			"reason", reason,
		)
		s.audit(ctx, core.AuditEvent{
			Kind: "result.legacy_fallback", ActorID: "responder",
			ObjectID: runID, Outcome: "fallback", Detail: boundedField(reason, 500),
		})
	case legacyShape:
		s.log.Warn("model result carried no typed operations", "run", runID)
		s.audit(ctx, core.AuditEvent{
			Kind: "result.legacy_shape", ActorID: "responder",
			ObjectID: runID, Outcome: "legacy_only",
		})
	}
}

func (s *Service) persistAgentReport(
	ctx context.Context,
	report agentReport,
	incident core.Incident,
	channelID string,
	sourceInput string,
	requestedBy string,
) (agentReport, error) {
	if s.sanitizer != nil {
		report.Message = s.sanitizer.Text(report.Message)
		for index := range report.FollowupMessages {
			report.FollowupMessages[index] = s.sanitizer.Text(
				report.FollowupMessages[index],
			)
		}
	} else {
		// Only reachable from tests that build a Service literal; the real
		// service always has a sanitizer. Still bound the parts.
		report.Message = boundedField(report.Message, 30000)
		for index := range report.FollowupMessages {
			report.FollowupMessages[index] = boundedField(
				report.FollowupMessages[index],
				maxReplyPartBytes,
			)
		}
	}
	if report.MemoryOffer != nil || report.PreferenceOffer != nil || report.RuleOffer != nil || report.ScheduleOffer != nil {
		// Configuration requests are not operational findings. Keeping model-produced
		// evidence here makes a confirmation card look as if its behavior was already saved.
		report.Evidence = nil
		report.Coverage = nil
		report.Visuals = nil
	}
	if len(report.Visuals) > s.cfg.Limits.MaxGeneratedVisuals {
		return agentReport{}, errors.New("structured agent response references too many generated visuals")
	}
	for index := range report.Visuals {
		report.Visuals[index].Artifact = s.cleanStructuredField(report.Visuals[index].Artifact, 255)
		report.Visuals[index].Title = s.cleanStructuredField(report.Visuals[index].Title, 200)
		report.Visuals[index].AltText = s.cleanStructuredField(report.Visuals[index].AltText, 1000)
		if report.Visuals[index].Artifact == "" || report.Visuals[index].Title == "" || report.Visuals[index].AltText == "" {
			return agentReport{}, errors.New("generated visual requires artifact, title, and alt_text")
		}
	}
	report.Evidence = sanitizeEvidence(report.Evidence, incident.ID, channelID, sourceInput, s.now())
	report.Coverage = sanitizeCoverage(report.Coverage, incident.ID, channelID, sourceInput, s.now())
	report.Memory = sanitizeMemory(report.Memory)
	for index := range report.Evidence {
		item := &report.Evidence[index]
		item.ClaimID = s.cleanStructuredField(item.ClaimID, 120)
		item.Claim = s.cleanStructuredField(item.Claim, 1000)
		item.Observation = s.cleanStructuredField(item.Observation, 2000)
		item.Relation = s.cleanStructuredField(item.Relation, 20)
		item.SourceType = s.cleanStructuredField(item.SourceType, 80)
		item.SourceID = s.cleanStructuredField(item.SourceID, 240)
		item.SourceName = s.cleanStructuredField(item.SourceName, 200)
		item.Target = s.cleanStructuredField(item.Target, 300)
		item.Freshness = s.cleanStructuredField(item.Freshness, 120)
		item.Confidence = s.cleanStructuredField(item.Confidence, 40)
		item.Metadata = s.cleanStructuredMetadata(item.Metadata)
		item.Dimensions = s.cleanStructuredMetadata(item.Dimensions)
	}
	for index := range report.Coverage {
		item := &report.Coverage[index]
		item.Layer = s.cleanStructuredField(item.Layer, 100)
		item.Status = s.cleanStructuredField(item.Status, 40)
		item.Source = s.cleanStructuredField(item.Source, 200)
		item.Detail = s.cleanStructuredField(item.Detail, 1000)
		item.ClaimIDs = s.cleanStructuredStrings(item.ClaimIDs, 20, 120)
	}
	report.Memory.Goal = s.cleanStructuredField(report.Memory.Goal, 1000)
	report.Memory.ChannelPurpose = s.cleanStructuredField(
		report.Memory.ChannelPurpose, 500,
	)
	report.Memory.SituationSummary = s.cleanStructuredField(
		report.Memory.SituationSummary, 1000,
	)
	report.Memory.ActiveTopics = s.cleanStructuredStrings(
		report.Memory.ActiveTopics, 12, 240,
	)
	report.Memory.OpenLoops = s.cleanStructuredStrings(
		report.Memory.OpenLoops, 20, 400,
	)
	report.Memory.Topology = s.cleanStructuredStrings(report.Memory.Topology, 30, 400)
	report.Memory.Decisions = s.cleanStructuredStrings(report.Memory.Decisions, 30, 400)
	report.Memory.UnresolvedQuestions = s.cleanStructuredStrings(
		report.Memory.UnresolvedQuestions, 30, 400,
	)
	report.Memory.EvidenceRefs = s.cleanStructuredStrings(
		report.Memory.EvidenceRefs, 50, 120,
	)
	for index := range report.Memory.Knowledge {
		item := &report.Memory.Knowledge[index]
		item.Subject = s.cleanStructuredField(item.Subject, 160)
		item.Statement = s.cleanStructuredField(item.Statement, 600)
		item.SourceRef = s.cleanStructuredField(item.SourceRef, 500)
		item.SourceMessageTS = s.cleanStructuredField(item.SourceMessageTS, 32)
	}
	report.Memory.Knowledge = recall.SanitizeKnowledge(report.Memory.Knowledge)
	if report.MemoryOffer != nil {
		report.MemoryOffer.Scope = s.cleanStructuredField(report.MemoryOffer.Scope, 20)
		report.MemoryOffer.Repository = s.cleanStructuredField(
			report.MemoryOffer.Repository, 63,
		)
		report.MemoryOffer.Subject = s.cleanStructuredField(report.MemoryOffer.Subject, 200)
		report.MemoryOffer.Predicate = s.cleanStructuredField(report.MemoryOffer.Predicate, 80)
		report.MemoryOffer.Value = s.cleanStructuredField(report.MemoryOffer.Value, 1000)
		report.MemoryOffer.Visibility = s.cleanStructuredField(
			report.MemoryOffer.Visibility, 20,
		)
		report.MemoryOffer.ExpiresIn = s.cleanStructuredField(report.MemoryOffer.ExpiresIn, 20)
		report.MemoryOffer.SourceRevision = s.cleanStructuredField(
			report.MemoryOffer.SourceRevision, 200,
		)
	}
	if report.PreferenceOffer != nil {
		report.PreferenceOffer.Scope = s.cleanStructuredField(
			report.PreferenceOffer.Scope, 20,
		)
		report.PreferenceOffer.Repository = s.cleanStructuredField(
			report.PreferenceOffer.Repository, 63,
		)
		report.PreferenceOffer.Name = s.cleanStructuredField(
			report.PreferenceOffer.Name, 80,
		)
		report.PreferenceOffer.Value = s.cleanStructuredField(
			report.PreferenceOffer.Value, 80,
		)
		report.PreferenceOffer.ExpiresIn = s.cleanStructuredField(
			report.PreferenceOffer.ExpiresIn, 20,
		)
	}
	if report.RuleOffer != nil {
		report.RuleOffer.Scope = s.cleanStructuredField(report.RuleOffer.Scope, 20)
		report.RuleOffer.Repository = s.cleanStructuredField(
			report.RuleOffer.Repository, 63,
		)
		report.RuleOffer.Trigger = s.cleanStructuredField(report.RuleOffer.Trigger, 80)
		report.RuleOffer.Action = s.cleanStructuredField(report.RuleOffer.Action, 80)
		report.RuleOffer.SourceKind = s.cleanStructuredField(
			report.RuleOffer.SourceKind, 20,
		)
		report.RuleOffer.ExpiresIn = s.cleanStructuredField(
			report.RuleOffer.ExpiresIn, 20,
		)
	}
	if report.ScheduleOffer != nil {
		report.ScheduleOffer.Title = s.cleanStructuredField(report.ScheduleOffer.Title, 160)
		report.ScheduleOffer.Prompt = s.cleanStructuredField(report.ScheduleOffer.Prompt, 1200)
		report.ScheduleOffer.Repository = s.cleanStructuredField(report.ScheduleOffer.Repository, 63)
		report.ScheduleOffer.DeliveryChannel = s.cleanStructuredField(report.ScheduleOffer.DeliveryChannel, 64)
		report.ScheduleOffer.Recurrence = s.cleanStructuredField(report.ScheduleOffer.Recurrence, 20)
		report.ScheduleOffer.StartAt = s.cleanStructuredField(report.ScheduleOffer.StartAt, 40)
		report.ScheduleOffer.LocalTime = s.cleanStructuredField(report.ScheduleOffer.LocalTime, 5)
		report.ScheduleOffer.Timezone = s.cleanStructuredField(report.ScheduleOffer.Timezone, 100)
		report.ScheduleOffer.CatchUp = s.cleanStructuredField(report.ScheduleOffer.CatchUp, 10)
		report.ScheduleOffer.ExpiresIn = s.cleanStructuredField(report.ScheduleOffer.ExpiresIn, 20)
		if len(report.ScheduleOffer.Weekdays) > 7 {
			return agentReport{}, errors.New("schedule offer has too many weekdays")
		}
	}
	if report.PendingApproval != nil {
		report.PendingApproval = s.prepareEmisarApproval(
			*report.PendingApproval,
			incident,
			channelID,
			sourceInput,
			requestedBy,
		)
	}

	evidence, err := s.store.RecordEvidence(ctx, report.Evidence)
	if err != nil {
		return agentReport{}, err
	}
	report.Evidence = evidence
	if err := s.store.RecordCoverage(ctx, report.Coverage); err != nil {
		return agentReport{}, err
	}
	if sourceInput != "" {
		episode, episodeErr := s.store.GetWorkEpisodeBySource(ctx, sourceInput)
		if episodeErr == nil {
			ledgerEvidence, listErr := s.store.ListEpisodeEvidence(ctx, episode.ID, 200)
			if listErr != nil {
				return agentReport{}, listErr
			}
			ledgerCoverage, listErr := s.store.ListEpisodeCoverage(ctx, episode.ID, 200)
			if listErr != nil {
				return agentReport{}, listErr
			}
			ledger := investigation.BuildLedger(
				investigation.Compile(episode), ledgerEvidence, ledgerCoverage, s.now().UTC(),
			)
			if err := s.store.RecordClaimAssessments(
				ctx, ledger.Assessments(episode.ID, s.now().UTC()),
			); err != nil {
				return agentReport{}, err
			}
		} else if !errors.Is(episodeErr, store.ErrNotFound) {
			return agentReport{}, episodeErr
		}
	}
	if incident.ID != "" {
		proposals, err := s.prepareActionProposals(
			report.Proposals, incident, sourceInput, requestedBy,
		)
		if err != nil {
			return agentReport{}, err
		}
		report.Proposals, err = s.store.CreateActionProposals(ctx, proposals)
		if err != nil {
			return agentReport{}, err
		}
	} else {
		report.Proposals = nil
	}
	if report.PendingApproval != nil {
		approval, _, err := s.store.RecordEmisarApproval(ctx, *report.PendingApproval)
		if err != nil {
			return agentReport{}, err
		}
		report.PendingApproval = &approval
		s.audit(ctx, core.AuditEvent{
			IncidentID: incident.ID,
			Kind:       "emisar.approval.pending",
			ActorID:    requestedBy,
			ObjectID:   approval.RequestID,
			Outcome:    approval.Status,
			Detail:     approval.ActionID + " runner=" + approval.RunnerRef,
		})
	}
	return report, nil
}

func sanitizeEvidence(
	items []core.Evidence,
	incidentID string,
	channelID string,
	sourceInput string,
	now time.Time,
) []core.Evidence {
	result := make([]core.Evidence, 0, min(len(items), 50))
	for _, item := range items[:min(len(items), 50)] {
		item.IncidentID = incidentID
		item.ChannelID = channelID
		item.SourceInput = sourceInput
		item.ClaimID = boundedField(item.ClaimID, 120)
		item.Claim = boundedField(item.Claim, 1000)
		item.Observation = boundedField(item.Observation, 2000)
		item.Relation = strings.ToLower(boundedField(item.Relation, 20))
		if item.Relation == "" {
			item.Relation = "supports"
		}
		item.HealthEffect = strings.ToLower(boundedField(item.HealthEffect, 20))
		if item.HealthEffect == "" {
			item.HealthEffect = "none"
		}
		if !validEvidenceHealthEffect(item.HealthEffect) {
			item.HealthEffect = "unknown"
		}
		item.SourceType = boundedField(item.SourceType, 80)
		item.SourceName = boundedField(item.SourceName, 200)
		item.Target = boundedField(item.Target, 300)
		item.ScopeNote = boundedField(item.ScopeNote, 1000)
		item.Freshness = boundedField(item.Freshness, 120)
		item.Confidence = boundedField(item.Confidence, 40)
		item.SourceURL = safeEvidenceURL(item.SourceURL)
		item.Metadata = boundedMetadata(item.Metadata)
		item.Dimensions = boundedMetadata(item.Dimensions)
		if !validEvidenceSourceType(item.SourceType) {
			item.SourceType = "other"
		}
		if !validConfidence(item.Confidence) {
			item.Confidence = ""
		}
		if item.ObservedAt.After(now.Add(5 * time.Minute)) {
			item.ObservedAt = time.Time{}
		}
		if (item.ClaimID == "" && item.Claim == "") ||
			(item.Observation == "" && len(item.Dimensions) == 0) ||
			item.SourceType == "" || item.SourceName == "" {
			continue
		}
		result = append(result, item)
	}
	return result
}

func validEvidenceHealthEffect(value string) bool {
	switch value {
	case "none", "risk", "degraded", "unhealthy", "unknown":
		return true
	default:
		return false
	}
}

func sanitizeCoverage(
	items []core.Coverage,
	incidentID string,
	channelID string,
	sourceInput string,
	now time.Time,
) []core.Coverage {
	result := make([]core.Coverage, 0, min(len(items), 30))
	for _, item := range items[:min(len(items), 30)] {
		item.IncidentID = incidentID
		item.ChannelID = channelID
		item.SourceInput = sourceInput
		item.Layer = boundedField(item.Layer, 100)
		item.Status = boundedField(item.Status, 40)
		item.Source = boundedField(item.Source, 200)
		item.Detail = boundedField(item.Detail, 1000)
		item.ClaimIDs = boundedUniqueFields(item.ClaimIDs, 20, 120)
		if !validCoverageLayer(item.Layer) || !validCoverageStatus(item.Status) {
			continue
		}
		if item.ObservedAt.After(now.Add(5 * time.Minute)) {
			item.ObservedAt = time.Time{}
		}
		if item.Layer == "" || item.Status == "" {
			continue
		}
		result = append(result, item)
	}
	return result
}

func boundedUniqueFields(values []string, limit int, bound int) []string {
	result := make([]string, 0, min(len(values), limit))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = boundedField(value, bound)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
		if len(result) == limit {
			break
		}
	}
	return result
}

func validEvidenceSourceType(value string) bool {
	switch value {
	case "repository", "emisar", "monitoring", "slack", "other":
		return true
	default:
		return false
	}
}

func validConfidence(value string) bool {
	switch value {
	case "", "high", "medium", "low":
		return true
	default:
		return false
	}
}

func validCoverageLayer(value string) bool {
	return investigation.ValidCoverageLayer(value)
}

func validCoverageStatus(value string) bool {
	switch value {
	case "healthy", "degraded", "unhealthy", "unknown", "not_applicable":
		return true
	default:
		return false
	}
}

func sanitizeMemory(memory core.AgentMemory) core.AgentMemory {
	memory.Goal = boundedField(memory.Goal, 1000)
	memory.ChannelPurpose = boundedField(memory.ChannelPurpose, 500)
	memory.SituationSummary = boundedField(memory.SituationSummary, 1000)
	memory.ActiveTopics = boundedStrings(memory.ActiveTopics, 12, 240)
	memory.OpenLoops = boundedStrings(memory.OpenLoops, 20, 400)
	memory.Topology = boundedStrings(memory.Topology, 30, 400)
	memory.Decisions = boundedStrings(memory.Decisions, 30, 400)
	memory.UnresolvedQuestions = boundedStrings(memory.UnresolvedQuestions, 30, 400)
	memory.EvidenceRefs = boundedStrings(memory.EvidenceRefs, 50, 120)
	memory.Knowledge = recall.SanitizeKnowledge(memory.Knowledge)
	return memory
}

func (s *Service) prepareActionProposals(
	items []core.ActionProposal,
	incident core.Incident,
	sourceInput string,
	requestedBy string,
) ([]core.ActionProposal, error) {
	result := make([]core.ActionProposal, 0, min(len(items), 10))
	for _, item := range items[:min(len(items), 10)] {
		policy, ok := s.cfg.Actions[item.ActionName]
		if !ok {
			s.log.Warn(
				"drop unconfigured agent action proposal",
				"incident", incident.ID,
				"action", item.ActionName,
			)
			continue
		}
		if item.Authority != "" && item.Authority != policy.Authority {
			return nil, fmt.Errorf(
				"proposal %q authority %q does not match configured authority %q",
				item.ActionName, item.Authority, policy.Authority,
			)
		}
		item.IncidentID = incident.ID
		item.ChannelID = incident.ChannelID
		item.SourceInput = sourceInput
		item.RequestedBy = requestedBy
		item.Authority = policy.Authority
		item.Risk = policy.Risk
		item.Required = 1
		if policy.Approval == "two_person" {
			item.Required = 2
		}
		item.ExpiresAt = s.now().UTC().Add(policy.ExpiresAfter.Duration)
		item.Title = boundedField(item.Title, 200)
		item.Summary = boundedField(item.Summary, 1000)
		item.Target = boundedField(item.Target, 300)
		item.BlastRadius = boundedField(item.BlastRadius, 1000)
		item.Rollback = boundedField(item.Rollback, 1000)
		item.Verification = boundedField(item.Verification, 1000)
		item.Parameters = boundedMetadata(item.Parameters)
		item.Title = s.cleanStructuredField(item.Title, 200)
		item.Summary = s.cleanStructuredField(item.Summary, 1000)
		item.Target = s.cleanStructuredField(item.Target, 300)
		item.BlastRadius = s.cleanStructuredField(item.BlastRadius, 1000)
		item.Rollback = s.cleanStructuredField(item.Rollback, 1000)
		item.Verification = s.cleanStructuredField(item.Verification, 1000)
		item.Parameters = s.cleanStructuredMetadata(item.Parameters)
		if item.Title == "" || item.Summary == "" || item.Target == "" ||
			item.BlastRadius == "" || item.Rollback == "" || item.Verification == "" {
			continue
		}
		result = append(result, item)
	}
	return result, nil
}

func (s *Service) prepareEmisarApproval(
	item core.EmisarApproval,
	incident core.Incident,
	channelID string,
	sourceInput string,
	requestedBy string,
) *core.EmisarApproval {
	item.RequestID = s.cleanStructuredField(item.RequestID, 80)
	item.RunID = s.cleanStructuredField(item.RunID, 200)
	item.OperationID = s.cleanStructuredField(item.OperationID, 200)
	item.ActionID = s.cleanStructuredField(item.ActionID, 200)
	item.PackRef = s.cleanStructuredField(item.PackRef, 300)
	item.RunnerRef = s.cleanStructuredField(item.RunnerRef, 300)
	item.Status = s.cleanStructuredField(item.Status, 40)
	item.ApprovalURL = safeEmisarApprovalURL(
		item.ApprovalURL,
		s.cfg.Coop.EmisarURL,
		item.RequestID,
	)
	if channelID == "" || requestedBy == "" || !s.cfg.IsOperator(requestedBy) ||
		item.RequestID == "" || item.RunID == "" || item.OperationID == "" ||
		item.ActionID == "" || item.PackRef == "" || item.RunnerRef == "" ||
		item.Status != "pending_approval" || item.ApprovalURL == "" ||
		item.ExpiresAt.IsZero() || !item.ExpiresAt.After(s.now().UTC()) {
		s.log.Warn(
			"drop invalid or unauthorized Emisar pending approval",
			"incident", incident.ID,
			"request", item.RequestID,
			"run", item.RunID,
		)
		return nil
	}
	item.IncidentID = incident.ID
	item.ChannelID = channelID
	item.SourceInput = sourceInput
	item.RequestedBy = requestedBy
	return &item
}

func (s *Service) cleanStructuredField(value string, limit int) string {
	value = s.sanitizeText(value)
	return boundedField(value, limit)
}

func (s *Service) cleanStructuredStrings(
	values []string,
	limit int,
	fieldLimit int,
) []string {
	result := make([]string, 0, min(len(values), limit))
	for _, value := range values[:min(len(values), limit)] {
		if value = s.cleanStructuredField(value, fieldLimit); value != "" {
			result = append(result, value)
		}
	}
	return result
}

func (s *Service) cleanStructuredMetadata(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string)
	for key, value := range values {
		if len(result) >= 30 {
			break
		}
		key = s.cleanStructuredField(key, 100)
		value = s.cleanStructuredField(value, 1000)
		if key != "" {
			result[key] = value
		}
	}
	return result
}

func boundedField(value string, limit int) string {
	return core.BoundedText(value, limit)
}

func boundedStrings(values []string, limit int, fieldLimit int) []string {
	result := make([]string, 0, min(len(values), limit))
	for _, value := range values[:min(len(values), limit)] {
		if value = boundedField(value, fieldLimit); value != "" {
			result = append(result, value)
		}
	}
	return result
}

func boundedMetadata(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string)
	count := 0
	for key, value := range values {
		if count >= 30 {
			break
		}
		key = boundedField(key, 100)
		value = boundedField(value, 1000)
		if key != "" {
			result[key] = value
			count++
		}
	}
	return result
}

func safeEvidenceURL(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return ""
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String()
}

func safeEmisarApprovalURL(value, emisarRPCURL, requestID string) string {
	value = strings.TrimSpace(value)
	requestID = strings.TrimSpace(requestID)
	approval, err := url.Parse(value)
	if err != nil || approval.Scheme != "https" || approval.Host == "" ||
		approval.User != nil || approval.RawQuery != "" || approval.Fragment != "" ||
		requestID == "" {
		return ""
	}
	rpc, err := url.Parse(strings.TrimSpace(emisarRPCURL))
	if err != nil || rpc.Scheme != "https" || rpc.Host == "" || rpc.User != nil ||
		!strings.EqualFold(approval.Scheme, rpc.Scheme) ||
		!strings.EqualFold(approval.Host, rpc.Host) {
		return ""
	}
	path := strings.TrimRight(approval.EscapedPath(), "/")
	if !strings.HasPrefix(path, "/app/") ||
		!strings.Contains(path, "/approvals/") ||
		!strings.HasSuffix(path, "/"+url.PathEscape(requestID)) {
		return ""
	}
	return approval.String()
}

func structuredResponseInstructions() string {
	return `Return exactly one JSON object and no code fence: {"operations": [...]}

` + investigation.ResultOperationsPrompt() + `

Evidence requires claim_id when it satisfies a contract claim, claim, observation, source_type,
source_name, relation=supports|contradicts, dimensions, observed_at when known, freshness, and
confidence. Coverage requires layer, status, source, detail, observed_at when known, and claim_ids.
Never invent a source, evidence, timestamp, action, target, approval, or outcome. The complete_episode
message uses concise Slack-supported standard Markdown and leads with the decision. A pending Emisar
approval belongs in request_approval with the exact approval.url. Do not place the approval URL in message;
Responder validates and renders it. Generated visuals reference only artifacts created in the
exact Coop output directory; never inline bytes, base64, data URLs, or local paths.

` + behaviorOfferPolicy
}

func (s *Service) structuredResponsePolicy() string {
	var catalog strings.Builder
	catalog.WriteString("\n\nConfigured action proposal catalog:\n")
	if len(s.cfg.Actions) == 0 {
		catalog.WriteString("- No actions are configured. Return an empty proposals array.")
		return structuredResponseInstructions() + catalog.String()
	}
	names := make([]string, 0, len(s.cfg.Actions))
	for name := range s.cfg.Actions {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		action := s.cfg.Actions[name]
		fmt.Fprintf(
			&catalog,
			"- `%s`: %s Authority: %s. Risk: %s. Approval: %s.\n",
			name,
			strings.TrimSpace(action.Description),
			action.Authority,
			action.Risk,
			action.Approval,
		)
	}
	catalog.WriteString(
		"Proposals are inert suggestions. Responder validates them against this exact catalog, " +
			"and Emisar remains authoritative for policy and approval.",
	)
	return structuredResponseInstructions() + catalog.String()
}

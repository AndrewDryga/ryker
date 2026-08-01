package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
)

type agentReport struct {
	Message         string                `json:"message"`
	Evidence        []core.Evidence       `json:"evidence,omitempty"`
	Coverage        []core.Coverage       `json:"coverage,omitempty"`
	Memory          core.AgentMemory      `json:"memory,omitempty"`
	MemoryOffer     *core.MemoryOffer     `json:"memory_offer,omitempty"`
	PreferenceOffer *core.PreferenceOffer `json:"preference_offer,omitempty"`
	RuleOffer       *core.RuleOffer       `json:"rule_offer,omitempty"`
	PendingApproval *core.EmisarApproval  `json:"pending_approval,omitempty"`
	Proposals       []core.ActionProposal `json:"proposals,omitempty"`
}

func parseAgentReport(message string) (agentReport, bool, error) {
	trimmed := strings.TrimSpace(message)
	if trimmed == "" {
		return agentReport{}, false, errors.New("agent response is empty")
	}
	if strings.HasPrefix(trimmed, "{") {
		report, err := decodeAgentReport(trimmed)
		if err == nil {
			return report, true, nil
		}
		if recovered, recoverErr := decodeAgentMessage(trimmed); recoverErr == nil {
			return agentReport{Message: recovered}, false, nil
		}
		return agentReport{}, true, err
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

func decodeAgentReport(message string) (agentReport, error) {
	normalized, err := normalizeEmptyStructuredTimestamps(message)
	if err != nil {
		return agentReport{}, fmt.Errorf("decode structured agent response: %w", err)
	}
	var report agentReport
	if err := decodeStrictJSON(normalized, &report); err != nil {
		return agentReport{}, fmt.Errorf("decode structured agent response: %w", err)
	}
	if strings.TrimSpace(report.Message) == "" {
		return agentReport{}, errors.New("structured agent response has no message")
	}
	offerCount := 0
	for _, present := range []bool{
		report.MemoryOffer != nil,
		report.PreferenceOffer != nil,
		report.RuleOffer != nil,
	} {
		if present {
			offerCount++
		}
	}
	if offerCount > 1 {
		return agentReport{}, errors.New(
			"structured agent response has multiple durable behavior offers",
		)
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
	} else {
		report.Message = boundedField(report.Message, 30000)
	}
	if report.MemoryOffer != nil || report.PreferenceOffer != nil || report.RuleOffer != nil {
		// Configuration requests are not operational findings. Keeping model-produced
		// evidence here makes a confirmation card look as if its behavior was already saved.
		report.Evidence = nil
		report.Coverage = nil
	}
	report.Evidence = sanitizeEvidence(report.Evidence, incident.ID, channelID, sourceInput)
	report.Coverage = sanitizeCoverage(report.Coverage, incident.ID, channelID, sourceInput)
	report.Memory = sanitizeMemory(report.Memory)
	for index := range report.Evidence {
		item := &report.Evidence[index]
		item.Claim = s.cleanStructuredField(item.Claim, 1000)
		item.Observation = s.cleanStructuredField(item.Observation, 2000)
		item.SourceType = s.cleanStructuredField(item.SourceType, 80)
		item.SourceName = s.cleanStructuredField(item.SourceName, 200)
		item.Target = s.cleanStructuredField(item.Target, 300)
		item.Freshness = s.cleanStructuredField(item.Freshness, 120)
		item.Confidence = s.cleanStructuredField(item.Confidence, 40)
		item.Metadata = s.cleanStructuredMetadata(item.Metadata)
	}
	for index := range report.Coverage {
		item := &report.Coverage[index]
		item.Layer = s.cleanStructuredField(item.Layer, 100)
		item.Status = s.cleanStructuredField(item.Status, 40)
		item.Source = s.cleanStructuredField(item.Source, 200)
		item.Detail = s.cleanStructuredField(item.Detail, 1000)
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
	if report.PendingApproval != nil {
		report.PendingApproval = s.prepareEmisarApproval(
			*report.PendingApproval,
			incident,
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
		approval, created, err := s.store.RecordEmisarApproval(ctx, *report.PendingApproval)
		if err != nil {
			return agentReport{}, err
		}
		report.PendingApproval = &approval
		_ = s.store.Audit(ctx, core.AuditEvent{
			IncidentID: incident.ID,
			Kind:       "emisar.approval.pending",
			ActorID:    requestedBy,
			ObjectID:   approval.RequestID,
			Outcome:    approval.Status,
			Detail:     approval.ActionID + " runner=" + approval.RunnerRef,
		})
		if created {
			_ = s.store.RecordTimeline(ctx, core.TimelineEvent{
				IncidentID: incident.ID,
				ChannelID:  incident.ChannelID,
				Kind:       "emisar.approval.pending",
				ActorID:    requestedBy,
				Title:      "Emisar approval required",
				Detail:     approval.ActionID + " for " + approval.RunnerRef,
			})
		}
	}
	return report, nil
}

func sanitizeEvidence(
	items []core.Evidence,
	incidentID string,
	channelID string,
	sourceInput string,
) []core.Evidence {
	result := make([]core.Evidence, 0, min(len(items), 50))
	for _, item := range items[:min(len(items), 50)] {
		item.IncidentID = incidentID
		item.ChannelID = channelID
		item.SourceInput = sourceInput
		item.Claim = boundedField(item.Claim, 1000)
		item.Observation = boundedField(item.Observation, 2000)
		item.SourceType = boundedField(item.SourceType, 80)
		item.SourceName = boundedField(item.SourceName, 200)
		item.Target = boundedField(item.Target, 300)
		item.Freshness = boundedField(item.Freshness, 120)
		item.Confidence = boundedField(item.Confidence, 40)
		item.SourceURL = safeEvidenceURL(item.SourceURL)
		item.Metadata = boundedMetadata(item.Metadata)
		if !validEvidenceSourceType(item.SourceType) {
			item.SourceType = "other"
		}
		if !validConfidence(item.Confidence) {
			item.Confidence = ""
		}
		if item.ObservedAt.After(time.Now().Add(5 * time.Minute)) {
			item.ObservedAt = time.Time{}
		}
		if item.Claim == "" || item.Observation == "" ||
			item.SourceType == "" || item.SourceName == "" {
			continue
		}
		result = append(result, item)
	}
	return result
}

func sanitizeCoverage(
	items []core.Coverage,
	incidentID string,
	channelID string,
	sourceInput string,
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
		if !validCoverageLayer(item.Layer) || !validCoverageStatus(item.Status) {
			continue
		}
		if item.ObservedAt.After(time.Now().Add(5 * time.Minute)) {
			item.ObservedAt = time.Time{}
		}
		if item.Layer == "" || item.Status == "" {
			continue
		}
		result = append(result, item)
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
	switch value {
	case "hardware", "host", "runtime", "scheduler", "workload",
		"dependency", "application", "slo", "change":
		return true
	default:
		return false
	}
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
		item.ExpiresAt = time.Now().UTC().Add(policy.ExpiresAfter.Duration)
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
	if incident.ID == "" || requestedBy == "" || !s.cfg.IsOperator(requestedBy) ||
		item.RequestID == "" || item.RunID == "" || item.OperationID == "" ||
		item.ActionID == "" || item.PackRef == "" || item.RunnerRef == "" ||
		item.Status != "pending_approval" || item.ApprovalURL == "" ||
		item.ExpiresAt.IsZero() || !item.ExpiresAt.After(time.Now().UTC()) {
		s.log.Warn(
			"drop invalid or unauthorized Emisar pending approval",
			"incident", incident.ID,
			"request", item.RequestID,
			"run", item.RunID,
		)
		return nil
	}
	item.IncidentID = incident.ID
	item.ChannelID = incident.ChannelID
	item.SourceInput = sourceInput
	return &item
}

func (s *Service) cleanStructuredField(value string, limit int) string {
	if s.sanitizer != nil {
		value = s.sanitizer.Text(value)
	}
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
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}
	value = value[:limit]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return strings.TrimSpace(value)
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
	return `Return exactly one JSON object and no code fence:
{
  "message": "plain-language, operator-facing standard Markdown that answers the question first",
  "evidence": [{
    "claim": "the operational claim this supports",
    "observation": "the exact verified observation",
    "source_type": "repository|emisar|monitoring|slack|other",
    "source_name": "specific tool, file, action, or system",
    "source_url": "optional https URL without credentials",
    "target": "specific entity",
    "observed_at": "RFC3339 timestamp; omit this field when unknown",
    "freshness": "why this is current enough",
    "confidence": "high|medium|low"
  }],
  "coverage": [{
    "layer": "hardware|host|runtime|scheduler|workload|dependency|application|slo|change",
    "status": "healthy|degraded|unhealthy|unknown|not_applicable",
    "source": "evidence source",
    "detail": "what was checked or why it remains unknown",
    "observed_at": "RFC3339 timestamp; omit this field when unknown"
  }],
  "memory": {
    "goal": "current user goal",
    "channel_purpose": "stable role of this Slack channel when known",
    "situation_summary": "short current shared situation",
    "active_topics": ["topic still active in the conversation"],
    "open_loops": ["unfinished question, promise, approval, or follow-up"],
    "topology": ["durable declared or verified topology fact"],
    "decisions": ["durable decision or correction"],
    "unresolved_questions": ["important open question"],
    "evidence_refs": ["stable evidence source name or identifier"]
  },
  "memory_offer": {
    "scope": "channel|workspace|repository",
    "repository": "exact configured repository key when scope is repository",
    "subject": "canonical source ID, except a normalized human alias for alias_of",
    "predicate": "alias_of|repository_for_channel|evidence_route|entity_relationship_correction|guidance",
    "value": "validated canonical value, or self-contained operator advice for guidance",
    "visibility": "channel|workspace|operator",
    "expires_in": "7d|30d|90d|365d",
    "source_revision": "optional immutable repository revision"
  },
  "preference_offer": {
    "scope": "operator|channel|repository|workspace",
    "repository": "exact configured repository key when scope is repository",
    "name": "health_check_depth|response_detail|response_location",
    "value": "typed value from the supported preference catalog",
    "expires_in": "7d|30d|90d|365d"
  },
  "rule_offer": {
    "scope": "channel",
    "repository": "exact configured repository key",
    "trigger": "terraform_plan|deployment|operational_alert",
    "action": "review_terraform_plan|verify_deployment|triage_alert",
    "source_kind": "any|human|app",
    "expires_in": "7d|30d|90d|365d"
  },
  "pending_approval": {
    "request_id": "exact approval.request_id returned by Emisar",
    "run_id": "exact run_id returned by Emisar",
    "operation_id": "exact operation_id returned by Emisar",
    "action_id": "exact action_id returned by Emisar",
    "pack_ref": "exact immutable pack_ref returned by Emisar",
    "runner_ref": "exact immutable runner_ref returned by Emisar",
    "status": "pending_approval",
    "approval_url": "exact approval.url returned by Emisar",
    "expires_at": "exact RFC3339 approval.expires_at returned by Emisar"
  },
  "proposals": [{
    "action_name": "one configured action name only",
    "title": "plain-language proposed action",
    "summary": "why it is justified",
    "target": "exact target",
    "parameters": {"name": "value"},
    "blast_radius": "what could be affected",
    "rollback": "how to reverse it",
    "verification": "how success will be verified",
    "authority": "emisar",
    "risk": "low|medium|high"
  }]
}
Omit memory_offer unless the current configured operator explicitly asked Responder to remember,
save, or correct durable context, or clearly requested lasting guidance with language such as
"from now on", "always", or "keep this in mind". A memory offer is inert until the host displays an
exact confirmation and an operator clicks it. For open-ended collaboration advice that does not fit
the typed preference or standing-rule catalogs, use predicate guidance, a short stable normalized
topic in subject, and the user's self-contained advice in value. Use workspace scope with operator
visibility for a personal cross-channel memory, channel scope with channel visibility for a shared
channel convention, and workspace visibility only for an explicit team-wide request. Guidance can
steer future model turns but cannot trigger work, establish current health, grant credentials,
authorize incidents or changes, approve actions, or override the current request or host policy.
Never use memory_offer for secrets, credentials, approvals, or transient observations.

` + behaviorOfferPolicy + `

Return at most one of memory_offer, preference_offer, or rule_offer. Use an empty array when no evidence, coverage, or
action proposal exists. Omit pending_approval unless the latest exact Emisar run response has
status pending_approval and includes its approval object. Copy only the exact Emisar run and
approval fields into pending_approval; never infer, rewrite, or invent any identifier, URL, expiry,
target, approval, or successful outcome. Do not place the approval URL in message because
Responder validates and renders the control. A pending approval means nothing has executed.
Never invent a source, timestamp, action name, target, approval, or successful outcome. The message must lead with the
answer, distinguish declared configuration from live observation, state material coverage gaps,
and use Slack-supported standard Markdown: short headings, bullets, tables when comparison helps,
links, block quotes for quoted alert text, and fenced language-tagged code only for code or logs.`
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

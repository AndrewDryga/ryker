package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/recall"
	"github.com/AndrewDryga/responder/internal/store"
)

const ()

func executionDeliveryID(base, idempotencyKey string) string {
	if !strings.Contains(idempotencyKey, ":recovery_") {
		return base
	}
	digest := sha256.Sum256([]byte(idempotencyKey))
	return base + "_exec_" + hex.EncodeToString(digest[:8])
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

func (s *Service) recordResultProtocol(ctx context.Context, runID string, legacyShape bool) {
	if !legacyShape {
		return
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "result.legacy_shape", ActorID: "responder",
		ObjectID: runID, Outcome: "legacy_only",
	})
}

func (s *Service) persistAgentReport(
	ctx context.Context,
	report decisionpkg.AgentReport,
	incident core.Incident,
	channelID string,
	sourceInput string,
	requestedBy string,
) (decisionpkg.AgentReport, error) {
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
		report.Message = decisionpkg.BoundedField(report.Message, 30000)
		for index := range report.FollowupMessages {
			report.FollowupMessages[index] = decisionpkg.BoundedField(
				report.FollowupMessages[index],
				decisionpkg.MaxReplyPartBytes,
			)
		}
	}
	if report.MemoryOffer != nil || report.PreferenceOffer != nil || report.RuleOffer != nil ||
		report.ScheduleOffer != nil || len(report.ScheduleOffers) != 0 {
		// Configuration requests are not operational findings. Keeping model-produced
		// evidence here makes a confirmation card look as if its behavior was already saved.
		report.Evidence = nil
		report.Coverage = nil
		report.Visuals = nil
	}
	if len(report.Visuals) > s.cfg.Limits.MaxGeneratedVisuals {
		return decisionpkg.AgentReport{}, errors.New("structured agent response references too many generated visuals")
	}
	for index := range report.Visuals {
		report.Visuals[index].Artifact = s.cleanStructuredField(report.Visuals[index].Artifact, 255)
		report.Visuals[index].Title = s.cleanStructuredField(report.Visuals[index].Title, 200)
		report.Visuals[index].AltText = s.cleanStructuredField(report.Visuals[index].AltText, 1000)
		if report.Visuals[index].Artifact == "" || report.Visuals[index].Title == "" || report.Visuals[index].AltText == "" {
			return decisionpkg.AgentReport{}, errors.New("generated visual requires artifact, title, and alt_text")
		}
	}
	report.Evidence = decisionpkg.SanitizeEvidence(report.Evidence, incident.ID, channelID, sourceInput, s.now())
	report.Coverage = decisionpkg.SanitizeCoverage(report.Coverage, incident.ID, channelID, sourceInput, s.now())
	report.Memory = memorypkg.SanitizeMemory(report.Memory)
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
	for _, offer := range orderedScheduleOffers(report.ScheduleOffer, report.ScheduleOffers) {
		offer.Title = s.cleanStructuredField(offer.Title, 160)
		offer.Prompt = s.cleanStructuredField(offer.Prompt, 1200)
		offer.Repository = s.cleanStructuredField(offer.Repository, 63)
		offer.DeliveryChannel = s.cleanStructuredField(offer.DeliveryChannel, 64)
		offer.Recurrence = s.cleanStructuredField(offer.Recurrence, 20)
		offer.StartAt = s.cleanStructuredField(offer.StartAt, 40)
		offer.LocalTime = s.cleanStructuredField(offer.LocalTime, 5)
		offer.Timezone = s.cleanStructuredField(offer.Timezone, 100)
		offer.CatchUp = s.cleanStructuredField(offer.CatchUp, 10)
		offer.ExpiresIn = s.cleanStructuredField(offer.ExpiresIn, 20)
		if len(offer.Weekdays) > 7 {
			return decisionpkg.AgentReport{}, errors.New("schedule offer has too many weekdays")
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

	evidence, err := s.store.Intelligence.RecordEvidence(ctx, report.Evidence)
	if err != nil {
		return decisionpkg.AgentReport{}, err
	}
	report.Evidence = evidence
	if err := s.store.Intelligence.RecordCoverage(ctx, report.Coverage); err != nil {
		return decisionpkg.AgentReport{}, err
	}
	if sourceInput != "" {
		episode, episodeErr := s.store.GetWorkEpisodeBySource(ctx, sourceInput)
		if episodeErr == nil {
			ledgerEvidence, listErr := s.store.Intelligence.ListEpisodeEvidence(ctx, episode.ID, 200)
			if listErr != nil {
				return decisionpkg.AgentReport{}, listErr
			}
			ledgerCoverage, listErr := s.store.Intelligence.ListEpisodeCoverage(ctx, episode.ID, 200)
			if listErr != nil {
				return decisionpkg.AgentReport{}, listErr
			}
			ledger := investigation.BuildLedger(
				investigation.Compile(episode), ledgerEvidence, ledgerCoverage, s.now().UTC(),
			)
			if err := s.store.Intelligence.RecordClaimAssessments(
				ctx, ledger.Assessments(episode.ID, s.now().UTC()),
			); err != nil {
				return decisionpkg.AgentReport{}, err
			}
		} else if !errors.Is(episodeErr, store.ErrNotFound) {
			return decisionpkg.AgentReport{}, episodeErr
		}
	}
	if report.PendingApproval != nil {
		approval, _, err := s.store.RecordEmisarApproval(ctx, *report.PendingApproval)
		if err != nil {
			return decisionpkg.AgentReport{}, err
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
	return decisionpkg.BoundedField(value, limit)
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

` + offerContractPolicy + `

` + behaviorOfferPolicy
}

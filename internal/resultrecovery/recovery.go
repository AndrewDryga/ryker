// Package resultrecovery preserves independently valid ledger records when an
// unrelated operation makes a model result stream unreadable.
package resultrecovery

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/retrydelay"
)

// Records are the immutable episode-ledger rows a correction round retains.
type Records struct {
	Evidence []core.Evidence
	Coverage []core.Coverage
	Findings []investigation.FindingOperation
}

const (
	episodeEvidenceLimit = 30
	episodeCoverageLimit = 20
	// UnreadableAttemptLimit gives syntax and schema failures one repair turn.
	UnreadableAttemptLimit = 2
	// SemanticAttemptLimit also permits one stronger-model retry.
	SemanticAttemptLimit = 3
)

// EpisodeLedger is the bounded read surface needed to give prompting and
// validation the same episode evidence view.
type EpisodeLedger interface {
	ListEpisodeEvidence(context.Context, string, int) ([]core.Evidence, error)
	ListEpisodeCoverage(context.Context, string, int) ([]core.Coverage, error)
}

// EpisodeRecords reads the continuity ledger shown as historical context. It
// can inform a new investigation, but current-state and completion validators
// must still use the candidate run's own evidence.
func EpisodeRecords(ctx context.Context, ledger EpisodeLedger, episodeID string) (Records, error) {
	evidence, err := ledger.ListEpisodeEvidence(ctx, episodeID, episodeEvidenceLimit)
	if err != nil {
		return Records{}, err
	}
	coverage, err := ledger.ListEpisodeCoverage(ctx, episodeID, episodeCoverageLimit)
	if err != nil {
		return Records{}, err
	}
	return Records{Evidence: evidence, Coverage: coverage}, nil
}

// CorrectionSpent bounds both one run's correction attempts and the episode's
// accumulated corrections. A zero maximum preserves the historical one-shot
// behavior used by explicitly no-retry configurations.
func CorrectionSpent(attempt, episodeCorrections, maximum int) bool {
	return retrydelay.Exhausted(attempt, maximum) ||
		(maximum > 0 && episodeCorrections > maximum)
}

// ConsumeWatchCorrection advances the watch envelope before checking the same
// shared correction budget used by incident and engineering runs.
func ConsumeWatchCorrection(
	state *decisionpkg.WatchTurnState,
	episodeCorrections, maximum int,
) bool {
	state.StructuredCorrections++
	return CorrectionSpent(state.StructuredCorrections, episodeCorrections, maximum)
}

// RecoveredReply is the only part of a schema-invalid result that may cross
// the final fallback boundary. It deliberately carries no operations,
// completion claim, evidence, approval, offer, or lifecycle action.
type RecoveredReply struct {
	Message          string
	FollowupMessages []string
}

// ReplyFallbackAudit makes every answer-preserving fallback observable under
// one event shape, regardless of which result lane produced it.
func ReplyFallbackAudit(run core.AgentRun, outcome, detail string) core.AuditEvent {
	return core.AuditEvent{
		IncidentID: run.IncidentID, Kind: "result.reply_fallback",
		ObjectID: run.ID, Outcome: outcome, Detail: detail,
	}
}

// BlockedWatch builds the safe continuation used after the host exhausts a
// structured-result correction budget. It keeps prior ledger records but no
// unvalidated offers or lifecycle operations.
func BlockedWatch(
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	reason string,
	prior *decisionpkg.WatchDecision,
) decisionpkg.WatchDecision {
	decision := decisionpkg.WatchDecision{}
	if prior != nil {
		decision.Evidence = prior.Evidence
		decision.Coverage = prior.Coverage
		decision.Memory = prior.Memory
	}
	finalAttempt := state.RecheckAttempt >= 2
	if input.Kind == "bot_message" && !finalAttempt {
		decision.Action = "ignore"
	} else {
		decision.Action = "reply"
		decision.Message = "I couldn't finish this check safely yet. I saved the evidence and kept the investigation open for a clean retry."
	}
	completion := &investigation.CompletionAssessment{
		Status:       "blocked",
		Summary:      "The host could not validate the final structured result.",
		MaterialGaps: []string{decisionpkg.BoundedField(reason, 500)},
		BlockerKind:  "tool_failure",
		Attempts:     []string{"Responder validated the result and requested a corrected completion."},
		NextAction:   "Retry the same investigation from its saved evidence.",
	}
	if !finalAttempt {
		completion.Recheck = &investigation.RecheckDirective{
			Key: "structured:" + run.ID, Reason: "Retry structured completion after host validation.",
			AfterSeconds: 60, AdditionalAttempts: 2,
		}
	}
	decision.Completion = completion
	return decision
}

// BlockedAgent is the equivalent safe continuation for an incident or
// engineering task result.
func BlockedAgent(reason string, prior *decisionpkg.AgentReport) decisionpkg.AgentReport {
	report := decisionpkg.AgentReport{
		Message: "I couldn't finish this check safely yet. The evidence is saved in this task, so it can continue without starting over.",
		Completion: &investigation.CompletionAssessment{
			Status:       "blocked",
			Summary:      "The host could not validate the final structured result.",
			MaterialGaps: []string{decisionpkg.BoundedField(reason, 500)},
			BlockerKind:  "tool_failure",
			Attempts:     []string{"Responder validated the result and requested a corrected completion."},
			NextAction:   "Continue the same task from its saved evidence.",
		},
	}
	if prior != nil {
		report.Evidence = prior.Evidence
		report.Coverage = prior.Coverage
		report.Memory = prior.Memory
	}
	return report
}

// ReplyOnlyWatch delivers the one independently valid completion reply while
// retaining the blocked continuation and rejecting every other model field.
func ReplyOnlyWatch(
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	reason string,
	reply RecoveredReply,
) decisionpkg.WatchDecision {
	decision := BlockedWatch(run, input, state, reason, nil)
	decision.Action = "reply"
	decision.Message = reply.Message
	decision.FollowupMessages = reply.FollowupMessages
	return decision
}

// ReplyOnlyAgent delivers that same bounded fallback on the task lane.
func ReplyOnlyAgent(reason string, reply RecoveredReply) decisionpkg.AgentReport {
	report := BlockedAgent(reason, nil)
	report.Message = reply.Message
	report.FollowupMessages = reply.FollowupMessages
	return report
}

// SemanticWatch delivers a parsed reply after the semantic correction budget
// is spent. Non-reply decisions retain the ordinary silent blocked behavior.
func SemanticWatch(
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	reason string,
	decision decisionpkg.WatchDecision,
) (decisionpkg.WatchDecision, bool) {
	if decision.Action != "reply" || decision.Message == decisionpkg.NoConversationReply {
		return BlockedWatch(run, input, state, reason, &decision), false
	}
	blocked := BlockedWatch(run, input, state, reason, &decision)
	blocked.Action = "reply"
	blocked.Attention = decision.Attention
	blocked.Message = decision.Message
	blocked.FollowupMessages = decision.FollowupMessages
	return blocked, true
}

// SemanticAgent is the incident/task equivalent. DecodeAgentReport has already
// bounded this message before semantic validation begins.
func SemanticAgent(reason string, report decisionpkg.AgentReport) decisionpkg.AgentReport {
	blocked := BlockedAgent(reason, &report)
	blocked.Message = report.Message
	blocked.FollowupMessages = report.FollowupMessages
	return blocked
}

// CompletionReply extracts one bounded canonical completion message while
// ignoring unrelated malformed operations. Watch results must explicitly say
// reply; incident/task results must use the operation-only envelope.
func CompletionReply(message string, watch bool) (RecoveredReply, bool) {
	trimmed := strings.TrimSpace(message)
	if decisionpkg.RejectMultipleJSONObjects(trimmed) != nil {
		return RecoveredReply{}, false
	}
	start := strings.Index(trimmed, "{")
	if start < 0 {
		return RecoveredReply{}, false
	}
	object, err := decisionpkg.FirstJSONObject(trimmed[start:])
	if err != nil {
		return RecoveredReply{}, false
	}
	var envelope struct {
		Action     string            `json:"action"`
		Operations []json.RawMessage `json:"operations"`
	}
	if err := json.Unmarshal([]byte(object), &envelope); err != nil {
		return RecoveredReply{}, false
	}
	if watch && strings.TrimSpace(envelope.Action) != "reply" ||
		!watch && strings.TrimSpace(envelope.Action) != "" ||
		len(envelope.Operations) > decisionpkg.MaxResultOperations {
		return RecoveredReply{}, false
	}
	var recovered RecoveredReply
	completions := 0
	for _, raw := range envelope.Operations {
		var operation struct {
			Type       string          `json:"type"`
			Completion json.RawMessage `json:"completion"`
		}
		if json.Unmarshal(raw, &operation) != nil ||
			strings.TrimSpace(operation.Type) != "complete_episode" {
			continue
		}
		completions++
		var completion struct {
			Message          string   `json:"message"`
			FollowupMessages []string `json:"followup_messages"`
		}
		if json.Unmarshal(operation.Completion, &completion) != nil {
			return RecoveredReply{}, false
		}
		recovered.Message, recovered.FollowupMessages, err =
			decisionpkg.NormalizeReplySequence(
				completion.Message, completion.FollowupMessages,
			)
		if err != nil || recovered.Message == decisionpkg.NoConversationReply {
			return RecoveredReply{}, false
		}
	}
	return recovered, completions == 1
}

// Watch recovers valid records from an invalid watch result and merges them
// into the records already held by the run.
func Watch(message string, prior Records, now time.Time) Records {
	var result decisionpkg.WatchDecision
	if !decode(message, &result) {
		return prior
	}
	return merge(prior, recover(result.Operations), now)
}

// AgentReport recovers valid records from an invalid incident or engineering
// report. The complete result remains rejected; only ledger rows survive.
func AgentReport(message string, now time.Time) Records {
	var result decisionpkg.AgentReport
	if !decode(message, &result) {
		return Records{}
	}
	return merge(Records{}, recover(result.Operations), now)
}

func decode(message string, target any) bool {
	trimmed := strings.TrimSpace(message)
	if decisionpkg.RejectMultipleJSONObjects(trimmed) != nil {
		return false
	}
	start := strings.Index(trimmed, "{")
	if start < 0 {
		return false
	}
	object, err := decisionpkg.FirstJSONObject(trimmed[start:])
	if err != nil {
		return false
	}
	normalized, err := decisionpkg.NormalizeEmptyStructuredTimestamps(object)
	return err == nil && decisionpkg.DecodeStrictJSON(normalized, target) == nil
}

func recover(operations []investigation.ResultOperation) Records {
	if len(operations) > decisionpkg.MaxResultOperations {
		return Records{}
	}
	counts := make(map[string]int, len(operations))
	for _, operation := range operations {
		counts[strings.TrimSpace(operation.ID)]++
	}
	result := Records{}
	for _, operation := range operations {
		operation.ID = strings.TrimSpace(operation.ID)
		operation.Type = strings.TrimSpace(operation.Type)
		if operation.ID == "" || counts[operation.ID] != 1 || operation.Validate() != nil {
			continue
		}
		switch operation.Type {
		case "record_evidence":
			if investigation.ValidateEvidence(*operation.Evidence) != nil {
				continue
			}
			row := *operation.Evidence
			row.ID = operation.ID
			result.Evidence = append(result.Evidence, row)
		case "record_coverage":
			result.Coverage = append(result.Coverage, *operation.Coverage)
		case "record_finding":
			row := *operation.Finding
			row.ID = operation.ID
			if row.Key == "" {
				row.Key = investigation.FindingKeyForOperationID(operation.ID)
			}
			result.Findings = append(result.Findings, row)
		}
	}
	return result
}

func merge(prior, current Records, now time.Time) Records {
	return Records{
		Evidence: decisionpkg.CarryEvidence(prior.Evidence,
			decisionpkg.SanitizeEvidence(current.Evidence, "", "", "", now)),
		Coverage: decisionpkg.CarryCoverage(prior.Coverage,
			completionpolicy.CurrentCoverage(
				decisionpkg.SanitizeCoverage(current.Coverage, "", "", "", now), now)),
		Findings: decisionpkg.CarryFindings(prior.Findings,
			decisionpkg.SanitizeFindings(current.Findings)),
	}
}

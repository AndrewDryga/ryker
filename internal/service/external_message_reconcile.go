package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/lifecycle"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const workExternalMessageReconcile = "external_message_reconcile"

type externalLifecyclePhase = lifecycle.Phase

const (
	externalLifecycleUnknown    = lifecycle.Unknown
	externalLifecycleCreated    = lifecycle.Created
	externalLifecyclePlanning   = lifecycle.Planning
	externalLifecycleReviewable = lifecycle.Reviewable
	externalLifecycleApplying   = lifecycle.Applying
	externalLifecycleSucceeded  = lifecycle.Succeeded
	externalLifecycleFailed     = lifecycle.Failed
	externalLifecycleStopped    = lifecycle.Stopped
)

func shouldReconcileExternalMessage(text string) bool {
	return lifecycle.ShouldReconcile(text)
}

func externalMessageLifecyclePhase(text string) externalLifecyclePhase {
	return lifecycle.Classify(text)
}

// EnforceExternalLifecycleCommunication suppresses public narration of an
// external lifecycle that has not reached a state worth telling anyone about.
func EnforceExternalLifecycleCommunication(
	input core.SlackInput,
	decision decisionpkg.WatchDecision,
) decisionpkg.WatchDecision {
	if input.Kind == "recheck" && waitsForExternalKind(decision, "terraform_run") &&
		(decision.Completion == nil || decision.Completion.Verdict == "" ||
			decision.Completion.Verdict == "in_progress") {
		return decisionpkg.SuppressWatchDecision(
			decision,
			"host kept an unchanged Terraform wait quiet",
		)
	}
	if input.Kind != "bot_message" {
		return decision
	}
	phase := externalMessageLifecyclePhase(input.Text)
	switch phase {
	case externalLifecycleCreated, externalLifecyclePlanning:
		// Slack's Terraform integration can remain at Planning even after HCP has
		// produced a saved plan. A provider-backed review or terminal result is
		// useful; a paraphrase of the visible intermediate state is not.
		if decision.Completion != nil &&
			(decision.Completion.Status == "blocked" ||
				(decision.Completion.Verdict != "" &&
					decision.Completion.Verdict != "in_progress")) {
			return decision
		}
		decision.PublicationUpdates = nil
		return decisionpkg.SuppressWatchDecision(
			decision,
			"host correlated a non-actionable external lifecycle update without public narration",
		)
	case externalLifecycleApplying:
		return decisionpkg.SuppressWatchDecision(
			decision,
			"host correlated an in-progress external lifecycle update without public narration",
		)
	case externalLifecycleReviewable:
		if decision.Completion == nil || decision.Completion.Verdict == "" ||
			decision.Completion.Verdict == "in_progress" {
			return decisionpkg.SuppressWatchDecision(
				decision,
				"host suppressed a plan-status update without a completed material review",
			)
		}
	case externalLifecycleSucceeded:
		if !successfulExternalLifecycleReplyAddsValue(decision, time.Now().UTC()) {
			return decisionpkg.SuppressWatchDecision(
				decision,
				"host suppressed a successful lifecycle status that added no fresh runtime result",
			)
		}
	}
	return decision
}

// EnrichExternalLifecycleReply adds source-owned navigation only after every
// host renderer has finalized the public message. Adding it earlier allowed an
// operational scope render to replace the message and silently discard the
// exact Terraform approval target.
func EnrichExternalLifecycleReply(
	input core.SlackInput,
	decision decisionpkg.WatchDecision,
) decisionpkg.WatchDecision {
	if (input.Kind != "bot_message" && input.Kind != "recheck") || decision.Action != "reply" ||
		decision.Completion == nil || decision.Completion.Verdict != "needs_review" {
		return decision
	}
	return appendTerraformProviderURL(decision, lifecycle.CanonicalProviderURL(input.Text))
}

func appendTerraformProviderURL(
	decision decisionpkg.WatchDecision,
	providerURL string,
) decisionpkg.WatchDecision {
	if providerURL == "" || strings.Contains(decision.Message, providerURL) {
		return decision
	}
	decision.Message = strings.TrimSpace(decision.Message) +
		"\n\n[Review the Terraform run](" + providerURL + ")."
	for index := range decision.Operations {
		operation := &decision.Operations[index]
		if operation.Type == "complete_episode" && operation.Completion != nil {
			operation.Completion.Message = decision.Message
		}
	}
	return decision
}

func waitsForExternalKind(decision decisionpkg.WatchDecision, kind string) bool {
	return lifecycle.WaitsForKind(decision, kind)
}

// TerraformLifecycleContinuationCorrection prevents a nonterminal Terraform
// episode from ending merely because the current turn had nothing public to
// say. Slack's Terraform app can stop at Run Planning, so the agent must leave
// a durable exact-run wakeup until HCP exposes a reviewable plan or a terminal
// result. Public narration is governed separately below.
func TerraformLifecycleContinuationCorrection(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	decision decisionpkg.WatchDecision,
) string {
	// Freshness is measured against when the turn ran, not when the card
	// arrived. It used to be input.ReceivedAt, and a card processed late — a
	// retry after a credential outage, a starved channel — could then never
	// satisfy the post-apply rule: evidence gathered when the model finally
	// ran read as observed hours in the future and was discarded, and the
	// same correction fired verbatim on every round. run_15d4bde1 (received
	// 00:49Z, retried 05:15Z) recorded ten health samples at 05:18Z and was
	// told twice to record fresh evidence. The communication check beside
	// this one already reads the wall clock.
	return lifecycle.TerraformContinuationCorrection(lifecycle.TerraformContinuationInput{
		InputKind: input.Kind,
		Text:      input.Text,
		Rules:     state.MatchedRules,
		Decision:  decision,
		Now:       time.Now().UTC(),
	})
}

// ExternalLifecycleReplyLanguageCorrection is an offline evaluation warning
// for lifecycle prose. Runtime acceptance relies on the typed source phase and
// completion contract rather than matching words generated by the model.
func ExternalLifecycleReplyLanguageCorrection(
	input core.SlackInput,
	decision decisionpkg.WatchDecision,
) string {
	if input.Kind != "bot_message" || decision.Action != "reply" {
		return ""
	}
	phase := externalMessageLifecyclePhase(input.Text)
	if phase != externalLifecycleReviewable && phase != externalLifecycleSucceeded &&
		phase != externalLifecycleFailed {
		return ""
	}
	message := strings.TrimSpace(decision.Message)
	normalized := strings.ToLower(strings.Join(strings.Fields(message), " "))
	if phase == externalLifecycleReviewable && decision.Completion != nil &&
		(decision.Completion.Verdict == "healthy" || decision.Completion.Verdict == "succeeded") &&
		decisionpkg.EpisodeContainsAny(normalized, "applied", "succeeded", "successful") &&
		!strings.Contains(normalized, "stale") {
		return "say explicitly that the source confirmation card is stale, then summarize only " +
			"the material change, its fresh post-rollout health, and one independent caveat"
	}
	for _, phrase := range []string{
		"terminal notification", "lifecycle check", "lifecycle boundary",
		"no further apply action is needed", "review caveat",
	} {
		if strings.Contains(normalized, phrase) {
			return "rewrite this lifecycle update like a teammate: remove `" + phrase +
				"`; say only whether the source card is stale, what materially changed, the fresh " +
				"post-rollout result, and one independent caveat if it matters"
		}
	}
	if phase == externalLifecycleReviewable && decision.Completion != nil &&
		decision.Completion.Verdict == "healthy" && len(strings.Fields(message)) > 75 {
		return "shorten this stale lifecycle update: say that the run already applied, summarize " +
			"the material changes and their fresh post-rollout health, then keep any independent " +
			"drift or follow-up to one final sentence"
	}
	return ""
}

// successfulExternalLifecycleReplyAddsValue prevents Responder from narrating
// a success state already visible in the source app message. A public reply is
// useful only when the investigation also established a fresh result outside
// the change pipeline, such as rollout, workload, dependency, or application
// health. Publication correlations are preserved even when source-channel
// prose is suppressed.
func successfulExternalLifecycleReplyAddsValue(
	decision decisionpkg.WatchDecision,
	now time.Time,
) bool {
	return lifecycle.ReplyAddsFreshOperationalValue(decision, now)
}

// EnforceExternalLifecycleEvidence binds facts already established by the
// source event to the typed result. The model still owns diagnosis and the
// operator-facing explanation, but it cannot accidentally lose or contradict
// an exact terminal lifecycle state while translating tool results.
func EnforceExternalLifecycleEvidence(
	input core.SlackInput,
	episode core.WorkEpisode,
	decision decisionpkg.WatchDecision,
) (decisionpkg.WatchDecision, bool) {
	if input.Kind != "bot_message" || decision.Action != "reply" ||
		externalMessageLifecyclePhase(input.Text) != externalLifecycleFailed {
		return decision, false
	}
	contract := investigation.Compile(episode)
	claimID := ""
	claim := ""
	for _, requirement := range contract.Claims {
		if requirement.Required && requirement.Layer == "change" {
			claimID = requirement.ID
			claim = requirement.Proposition
			break
		}
	}
	if claimID == "" {
		return decision, false
	}

	observedAt := input.ReceivedAt.UTC()
	if observedAt.IsZero() {
		observedAt = time.Now().UTC()
	}
	terminalEvidence := core.Evidence{
		ID:           "external_terminal_" + input.ID,
		ClaimID:      claimID,
		Claim:        claim,
		Observation:  "The exact external lifecycle event reports a terminal failure.",
		Relation:     "contradicts",
		HealthEffect: "unhealthy",
		SourceType:   "slack",
		SourceID:     input.EventID,
		SourceName:   "External lifecycle event",
		Target:       externalLifecycleCorrelationKey(input.Text),
		Freshness:    "Observed in the current source event.",
		Confidence:   "high",
		ObservedAt:   observedAt,
	}
	terminalCoverage := core.Coverage{
		Layer:      "change",
		ClaimIDs:   []string{claimID},
		Status:     "unhealthy",
		Source:     "External lifecycle event",
		Detail:     "The exact external run is terminally failed; cause and partial effects may still require investigation.",
		ObservedAt: observedAt,
	}

	hasTerminalEvidence := false
	for _, item := range decision.Evidence {
		if item.ClaimID == claimID && item.Relation == "contradicts" &&
			item.HealthEffect == "unhealthy" {
			hasTerminalEvidence = true
			break
		}
	}
	if !hasTerminalEvidence {
		decision.Evidence = append(decision.Evidence, terminalEvidence)
	}

	coverageFound := false
	for index := range decision.Coverage {
		if decision.Coverage[index].Layer != "change" {
			continue
		}
		coverageFound = true
		decision.Coverage[index].Status = terminalCoverage.Status
		decision.Coverage[index].Source = terminalCoverage.Source
		decision.Coverage[index].Detail = terminalCoverage.Detail
		if !containsString(decision.Coverage[index].ClaimIDs, claimID) {
			decision.Coverage[index].ClaimIDs = append(decision.Coverage[index].ClaimIDs, claimID)
		}
		decision.Coverage[index].ObservedAt = terminalCoverage.ObservedAt
		break
	}
	if !coverageFound {
		decision.Coverage = append(decision.Coverage, terminalCoverage)
	}
	if len(decision.Operations) > 0 {
		decision.Operations = bindTerminalLifecycleOperations(
			decision.Operations,
			terminalEvidence,
			terminalCoverage,
		)
		decision.AppliedOperations = append(
			[]investigation.ResultOperation(nil), decision.Operations...,
		)
	}
	return decision, true
}

// bindTerminalLifecycleOperations preserves the operations-only result
// transport while adding source facts that the host knows independently of
// the model. complete_episode must remain the final operation.
func bindTerminalLifecycleOperations(
	operations []investigation.ResultOperation,
	evidence core.Evidence,
	coverage core.Coverage,
) []investigation.ResultOperation {
	result := append([]investigation.ResultOperation(nil), operations...)
	hasEvidence := false
	hasCoverage := false
	completionIndex := len(result)
	for index := range result {
		operation := &result[index]
		if operation.Type == "complete_episode" && completionIndex == len(result) {
			completionIndex = index
		}
		if operation.Type == "record_evidence" && operation.Evidence != nil &&
			operation.Evidence.ClaimID == evidence.ClaimID &&
			operation.Evidence.Relation == "contradicts" &&
			operation.Evidence.HealthEffect == "unhealthy" {
			hasEvidence = true
		}
		if operation.Type == "record_coverage" && operation.Coverage != nil &&
			operation.Coverage.Layer == coverage.Layer {
			bound := coverage
			bound.ClaimIDs = appendUniqueStrings(operation.Coverage.ClaimIDs, coverage.ClaimIDs...)
			operation.Coverage = &bound
			hasCoverage = true
		}
		if operation.Type == "complete_episode" && operation.Completion != nil {
			for coverageIndex := range operation.Completion.Coverage {
				if operation.Completion.Coverage[coverageIndex].Layer != coverage.Layer {
					continue
				}
				bound := coverage
				bound.ClaimIDs = appendUniqueStrings(
					operation.Completion.Coverage[coverageIndex].ClaimIDs,
					coverage.ClaimIDs...,
				)
				operation.Completion.Coverage[coverageIndex] = bound
				hasCoverage = true
			}
		}
	}
	insert := make([]investigation.ResultOperation, 0, 2)
	if !hasEvidence {
		bound := evidence
		insert = append(insert, investigation.ResultOperation{
			ID: "host-external-terminal-evidence", Type: "record_evidence", Evidence: &bound,
		})
	}
	if !hasCoverage {
		bound := coverage
		insert = append(insert, investigation.ResultOperation{
			ID: "host-external-terminal-coverage", Type: "record_coverage", Coverage: &bound,
		})
	}
	if len(insert) == 0 {
		return result
	}
	result = append(result, make([]investigation.ResultOperation, len(insert))...)
	copy(result[completionIndex+len(insert):], result[completionIndex:])
	copy(result[completionIndex:], insert)
	return result
}

func appendUniqueStrings(values []string, candidates ...string) []string {
	result := append([]string(nil), values...)
	for _, candidate := range candidates {
		if !containsString(result, candidate) {
			result = append(result, candidate)
		}
	}
	return result
}

func containsString(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

func deterministicExternalLifecycleIgnore(input core.SlackInput) (string, bool) {
	if input.Kind != "bot_message" {
		return "", false
	}
	if decisionpkg.ExternalCoordinationOnlyEvent(input.Text) {
		return "host recorded an incident coordination update without repeating the alert investigation", true
	}
	switch externalMessageLifecyclePhase(input.Text) {
	case externalLifecycleCreated, externalLifecyclePlanning:
		return "host correlated a non-actionable external lifecycle update without public narration", true
	case externalLifecycleApplying:
		return "host correlated an in-progress external lifecycle update without public narration", true
	default:
		return "", false
	}
}

// shouldInspectPendingExternalLifecycle keeps routine app progress cheap while
// allowing an operator-confirmed lifecycle rule to turn an otherwise silent
// Planning event into durable work. The rule grants read-only initiative only;
// Coop and Emisar still enforce tool and mutation authority.
func (s *Service) shouldInspectPendingExternalLifecycle(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	phase := externalMessageLifecyclePhase(input.Text)
	if phase != externalLifecycleCreated && phase != externalLifecyclePlanning {
		return false, nil
	}
	if externalLifecycleCorrelationKey(input.Text) == "" {
		return false, nil
	}
	rules, err := s.matchingStandingRules(ctx, input)
	if err != nil {
		return false, err
	}
	for _, rule := range rules {
		if lifecycle.HasTerraformRule([]core.StandingRule{rule}) {
			return true, nil
		}
	}
	return false, nil
}

func externalLifecycleCorrelationKey(text string) string {
	return lifecycle.CorrelationKey(text)
}

func (s *Service) scheduleExternalMessageReconciliation(
	ctx context.Context,
	input core.SlackInput,
) error {
	if input.Kind != "bot_message" || input.ID == "" || input.ChannelID == "" ||
		input.MessageTS == "" || !shouldReconcileExternalMessage(input.Text) {
		return nil
	}
	return s.store.EnqueueWork(ctx, store.WorkItem{
		Kind:      workExternalMessageReconcile,
		SubjectID: input.ID,
		Lane:      store.WorkLaneBackground,
		Priority:  42,
		AvailableAt: s.now().UTC().Add(
			s.cfg.Slack.ExternalMessageReconcileInterval.Duration,
		),
		DeadlineAt: input.ReceivedAt.Add(s.cfg.Slack.ExternalMessageReconcileWindow.Duration),
	})
}

func (s *Service) seedExternalMessageReconciliations(ctx context.Context) error {
	now := s.now().UTC()
	inputs, err := s.store.ListLatestSlackInputsByKind(
		ctx,
		"bot_message",
		now.Add(-s.cfg.Slack.ExternalMessageReconcileWindow.Duration),
		1000,
	)
	if err != nil {
		return err
	}
	for _, input := range inputs {
		if !shouldReconcileExternalMessage(input.Text) {
			continue
		}
		if err := s.scheduleExternalMessageReconciliation(ctx, input); err != nil {
			return err
		}
		if err := s.store.EnqueueWork(ctx, store.WorkItem{
			Kind: workExternalMessageReconcile, SubjectID: input.ID,
			Lane: store.WorkLaneBackground, Priority: 42, AvailableAt: now,
			DeadlineAt: input.ReceivedAt.Add(s.cfg.Slack.ExternalMessageReconcileWindow.Duration),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) reconcileExternalMessage(
	ctx context.Context,
	item store.WorkItem,
) error {
	if !item.DeadlineAt.IsZero() && !s.now().UTC().Before(item.DeadlineAt) {
		return nil
	}
	source, err := s.store.GetSlackInput(ctx, item.SubjectID)
	if err != nil {
		return err
	}
	if source.Kind != "bot_message" || !shouldReconcileExternalMessage(source.Text) {
		return nil
	}
	history, err := s.slack.RecentMessages(
		ctx,
		source.ChannelID,
		"",
		"",
		source.MessageTS,
		100,
	)
	if err != nil {
		return err
	}
	current := newestCorrelatedExternalLifecycle(source, history)
	if current.Timestamp == "" {
		exact, exactErr := s.slack.RecentMessages(
			ctx,
			source.ChannelID,
			"",
			source.MessageTS,
			source.MessageTS,
			10,
		)
		if exactErr != nil {
			return exactErr
		}
		current = newestCorrelatedExternalLifecycle(source, exact)
	}
	if current.Timestamp == "" {
		return slackui.ErrSearchIncomplete
	}
	updated := reconciledExternalMessageInput(s.cfg.Slack.TeamID, source, current)
	if externalMessageFingerprint(source.Text, source.Attachments) ==
		externalMessageFingerprint(updated.Text, updated.Attachments) {
		return s.scheduleExternalMessageReconciliation(ctx, source)
	}
	created, err := s.store.AdmitSlackInput(ctx, updated)
	if err != nil {
		return err
	}
	if created {
		s.invalidateSlackHistory(updated.ChannelID)
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.external_message", ActorID: updated.UserID,
			ObjectID: updated.EventID, Outcome: "reconciled_update", Detail: source.ID,
		})
	}
	return s.scheduleExternalMessageReconciliation(ctx, updated)
}

func newestCorrelatedExternalLifecycle(
	source core.SlackInput,
	history []slackui.HistoryMessage,
) slackui.HistoryMessage {
	key := externalLifecycleCorrelationKey(source.Text)
	var newest slackui.HistoryMessage
	for _, message := range history {
		sameMessage := message.Timestamp == source.MessageTS
		sameActor := core.FirstNonempty(message.BotID, message.UserID) == source.UserID
		if !sameMessage && (key == "" || !sameActor ||
			externalLifecycleCorrelationKey(message.Text) != key) {
			continue
		}
		if newest.Timestamp == "" || message.Timestamp > newest.Timestamp {
			newest = message
		}
	}
	return newest
}

func reconciledExternalMessageInput(
	teamID string,
	source core.SlackInput,
	message slackui.HistoryMessage,
) core.SlackInput {
	attachments := make([]core.SlackAttachment, 0, len(message.Files))
	for _, file := range message.Files {
		attachments = append(attachments, core.SlackAttachment{
			ID: file.ID, Name: file.Name, MediaType: file.MediaType,
			Size: file.Size, URLPrivate: file.URLPrivate,
		})
	}
	fingerprint := externalMessageFingerprint(message.Text, attachments)
	eventDigest := sha256.Sum256([]byte(
		source.ChannelID + "\x00" + message.Timestamp + "\x00" + fingerprint,
	))
	eventID := "reconcile:" + hex.EncodeToString(eventDigest[:12])
	input := core.SlackInput{
		EnvelopeID: eventID,
		EventID:    eventID,
		Kind:       "bot_message", TeamID: teamID, ChannelID: source.ChannelID,
		ThreadTS: message.ThreadTS, MessageTS: message.Timestamp,
		UserID: core.FirstNonempty(message.BotID, message.UserID, source.UserID),
		Text:   message.Text, Attachments: attachments, ReceivedAt: time.Now().UTC(),
	}
	bindCanonicalSlackMessageInputID(&input)
	return input
}

func externalMessageFingerprint(text string, attachments []core.SlackAttachment) string {
	payload, err := json.Marshal(struct {
		Text        string                 `json:"text"`
		Attachments []core.SlackAttachment `json:"attachments,omitempty"`
	}{Text: text, Attachments: attachments})
	if err != nil {
		// Both fields are plain strings and numbers, so this cannot fail. If it
		// ever does, degrade to a text-only fingerprint rather than taking the
		// whole service down over a reconciliation identity.
		payload = []byte(text)
	}
	digest := sha256.Sum256(payload)
	return hex.EncodeToString(digest[:12])
}

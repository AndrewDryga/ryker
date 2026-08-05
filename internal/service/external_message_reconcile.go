package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const workExternalMessageReconcile = "external_message_reconcile"

var externalLifecycleSubjects = []string{
	"run", "deployment", "job", "workflow", "build", "release", "plan", "apply",
}

var externalLifecyclePendingStates = []string{
	"created", "planning", "planned", "pending", "waiting", "queued", "running", "applying",
	"in progress", "needs confirmation", "cost estimating", "policy checking",
	"policy checked", "confirmed",
}

type externalLifecyclePhase string

const (
	externalLifecycleUnknown    externalLifecyclePhase = "unknown"
	externalLifecycleCreated    externalLifecyclePhase = "created"
	externalLifecyclePlanning   externalLifecyclePhase = "planning"
	externalLifecycleReviewable externalLifecyclePhase = "reviewable"
	externalLifecycleApplying   externalLifecyclePhase = "applying"
	externalLifecycleSucceeded  externalLifecyclePhase = "succeeded"
	externalLifecycleFailed     externalLifecyclePhase = "failed"
	externalLifecycleStopped    externalLifecyclePhase = "stopped"
)

var (
	externalLifecycleLinkPattern = regexp.MustCompile(`<((?:https?://)[^>|]+)(?:\|[^>]*)?>`)
	externalLifecycleIDPattern   = regexp.MustCompile(
		`(?i)(?:^|[|>[:space:]])(run|deployment|job|workflow|build|release|plan|apply)[[:space:]:]+([a-z0-9][a-z0-9._:/-]{2,})`,
	)
)

var externalLifecycleGenericIDs = map[string]struct{}{
	"notification": {}, "planning": {}, "planned": {}, "pending": {}, "waiting": {},
	"queued": {}, "running": {}, "applying": {}, "progress": {}, "confirmation": {},
	"confirmed": {}, "succeeded": {}, "successful": {}, "applied": {}, "errored": {},
	"error": {}, "failed": {}, "discarded": {}, "canceled": {}, "cancelled": {},
	"completed": {},
}

func shouldReconcileExternalMessage(text string) bool {
	for _, line := range strings.Split(strings.ToLower(text), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		subject := false
		for _, candidate := range externalLifecycleSubjects {
			if strings.HasPrefix(line, candidate+" ") || strings.HasPrefix(line, candidate+":") {
				subject = true
				break
			}
		}
		if !subject && !strings.HasPrefix(line, "status:") && !strings.HasPrefix(line, "state:") {
			continue
		}
		for _, state := range externalLifecyclePendingStates {
			if strings.Contains(line, state) {
				return true
			}
		}
	}
	return false
}

// externalMessageLifecyclePhase classifies only explicit lifecycle status lines.
// This keeps ordinary prose such as "the job is running slowly" out of the
// deterministic Slack routing policy.
func externalMessageLifecyclePhase(text string) externalLifecyclePhase {
	phase := externalLifecycleUnknown
	for _, line := range strings.Split(strings.ToLower(text), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !externalLifecycleStatusLine(line) {
			continue
		}
		switch {
		case containsLifecycleState(line,
			"errored", "failed", "failure", "apply failed", "run errored",
		):
			return externalLifecycleFailed
		case containsLifecycleState(line,
			"discarded", "cancelled", "canceled", "stopped",
		):
			return externalLifecycleStopped
		case containsLifecycleState(line,
			"applied", "succeeded", "successful", "completed", "finished",
		):
			phase = externalLifecycleSucceeded
		case containsLifecycleState(line, "applying", "apply in progress"):
			if phase != externalLifecycleSucceeded {
				phase = externalLifecycleApplying
			}
		case containsLifecycleState(line,
			"planned", "needs confirmation", "needs approval",
		):
			if phase == externalLifecycleUnknown || phase == externalLifecycleCreated ||
				phase == externalLifecyclePlanning {
				phase = externalLifecycleReviewable
			}
		case containsLifecycleState(line,
			"planning", "cost estimating", "policy checking", "policy checked",
		):
			if phase == externalLifecycleUnknown || phase == externalLifecycleCreated {
				phase = externalLifecyclePlanning
			}
		case containsLifecycleState(line,
			"created", "pending", "waiting", "queued", "running", "in progress",
		):
			if phase == externalLifecycleUnknown {
				phase = externalLifecycleCreated
			}
		}
	}
	return phase
}

func externalLifecycleStatusLine(line string) bool {
	if strings.HasPrefix(line, "status:") || strings.HasPrefix(line, "state:") {
		return true
	}
	for _, subject := range externalLifecycleSubjects {
		if strings.HasPrefix(line, subject+" ") || strings.HasPrefix(line, subject+":") {
			return true
		}
	}
	return false
}

func containsLifecycleState(line string, states ...string) bool {
	for _, state := range states {
		if line == state || strings.Contains(line, " "+state) ||
			strings.Contains(line, state+" ") || strings.Contains(line, state+" -") ||
			strings.Contains(line, state+":") {
			return true
		}
	}
	return false
}

func enforceExternalLifecycleCommunication(
	input core.SlackInput,
	decision watchDecision,
) watchDecision {
	if input.Kind != "bot_message" {
		return decision
	}
	phase := externalMessageLifecyclePhase(input.Text)
	switch phase {
	case externalLifecycleCreated, externalLifecyclePlanning:
		decision.PublicationUpdates = nil
		return suppressWatchDecision(
			decision,
			"host correlated a non-actionable external lifecycle update without public narration",
		)
	case externalLifecycleApplying:
		return suppressWatchDecision(
			decision,
			"host correlated an in-progress external lifecycle update without public narration",
		)
	case externalLifecycleReviewable:
		if decision.Completion == nil || decision.Completion.Verdict == "" ||
			decision.Completion.Verdict == "in_progress" {
			return suppressWatchDecision(
				decision,
				"host suppressed a plan-status update without a completed material review",
			)
		}
	}
	return decision
}

// enforceExternalLifecycleEvidence binds facts already established by the
// source event to the typed result. The model still owns diagnosis and the
// operator-facing explanation, but it cannot accidentally lose or contradict
// an exact terminal lifecycle state while translating tool results.
func enforceExternalLifecycleEvidence(
	input core.SlackInput,
	episode core.WorkEpisode,
	decision watchDecision,
) (watchDecision, bool) {
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
	hasTerminalEvidence := false
	for _, item := range decision.Evidence {
		if item.ClaimID == claimID && item.Relation == "contradicts" &&
			item.HealthEffect == "unhealthy" {
			hasTerminalEvidence = true
			break
		}
	}
	if !hasTerminalEvidence {
		decision.Evidence = append(decision.Evidence, core.Evidence{
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
		})
	}

	coverageFound := false
	for index := range decision.Coverage {
		if decision.Coverage[index].Layer != "change" {
			continue
		}
		coverageFound = true
		decision.Coverage[index].Status = "unhealthy"
		decision.Coverage[index].Source = "External lifecycle event"
		decision.Coverage[index].Detail =
			"The exact external run is terminally failed; cause and partial effects may still require investigation."
		if !containsString(decision.Coverage[index].ClaimIDs, claimID) {
			decision.Coverage[index].ClaimIDs = append(decision.Coverage[index].ClaimIDs, claimID)
		}
		decision.Coverage[index].ObservedAt = observedAt
		break
	}
	if !coverageFound {
		decision.Coverage = append(decision.Coverage, core.Coverage{
			Layer:      "change",
			ClaimIDs:   []string{claimID},
			Status:     "unhealthy",
			Source:     "External lifecycle event",
			Detail:     "The exact external run is terminally failed; cause and partial effects may still require investigation.",
			ObservedAt: observedAt,
		})
	}
	return decision, true
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
	switch externalMessageLifecyclePhase(input.Text) {
	case externalLifecycleCreated, externalLifecyclePlanning:
		return "host correlated a non-actionable external lifecycle update without public narration", true
	case externalLifecycleApplying:
		return "host correlated an in-progress external lifecycle update without public narration", true
	default:
		return "", false
	}
}

func externalLifecycleCorrelationKey(text string) string {
	bestLink := ""
	for _, match := range externalLifecycleLinkPattern.FindAllStringSubmatch(text, -1) {
		if len(match) > 1 && len(match[1]) > len(bestLink) {
			bestLink = strings.TrimSpace(match[1])
		}
	}
	if bestLink != "" {
		return "link:" + bestLink
	}
	for _, match := range externalLifecycleIDPattern.FindAllStringSubmatch(text, -1) {
		if len(match) < 3 {
			continue
		}
		identifier := strings.ToLower(strings.Trim(match[2], ".,;"))
		if _, generic := externalLifecycleGenericIDs[identifier]; generic {
			continue
		}
		return strings.ToLower(match[1]) + ":" + identifier
	}
	return ""
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
		AvailableAt: time.Now().UTC().Add(
			s.cfg.Slack.ExternalMessageReconcileInterval.Duration,
		),
		DeadlineAt: input.ReceivedAt.Add(s.cfg.Slack.ExternalMessageReconcileWindow.Duration),
	})
}

func (s *Service) seedExternalMessageReconciliations(ctx context.Context) error {
	now := time.Now().UTC()
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
	if !item.DeadlineAt.IsZero() && !time.Now().UTC().Before(item.DeadlineAt) {
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
		_ = s.store.Audit(ctx, core.AuditEvent{
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
		sameActor := firstNonempty(message.BotID, message.UserID) == source.UserID
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
		UserID: firstNonempty(message.BotID, message.UserID, source.UserID),
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
		panic(err)
	}
	digest := sha256.Sum256(payload)
	return hex.EncodeToString(digest[:12])
}

package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/store"
)

// Evaluator is the seam the offline evaluation harness replays prompts,
// episodes, and offers through. The harness constructs them exactly the way
// the runtime does without running the service; nothing at runtime may reach
// through this type.
type Evaluator struct{ service Service }

// NewEvaluator wraps a config in the prompt- and offer-construction internals
// the offline evaluation harness replays.
func NewEvaluator(cfg config.Config) *Evaluator { return &Evaluator{service: Service{cfg: cfg}} }

// Store exposes the evaluator's store, which is the zero nil the harness
// passes through to helpers that accept one.
func (e *Evaluator) Store() *store.Store { return e.service.store }

// EpisodeForWatchedInput builds the work episode a watched Slack input opens.
func (e *Evaluator) EpisodeForWatchedInput(
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
) *core.WorkEpisode {
	return e.service.episodeForWatchedInput(input, state)
}

// EpisodeForIncident builds the work episode an incident or task run opens.
func (e *Evaluator) EpisodeForIncident(
	incident core.Incident,
	mode core.AgentRunMode,
	sourceKind string,
	objective string,
) *core.WorkEpisode {
	return e.service.episodeForIncident(incident, mode, sourceKind, objective)
}

// WatchPrompt assembles the watch prompt and the context it had to omit.
func (e *Evaluator) WatchPrompt(
	input core.SlackInput,
	botUserID string,
	conversationFollowup bool,
	recent []decisionpkg.WatchContextMessage,
	channelAroundRoot []decisionpkg.WatchContextMessage,
	memory core.AgentMemory,
	related []decisionpkg.ConversationSituationContext,
	referenced *decisionpkg.ReferencedThreadContext,
	prior decisionpkg.OperationalMemoryContext,
	activeRepository string,
	matchedRules []core.StandingRule,
	budget int,
) (string, []core.ContextOmission) {
	return e.service.watchPrompt(
		input,
		botUserID,
		conversationFollowup,
		recent,
		channelAroundRoot,
		memory,
		related,
		referenced,
		prior,
		// The offline corpus replays recorded Slack turns against no database,
		// so it has no episode history to recall. Recall is exercised by the Go
		// tests beside the code, which is where a host-side selection belongs.
		nil,
		activeRepository,
		matchedRules,
		budget,
	)
}

// ConversationPrompt assembles the conversation-lane prompt.
func (e *Evaluator) ConversationPrompt(
	input core.SlackInput,
	botUserID string,
	conversationFollowup bool,
	recent []decisionpkg.WatchContextMessage,
	memory core.AgentMemory,
	related []decisionpkg.ConversationSituationContext,
	referenced *decisionpkg.ReferencedThreadContext,
	prior decisionpkg.OperationalMemoryContext,
	activeRepository string,
) string {
	return e.service.conversationPrompt(
		input,
		botUserID,
		conversationFollowup,
		recent,
		memory,
		related,
		referenced,
		prior,
		activeRepository,
	)
}

// PrepareMemoryOfferAction resolves a memory offer the way the runtime does.
func (e *Evaluator) PrepareMemoryOfferAction(
	input core.SlackInput,
	offer *core.MemoryOffer,
) (string, string, string, string, bool) {
	return e.service.prepareMemoryOfferAction(input, offer)
}

// PreparePreferenceOfferAction resolves a preference offer the way the runtime
// does.
func (e *Evaluator) PreparePreferenceOfferAction(
	input core.SlackInput,
	offer *core.PreferenceOffer,
) (string, core.ResponderPreference, string, bool) {
	return e.service.preparePreferenceOfferAction(input, offer)
}

// PrepareRuleOfferAction resolves a standing-rule offer the way the runtime
// does.
func (e *Evaluator) PrepareRuleOfferAction(
	input core.SlackInput,
	offer *core.RuleOffer,
) (string, core.StandingRule, string, bool) {
	return e.service.prepareRuleOfferAction(input, offer)
}

// NormalizeScheduleOffer resolves a schedule offer the way the runtime does.
func (e *Evaluator) NormalizeScheduleOffer(
	ctx context.Context,
	input core.SlackInput,
	offer *core.ScheduleOffer,
) (core.ScheduledTask, string, bool) {
	return e.service.normalizeScheduleOffer(ctx, input, offer)
}

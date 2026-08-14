package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

// recordAgentActivity stores one narrated moment from inside a turn.
//
// It never fails the poll. The turn still has to reach its terminal state and
// the answer still has to be delivered; a moment Responder could not store
// costs a line in a trace, and trading the answer for the story of the answer
// would be the wrong way round. Failures are logged and the poll continues.
//
// An older Coop sends no payload at all. That decodes to an empty activity,
// which is stored with its kind and timestamp intact — "Coop narrated
// something here and this build cannot read it" is a truer trace than silence.
// It reports whether the moment was new. A rewound cursor redelivers moments
// that are already stored, and a card refreshed for one of those would be
// paying a Slack write to render a line it is already showing.
func (s *Service) recordAgentActivity(
	ctx context.Context,
	run core.AgentRun,
	event coop.Event,
) bool {
	if run.EpisodeID == "" {
		return false
	}
	activity := core.AgentActivity{
		EpisodeID:  run.EpisodeID,
		AgentRunID: run.ID,
		SessionID:  run.SessionID,
		TurnID:     event.TurnID,
		Sequence:   event.Sequence,
		Kind:       event.Type,
		OccurredAt: event.OccurredAt,
	}
	if decoded, ok := coop.DecodeActivity(event.Payload); ok {
		activity.ToolCallID = decoded.ToolCallID
		activity.Title = decoded.Label(event.Type)
		activity.ToolKind = decoded.Kind
		activity.Status = decoded.Status
		activity.Detail = decoded.Detail(event.Type)
	}
	stored, err := s.store.Activity.Record(ctx, activity)
	if err != nil {
		s.log.Warn(
			"record agent activity",
			"run", run.ID, "sequence", event.Sequence, "kind", event.Type, "error", err,
		)
		return false
	}
	return stored
}

// refreshCardForActivity marks the pinned card stale because the turn moved.
//
// Every other bump names a state change; this one exists because nothing about
// the incident changed and the card is wrong anyway — one more tool call, one
// more minute since the last. The throttle is what makes it affordable, and the
// store's guards are what make it safe: a turn that has already ended has no
// window to refresh.
//
// It never fails the poll, for the same reason recording never does. The turn
// still has to reach its terminal state and the answer still has to be
// delivered; a refresh Responder could not request costs a card that is fifteen
// seconds staler than it might have been, and it will be requested again on the
// next narrated moment anyway.
func (s *Service) refreshCardForActivity(ctx context.Context, run core.AgentRun) {
	if run.IncidentID == "" {
		return
	}
	if !s.cardActivity.Allow(run.IncidentID, s.now()) {
		return
	}
	if _, err := s.store.TaskCards.BumpActiveTurn(ctx, run.IncidentID); err != nil {
		s.log.Warn(
			"refresh card for agent activity",
			"incident", run.IncidentID, "run", run.ID, "error", err,
		)
	}
}

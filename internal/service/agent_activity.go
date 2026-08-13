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
func (s *Service) recordAgentActivity(
	ctx context.Context,
	run core.AgentRun,
	event coop.Event,
) {
	if run.EpisodeID == "" {
		return
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
	if _, err := s.store.Activity.Record(ctx, activity); err != nil {
		s.log.Warn(
			"record agent activity",
			"run", run.ID, "sequence", event.Sequence, "kind", event.Type, "error", err,
		)
	}
}

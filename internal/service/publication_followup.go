package service

// Publication followup itself lives in internal/publication. What stays here is
// the part that needs the rest of the service: recognising when an operator's
// message refers to a publication that is still in flight, and applying the
// updates a model proposed.

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	publicationpkg "github.com/AndrewDryga/responder/internal/publication"
	"github.com/AndrewDryga/responder/internal/publicationcontext"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func (s *Service) inputReferencesActivePublication(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	items, err := s.store.PublicationFollowups.ListActiveContexts(
		ctx,
		s.now().UTC().Add(-s.cfg.GitHub.DeliveryCorrelationWindow.Duration),
		20,
	)
	if err != nil {
		return false, err
	}
	return publicationcontext.AppearsInAny(input.Text, items), nil
}

func (s *Service) applyPublicationUpdates(
	ctx context.Context,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	updates []decisionpkg.PublicationUpdate,
) error {
	if len(updates) == 0 || input.Kind != "bot_message" {
		return nil
	}
	for _, update := range updates {
		publicationContext, ok := publicationcontext.Find(
			state.ActivePublications, update.IncidentID,
		)
		if !ok || !publicationcontext.ReferenceMatches(
			input.Text, update.Reference, publicationContext, state.ActivePublications,
		) {
			s.audit(ctx, core.AuditEvent{
				IncidentID: update.IncidentID, Kind: "publication.correlation",
				ActorID: input.UserID, ObjectID: input.ID, Outcome: "rejected",
				Detail: "external app message did not contain an exact recorded PR, branch, or commit reference",
			})
			continue
		}
		incident, err := s.store.GetIncident(ctx, update.IncidentID)
		if err != nil {
			return err
		}
		sourceKey := externalLifecycleCorrelationKey(input.Text)
		if sourceKey == "" {
			sourceKey = input.ID
		}
		eventKey := publicationpkg.LifecycleKey(
			update.IncidentID, sourceKey, update.Kind, update.State,
		)
		summary := update.Summary
		if input.ChannelID != "" && input.ChannelID != incident.ChannelID {
			summary += "\n\nSource: <#" + input.ChannelID + ">"
		}
		_, err = s.store.PublicationFollowups.RecordLifecycleEvent(ctx, core.PublicationLifecycleEvent{
			ID: eventKey, IncidentID: incident.ID, Kind: update.Kind,
			State: update.State, Summary: summary,
			SourceChannelID: input.ChannelID, SourceMessageTS: input.MessageTS,
		})
		if err != nil {
			return err
		}
		s.recordTimeline(ctx, core.TimelineEvent{
			ID: "tl_" + eventKey, IncidentID: incident.ID,
			ChannelID: incident.ChannelID, Kind: "publication." + update.Kind,
			ActorID: "slack_app", Title: summary,
			Detail: "Correlated from Slack message " + input.ChannelID + "/" + input.MessageTS,
		})
	}
	return nil
}

// publicationFollower binds the followup package to this service's store,
// publisher, clock and delivery queue.
//
// The status source is optional on purpose: a deployment configured without
// GitHub credentials is supported, and the followup defers rather than failing.
func (s *Service) publicationFollower() *publicationpkg.Follower {
	return publicationpkg.NewFollower(
		s.store.PublicationFollowups,
		s.store.Publications,
		s.store,
		publicationpkg.StatusSourceFor(s.publisher),
		serviceReporter{s},
		publicationpkg.Config{
			FollowupInterval:          s.cfg.GitHub.FollowupInterval.Duration,
			DeliveryCorrelationWindow: s.cfg.GitHub.DeliveryCorrelationWindow.Duration,
		},
		func() time.Time { return s.now() },
	)
}

// serviceReporter adapts the service's delivery queue and timeline to the
// narrow Reporter port.
type serviceReporter struct{ s *Service }

func (r serviceReporter) Enqueue(
	ctx context.Context,
	deliveryID string,
	incident core.Incident,
	kind, threadTS string,
	message slackui.Message,
) error {
	if incident.IsEngineeringTask() && kind == "publication_followup" {
		// Follow-up state and events mark the durable task card dirty. The
		// message belongs in the card's delivery section, not Latest update,
		// which remains the agent's work report.
		return nil
	}
	return r.s.enqueue(ctx, deliveryID, incident, kind, threadTS, message)
}

func (r serviceReporter) RecordTimeline(ctx context.Context, event core.TimelineEvent) {
	r.s.recordTimeline(ctx, event)
}

func (s *Service) processPublicationFollowup(ctx context.Context) error {
	return s.publicationFollower().Process(ctx)
}

func (s *Service) checkPublicationFollowup(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	return s.publicationFollower().Check(ctx, input, incident)
}

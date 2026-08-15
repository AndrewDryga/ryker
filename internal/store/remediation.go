package store

import (
	"context"
	"errors"

	"github.com/AndrewDryga/responder/internal/core"
)

// LoadRemediationRecord assembles one incident's canonical records without
// copying or mutating them. Rendering code derives timelines and postmortems
// from this snapshot.
func (s *Store) LoadRemediationRecord(
	ctx context.Context,
	incidentID string,
) (core.RemediationRecord, error) {
	incident, err := s.GetIncident(ctx, incidentID)
	if err != nil {
		return core.RemediationRecord{}, err
	}
	record := core.RemediationRecord{Incident: incident}
	if record.Signals, err = s.ListSignals(ctx, incidentID); err != nil {
		return core.RemediationRecord{}, err
	}
	if record.AgentRuns, err = s.ListAgentRunsForIncident(ctx, incidentID); err != nil {
		return core.RemediationRecord{}, err
	}
	if record.Evidence, err = s.Intelligence.ListEvidence(ctx, incidentID, "", 100); err != nil {
		return core.RemediationRecord{}, err
	}
	if record.Coverage, err = s.Intelligence.ListCoverage(ctx, incidentID, "", 100); err != nil {
		return core.RemediationRecord{}, err
	}
	if record.Events, err = s.Intelligence.ListTimeline(ctx, incidentID, "", 500); err != nil {
		return core.RemediationRecord{}, err
	}
	if record.Approvals, err = s.Approvals.ListForIncident(ctx, incidentID); err != nil {
		return core.RemediationRecord{}, err
	}
	// The follow-up section used to be five static checkboxes ending in "assign
	// remaining corrective actions and owners", which is a sentence asking
	// somebody to do the tracking by hand. Every episode this incident ran
	// already has a commitment row with a state and a thread; loading them is
	// what turns that section from a suggestion into a record.
	if record.Commitments, err = listIncidentCommitments(ctx, s.db, incidentID, 25); err != nil {
		return core.RemediationRecord{}, err
	}
	record.Publication, err = s.GetPublication(ctx, incidentID)
	if errors.Is(err, ErrNotFound) {
		err = nil
	}
	if err != nil {
		return core.RemediationRecord{}, err
	}
	return record, nil
}

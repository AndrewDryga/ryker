package core

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// RemediationTimeline derives an append-only-looking operator view from the
// canonical incident records. Stable IDs make the projection deterministic.
func RemediationTimeline(record RemediationRecord) []TimelineEvent {
	incident := record.Incident
	events := make([]TimelineEvent, 0, 2+len(record.Events)+len(record.Signals)*2+
		len(record.AgentRuns)+len(record.Proposals)*2+len(record.Approvals)*2+2)
	appendEvent := func(event TimelineEvent) {
		if event.CreatedAt.IsZero() || strings.TrimSpace(event.Title) == "" {
			return
		}
		if event.IncidentID == "" {
			event.IncidentID = incident.ID
		}
		if event.ChannelID == "" {
			event.ChannelID = incident.ChannelID
		}
		events = append(events, event)
	}

	workLabel := "Incident"
	if incident.IsEngineeringTask() {
		workLabel = "Engineering task"
	}
	appendEvent(TimelineEvent{
		ID: "incident:" + incident.ID + ":opened", Kind: "incident.opened",
		Title: workLabel + " opened", Detail: incident.Title,
		CreatedAt: incident.CreatedAt,
	})
	explicitAlerts := make(map[string]bool)
	for _, event := range record.Events {
		if strings.HasPrefix(event.Kind, "alert.") {
			explicitAlerts[event.Kind+"\x00"+event.Title] = true
		}
	}
	for _, signal := range record.Signals {
		started := firstTime(signal.StartsAt, signal.ReceivedAt)
		if !explicitAlerts["alert.firing\x00"+signal.Title] {
			appendEvent(TimelineEvent{
				ID:   "signal:" + signal.Route + ":" + signal.SourceID + ":firing",
				Kind: "alert.firing", ActorID: signal.Route,
				Title: "Alert fired: " + signal.Title, Detail: signal.Summary,
				URL: signal.SourceURL, CreatedAt: started,
			})
		}
		if signal.Status == SignalResolved || !signal.EndsAt.IsZero() {
			if !explicitAlerts["alert.resolved\x00"+signal.Title] {
				appendEvent(TimelineEvent{
					ID:   "signal:" + signal.Route + ":" + signal.SourceID + ":resolved",
					Kind: "alert.resolved", ActorID: signal.Route,
					Title:     "Alert resolved: " + signal.Title,
					URL:       signal.SourceURL,
					CreatedAt: firstTime(signal.EndsAt, signal.ReceivedAt),
				})
			}
		}
	}

	for _, event := range record.Events {
		if projectedTimelineKind(event.Kind) {
			continue
		}
		appendEvent(event)
	}

	for _, run := range record.AgentRuns {
		when := firstTime(run.StartedAt, run.CreatedAt)
		title := "Investigation " + strings.ReplaceAll(string(run.State), "_", " ")
		detail := ""
		if !run.CompletedAt.IsZero() {
			when = run.CompletedAt
		}
		if run.State == AgentRunCompleted {
			title = "Investigation completed"
		} else if run.State == AgentRunFailed || run.State == AgentRunCancelled ||
			run.State == AgentRunSuperseded {
			title = "Investigation " + string(run.State)
			detail = run.LastError
		}
		if run.Repository != "" {
			detail = joinDetail(detail, "Repository: "+run.Repository)
		}
		appendEvent(TimelineEvent{
			ID: "agent-run:" + run.ID, Kind: "agent.run." + string(run.State),
			ActorID: "responder", Title: title, Detail: detail,
			EvidenceIDs: evidenceForSource(record.Evidence, run.ID), CreatedAt: when,
		})
	}

	for _, proposal := range record.Proposals {
		appendEvent(TimelineEvent{
			ID: "proposal:" + proposal.ID + ":created", Kind: "action.proposed",
			ActorID: proposal.RequestedBy, Title: "Action proposed: " + proposal.Title,
			Detail:    proposal.ActionName + " for " + proposal.Target,
			CreatedAt: proposal.CreatedAt,
		})
		if proposal.Status != "" && proposal.Status != "pending" {
			appendEvent(TimelineEvent{
				ID:   "proposal:" + proposal.ID + ":" + proposal.Status,
				Kind: "action." + proposal.Status,
				Title: "Action " + strings.ReplaceAll(proposal.Status, "_", " ") +
					": " + proposal.Title,
				Detail: proposal.Result, CreatedAt: proposal.UpdatedAt,
			})
		}
	}

	for _, approval := range record.Approvals {
		appendEvent(TimelineEvent{
			ID: "emisar-run:" + approval.RunID + ":approval", Kind: "emisar.approval.required",
			ActorID: approval.RequestedBy, Title: "Approval required: " + approval.ActionID,
			Detail: approval.RunnerRef, URL: approval.ApprovalURL,
			CreatedAt: approval.CreatedAt,
		})
		if !approval.TerminalAt.IsZero() {
			detail := approval.RunnerRef
			if approval.LastError != "" {
				detail = joinDetail(detail, approval.LastError)
			}
			appendEvent(TimelineEvent{
				ID:   "emisar-run:" + approval.RunID + ":terminal",
				Kind: "emisar.run." + approval.Status, ActorID: "emisar",
				Title: "Emisar run " + strings.ReplaceAll(approval.Status, "_", " ") +
					": " + approval.ActionID,
				Detail: detail, URL: firstNonemptyString(approval.RunURL, approval.ApprovalURL),
				CreatedAt: approval.TerminalAt,
			})
		}
	}

	publication := record.Publication
	if publication.IncidentID != "" {
		appendEvent(TimelineEvent{
			ID: "publication:" + incident.ID + ":started", Kind: "publication.started",
			ActorID: "responder", Title: "Draft PR publication started",
			Detail:    publication.Repository + " from " + publication.HeadBranch,
			CreatedAt: publication.CreatedAt,
		})
		if publication.Published() {
			appendEvent(TimelineEvent{
				ID: "publication:" + incident.ID + ":published", Kind: "publication.published",
				ActorID: "responder",
				Title:   fmt.Sprintf("Draft PR #%d published", publication.PRNumber),
				Detail:  publication.CommitSHA, URL: publication.PRURL,
				CreatedAt: publication.PublishedAt,
			})
		} else if publication.State == "failed" {
			appendEvent(TimelineEvent{
				ID: "publication:" + incident.ID + ":failed", Kind: "publication.failed",
				ActorID: "responder", Title: "Draft PR publication failed",
				Detail: publication.LastError, CreatedAt: publication.UpdatedAt,
			})
		}
	}

	closedAt := firstTime(incident.ClosedAt, incident.ResolvedAt)
	if !closedAt.IsZero() {
		appendEvent(TimelineEvent{
			ID: "incident:" + incident.ID + ":closed", Kind: "incident.closed",
			Title: workLabel + " closed", CreatedAt: closedAt,
		})
	}

	sort.SliceStable(events, func(i, j int) bool {
		if events[i].CreatedAt.Equal(events[j].CreatedAt) {
			return events[i].ID < events[j].ID
		}
		return events[i].CreatedAt.Before(events[j].CreatedAt)
	})
	return events
}

func projectedTimelineKind(kind string) bool {
	return strings.HasPrefix(kind, "emisar.approval.") ||
		kind == "agent.failure" || kind == "action.approve" || kind == "action.reject" ||
		kind == "incident.closed" || kind == "engineering_task.closed"
}

func evidenceForSource(items []Evidence, sourceInput string) []string {
	result := make([]string, 0)
	for _, item := range items {
		if item.SourceInput == sourceInput {
			result = append(result, item.ID)
		}
	}
	return result
}

func firstTime(values ...time.Time) time.Time {
	for _, value := range values {
		if !value.IsZero() {
			return value
		}
	}
	return time.Time{}
}

func joinDetail(left, right string) string {
	left = strings.TrimSpace(left)
	right = strings.TrimSpace(right)
	if left == "" {
		return right
	}
	if right == "" {
		return left
	}
	return left + "; " + right
}

func firstNonemptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

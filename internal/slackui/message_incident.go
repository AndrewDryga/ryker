package slackui

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

func IncidentCardWithPublication(
	incident core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
) Message {
	if incident.IsEngineeringTask() {
		return engineeringTaskCard(
			incident, repositoryName, signals, hasCodeChanges, codeChangesKnown, publication,
		)
	}
	status := incidentStatusLabel(incident.Status)
	workflow := workflowStateLabel(incident.Workflow)
	severity := displayOr(incident.Severity, "unclassified")
	header := singleLine(incident.Title)
	if incident.Severity != "" {
		header = strings.ToUpper(truncateUTF8(incident.Severity, 18)) + " | " + header
	}
	fallback := fmt.Sprintf(
		"Incident %s: %s. Severity %s. Alert %s; Responder %s. %d of %d signals firing in %s.",
		ShortID(incident.ID), escapeSlackText(incident.Title), escapeSlackText(severity), status, workflow,
		incident.FiringCount, incident.SignalCount, escapeSlackText(repositoryName),
	)
	if incident.LastError != "" {
		fallback += " Action needed: " + truncateUTF8(escapeSlackText(incident.LastError), 500)
	}
	message := Message{
		Text:   truncateUTF8(fallback, 4000),
		Header: truncateUTF8(header, 150),
		Sections: []string{
			fmt.Sprintf("*%s*  |  Responder: *%s*\n%s", status, workflow, signalStateSummary(incident)),
		},
		Fields: []Field{
			{Label: "Incident", Value: ShortID(incident.ID)},
			{Label: "Severity", Value: escapeSlackText(severity)},
			{Label: "Repository", Value: escapeSlackText(repositoryName)},
			{Label: "Signals", Value: fmt.Sprintf("%d firing / %d total", incident.FiringCount, incident.SignalCount)},
		},
		Context: []string{
			"Reply in this thread to collaborate with Responder.",
			"Updated " + incident.UpdatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		},
		Actions: incidentActions(incident, hasCodeChanges, codeChangesKnown, publication),
	}
	if !incident.CreatedAt.IsZero() {
		message.Fields = append(message.Fields, Field{
			Label: "Started", Value: incident.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		})
	}
	if incident.CoopForkName != "" {
		message.Fields = append(message.Fields, Field{Label: "Fork", Value: "`" + incident.CoopForkName + "`"})
	}
	switch {
	case !incident.ClosedAt.IsZero():
		message.Fields = append(message.Fields, Field{
			Label: "Closed", Value: incident.ClosedAt.UTC().Format("2006-01-02 15:04 UTC"),
		})
	case !incident.ResolvedAt.IsZero():
		message.Fields = append(message.Fields, Field{
			Label: "Resolved", Value: incident.ResolvedAt.UTC().Format("2006-01-02 15:04 UTC"),
		})
	case !incident.ResolveDueAt.IsZero():
		message.Fields = append(message.Fields, Field{
			Label: "Recovery check", Value: incident.ResolveDueAt.UTC().Format("2006-01-02 15:04 UTC"),
		})
	}
	if signal, ok := primarySignal(signals); ok {
		if summary := strings.TrimSpace(signal.Summary); summary != "" {
			message.Sections = append(
				message.Sections,
				"*Alert summary*\n"+truncateUTF8(escapeSlackText(summary), 1200),
			)
		}
		if link := sourceLink(signal.SourceURL); link != "" {
			message.Context = append(message.Context, "Alert source: "+link)
		}
	}
	if explanation := correlationExplanation(incident, signals); explanation != "" {
		message.Sections = append(message.Sections, "*Why these signals are grouped*\n"+explanation)
	}
	if incident.LastError != "" {
		sections := []string{
			message.Sections[0],
			"*Action needed*\n" + truncateUTF8(escapeSlackText(incident.LastError), 800),
		}
		message.Sections = append(sections, message.Sections[1:]...)
	}
	return message
}

func ConversationResponseWithIncidentOffer(
	text string,
	sourceInputID string,
	sanitizer *Sanitizer,
) Message {
	message := ConversationResponse(text, sanitizer)
	message.Actions = []Action{{
		ID:    ActionOpenIncident,
		Label: "Open incident room",
		Value: sourceInputID,
		Style: "primary",
		Confirm: "Create a dedicated incident room and isolated Coop working copy from this message? " +
			"No merge, push, deployment, or infrastructure change will occur.",
	}}
	return message
}

func WithIncidentOffer(message Message, sourceInputID string) Message {
	// The incident button and confirmation dialog carry the boundary. A context
	// footer is redundant and is concatenated to copied Slack Markdown.
	//
	// So drop it, which this said for months without doing. Every
	// evidence-backed reply that also offered an incident shipped the footer
	// anyway, because the composer adds it upstream: ConciseEvidenceResponse
	// appends "Details saved: N findings…" and this only ever appended the
	// button. Nothing is lost — that footer is a count, not attribution, and
	// the incident room carries the findings themselves.
	message.Context = nil
	message.Actions = append(message.Actions, Action{
		ID: ActionOpenIncident, Label: "Open incident room", Value: sourceInputID,
		Style: "primary",
		Confirm: "Create a dedicated incident room and isolated Coop working copy from this message? " +
			"No merge, push, deployment, or infrastructure change will occur.",
	})
	return message
}

func IncidentEvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, sanitizer)
	message.Header = "Investigation update"
	message.Text = truncateUTF8("Investigation update: "+message.Text, 4000)
	message.Context = append(
		message.Context,
		"Use `/responder evidence` for the detailed source ledger. Internal tool output and hidden reasoning are omitted.",
	)
	return message
}

func TimelineMessage(record core.RemediationRecord) Message {
	incident := record.Incident
	events := core.RemediationTimeline(record)
	var body strings.Builder
	body.WriteString("## Remediation timeline\n")
	if len(events) == 0 {
		body.WriteString("\nNo incident activity has been recorded yet.")
	}
	start := max(0, len(events)-40)
	for _, event := range events[start:] {
		fmt.Fprintf(
			&body,
			"\n- **%s** - %s",
			event.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			escapeSlackText(event.Title),
		)
		if event.Detail != "" {
			fmt.Fprintf(
				&body, "  \n  %s",
				truncateUTF8(escapeSlackText(event.Detail), 600),
			)
		}
		if link := sourceLink(event.URL); link != "" {
			fmt.Fprintf(&body, "  \n  %s", link)
		}
	}
	return Message{
		Text: fmt.Sprintf(
			"Incident %s remediation timeline with %d events.",
			ShortID(incident.ID), len(events),
		),
		Markdown: truncateMarkdown(body.String(), 12000),
		Context: []string{
			"Built from the alert, agent runs, evidence, Emisar approvals, and publication state. The latest events are shown oldest first.",
		},
	}
}

func HandoffMessage(
	record core.RemediationRecord,
) Message {
	incident := record.Incident
	events := core.RemediationTimeline(record)
	var body strings.Builder
	fmt.Fprintf(
		&body,
		"## Shift handoff: %s\n\n**State:** %s, Responder %s  \n"+
			"**Signals:** %d firing / %d total  \n**Severity:** %s\n",
		escapeSlackText(incident.Title),
		incidentStatusLabel(incident.Status),
		workflowStateLabel(incident.Workflow),
		incident.FiringCount,
		incident.SignalCount,
		displayOr(incident.Severity, "unclassified"),
	)
	if incident.LastError != "" {
		fmt.Fprintf(&body, "\n**Operator action needed:** %s\n", incident.LastError)
	}
	if len(events) > 0 {
		body.WriteString("\n### Latest decisions and findings\n")
		start := max(0, len(events)-8)
		for _, event := range events[start:] {
			fmt.Fprintf(
				&body,
				"\n- **%s:** %s",
				event.CreatedAt.UTC().Format("15:04 UTC"),
				event.Title,
			)
		}
	}
	message := EvidenceResponse(
		body.String(), record.Evidence[:min(len(record.Evidence), 6)],
		record.Coverage[:min(len(record.Coverage), 12)],
		NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"This handoff is generated from durable incident state; unknown coverage remains explicit.",
	)
	return message
}

func PostmortemDraft(record core.RemediationRecord) Message {
	incident := record.Incident
	events := core.RemediationTimeline(record)
	var body strings.Builder
	closedAt := incident.ClosedAt
	if closedAt.IsZero() {
		closedAt = incident.ResolvedAt
	}
	closed := "Still open"
	if !closedAt.IsZero() {
		closed = closedAt.UTC().Format("2006-01-02 15:04 UTC")
	}
	fmt.Fprintf(
		&body,
		"## Post-incident draft: %s\n\n"+
			"**Incident:** `%s`  \n**Severity:** %s  \n**Started:** %s  \n**Closed:** %s\n\n"+
			"### What is verified\n",
		escapeSlackText(incident.Title),
		ShortID(incident.ID),
		displayOr(incident.Severity, "unclassified"),
		incident.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		closed,
	)
	if len(record.Evidence) == 0 {
		body.WriteString("\nNo structured evidence was recorded. Root cause must remain unassigned.")
	} else {
		for _, item := range record.Evidence[:min(len(record.Evidence), 8)] {
			fmt.Fprintf(
				&body, "\n- **%s:** %s",
				escapeSlackText(item.Claim), escapeSlackText(item.Observation),
			)
		}
	}
	body.WriteString("\n\n### Remediation and approvals\n")
	if len(record.Approvals) == 0 && record.Publication.IncidentID == "" {
		body.WriteString("\nNo governed operation or code publication was recorded.")
	}
	for _, approval := range record.Approvals {
		status := strings.ReplaceAll(displayOr(approval.Status, "unknown"), "_", " ")
		fmt.Fprintf(
			&body, "\n- **%s** on `%s`: %s",
			escapeSlackText(approval.ActionID), safeInlineCode(approval.RunnerRef),
			escapeSlackText(status),
		)
		if link := sourceLink(firstNonemptyUI(approval.RunURL, approval.ApprovalURL)); link != "" {
			fmt.Fprintf(&body, " - %s", link)
		}
	}
	if record.Publication.IncidentID != "" {
		publication := record.Publication
		fmt.Fprintf(
			&body, "\n- **Draft PR:** %s",
			escapeSlackText(strings.ReplaceAll(string(publication.State), "_", " ")),
		)
		if link := sourceLink(publication.PRURL); link != "" {
			fmt.Fprintf(&body, " - %s", link)
		}
	}
	body.WriteString("\n\n### Timeline\n")
	start := max(0, len(events)-20)
	for _, event := range events[start:] {
		fmt.Fprintf(
			&body,
			"\n- **%s:** %s",
			event.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			escapeSlackText(event.Title),
		)
	}
	body.WriteString("\n\n### Follow-up\n")
	body.WriteString("\n- [ ] Confirm impact and affected users")
	body.WriteString("\n- [ ] Confirm root cause from cited evidence")
	for _, item := range record.Coverage {
		if item.Status == "unknown" || item.Status == "degraded" {
			fmt.Fprintf(
				&body, "\n- [ ] Resolve %s coverage: %s",
				escapeSlackText(item.Layer), truncateUTF8(escapeSlackText(item.Detail), 300),
			)
		}
	}
	for _, approval := range record.Approvals {
		if approval.TerminalAt.IsZero() {
			fmt.Fprintf(
				&body, "\n- [ ] Complete Emisar approval for `%s`",
				safeInlineCode(approval.ActionID),
			)
		}
	}
	body.WriteString("\n- [ ] Assign remaining corrective actions and owners\n")
	message := EvidenceResponse(
		body.String(), nil, record.Coverage[:min(len(record.Coverage), 12)],
		NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"Generated from the durable remediation record. It does not invent impact, root cause, owners, or actions that were not recorded.",
	)
	return message
}

func incidentDirectoryStatus(incident core.Incident) string {
	if incident.Status == core.IncidentClosed {
		return "closed"
	}
	return workflowStateLabel(incident.Workflow)
}

func ManualHandoff(channelID string) Message {
	return Message{
		Text:   "Responder created incident room <#" + channelID + ">.",
		Header: "Incident room ready",
		Sections: []string{
			"Continue in <#" + channelID + ">. Responder is preparing the isolated workspace and will post investigation updates in the incident thread.",
		},
		Context: []string{"The originating request remains linked here for reference."},
	}
}

func EngineeringTaskHandoff(channelID string) Message {
	return Message{
		Text:   "Responder created engineering room <#" + channelID + ">.",
		Header: "Engineering room ready",
		Sections: []string{
			"Continue in <#" + channelID + ">. Responder is preparing an isolated writable working copy and will complete the requested repository work in that room.",
		},
		Context: []string{
			"No merge, push, deployment, or infrastructure change occurs without separate authorization.",
		},
	}
}

func incidentActions(
	incident core.Incident,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
) []Action {
	if incident.RootTS == "" {
		return nil
	}
	changes := Action{ID: ActionChanges, Label: "View diff", Value: incident.ID}
	review := Action{
		ID: ActionReview, Label: "Run readiness check", Value: incident.ID,
		Confirm: "Compare the isolated changes with the current repository state, check rebase and configured validation and policy gates, and report whether the fix is ready for external review. This does not merge, push, sign, or deploy.",
	}
	publish := Action{
		ID: ActionPublishPR, Label: "Create draft PR",
		Value: PublicationActionValue(incident.ID, publication.Generation), Style: "primary",
		Confirm: "Run a fresh Coop readiness review, recreate the exact approved tree in an isolated checkout, push a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
	}
	if publication.Published() || publication.NeedsUpdate() {
		publish.Label = "Update draft PR"
		publish.Confirm = "Run a fresh Coop readiness review and update the existing Responder draft PR using lease-protected branch publication? This cannot merge or deploy."
	} else if publication.State == core.PublicationFailed {
		publish.Label = "Retry draft PR"
	}
	viewPR := Action{
		ID: ActionViewPR, Label: "Open PR", Value: incident.ID,
		URL: publication.PRURL,
	}
	checkDelivery := Action{
		ID: ActionCheckDelivery, Label: "Check delivery", Value: incident.ID,
	}
	closeIncident := Action{
		ID: ActionResolve, Label: "Close incident", Value: incident.ID, Style: "danger",
		Confirm: "Close this work? Responder later reclaims zero-change or published workspace state. Unpublished changes remain retained for operator action.",
	}
	if incident.IsEngineeringTask() {
		closeIncident.Label = "Close task"
		if hasCodeChanges && !publication.Published() {
			closeIncident.Confirm = "Close this task and retain its unpublished changes? Closed Coop sessions cannot be reviewed or published. Create the draft PR first unless you intend to inspect and explicitly discard the retained work later."
		}
	}
	if incident.Status == core.IncidentClosed {
		actions := make([]Action, 0, 3)
		if hasCodeChanges {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
			if publication.Published() {
				actions = append(actions, checkDelivery)
			}
		}
		if hasCodeChanges && !publication.Published() && incident.IsEngineeringTask() {
			actions = append(actions, Action{
				ID: ActionDiscardWork, Label: "Discard retained work",
				Value: incident.ID, Style: "danger",
				Confirm: "Permanently delete this closed task's unpublished committed work and isolated Coop state? This cannot be undone. Dirty uncommitted work is never discarded.",
			})
		}
		return actions
	}
	if incident.CoopSessionID == "" {
		return []Action{closeIncident}
	}
	if incident.ActiveTurnID != "" {
		actions := []Action{{
			ID: ActionStop, Label: "Stop current run", Value: incident.ID, Style: "danger",
			Confirm: "Stop the active agent turn? The fork and queued work are preserved.",
		}}
		if hasCodeChanges {
			actions = append(actions, changes)
		}
		return actions
	}
	if publication.InProgress() {
		actions := make([]Action, 0, 2)
		if incident.CoopSessionID != "" {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return actions
	}
	if publication.State == core.PublicationFailed {
		if codeChangesKnown && !hasCodeChanges {
			actions := make([]Action, 0, 2)
			if publication.HasPR() {
				actions = append(actions, viewPR)
			}
			return append(actions, closeIncident)
		}
		actions := []Action{changes, publish}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return append(actions, closeIncident)
	}
	if publication.Published() && !hasCodeChanges {
		return []Action{viewPR, checkDelivery, closeIncident}
	}
	if publication.NeedsUpdate() {
		return []Action{changes, publish, viewPR, closeIncident}
	}
	if incident.Workflow == core.WorkflowInvestigating {
		actions := make([]Action, 0, 1)
		if hasCodeChanges {
			actions = append(actions, changes)
		}
		return actions
	}
	actions := make([]Action, 0, 4)
	if incident.Workflow != core.WorkflowBlocked {
		actions = append(actions, Action{
			ID: ActionUpdate, Label: "Ask agent for update", Value: incident.ID, Style: "primary",
			Confirm: "Ask Responder to inspect current evidence and post a concise update?",
		})
	}
	if hasCodeChanges {
		actions = append(actions, changes)
		actions = append(actions, review)
		if incident.IsEngineeringTask() {
			actions = append(actions, publish)
			if publication.HasPR() {
				actions = append(actions, viewPR)
				if publication.Published() {
					actions = append(actions, checkDelivery)
				}
			}
		}
	}
	return append(actions, closeIncident)
}

func incidentStatusLabel(status core.IncidentStatus) string {
	switch status {
	case core.IncidentActive:
		return "Active"
	case core.IncidentMonitoring:
		return "Monitoring recovery"
	case core.IncidentResolved:
		return "Resolved"
	case core.IncidentClosed:
		return "Closed"
	default:
		return displayOr(strings.ReplaceAll(string(status), "_", " "), "Unknown")
	}
}

func IncidentStatusMessage(incident core.Incident) Message {
	status := incidentStatusLabel(incident.Status)
	activity := workflowStateLabel(incident.Workflow)
	next := "Reply normally in this incident channel to give Responder its next request."
	noun := "Incident"
	stateLabel := "Alert state"
	if incident.IsEngineeringTask() {
		noun = "Engineering task"
		stateLabel = "Task state"
		next = "Reply normally in this thread to give Responder its next request."
		if incident.Workflow == core.WorkflowProvisioningChannel {
			if incident.IsThreadScoped() {
				activity = "Starting task"
			} else {
				activity = "Creating working room"
			}
		}
	}
	switch incident.Workflow {
	case core.WorkflowProvisioningChannel, core.WorkflowProvisioningSession:
		next = "Wait for preparation to finish. The work card will update automatically."
	case core.WorkflowHolding:
		next = "Responder will start when capacity is available. Close another work item if this is urgent."
	case core.WorkflowInvestigating:
		next = "An agent turn is running or queued. Wait for its update, or use `/responder stop` to cancel it."
	case core.WorkflowBlocked:
		next = "Read *Action needed* on the work card, resolve that blocker, then reply to continue."
	case core.WorkflowClosed:
		next = "This work item no longer accepts agent turns. Dirty or unpublished changes are retained; published or zero-change workspace state expires by policy."
	}
	return Message{
		Text: fmt.Sprintf(
			"%s %s is %s. Responder is %s. %s",
			noun, ShortID(incident.ID), status, activity, signalStateSummary(incident),
		),
		Header: noun + " " + ShortID(incident.ID) + ": " + activity,
		Sections: []string{
			"*" + stateLabel + ": " + status + "*\n" + signalStateSummary(incident),
			"*Responder activity: " + activity + "*\n" + workflowStateDescription(incident),
			"*What to do next*\n" + next,
		},
		Context: []string{
			"Status is read-only. No publication, merge, signing, deployment, or infrastructure change was requested.",
		},
	}
}

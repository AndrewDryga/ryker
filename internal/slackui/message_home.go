package slackui

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

func OperationsHome(
	openIncidents int,
	totalIncidents int,
	openSessions int,
	failedWork int,
	publishedPRs int,
	cleanupPending int,
	cleanupBlocked int,
	memoryActive int,
	preferenceActive int,
	ruleActive int,
	scheduleActive int,
	commitmentActive int,
	incidents []core.Incident,
	commitments []core.Commitment,
	situations []core.ChannelMemory,
	memories []core.MemoryEntry,
	preferences []core.ResponderPreference,
	rules []core.StandingRule,
) Message {
	state := "Operational"
	if failedWork > 0 {
		state = "Needs attention"
	}
	message := Message{
		Text: fmt.Sprintf(
			"Responder operations: %s. %d open work items, %d failed work items.",
			state, openIncidents+commitmentActive, failedWork,
		),
		Header:   "Emisar",
		Sections: []string{"*" + state + "*"},
		Fields: []Field{
			{Label: "Open work", Value: fmt.Sprint(openIncidents)},
			{Label: "Active commitments", Value: fmt.Sprint(commitmentActive)},
			{Label: "Active sessions", Value: fmt.Sprint(openSessions)},
			{Label: "Failed work", Value: fmt.Sprint(failedWork)},
			{Label: "Recorded work", Value: fmt.Sprint(totalIncidents)},
			{Label: "Draft PRs", Value: fmt.Sprint(publishedPRs)},
			{Label: "Cleanup queued", Value: fmt.Sprint(cleanupPending)},
			{Label: "Cleanup blocked", Value: fmt.Sprint(cleanupBlocked)},
			{Label: "Saved memory visible here", Value: fmt.Sprint(memoryActive)},
			{Label: "Enabled preferences", Value: fmt.Sprint(preferenceActive)},
			{Label: "Enabled standing rules", Value: fmt.Sprint(ruleActive)},
			{Label: "Active schedules", Value: fmt.Sprint(scheduleActive)},
		},
		Context: []string{
			"Ask Emisar what it is working on, what it remembers, or how a channel is configured. Slash commands remain available as recovery controls.",
		},
	}
	if cleanupBlocked > 0 {
		message.Sections = append(
			message.Sections,
			fmt.Sprintf(
				"*Retained work needs attention*\n%d Coop workspace%s could not be reclaimed "+
					"because Responder found dirty or unpublished changes. Inspect the related "+
					"task before explicitly publishing or discarding it.",
				cleanupBlocked,
				map[bool]string{true: "s", false: ""}[cleanupBlocked != 1],
			),
		)
	}
	if len(incidents) > 0 {
		var current strings.Builder
		current.WriteString("*Current work*\n")
		for _, incident := range incidents[:min(len(incidents), 8)] {
			room := "#" + displayOr(incident.ChannelName, "room pending")
			if incident.ChannelID != "" && incident.ChannelWritable() {
				room = "<#" + incident.ChannelID + ">"
			}
			fmt.Fprintf(
				&current,
				"\n- **%s** - %s - %s - %s",
				escapeSlackText(incident.Title),
				incidentDirectoryStatus(incident),
				room,
				signalStateSummary(incident),
			)
		}
		message.Sections = append(message.Sections, current.String())
	}
	if len(commitments) > 0 {
		var owed strings.Builder
		owed.WriteString("*What Emisar owes the team*\n")
		for _, commitment := range commitments[:min(len(commitments), 8)] {
			location := ""
			if commitment.ChannelID != "" {
				location = " in <#" + commitment.ChannelID + ">"
			}
			fmt.Fprintf(
				&owed,
				"\n- **%s**%s\n  %s - %s",
				escapeSlackText(commitment.Title),
				location,
				commitmentStateLabel(commitment.State),
				escapeSlackText(commitment.Status),
			)
			if commitment.NextAction != "" {
				fmt.Fprintf(
					&owed,
					"\n  Next: %s",
					escapeSlackText(commitment.NextAction),
				)
			}
		}
		message.Sections = append(message.Sections, owed.String())
	}
	if len(situations) > 0 {
		var current strings.Builder
		current.WriteString("*Current channel situations*\n")
		for _, situation := range situations[:min(len(situations), 5)] {
			summary := strings.TrimSpace(situation.State.SituationSummary)
			if summary == "" {
				summary = displayOr(
					strings.TrimSpace(situation.State.Goal),
					"Context retained; no current summary",
				)
			}
			fmt.Fprintf(
				&current,
				"\n- <#%s> - %s",
				situation.ChannelID,
				escapeSlackText(summary),
			)
			if count := len(situation.State.OpenLoops); count > 0 {
				suffix := "s"
				if count == 1 {
					suffix = ""
				}
				fmt.Fprintf(&current, "\n  %d open loop%s", count, suffix)
			}
			fmt.Fprintf(
				&current,
				"\n  Updated %s",
				situation.UpdatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			)
		}
		message.Sections = append(message.Sections, current.String())
	}
	if len(memories) > 0 {
		var saved strings.Builder
		saved.WriteString("*Operational memory*\n")
		for index, entry := range memories[:min(len(memories), 6)] {
			fmt.Fprintf(
				&saved,
				"\n%d. **%s** `%s` `%s`\n   %s scope; expires %s",
				index+1,
				escapeSlackText(entry.SubjectKey),
				entry.Predicate,
				entry.Value,
				entry.ScopeKind,
				entry.ExpiresAt.UTC().Format("2006-01-02"),
			)
			message.Actions = append(message.Actions, Action{
				ID:      ActionForgetMemory,
				Label:   fmt.Sprintf("Forget memory %d", index+1),
				Value:   entry.ID,
				Style:   "danger",
				Confirm: "Permanently forget this saved memory? The audit trail will retain only the entry ID and outcome, not its value.",
			})
		}
		message.Sections = append(message.Sections, saved.String())
		message.Context = append(
			message.Context,
			"Saved memory is an operator-confirmed hint, never current health evidence. Fresh live observations and repository state take precedence.",
		)
	}
	if len(preferences) > 0 {
		var saved strings.Builder
		saved.WriteString("*Responder preferences*\n")
		for index, preference := range preferences[:min(len(preferences), 3)] {
			state := "disabled"
			if preference.Enabled {
				state = "enabled"
			}
			fmt.Fprintf(
				&saved,
				"\n%d. **`%s` = `%s`** - %s\n   %s scope; expires %s",
				index+1,
				preference.Name,
				preference.Value,
				state,
				preference.ScopeKind,
				preference.ExpiresAt.UTC().Format("2006-01-02"),
			)
			message.Actions = append(message.Actions, preferenceActions(preference)...)
		}
		message.Sections = append(message.Sections, saved.String())
	}
	if len(rules) > 0 {
		var saved strings.Builder
		saved.WriteString("*Standing rules*\n")
		for index, rule := range rules[:min(len(rules), 3)] {
			state := "disabled"
			if rule.Enabled {
				state = "enabled"
			}
			fmt.Fprintf(
				&saved,
				"\n%d. **`%s` -> `%s`** - %s\n   channel `%s`; %d runs; expires %s",
				index+1,
				rule.Trigger,
				rule.Action,
				state,
				rule.ChannelID,
				rule.TriggerCount,
				rule.ExpiresAt.UTC().Format("2006-01-02"),
			)
			message.Actions = append(message.Actions, ruleActions(rule)...)
		}
		message.Sections = append(message.Sections, saved.String())
	}
	return message
}

func OperationsHomeRestricted() Message {
	return Message{
		Text:   "Responder operations access is limited to configured operators.",
		Header: "Emisar",
		Sections: []string{
			"*Operations dashboard access is restricted*\n" +
				"Incident titles, active work, failures, and session state are visible only to " +
				"configured Responder operators.",
			"You can still ask Responder read-only operational questions in a channel or direct " +
				"message where the app is available. Incident, engineering, publication, and " +
				"configuration controls require operator access.",
		},
		Context: []string{
			"An administrator can grant access by adding your Slack user ID to `slack.operators` and restarting Responder.",
		},
	}
}

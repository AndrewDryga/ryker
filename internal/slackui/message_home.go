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
	// This page answers one question: what needs me?
	//
	// It used to answer four at once — what needs you, a cleanup chore, how the
	// workspace is configured, and which of Responder's own mistakes to pin as
	// tests — with nothing marking where one ended and the next began. Four
	// jobs in one scroll reads as a mess of text and buttons no matter how well
	// each line is written, so the page now leads with the answer, and the two
	// secondary jobs sit below it under their own headings.
	needs := commitmentActive
	state := "Nothing needs you"
	if needs > 0 {
		state = fmt.Sprintf("%d need%s you",
			needs, map[bool]string{true: "", false: "s"}[needs != 1])
	}
	// Everything the page is not about, on one line, each with the command that
	// opens it. These were nine tiles and a paragraph-length banner competing
	// with the work for the reader's attention.
	elsewhere := make([]string, 0, 4)
	if failedWork > 0 {
		elsewhere = append(elsewhere, fmt.Sprintf("%d failed · `/responder failures`", failedWork))
	}
	if cleanupBlocked > 0 {
		elsewhere = append(elsewhere, fmt.Sprintf("%d retained workspaces · `/responder sessions`", cleanupBlocked))
	}
	if publishedPRs > 0 {
		elsewhere = append(elsewhere, fmt.Sprintf("%d draft PRs", publishedPRs))
	}
	if scheduleActive > 0 {
		label := "tasks"
		if scheduleActive == 1 {
			label = "task"
		}
		elsewhere = append(elsewhere, fmt.Sprintf(
			"%d scheduled %s · `/responder schedules`", scheduleActive, label,
		))
	}
	elsewhere = append(elsewhere, "`/responder status` for everything in flight")

	message := Message{
		Text: fmt.Sprintf(
			"Emisar: %s. %d failed work items.", state, failedWork,
		),
		Header:   "Emisar",
		Sections: []string{"*" + state + "*"},
		Context:  []string{strings.Join(elsewhere, "\n")},
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
	// Only work a person can move. A failed run belongs to the retry machinery
	// and to the failure count, not to a list titled with what is owed to the
	// team — that framing put a Coop idempotency conflict in front of an
	// operator as a task.
	// The same alert firing twice produces two commitments with the same
	// headline and nothing to tell them apart on the page, which reads as a
	// rendering fault. Collapse them and say how many.
	owedItems := make([]core.Commitment, 0, len(commitments))
	repeats := make(map[string]int, len(commitments))
	seenHeadline := make(map[string]bool, len(commitments))
	for _, commitment := range commitments {
		if !operatorActionable(commitment.State) {
			continue
		}
		key := commitmentHeadline(commitment.Title)
		repeats[key]++
		if seenHeadline[key] {
			continue
		}
		seenHeadline[key] = true
		owedItems = append(owedItems, commitment)
	}
	if len(owedItems) > 0 {
		message.Sections = append(message.Sections, "*Needs a decision from you*")
		for _, commitment := range owedItems[:min(len(owedItems), 5)] {
			headline := commitmentHeadline(commitment.Title)
			line := "*" + headline + "*"
			if count := repeats[headline]; count > 1 {
				line += fmt.Sprintf(" ×%d", count)
			}
			if commitment.ChannelID != "" {
				line += " · <#" + commitment.ChannelID + ">"
			}
			// What to do, not why Responder stopped. The status paragraph is
			// Responder reasoning about itself; five of them made a wall to mine
			// for the one line that was an instruction. It stays in the thread,
			// and is used here only when there is no next action to show.
			switch {
			case !genericProgressText(commitment.NextAction):
				line += "\n" + escapeSlackText(shortInstruction(commitment.NextAction))
			case !genericProgressText(commitment.Status):
				line += "\n" + escapeSlackText(shortInstruction(commitment.Status))
			}
			message = AppendRow(message, line, openThreadAction(commitment))
		}
		if extra := len(owedItems) - 5; extra > 0 {
			message.Sections = append(message.Sections,
				fmt.Sprintf("_and %d more — `/responder status`_", extra))
		}
	}

	// A channel with no summary and no goal has nothing to report, and
	// "Context retained; no current summary" is a placeholder wearing the
	// costume of content — three of them filled a section that said nothing.
	described := make([]core.ChannelMemory, 0, len(situations))
	for _, situation := range situations {
		if strings.TrimSpace(situation.State.SituationSummary) != "" ||
			strings.TrimSpace(situation.State.Goal) != "" {
			described = append(described, situation)
		}
	}
	if len(described) > 0 {
		var current strings.Builder
		current.WriteString("*Channel situations*\n")
		for _, situation := range described[:min(len(described), 5)] {
			summary := strings.TrimSpace(situation.State.SituationSummary)
			if summary == "" {
				summary = strings.TrimSpace(situation.State.Goal)
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
		message.Sections = append(message.Sections, "*Settings* — how Responder behaves here")
		for _, preference := range preferences[:min(len(preferences), 3)] {
			state := "disabled"
			if preference.Enabled {
				state = "enabled"
			}
			// One row per preference, so its controls sit under it. Two channel
			// preferences read as identical duplicates when the scope says only
			// "channel scope", so the row names the channel it applies to.
			scope := preference.ScopeKind + " scope"
			if preference.ScopeKind == "channel" && preference.ScopeKey != "" {
				scope = "<#" + preference.ScopeKey + ">"
			}
			message = AppendRow(message, fmt.Sprintf(
				"*`%s` = `%s`* — %s\n%s; expires %s",
				preference.Name,
				preference.Value,
				state,
				scope,
				preference.ExpiresAt.UTC().Format("2006-01-02"),
			), preferenceActions(preference))
		}
	}
	if len(rules) > 0 {
		message.Sections = append(message.Sections, "*Standing rules* — what Responder does automatically")
		for _, rule := range rules[:min(len(rules), 3)] {
			state := "disabled"
			if rule.Enabled {
				state = "enabled"
			}
			message = AppendRow(message, fmt.Sprintf(
				"*`%s` -> `%s`* — %s\n<#%s>; %d runs; expires %s",
				rule.Trigger,
				rule.Action,
				state,
				rule.ChannelID,
				rule.TriggerCount,
				rule.ExpiresAt.UTC().Format("2006-01-02"),
			), ruleActions(rule))
		}
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

// commitmentHeadline turns a work title into something readable in a list.
//
// A title is often the Slack message that started the work, so it arrives as
// raw markup: an alert row renders as the whole
// "<https://grafana…/view?orgId=1|[VA1 FIRING:1] WARNING | …> *FIRING - 1 ale…"
// and fills three lines with a URL nobody can act on. Keep the link text,
// which is the alert name, and drop the address.
func commitmentHeadline(title string) string {
	cleaned := slackLinkTextPattern.ReplaceAllString(strings.TrimSpace(title), "$1")
	cleaned = strings.TrimSpace(bareURLPattern.ReplaceAllString(cleaned, ""))
	cleaned = singleLine(cleaned)
	// The source message's own emphasis leaks in as stray * and _ once the
	// surrounding text is cut, and a template that did not resolve arrives as
	// "[no value]". Both read as corruption in a list.
	cleaned = strings.NewReplacer("*", "", "_", "", "`", "").Replace(cleaned)
	cleaned = strings.ReplaceAll(cleaned, "[no value]", "")
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	if cleaned == "" {
		cleaned = "Untitled work"
	}
	// Cut on a word so a headline does not end mid-token like "…for 24h FI".
	if trimmed := truncateUTF8(cleaned, 110); trimmed != cleaned {
		if cut := strings.LastIndex(trimmed, " "); cut > 40 {
			trimmed = trimmed[:cut]
		}
		cleaned = strings.TrimRight(trimmed, " ,;:-") + "…"
	}
	return escapeSlackText(cleaned)
}

// genericProgressText reports whether a status or next action says nothing the
// reader can act on. "Needs operator attention" beside a Blocked label is the
// label again, and "Review the blocker or retry" is a restatement of the word
// blocked — six of those in a row was most of the App Home's owed-work list.
func genericProgressText(value string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(value), " "))
	normalized = strings.TrimRight(normalized, ".")
	switch normalized {
	case "",
		"needs operator attention",
		"review the blocker or retry",
		"retry the same investigation from its saved evidence",
		"the host could not validate the final structured result",
		"needs attention",
		"blocked":
		return true
	}
	// Internal machinery, not a sentence for an operator. A transport error
	// names a component the reader does not operate and cannot act on, so it
	// belongs in the failure record rather than in a list of things to do.
	for _, marker := range []string{
		"coop api", "idempotency", "dial unix", "context deadline exceeded",
		"connection refused", "acp request was rejected", "500 internal",
	} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

// operatorActionable reports whether a work item is waiting on a person.
//
// A failed run is not a promise owed to the team; it is a run that died, and
// the retry is Responder's job. Listing failures as owed work is what put a
// Coop idempotency conflict in front of an operator as something to do.
func operatorActionable(state core.CommitmentState) bool {
	switch state {
	case core.CommitmentBlocked, core.CommitmentQueued,
		core.CommitmentWorking, core.CommitmentFinishing:
		return true
	default:
		return false
	}
}

// openThreadAction is the button that makes an item on this page actionable.
//
// A page headed "needs a decision from you" that offers no way to reach the
// conversation is a list of homework. app_redirect is used rather than a
// workspace permalink because it needs no team domain, which this process does
// not store, and Slack resolves it to the same message.
func openThreadAction(commitment core.Commitment) []Action {
	if commitment.ChannelID == "" {
		return nil
	}
	url := "https://slack.com/app_redirect?channel=" + commitment.ChannelID
	if anchor := strings.TrimSpace(commitment.ThreadTS); anchor != "" {
		url += "&message_ts=" + anchor
	}
	return []Action{{ID: ActionOpenWorkThread, Label: "Open", Value: commitment.ID, URL: url}}
}

// shortInstruction keeps the first sentence of a next action.
//
// These arrive as a paragraph — "read the run holding the lock: if it is stuck
// in Applying with a dead executor, force-unlock and queue a fresh run; if it
// is genuinely applying, wait. Say which workspace and I can carry the rest."
// The first sentence is the instruction; the rest is the caveats, which belong
// in the thread the Open button now reaches.
func shortInstruction(value string) string {
	trimmed := singleLine(strings.TrimSpace(value))
	if trimmed == "" {
		return ""
	}
	if cut := strings.IndexAny(trimmed, ".!?"); cut > 30 && cut < len(trimmed)-1 {
		trimmed = trimmed[:cut+1]
	}
	if len(trimmed) > 160 {
		trimmed = truncateUTF8(trimmed, 160)
		if space := strings.LastIndex(trimmed, " "); space > 60 {
			trimmed = trimmed[:space]
		}
		trimmed = strings.TrimRight(trimmed, " ,;:-") + "…"
	}
	return "→ " + trimmed
}

package slackui

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func WithMemoryOffer(
	message Message,
	offer core.MemoryOffer,
	actionValue string,
	scopeLabel string,
	expiresLabel string,
) Message {
	if offer.Predicate == "guidance" {
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*Proposed guidance*\n> %s\n\nApplies to: %s · Expires: %s",
			escapeSlackText(offer.Value),
			guidanceOfferScopeLabel(offer, scopeLabel),
			expiresLabel,
		))
		message.Context = append(
			message.Context,
			"Nothing is saved yet. This can steer future replies, but it cannot start work, prove operational state, or authorize any action.",
		)
		message.Actions = append(message.Actions, Action{
			ID:    ActionRememberMemory,
			Label: "Remember this",
			Value: actionValue,
			Style: "primary",
			Confirm: "Remember this guidance for " + expiresLabel +
				"? Your current request and Responder's safety policy will always take precedence.",
		})
		return message
	}
	revision := ""
	if offer.SourceRevision != "" {
		revision = "\nSource revision: `" + offer.SourceRevision + "`"
	}
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Proposed operational memory*\n`%s` *%s* `%s`\n\nScope: %s · Visibility: `%s` · Expires: %s%s",
		offer.Subject,
		offer.Predicate,
		offer.Value,
		scopeLabel,
		offer.Visibility,
		expiresLabel,
		revision,
	))
	message.Context = append(
		message.Context,
		"Nothing is saved yet. This is an operator-reviewed hint, not live evidence; Responder will re-check it against repositories and operational tools before relying on it.",
	)
	message.Actions = append(message.Actions, Action{
		ID:    ActionRememberMemory,
		Label: "Remember for " + expiresLabel,
		Value: actionValue,
		Style: "primary",
		Confirm: "Save this " + scopeLabel + " memory for " + expiresLabel +
			"? It may guide future investigations but cannot establish current health or authorize a change.",
	})
	return message
}

func WithPreferenceOffer(
	message Message,
	offer core.PreferenceOffer,
	preference core.ResponderPreference,
	actionValue string,
	expiresLabel string,
) Message {
	title, description := preferenceDescription(preference)
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Proposed preference: %s*\n"+
			"%s\n\n"+
			"Scope: %s · Expires: %s",
		title,
		description,
		preferenceScopeLabel(preference),
		expiresLabel,
	))
	boundary := "This changes investigation depth or presentation only"
	if offer.Name == "response_location" {
		boundary = "This changes where future Slack replies appear only"
	}
	message.Context = append(
		message.Context,
		"Nothing is saved yet. "+boundary+"; it cannot establish health, create an incident, edit files, approve an action, or mutate infrastructure.",
	)
	message.Actions = append(message.Actions, Action{
		ID:    ActionRememberPreference,
		Label: "Remember this",
		Value: actionValue,
		Style: "primary",
		Confirm: "Save this " + preference.ScopeKind + " preference for " +
			expiresLabel + "? It changes future Responder behavior within the shown scope.",
	})
	return message
}

func WithRuleOffer(
	message Message,
	offer core.RuleOffer,
	rule core.StandingRule,
	actionValue string,
	expiresLabel string,
) Message {
	description := fmt.Sprintf(
		"When `%s` matches a `%s` message, run `%s` against repository `%s` and reply in that message's thread.",
		offer.Trigger,
		offer.SourceKind,
		offer.Action,
		offer.Repository,
	)
	label := "Enable standing rule"
	confirmation := "Matching messages will start a bounded investigation and receive a threaded reply."
	if offer.Trigger == "operational_alert" && offer.Action == "triage_alert" {
		source := "alert messages"
		switch offer.SourceKind {
		case "app":
			source = "app alerts"
		case "human":
			source = "alerts posted by teammates"
		}
		description = "For " + source + " in this channel, acknowledge with :eyes:, investigate using current repository and live evidence, and reply in the alert's thread with impact, likely cause, and focused fixes. For critical alerts, include the safest immediate remediation to consider."
		label = "Enable alert triage"
		confirmation = "Matching alerts will be acknowledged, investigated read-only, and receive an evidence-backed threaded reply."
	}
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Proposed standing rule*\n"+
			"%s\n\n"+
			"Scope: This channel · Expires: %s",
		description,
		expiresLabel,
	))
	message.Context = append(
		message.Context,
		"Nothing is saved yet. This rule listens only for its typed trigger, even when broad proactive triage is off. It is read-only and cannot create an incident, edit files, deploy, approve, or mutate infrastructure.",
	)
	message.Actions = append(message.Actions, Action{
		ID:    ActionRememberRule,
		Label: label,
		Value: actionValue,
		Style: "primary",
		Confirm: "Enable this read-only standing rule in the current channel for " +
			expiresLabel + "? " + confirmation,
	})
	return message
}

func WithScheduleOffer(
	message Message,
	task core.ScheduledTask,
	actionValue string,
	when string,
) Message {
	message.Text = conditionalScheduleOfferLead(message.Text)
	message.Markdown = conditionalScheduleOfferLead(message.Markdown)
	destination := "<#" + firstNonemptyUI(task.DeliveryChannel, task.ChannelID) + ">"
	if task.ThreadTS != "" &&
		firstNonemptyUI(task.DeliveryChannel, task.ChannelID) == task.ChannelID {
		destination = "this thread"
	}
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Proposed scheduled task: %s*\n%s\n\n*When:* %s\n*Where:* %s · *Repository:* `%s`",
		escapeSlackText(task.Title), escapeSlackText(task.Prompt), when,
		destination, safeInlineCode(task.Repository),
	))
	message.Context = append(message.Context,
		"Nothing is scheduled yet. Each occurrence re-runs this request through current Coop, repository, tool, and Emisar policies. It cannot reuse an old approval, and overlapping occurrences are skipped.",
	)
	message.Actions = append(message.Actions, Action{
		ID: ActionRememberSchedule, Label: "Schedule this", Value: actionValue,
		Style:   "primary",
		Confirm: "Create this scheduled task? Future runs use the current policies and may still require operator approval.",
	})
	return message
}

func conditionalScheduleOfferLead(value string) string {
	if match := scheduleCommitmentPattern.FindStringIndex(value); match != nil {
		return "Confirm the schedule below and I’ll " +
			strings.TrimSpace(value[match[1]:])
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "confirm") && strings.Contains(lower, "schedule") {
		return value
	}
	return "Confirm the schedule below to create this task.\n\n" + value
}

func ScheduleOfferUnavailable(message Message) Message {
	message.Text = "I couldn’t safely prepare that schedule, so nothing was scheduled."
	message.Markdown = message.Text
	message.Sections = nil
	message.Fields = nil
	message.Context = []string{
		"Please restate the timing and task. Responder will show the exact schedule for confirmation before saving it.",
	}
	message.Actions = nil
	return message
}

func scheduleToggleValue(id string, enabled bool) string {
	data, _ := json.Marshal(struct {
		ID      string `json:"id"`
		Enabled bool   `json:"enabled"`
	}{ID: id, Enabled: enabled})
	return string(data)
}

func scheduleActions(task core.ScheduledTask) []Action {
	actions := make([]Action, 0, 4)
	label := "Pause schedule"
	if !task.Enabled {
		label = "Resume schedule"
	}
	if !task.NextRunAt.IsZero() {
		actions = append(actions, Action{ID: ActionToggleSchedule, Label: label, Value: scheduleToggleValue(task.ID, !task.Enabled)})
	}
	return append(actions,
		Action{ID: ActionRunSchedule, Label: "Run now", Value: task.ID, Style: "primary"},
		Action{ID: ActionEditSchedule, Label: "Replace", Value: task.ID},
		Action{ID: ActionDeleteSchedule, Label: "Delete", Value: task.ID, Style: "danger", Confirm: "Delete this scheduled task? Future occurrences will not run."},
	)
}

func scheduleDirectoryActions(task core.ScheduledTask, number int) []Action {
	actions := scheduleActions(task)
	for index := range actions {
		actions[index].Label += fmt.Sprintf(" #%d", number)
	}
	return actions
}

func ScheduleSavedMessage(task core.ScheduledTask) Message {
	destination := "<#" + firstNonemptyUI(task.DeliveryChannel, task.ChannelID) + ">"
	if task.ThreadTS != "" && firstNonemptyUI(task.DeliveryChannel, task.ChannelID) == task.ChannelID {
		destination = "this thread"
	}
	return Message{
		Text:     "Scheduled " + task.Title + ". Next run: " + task.NextRunAt.Format(time.RFC3339),
		Header:   "Scheduled task created",
		Sections: []string{fmt.Sprintf("*%s*\n%s\n\nNext run: %s\nDelivery: %s\nRepository: `%s`", escapeSlackText(task.Title), escapeSlackText(task.Prompt), task.NextRunAt.In(timeLocation(task.Timezone)).Format("Mon, 02 Jan 2006 15:04 MST"), destination, safeInlineCode(task.Repository))},
		Context:  []string{"I’ll run only one copy at a time. Each occurrence uses current access and approval rules."},
		Actions:  scheduleActions(task),
	}
}

func ScheduledRunStartedMessage(task core.ScheduledTask, scheduledFor time.Time) Message {
	title := strings.TrimSpace(task.Title)
	if title == "" {
		title = "Scheduled check"
	}
	return Message{
		Text:     fmt.Sprintf("%s started", title),
		Header:   title,
		Sections: []string{"Scheduled check started. Emisar is gathering fresh evidence and will report in this thread."},
		Context:  []string{"Scheduled for " + scheduledFor.UTC().Format("2006-01-02 15:04 UTC")},
	}
}

func ScheduleStateMessage(task core.ScheduledTask) Message {
	state := "paused"
	if task.Enabled {
		state = "active"
	}
	return Message{
		Text:     "Scheduled task " + task.Title + " is " + state + ".",
		Header:   "Schedule " + state,
		Sections: []string{"*" + escapeSlackText(task.Title) + "* is now " + state + "."},
		Actions:  scheduleActions(task),
	}
}

func ScheduleDeletedMessage() Message {
	return Message{Text: "Scheduled task deleted.", Header: "Schedule deleted", Sections: []string{"Future occurrences will not run. A task already in progress can finish. Existing audit records age out with operational retention."}}
}

func ScheduleDirectoryMessage(tasks []core.ScheduledTask) Message {
	message := Message{Text: fmt.Sprintf("Emisar has %d unexpired scheduled tasks in this channel.", len(tasks)), Header: "Scheduled tasks for this channel", Context: []string{"Schedules decide when to submit a request. Every occurrence still uses current Coop, repository, tool, and Emisar policy."}}
	if len(tasks) == 0 {
		message.Sections = []string{"No scheduled tasks are configured here.", "Example: `@Emisar every Monday at 09:00, summarize production health in this channel`. I’ll normalize the timing and ask for confirmation."}
		return message
	}
	for index, task := range tasks[:min(len(tasks), 8)] {
		state := "paused"
		if task.Enabled {
			state = "active"
		} else if task.NextRunAt.IsZero() {
			state = "completed"
		}
		next := "none"
		if !task.NextRunAt.IsZero() {
			next = task.NextRunAt.In(timeLocation(task.Timezone)).Format("2006-01-02 15:04 MST")
		}
		message.Sections = append(message.Sections, fmt.Sprintf("*%d. %s*\n%s · next: %s · last: %s\nRepository: `%s`", index+1, escapeSlackText(task.Title), state, next, firstNonemptyUI(task.LastOutcome, "never"), safeInlineCode(task.Repository)))
		message.Actions = append(message.Actions, scheduleDirectoryActions(task, index+1)...)
	}
	return message
}

func PreferenceSavedMessage(
	preference core.ResponderPreference,
	replaced bool,
) Message {
	title, description := preferenceDescription(preference)
	header := "Responder preference saved"
	if replaced {
		header = "Responder preference updated"
	}
	return Message{
		Text: fmt.Sprintf(
			"%s: %s.",
			header, description,
		),
		Header: header,
		Sections: []string{fmt.Sprintf(
			"*%s*\n%s\n\nScope: %s\nExpires: %s",
			title,
			description,
			preferenceScopeLabel(preference),
			preference.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
		)},
		Context: []string{preferencePrecedenceText(preference) +
			" It does not authorize incidents or changes."},
		Actions: preferenceActions(preference),
	}
}

func PreferenceStateMessage(preference core.ResponderPreference) Message {
	state := "disabled"
	if preference.Enabled {
		state = "enabled"
	}
	return Message{
		Text:   fmt.Sprintf("Responder preference %s is %s.", preference.Name, state),
		Header: "Preference " + state,
		Sections: []string{fmt.Sprintf(
			"`%s` remains `%s` for %s and is now *%s*.",
			preference.Name, preference.Value, preferenceScopeLabel(preference), state,
		)},
		Context: []string{
			"Disabled preferences remain stored until expiry or deletion and are not supplied to investigations.",
		},
		Actions: preferenceActions(preference),
	}
}

func PreferenceDeletedMessage() Message {
	return Message{
		Text:     "Responder permanently deleted the selected preference.",
		Header:   "Preference deleted",
		Sections: []string{"The preference will no longer affect future investigations."},
		Context:  []string{"The audit trail retains only its ID, scope, and deletion outcome."},
	}
}

func PreferenceDirectoryMessage(
	preferences []core.ResponderPreference,
) Message {
	message := Message{
		Text:   fmt.Sprintf("Responder has %d unexpired preferences visible here.", len(preferences)),
		Header: "Responder preferences",
		Context: []string{
			"Precedence is operator, channel, repository, then workspace. Disabled preferences are retained but do not affect investigations.",
		},
	}
	if len(preferences) == 0 {
		message.Sections = []string{
			"No operator, channel, repository, or workspace preference matches this context.",
			"Examples: `@Emisar when I ask for infrastructure health, always run a deep check` or `@Emisar from now on keep responses concise in this channel`. Emisar will show a confirmation before saving.",
		}
		return message
	}
	for index, preference := range preferences[:min(len(preferences), 8)] {
		state := "disabled"
		if preference.Enabled {
			state = "enabled"
		}
		title, description := preferenceDescription(preference)
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*%d. %s*\n%s\n%s · %s · expires %s",
			index+1,
			title,
			description,
			state,
			preferenceScopeLabel(preference),
			preference.ExpiresAt.UTC().Format("2006-01-02"),
		))
		message.Actions = append(message.Actions, preferenceActions(preference)...)
	}
	return message
}

func preferenceDescription(preference core.ResponderPreference) (string, string) {
	switch preference.Name {
	case "health_check_depth":
		return "Health-check depth", "Use " + preference.Value + " infrastructure health checks."
	case "response_detail":
		return "Response detail", "Use " + preference.Value + " detail in responses."
	case "response_location":
		switch preference.Value {
		case "prefer_thread":
			return "Reply location", "Prefer threads unless the current conversation explicitly moves to the channel."
		case "prefer_channel":
			return "Reply location", "Prefer channel replies unless the current conversation explicitly stays in a thread."
		default:
			return "Reply location", "Follow the current conversation location."
		}
	default:
		return preference.Name, "Use " + preference.Value + "."
	}
}

func RuleSavedMessage(rule core.StandingRule, replaced bool) Message {
	header := "Standing rule enabled"
	if replaced {
		header = "Standing rule updated"
	}
	return Message{
		Text: fmt.Sprintf(
			"%s: %s triggers %s in this channel.",
			header, rule.Trigger, rule.Action,
		),
		Header: header,
		Sections: []string{fmt.Sprintf(
			"`%s` -> `%s`\n\nRepository: `%s` · Source: `%s`\n"+
				"Expires: %s",
			rule.Trigger,
			rule.Action,
			rule.Repository,
			rule.SourceKind,
			rule.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
		)},
		Context: []string{
			"Matching messages now start a read-only investigation and receive a threaded reply, even when broad proactive triage is off. Slack event IDs and durable rule runs prevent duplicate execution.",
		},
		Actions: ruleActions(rule),
	}
}

func RuleStateMessage(rule core.StandingRule) Message {
	state := "disabled"
	if rule.Enabled {
		state = "enabled"
	}
	return Message{
		Text:   fmt.Sprintf("Standing rule %s is %s.", rule.Trigger, state),
		Header: "Standing rule " + state,
		Sections: []string{fmt.Sprintf(
			"`%s` -> `%s` is now *%s* in this channel.",
			rule.Trigger, rule.Action, state,
		)},
		Context: []string{
			"Disabled rules remain stored until expiry or deletion and do not admit or investigate matching messages.",
		},
		Actions: ruleActions(rule),
	}
}

func RuleDeletedMessage() Message {
	return Message{
		Text:     "Responder permanently deleted the selected standing rule.",
		Header:   "Standing rule deleted",
		Sections: []string{"Matching messages will no longer trigger this rule."},
		Context:  []string{"Durable execution records age out with normal operational retention."},
	}
}

func RuleDirectoryMessage(rules []core.StandingRule) Message {
	message := Message{
		Text:   fmt.Sprintf("Responder has %d unexpired standing rules in this channel.", len(rules)),
		Header: "Standing rules for this channel",
		Context: []string{
			"Rules are typed, read-only subscriptions. They can admit matching messages while broad proactive triage is off; they never create incidents or authorize changes.",
		},
	}
	if len(rules) == 0 {
		message.Sections = []string{
			"No standing rules are configured in this channel.",
			"Example: `@Emisar when you see a new Terraform plan here, review its main diff and red flags`. Emisar will show the normalized trigger, repository, expiry, and safety boundary before saving.",
		}
		return message
	}
	for index, rule := range rules[:min(len(rules), 8)] {
		state := "disabled"
		if rule.Enabled {
			state = "enabled"
		}
		lastRun := "never"
		if !rule.LastTriggered.IsZero() {
			lastRun = rule.LastTriggered.UTC().Format("2006-01-02 15:04 UTC")
		}
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*%d.* `%s` -> `%s`\n%s · source `%s` · repository `%s`\n"+
				"Runs: %d · last: %s · expires: %s",
			index+1,
			rule.Trigger,
			rule.Action,
			state,
			rule.SourceKind,
			rule.Repository,
			rule.TriggerCount,
			lastRun,
			rule.ExpiresAt.UTC().Format("2006-01-02"),
		))
		message.Actions = append(message.Actions, ruleActions(rule)...)
	}
	return message
}

func preferenceScopeLabel(preference core.ResponderPreference) string {
	switch preference.ScopeKind {
	case "operator":
		return "You (operator preference)"
	case "channel":
		return "This channel"
	case "repository":
		return "Repository `" + safeInlineCode(preference.ScopeKey) + "`"
	case "workspace":
		return "This Slack workspace"
	default:
		return "Unknown scope"
	}
}

func preferencePrecedenceText(preference core.ResponderPreference) string {
	switch preference.ScopeKind {
	case "operator":
		return "The preference is enabled and has the highest precedence for your requests."
	case "channel":
		return "The preference is enabled. Your operator preference, if configured, takes precedence."
	case "repository":
		return "The preference is enabled. Operator and channel preferences, if configured, take precedence."
	case "workspace":
		return "The preference is enabled. Operator, channel, and repository preferences, if configured, take precedence."
	default:
		return "The preference is enabled."
	}
}

func preferenceActions(preference core.ResponderPreference) []Action {
	label := "Disable preference"
	if !preference.Enabled {
		label = "Enable preference"
	}
	return []Action{
		{
			ID: ActionTogglePreference, Label: label,
			Value: behaviorToggleValue(preference.ID, !preference.Enabled),
		},
		{
			ID: ActionEditPreference, Label: "Edit preference",
			Value: preference.ID,
		},
		{
			ID: ActionDeletePreference, Label: "Delete preference",
			Value: preference.ID, Style: "danger",
			Confirm: "Permanently delete this Responder preference? It will stop affecting future investigations.",
		},
	}
}

func ruleActions(rule core.StandingRule) []Action {
	label := "Disable rule"
	if !rule.Enabled {
		label = "Enable rule"
	}
	return []Action{
		{
			ID: ActionToggleRule, Label: label,
			Value: behaviorToggleValue(rule.ID, !rule.Enabled),
		},
		{
			ID: ActionEditRule, Label: "Edit rule",
			Value: rule.ID,
		},
		{
			ID: ActionDeleteRule, Label: "Delete rule",
			Value: rule.ID, Style: "danger",
			Confirm: "Permanently delete this standing rule? Matching messages will no longer trigger it.",
		},
	}
}

func MemorySavedMessage(entry core.MemoryEntry, replaced bool) Message {
	if entry.Predicate == "guidance" {
		action := "remember"
		header := "Guidance remembered"
		if replaced {
			action = "use the updated guidance"
			header = "Guidance updated"
		}
		return Message{
			Text:   "I'll " + action + ": " + entry.Value,
			Header: header,
			Sections: []string{fmt.Sprintf(
				"> %s\n\nApplies to: %s · Expires: %s",
				escapeSlackText(entry.Value),
				guidanceEntryScopeLabel(entry),
				entry.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
			)},
			Context: []string{
				"This steers future replies when relevant. Your current request and Responder's safety policy take precedence.",
			},
			Actions: []Action{{
				ID:      ActionForgetMemory,
				Label:   "Forget this",
				Value:   entry.ID,
				Style:   "danger",
				Confirm: "Permanently forget this guidance? It will no longer steer future replies.",
			}},
		}
	}
	action := "Saved"
	if replaced {
		action = "Updated"
	}
	return Message{
		Text: fmt.Sprintf(
			"%s Responder memory: %s %s %s.",
			action, entry.SubjectKey, entry.Predicate, entry.Value,
		),
		Header: action + " operational memory",
		Sections: []string{fmt.Sprintf(
			"*%s* `%s` `%s`\n\nScope: `%s:%s`\nExpires: %s",
			entry.SubjectKey, entry.Predicate, entry.Value,
			entry.ScopeKind, entry.ScopeKey,
			entry.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
		)},
		Context: []string{
			"Responder treats this as an operator-confirmed hint. Fresh live evidence and current repository content take precedence.",
		},
		Actions: []Action{{
			ID:      ActionForgetMemory,
			Label:   "Forget this memory",
			Value:   entry.ID,
			Style:   "danger",
			Confirm: "Permanently forget this saved memory? The audit trail will retain only the entry ID and outcome, not its value.",
		}},
	}
}

func MemoryForgottenMessage() Message {
	return Message{
		Text:     "Responder forgot the selected operational memory.",
		Header:   "Operational memory forgotten",
		Sections: []string{"The saved value was permanently deleted and will no longer be supplied to future investigations."},
		Context:  []string{"The audit trail retains only the memory entry ID and deletion outcome."},
	}
}

func MemoryDirectoryMessage(entries []core.MemoryEntry) Message {
	message := Message{
		Text:   fmt.Sprintf("Responder has %d active memory entries visible here.", len(entries)),
		Header: "What Responder remembers here",
		Context: []string{
			"Guidance is advice, and operational mappings are hints rather than current health evidence. Current requests, host policy, fresh observations, and repository state take precedence.",
		},
	}
	if len(entries) == 0 {
		message.Sections = []string{
			"No active memory matches this channel, its configured repository, and your visibility.",
			"Tell Responder to remember guidance, an alias, a repository binding, an evidence route, or an entity relationship correction. It will show exactly what it plans to remember before anything is saved.",
		}
		return message
	}
	for index, entry := range entries[:min(len(entries), 20)] {
		if entry.Predicate == "guidance" {
			message.Sections = append(message.Sections, fmt.Sprintf(
				"*%d. Guidance: %s*\n> %s\nApplies to: %s · Expires: %s",
				index+1,
				escapeSlackText(strings.ReplaceAll(entry.SubjectKey, "_", " ")),
				escapeSlackText(entry.Value),
				guidanceEntryScopeLabel(entry),
				entry.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
			))
		} else {
			message.Sections = append(message.Sections, fmt.Sprintf(
				"*%d. %s*\n`%s` `%s`\nScope: `%s:%s` · Expires: %s",
				index+1,
				escapeSlackText(entry.SubjectKey),
				entry.Predicate,
				entry.Value,
				entry.ScopeKind,
				entry.ScopeKey,
				entry.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
			))
		}
		message.Actions = append(message.Actions, Action{
			ID:      ActionForgetMemory,
			Label:   fmt.Sprintf("Forget memory %d", index+1),
			Value:   entry.ID,
			Style:   "danger",
			Confirm: "Permanently forget this saved memory? The audit trail will retain only the entry ID and outcome, not its value.",
		})
	}
	return message
}

func MemoryHealthMessage(
	entries []core.MemoryEntry,
	rollups []core.MemoryRollup,
	health core.MemoryHealth,
) Message {
	message := MemoryDirectoryMessage(entries)
	lastDreamed := "not run yet"
	if !health.LastDreamedAt.IsZero() {
		lastDreamed = health.LastDreamedAt.UTC().Format("2006-01-02 15:04 UTC")
	}
	message.Sections = append([]string{fmt.Sprintf(
		"*Memory health*\n%d confirmed memories · %d recalled · %d recent conversation summaries · %d continuity rollups\nLast consolidation: %s",
		health.ExplicitActive,
		health.ExplicitRecalled,
		health.ConversationSummaries,
		health.Rollups,
		lastDreamed,
	)}, message.Sections...)
	if health.PendingReviews > 0 {
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*Review needed*\n%d saved memory item%s may be stale or redundant. Nothing will be changed automatically.",
			health.PendingReviews,
			map[bool]string{true: "", false: "s"}[health.PendingReviews == 1],
		))
		message.Actions = append([]Action{{
			ID: ActionReviewMemory, Label: "Review memory", Value: "next",
		}}, message.Actions...)
	}
	if len(rollups) > 0 {
		var continuity strings.Builder
		continuity.WriteString("*Older conversation continuity*")
		for index, rollup := range rollups[:min(len(rollups), 4)] {
			summary := strings.TrimSpace(rollup.State.SituationSummary)
			if summary == "" {
				summary = displayOr(strings.TrimSpace(rollup.State.Goal), "No situation summary")
			}
			fmt.Fprintf(
				&continuity,
				"\n%d. %s · %s to %s · %d source summaries\n> %s",
				index+1,
				escapeSlackText(rollup.ScopeKind+":"+rollup.ScopeKey),
				rollup.PeriodStart.UTC().Format("2006-01-02"),
				rollup.PeriodEnd.UTC().Format("2006-01-02"),
				rollup.SourceCount,
				escapeSlackText(summary),
			)
			message.Actions = append(message.Actions, Action{
				ID: ActionForgetMemoryRollup, Label: fmt.Sprintf("Discard continuity %d", index+1),
				Value: rollup.ID, Style: "danger",
				Confirm: "Discard this synthesized continuity summary? Its already-compacted source summaries cannot be restored.",
			})
		}
		message.Sections = append(message.Sections, continuity.String())
		message.Context = append(message.Context,
			"Continuity rollups are lossy summaries of older conversations, not instructions or operational evidence.")
	}
	return message
}

func MemoryRollupForgottenMessage() Message {
	return Message{
		Text:   "Older conversation continuity discarded.",
		Header: "Continuity summary discarded",
		Sections: []string{
			"The selected synthesized summary was removed and will no longer appear in future context.",
		},
		Context: []string{"Current conversation summaries and operator-confirmed memory were not changed."},
	}
}

func guidanceOfferScopeLabel(offer core.MemoryOffer, fallback string) string {
	switch {
	case offer.Scope == "workspace" && offer.Visibility == "operator":
		return "only you, across this workspace"
	case offer.Scope == "workspace" && offer.Visibility == "workspace":
		return "everyone in this workspace"
	case offer.Scope == "channel":
		return "this channel"
	case offer.Scope == "repository" && offer.Visibility == "operator":
		return "only you, for repository `" + escapeSlackText(offer.Repository) + "`"
	case offer.Scope == "repository":
		return "repository `" + escapeSlackText(offer.Repository) + "`"
	default:
		return escapeSlackText(fallback)
	}
}

// FeedbackSummary is one open feedback item as the App Home shows it.
type FeedbackSummary struct {
	ID        string
	Category  string
	Sentiment string
	Summary   string
	SourceRef string
}

// AppendFeedbackDigest adds open product feedback to the App Home, with the two
// decisions an operator can make about each item.
//
// Capturing feedback and never acting on it is worse than not capturing it: the
// person sees their input accepted and nothing change. Surfacing it with a way
// to convert it into durable guidance is what closes that loop — and the
// conversion goes through the ordinary guidance confirmation, so the model
// never gains a path to write its own instructions.
// AppendFeedbackDigest adds open product feedback to the App Home, with the two
// decisions an operator can make about each item.
//
// Capturing feedback and never acting on it is worse than not capturing it: the
// person sees their input accepted and nothing change. Surfacing it with a way
// to convert it into durable guidance is what closes that loop — and the
// conversion goes through the ordinary guidance confirmation, so the model
// never gains a path to write its own instructions.
func AppendFeedbackDigest(message Message, items []FeedbackSummary) Message {
	if len(items) == 0 {
		return message
	}
	byCategory := map[string]int{}
	for _, item := range items {
		byCategory[item.Category]++
	}
	counts := make([]string, 0, len(byCategory))
	for _, category := range []string{
		"correctness", "ux", "tone", "latency", "reliability", "feature_request", "other",
	} {
		if count := byCategory[category]; count > 0 {
			counts = append(counts, fmt.Sprintf("%s %d", strings.ReplaceAll(category, "_", " "), count))
		}
	}
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Product feedback awaiting a decision (%d)*\n%s",
		len(items), escapeSlackText(strings.Join(counts, " · ")),
	))
	for index, item := range items {
		if index >= 5 {
			message.Context = append(message.Context, fmt.Sprintf(
				"%d more feedback items are open; use `/responder feedback` to see them.",
				len(items)-5,
			))
			break
		}
		line := fmt.Sprintf(
			"%d. %s\n_%s · %s_",
			index+1,
			escapeSlackText(item.Summary),
			escapeSlackText(item.Category),
			escapeSlackText(item.Sentiment),
		)
		if item.SourceRef != "" {
			line += " · " + escapeSlackText(item.SourceRef)
		}
		message.Sections = append(message.Sections, line)
		// Tone feedback is the one category a typed preference can actually
		// express: response_detail is enforced, where guidance is only weighed.
		// The direction is NOT inferred from the text — "be more concise" and
		// "too terse" are both tone, and guessing between them from prose is
		// how an agent starts confidently doing the opposite of what was asked.
		// The operator picks.
		if item.Category == "tone" {
			message.Actions = append(message.Actions, Action{
				ID:    ActionConvertFeedbackBrief,
				Label: fmt.Sprintf("Always be briefer %d", index+1),
				Value: item.ID,
				Confirm: "Set a standing preference for briefer replies in this workspace? " +
					"This is enforced, not a hint, and you can change it any time.",
			})
		}
		message.Actions = append(message.Actions,
			Action{
				ID: ActionConvertFeedback, Label: fmt.Sprintf("Make it guidance %d", index+1),
				Value: item.ID, Style: "primary",
				Confirm: "Turn this feedback into durable guidance? You will confirm the exact " +
					"wording before anything is saved.",
			},
			Action{
				ID: ActionDismissFeedback, Label: fmt.Sprintf("Dismiss %d", index+1),
				Value: item.ID,
			},
		)
	}
	return message
}

// FixtureCandidateSummary is one correction awaiting review.
type FixtureCandidateSummary struct {
	ID         string
	Capability string
	Reason     string
	Correction string
}

// AppendFixtureReview adds corrections awaiting review to the App Home.
//
// These are the moments Responder was told it got something wrong. Keeping one
// turns it into a regression test so the same mistake cannot come back;
// discarding says the correction was situational and not worth pinning.
//
// The framing matters. An operator reading this is being asked to judge a
// lesson, not to triage an error — so the section leads with what Responder was
// told, not with which internal check produced it.
func AppendFixtureReview(message Message, items []FixtureCandidateSummary) Message {
	if len(items) == 0 {
		return message
	}
	message.Sections = append(message.Sections,
		"*Corrections worth keeping?*\nEach of these is a moment I was told I got something "+
			"wrong. Keep one and it becomes a test, so that mistake cannot come back. "+
			"Discard it if it was situational.",
	)
	for index, item := range items {
		line := "• " + escapeSlackText(truncateUTF8(item.Correction, 300))
		if item.Capability != "" {
			line += " · " + escapeSlackText(item.Capability)
		}
		message.Sections = append(message.Sections, line)
		message.Actions = append(message.Actions,
			Action{
				ID: ActionKeepFixtureCandidate, Label: fmt.Sprintf("Keep %d", index+1),
				Value: item.ID, Style: "primary",
				Confirm: "Turn this correction into a regression test? " +
					"It will be reviewed once more before it reaches a release gate.",
			},
			Action{
				ID: ActionDiscardFixtureCandidate, Label: fmt.Sprintf("Discard %d", index+1),
				Value: item.ID,
			},
		)
	}
	return message
}

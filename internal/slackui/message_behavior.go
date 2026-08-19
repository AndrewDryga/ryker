package slackui

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
)

// rememberPhrase reads the duration into the sentence a button and its
// confirmation share. "for 30 days" is right and "for never" is not, and a
// card that cannot say what it is offering is how this started.
func rememberPhrase(expiresLabel string) string {
	if expiresLabel == core.NeverExpires {
		return "permanently"
	}
	return "for " + expiresLabel
}

// expiryTerm names an offer's lifetime. A duration stands on its own — "90
// days" — but the bare word "never" does not, so permanence says what it is.
func expiryTerm(expiresLabel string) string {
	if expiresLabel == core.NeverExpires {
		return "never expires"
	}
	return expiresLabel
}

// expiryPhrase is expiryTerm where the surrounding copy already said "Expires:".
func expiryPhrase(expiresLabel string) string {
	if expiresLabel == core.NeverExpires {
		return expiryTerm(expiresLabel)
	}
	return "Expires: " + expiresLabel
}

// expiryStamp is the same answer as a bare date, for the App Home rows that
// still compose their own line around it.
func expiryStamp(expires time.Time, layout string) string {
	if core.IsPermanentExpiry(expires) {
		return core.NeverExpires
	}
	return expires.UTC().Format(layout)
}

// expiryFact is the same answer for something already saved, in the reader's
// own timezone: every absolute time these cards printed was UTC, and nobody
// reading them is.
func expiryFact(expires time.Time) string {
	if core.IsPermanentExpiry(expires) {
		return expiryTerm(core.NeverExpires)
	}
	return "expires " + slackDate(expires, "2006-01-02 15:04 UTC")
}

func WithMemoryOffer(
	message Message,
	offer core.MemoryOffer,
	actionValue string,
	permanentValue string,
	scopeLabel string,
	expiresLabel string,
) Message {
	if offer.Predicate == "guidance" {
		boundary := "Saved guidance shapes replies; current requests and safety policy take priority."
		actions := []Action{{
			ID:      ActionRememberMemory,
			Label:   "Remember this",
			Value:   actionValue,
			Style:   "primary",
			Confirm: "Remember this guidance " + rememberPhrase(expiresLabel) + "?",
		}}
		if permanentValue != "" {
			actions = append(actions, Action{
				ID:      ActionRememberMemory,
				Label:   "Remember permanently",
				Value:   permanentValue,
				Confirm: "Remember this guidance permanently?",
			})
		}
		return offerCard(message, boundary, offerProposal{
			Quote: escapeSlackText(offer.Value),
			Facts: joinFacts([]string{
				"Applies to " + guidanceOfferScopeLabel(offer, scopeLabel),
				expiryPhrase(expiresLabel),
			}),
			Actions: actions,
		})
	}
	facts := []string{
		"Scope: " + scopeLabel,
		"Visibility: `" + offer.Visibility + "`",
		"Expires: " + expiresLabel,
	}
	if offer.SourceRevision != "" {
		facts = append(facts, "revision `"+offer.SourceRevision+"`")
	}
	return offerCard(
		message,
		"Saved memory guides investigations; current evidence decides health.",
		offerProposal{
			Quote: fmt.Sprintf("`%s` *%s* `%s`", offer.Subject, offer.Predicate, offer.Value),
			Facts: joinFacts(facts),
			Actions: []Action{{
				ID:      ActionRememberMemory,
				Label:   "Remember for " + expiresLabel,
				Value:   actionValue,
				Style:   "primary",
				Confirm: "Save this " + scopeLabel + " memory for " + expiresLabel + "?",
			}},
		},
	)
}

// A fact-shaped memory never reaches the permanent branch above: the host
// rejects the offer before a card exists, so the only expiry this card can
// render is a duration.

func WithPreferenceOffer(
	message Message,
	offer core.PreferenceOffer,
	preference core.ResponderPreference,
	actionValue string,
	expiresLabel string,
) Message {
	title, description := preferenceDescription(preference)
	label := "Remember this"
	if offer.Name == "response_location" {
		label = "Use this reply style"
	}
	return offerCard(message, behaviorOfferContext, offerProposal{
		Quote: description,
		Facts: joinFacts([]string{
			title,
			preferenceScopeLabel(preference),
			expiryTerm(expiresLabel),
		}),
		Actions: []Action{{
			ID:      ActionRememberPreference,
			Label:   label,
			Value:   actionValue,
			Style:   "primary",
			Confirm: "Use this setting " + rememberPhrase(expiresLabel) + "?",
		}},
	})
}

func WithRuleOffer(
	message Message,
	offer core.RuleOffer,
	rule core.StandingRule,
	actionValue string,
	expiresLabel string,
) Message {
	workflow := standingRuleWorkflow(rule)
	title := workflow.Name
	if title == "" {
		title = "Standing rule"
	}
	description := core.StandingWorkflowEffect(workflow)
	if description == "." {
		description = fmt.Sprintf("Watch matching messages and reply in their threads using `%s`.", offer.Repository)
	}
	return offerCard(message, behaviorOfferContext, offerProposal{
		Quote: description,
		Facts: joinFacts([]string{
			title,
			"Repository `" + rule.Repository + "`",
			"This channel",
			expiryTerm(expiresLabel),
		}),
		Actions: []Action{{
			ID:      ActionRememberRule,
			Label:   "Enable rule",
			Value:   actionValue,
			Style:   "primary",
			Confirm: "Enable this read-only rule " + rememberPhrase(expiresLabel) + "?",
		}},
	})
}

const behaviorOfferContext = ""

func WithScheduleOffer(
	message Message,
	task core.ScheduledTask,
	actionValue string,
	when string,
) Message {
	return WithScheduleOffers(message, []core.ScheduledTask{task}, actionValue, []string{when})
}

func WithScheduleOffers(
	message Message,
	tasks []core.ScheduledTask,
	actionValue string,
	whens []string,
) Message {
	if len(tasks) == 0 || len(tasks) != len(whens) {
		return ScheduleOfferUnavailable(message)
	}
	message.Text = conditionalScheduleOfferLead(message.Text)
	message.Markdown = conditionalScheduleOfferLead(message.Markdown)
	boundary := "Each run uses current policy and skips overlapping occurrences."
	confirm := Action{
		ID: ActionRememberSchedule, Label: "Schedule this", Value: actionValue,
		Style:   "primary",
		Confirm: "Create this task under the policies and approvals current at run time?",
	}
	if len(tasks) > 1 {
		confirm.Label = fmt.Sprintf("Schedule all %d", len(tasks))
		confirm.Confirm = fmt.Sprintf("Create all %d follow-up checks as one set?", len(tasks))
		boundary = "One confirmation saves the full set using current access and approval rules."
	}
	// One confirmation covers every proposal, so it sits on the first row rather
	// than repeating down the card. The rows past the ceiling are still saved by
	// it — a listing that quietly dropped them would be describing a smaller
	// commitment than the button makes.
	shown := tasks
	if len(shown) > directoryRowLimit {
		boundary += fmt.Sprintf(
			" %d more are covered by the same confirmation and not shown here.",
			len(shown)-directoryRowLimit,
		)
		shown = shown[:directoryRowLimit]
	}
	proposals := make([]offerProposal, 0, len(shown))
	for index, task := range shown {
		proposal := offerProposal{
			Quote: escapeSlackText(task.Prompt),
			Facts: joinFacts([]string{
				"*" + escapeSlackText(task.Title) + "*",
				whens[index],
				scheduleDestination(task),
				"`" + safeInlineCode(task.Repository) + "`",
			}),
		}
		if index == 0 {
			proposal.Actions = []Action{confirm}
		}
		proposals = append(proposals, proposal)
	}
	return offerCard(message, boundary, proposals...)
}

// scheduleDestination names where an occurrence will report.
func scheduleDestination(task core.ScheduledTask) string {
	channel := firstNonemptyUI(task.DeliveryChannel, task.ChannelID)
	if task.ThreadTS != "" && channel == task.ChannelID {
		return "this thread"
	}
	if channel == "" {
		return ""
	}
	return "<#" + channel + ">"
}

func conditionalScheduleOfferLead(value string) string {
	if match := scheduleCommitmentPattern.FindStringIndex(value); match != nil {
		return "Confirm the schedule below to have Responder " +
			strings.TrimSpace(value[match[1]:])
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "confirm") && strings.Contains(lower, "schedule") {
		return value
	}
	return "Confirm the schedule below to create this task.\n\n" + value
}

// ScheduleOfferUnavailable replaces an offer that could not be prepared.
//
// Grey and stateless: nothing was saved, nothing is pending, and the only thing
// wanted is the ask again. It decorates the reply it arrives on rather than
// standing alone, so it strips that reply back to this one statement — every
// control included. Rows and the overflow menu are cleared alongside Actions
// because a proposal is a row now: clearing only the button pile would have
// deleted the sentence a confirmation referred to and left the confirmation.
func ScheduleOfferUnavailable(message Message) Message {
	message.Text = "Schedule could not be prepared."
	message.Markdown = message.Text
	message.Stripe = StripeIdle
	message.Sections = nil
	message.Fields = nil
	message.Context = []string{"Restate the timing and task to try again."}
	message.Actions = nil
	message.Rows = nil
	message.Overflow = nil
	return message
}

func scheduleToggleValue(id string, enabled bool) string {
	data, _ := json.Marshal(struct {
		ID      string `json:"id"`
		Enabled bool   `json:"enabled"`
	}{ID: id, Enabled: enabled})
	return string(data)
}

// scheduleToggleAction is the control that stops a schedule without destroying
// it, named for the state it moves to.
func scheduleToggleAction(task core.ScheduledTask) Action {
	label := "Pause schedule"
	if !task.Enabled {
		label = "Resume schedule"
	}
	return Action{
		ID: ActionToggleSchedule, Label: label,
		Value: scheduleToggleValue(task.ID, !task.Enabled),
	}
}

// scheduleRowActions splits a schedule's four controls into the two that earn a
// button on a listed row and the two that sit behind its ⋯.
//
// Run now and Delete are what a person opens this list to do. Pausing and
// replacing are real but rarer, and at ten rows four buttons apiece is eighty
// controls on one card — which is how the old list came to number its buttons
// instead of naming them.
func scheduleRowActions(task core.ScheduledTask) (actions, overflow []Action) {
	actions = []Action{
		{ID: ActionRunSchedule, Label: "Run now", Value: task.ID},
		{
			ID: ActionDeleteSchedule, Label: "Delete", Value: task.ID, Style: "danger",
			Confirm: "Delete this scheduled task? Future occurrences will not run.",
		},
	}
	// A finished one-shot has nothing to pause.
	if !task.NextRunAt.IsZero() {
		overflow = append(overflow, scheduleToggleAction(task))
	}
	return actions, append(overflow, Action{
		ID: ActionEditSchedule, Label: "Replace", Value: task.ID,
	})
}

// scheduleNextRun is when the next occurrence lands, in the reader's timezone.
func scheduleNextRun(task core.ScheduledTask) string {
	if task.NextRunAt.IsZero() {
		return ""
	}
	return slackDate(task.NextRunAt, "2006-01-02 15:04 UTC")
}

// scheduleLastRun reports what the last occurrence produced rather than when it
// happened. "last: never" was on every row of a list where most rows had run —
// it was reporting the outcome column, which nothing had ever written.
func scheduleLastRun(task core.ScheduledTask) string {
	if outcome := strings.TrimSpace(task.LastOutcome); outcome != "" {
		return "last run " + escapeSlackText(outcome)
	}
	if task.LastRunAt.IsZero() {
		return "not run yet"
	}
	return "last run " + slackDate(task.LastRunAt, "2006-01-02 15:04 UTC")
}

// scheduleStateWord is the schedule's own state, which is not the same question
// as whether it is enabled: a one-shot that has fired is neither paused nor
// waiting, it is done.
func scheduleStateWord(task core.ScheduledTask) string {
	switch {
	case task.Enabled:
		return "active"
	case task.NextRunAt.IsZero():
		return "completed"
	default:
		return "paused"
	}
}

func ScheduleSavedMessage(task core.ScheduledTask) Message {
	return SchedulesSavedMessage([]core.ScheduledTask{task})
}

func SchedulesSavedMessage(tasks []core.ScheduledTask) Message {
	if len(tasks) == 0 {
		return Message{
			Text: "No scheduled tasks were created.", Header: "Nothing scheduled",
			Temporary: true,
		}
	}
	if len(tasks) > 1 {
		// Undo is one action value, and the action behind it deletes one task by
		// id (handleDeleteSchedule reads a single id from the value). An "Undo
		// all" here would remove one of the batch and say it removed the batch,
		// so the multi-check receipt carries no control and the directory is
		// where a mistaken batch gets unwound.
		message := receiptCard(
			fmt.Sprintf("Scheduled %d follow-up checks.", len(tasks)),
			"Scheduled.",
			fmt.Sprintf("%d follow-up checks.", len(tasks)),
			[]string{"Manage or run them early from the App Home."},
		)
		for _, task := range tasks[:min(len(tasks), directoryRowLimit)] {
			message = AppendRow(message, joinFacts([]string{
				"*" + escapeSlackText(task.Title) + "*",
				scheduleNextRun(task),
				scheduleDestination(task),
			}), nil)
		}
		if extra := len(tasks) - directoryRowLimit; extra > 0 {
			message.Context = append(message.Context, fmt.Sprintf(
				"and %d more — the App Home lists them all.", extra,
			))
		}
		return message
	}
	task := tasks[0]
	return receiptCard(
		"Scheduled "+task.Title+". Next run: "+task.NextRunAt.Format(time.RFC3339),
		"Scheduled.",
		escapeSlackText(task.Title)+" runs "+scheduleNextRun(task)+".",
		[]string{
			scheduleDestination(task),
			"`" + safeInlineCode(task.Repository) + "`",
			"One copy runs at a time, and each occurrence uses current access and approval rules.",
		},
		undoAction(ActionDeleteSchedule, task.ID),
	)
}

func ScheduledRunStartedMessage(task core.ScheduledTask, scheduledFor time.Time) Message {
	title := strings.TrimSpace(task.Title)
	if title == "" {
		title = "Scheduled check"
	}
	return Message{
		Text:      fmt.Sprintf("%s started", title),
		Header:    title,
		Sections:  []string{"Scheduled check started. Emisar is gathering fresh evidence and will report in this thread."},
		Context:   []string{"Scheduled for " + scheduledFor.UTC().Format("2006-01-02 15:04 UTC")},
		Temporary: true,
	}
}

func ScheduleStateMessage(task core.ScheduledTask) Message {
	title := escapeSlackText(task.Title)
	actions := []Action{scheduleToggleAction(task)}
	if task.NextRunAt.IsZero() {
		actions = nil
	}
	actions = append(actions, Action{
		ID: ActionRunSchedule, Label: "Run now", Value: task.ID,
	})
	if task.Enabled {
		when := scheduleNextRun(task)
		statement := "*Active.* " + title + " runs again " + when + "."
		if when == "" {
			statement = "*Active.* " + title + " runs on its schedule."
		}
		return stateChangeCard(
			"Active. Scheduled task "+task.Title+" runs on its schedule.",
			statement, "", actions...,
		)
	}
	return stateChangeCard(
		"Paused. Scheduled task "+task.Title+" will not run until you resume it.",
		"*Paused.* "+title+" will not run until you resume it.",
		"It stays saved with its timing intact.",
		actions...,
	)
}

func ScheduleDeletedMessage() Message {
	return stateChangeCard(
		"Deleted. Future occurrences of that scheduled task will not run.",
		"*Deleted.* Future occurrences will not run.",
		"A run already in progress can finish.",
	)
}

func ScheduleDirectoryMessage(tasks []core.ScheduledTask) Message {
	message := Message{
		Text:      "Emisar has " + countLabel(len(tasks), "unexpired scheduled task") + " in this channel.",
		Header:    "Scheduled tasks for this channel",
		Temporary: true,
	}
	if len(tasks) == 0 {
		message.Sections = []string{"No scheduled tasks are configured here.", "Example: `@Emisar every Monday at 09:00, summarize production health in this channel`. I’ll normalize the timing and ask for confirmation."}
		return message
	}
	entries := make([]directoryEntry, 0, len(tasks))
	for _, task := range tasks {
		actions, overflow := scheduleRowActions(task)
		next := ""
		if when := scheduleNextRun(task); when != "" {
			next = "next " + when
		}
		entries = append(entries, directoryEntry{
			Text: "*" + escapeSlackText(task.Title) + "*\n" + joinFacts([]string{
				scheduleStateWord(task),
				next,
				scheduleLastRun(task),
				"`" + safeInlineCode(task.Repository) + "`",
			}),
			Actions:  actions,
			Overflow: overflow,
		})
	}
	return directoryCard(message, entries, "most recently changed first.")
}

func PreferenceSavedMessage(
	preference core.ResponderPreference,
	replaced bool,
) Message {
	title, description := preferenceDescription(preference)
	verb := "Saved."
	if replaced {
		verb = "Updated."
	}
	return receiptCard(
		verb+" "+description,
		verb,
		description,
		[]string{
			title,
			preferenceScopeLabel(preference),
			expiryFact(preference.ExpiresAt),
			preferencePrecedenceText(preference),
		},
		undoAction(ActionDeletePreference, preference.ID),
	)
}

func PreferenceStateMessage(preference core.ResponderPreference) Message {
	title, description := preferenceDescription(preference)
	if preference.Enabled {
		return stateChangeCard(
			"Enabled. "+description,
			"*Enabled.* "+description,
			preferencePrecedenceText(preference),
			preferenceToggleAction(preference),
		)
	}
	return stateChangeCard(
		"Disabled. "+title+" no longer shapes replies.",
		"*Disabled.* "+title+" no longer shapes replies.",
		"Stored until its expiry or deletion.",
		preferenceToggleAction(preference),
	)
}

func PreferenceDeletedMessage() Message {
	return stateChangeCard(
		"Deleted. That preference no longer affects future investigations.",
		"*Deleted.* It will no longer affect future investigations.",
		"",
	)
}

func PreferenceDirectoryMessage(
	preferences []core.ResponderPreference,
) Message {
	message := Message{
		Text:      "Responder has " + countLabel(len(preferences), "unexpired preference") + " visible here.",
		Header:    "Responder preferences",
		Temporary: true,
	}
	if len(preferences) == 0 {
		message.Context = []string{"Preference priority: operator, channel, repository, workspace."}
		message.Sections = []string{
			"No operator, channel, repository, or workspace preference matches this context.",
			"Examples: `@Emisar when I ask for infrastructure health, always run a deep check` or `@Emisar from now on keep responses concise in this channel`. Emisar will show a confirmation before saving.",
		}
		return message
	}
	message.Context = []string{"Preference priority: operator, channel, repository, workspace."}
	entries := make([]directoryEntry, 0, len(preferences))
	for _, preference := range preferences {
		state := "disabled"
		if preference.Enabled {
			state = "enabled"
		}
		title, description := preferenceDescription(preference)
		entries = append(entries, directoryEntry{
			Text: "*" + title + "* — " + description + "\n" + joinFacts([]string{
				state,
				preferenceScopeLabel(preference),
				expiryFact(preference.ExpiresAt),
			}),
			Actions: preferenceRowActions(preference),
		})
	}
	return directoryCard(message, entries, "highest precedence first.")
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
			return "Reply in threads", "Reply in the relevant thread unless someone explicitly moves the conversation back to the channel."
		case "prefer_channel":
			return "Reply in the channel", "Reply in the channel unless the conversation explicitly stays in a thread."
		default:
			return "Follow the conversation", "Reply wherever the current conversation is happening."
		}
	default:
		return preference.Name, "Use " + preference.Value + "."
	}
}

func RuleSavedMessage(rule core.StandingRule, replaced bool) Message {
	verb := "Enabled."
	if replaced {
		verb = "Updated."
	}
	workflow := standingRuleWorkflow(rule)
	return receiptCard(
		verb+" "+workflow.Name+" is active.",
		verb,
		core.StandingWorkflowEffect(workflow),
		[]string{
			workflow.Name,
			"repository `" + rule.Repository + "`",
			"watches " + standingRuleSourceDescription(rule.SourceKind),
			expiryFact(rule.ExpiresAt),
			"Starts read-only work.",
		},
		undoAction(ActionDeleteRule, rule.ID),
	)
}

func RuleStateMessage(rule core.StandingRule) Message {
	workflow := standingRuleWorkflow(rule)
	if rule.Enabled {
		return stateChangeCard(
			"Enabled. "+workflow.Name+" is watching again.",
			"*Enabled.* "+standingRuleEffect(rule),
			"Starts read-only work.",
			ruleToggleAction(rule),
		)
	}
	return stateChangeCard(
		"Disabled. "+workflow.Name+" no longer admits matching messages.",
		"*Disabled.* "+workflow.Name+" no longer admits or investigates matching messages.\n"+
			standingRuleEffect(rule),
		"It stays stored until it expires or you delete it.",
		ruleToggleAction(rule),
	)
}

func standingRuleEffect(rule core.StandingRule) string {
	workflow, _, _, err := core.NormalizeStandingWorkflow(
		rule.Workflow, rule.Trigger, rule.Action,
	)
	if err == nil {
		return core.StandingWorkflowEffect(workflow)
	}
	return "This legacy rule watches " + escapeSlackText(rule.Trigger) +
		" and runs " + escapeSlackText(rule.Action) + "."
}

func RuleDeletedMessage() Message {
	return stateChangeCard(
		"Deleted. Matching messages will no longer trigger that rule.",
		"*Deleted.* Matching messages will no longer trigger it.",
		"Execution history follows normal retention.",
	)
}

func RuleDirectoryMessage(rules []core.StandingRule) Message {
	message := Message{
		Text:      "Responder has " + countLabel(len(rules), "unexpired standing rule") + " in this channel.",
		Header:    "Standing rules for this channel",
		Temporary: true,
	}
	if len(rules) == 0 {
		message.Context = []string{"Rules watch matching messages and start read-only triage."}
		message.Sections = []string{
			"No standing rules are configured in this channel.",
			"Example: `@Emisar when you see a new Terraform plan here, review its main diff and red flags`. Emisar will show the normalized trigger, repository, expiry, and safety boundary before saving.",
		}
		return message
	}
	message.Context = []string{fmt.Sprintf(
		"%s here · typed read-only subscriptions that never create incidents or authorize changes.",
		countLabel(len(rules), "unexpired standing rule"),
	)}
	entries := make([]directoryEntry, 0, len(rules))
	for _, rule := range rules {
		workflow := standingRuleWorkflow(rule)
		state := "disabled"
		if rule.Enabled {
			state = "enabled"
		}
		lastFired := "never fired"
		if !rule.LastTriggered.IsZero() {
			lastFired = "last fired " + slackDate(rule.LastTriggered, "2006-01-02 15:04 UTC")
		}
		entries = append(entries, directoryEntry{
			// Three lines rather than two: the worth sentence is the one fact
			// that answers whether to keep a rule, and a fire count without it
			// reads the same whether the rule did work all week or matched
			// constantly and answered nothing.
			Text: "*" + workflow.Name + "* — " + core.StandingWorkflowEffect(workflow) + "\n" +
				joinFacts([]string{
					state,
					"watches " + standingRuleSourceDescription(rule.SourceKind),
					"`" + rule.Repository + "`",
					lastFired,
					expiryFact(rule.ExpiresAt),
				}) + "\n_" + StandingRuleWorth(rule) + "_",
			Actions: ruleRowActions(rule),
		})
	}
	return directoryCard(message, entries, "most recently changed first.")
}

func standingRuleWorkflow(rule core.StandingRule) core.StandingWorkflow {
	workflow, _, _, err := core.NormalizeStandingWorkflow(
		rule.Workflow, rule.Trigger, rule.Action,
	)
	if err == nil {
		return workflow
	}
	return core.StandingWorkflow{Name: firstNonemptyUI(rule.WorkflowName, "Standing rule")}
}

func standingRuleSourceDescription(source string) string {
	switch source {
	case "app":
		return "app messages"
	case "human":
		return "messages from people"
	default:
		return "messages from people and apps"
	}
}

// StandingRuleWorth is the one line that answers "should I keep this rule".
//
// A fire count on its own cannot: emisar's Terraform rule had fired 64 times and
// every recorded outcome of it was 'ignore', which reads identically to a rule
// doing useful work all week. So the sentence leads with what the fires
// produced, and says plainly when it produced nothing.
//
// The recorded total is stated separately from the fire count whenever they
// differ, because they mean different things and collapsing them would be a
// claim rather than a report. Fires from before Responder started recording
// outcomes are fires nobody observed; describing them as quiet would invent the
// observation, and leaving them out of the denominator without saying so would
// hide that most of the rule's history is unaccounted for.
func StandingRuleWorth(rule core.StandingRule) string {
	recorded := rule.ActedCount + rule.QuietCount
	if recorded == 0 {
		return fmt.Sprintf(
			"Fired %d times · no outcome recorded yet, so there is nothing to judge it on",
			rule.TriggerCount,
		)
	}
	worth := fmt.Sprintf(
		"Fired %d times · acted %d, did nothing %d",
		rule.TriggerCount, rule.ActedCount, rule.QuietCount,
	)
	if recorded < rule.TriggerCount {
		worth += fmt.Sprintf(" of the %d fires with a recorded outcome", recorded)
	}
	switch {
	case !rule.LastActed.IsZero():
		worth += " · last acted " + rule.LastActed.UTC().Format("2006-01-02 15:04 UTC")
	case rule.ActedCount > 0:
		worth += " · nothing acted on recently"
	default:
		worth += " · it has never done anything"
	}
	return worth
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

// The labels below are bare verbs because the row above them says what they
// act on. "Disable preference 3" was a button label on a card that already had
// the preference written directly above it, twice — once in the row and once in
// the number.
func preferenceToggleAction(preference core.ResponderPreference) Action {
	label := "Disable"
	if !preference.Enabled {
		label = "Enable"
	}
	return Action{
		ID: ActionTogglePreference, Label: label,
		Value: behaviorToggleValue(preference.ID, !preference.Enabled),
	}
}

func preferenceRowActions(preference core.ResponderPreference) []Action {
	return []Action{
		preferenceToggleAction(preference),
		{ID: ActionEditPreference, Label: "Edit", Value: preference.ID},
		{
			ID: ActionDeletePreference, Label: "Delete",
			Value: preference.ID, Style: "danger",
			Confirm: "Permanently delete this Responder preference? It will stop affecting future investigations.",
		},
	}
}

func ruleToggleAction(rule core.StandingRule) Action {
	label := "Disable"
	if !rule.Enabled {
		label = "Enable"
	}
	return Action{
		ID: ActionToggleRule, Label: label,
		Value: behaviorToggleValue(rule.ID, !rule.Enabled),
	}
}

func ruleRowActions(rule core.StandingRule) []Action {
	return []Action{
		ruleToggleAction(rule),
		{ID: ActionEditRule, Label: "Edit", Value: rule.ID},
		{
			ID: ActionDeleteRule, Label: "Delete",
			Value: rule.ID, Style: "danger",
			Confirm: "Permanently delete this standing rule? Matching messages will no longer trigger it.",
		},
	}
}

func MemorySavedMessage(entry core.MemoryEntry, replaced bool) Message {
	if entry.Predicate == "guidance" {
		verb, lede := "Remembered.", "I'll remember: "
		if replaced {
			verb, lede = "Updated.", "I'll use the updated guidance: "
		}
		return receiptCard(
			lede+entry.Value,
			verb,
			escapeSlackText(entry.Value),
			[]string{
				"Applies to " + guidanceEntryScopeLabel(entry),
				expiryFact(entry.ExpiresAt),
				"It steers future replies when relevant; your current request and Responder's safety policy take precedence.",
			},
			undoAction(ActionForgetMemory, entry.ID),
		)
	}
	verb := "Saved."
	if replaced {
		verb = "Updated."
	}
	return receiptCard(
		fmt.Sprintf(
			"%s operational memory: %s %s %s.",
			strings.TrimSuffix(verb, "."), entry.SubjectKey, entry.Predicate, entry.Value,
		),
		verb,
		fmt.Sprintf("`%s` `%s` `%s`", entry.SubjectKey, entry.Predicate, entry.Value),
		[]string{
			fmt.Sprintf("scope `%s:%s`", entry.ScopeKind, entry.ScopeKey),
			expiryFact(entry.ExpiresAt),
			"An operator-confirmed hint: fresh live evidence and current repository content take precedence.",
		},
		undoAction(ActionForgetMemory, entry.ID),
	)
}

func MemoryForgottenMessage() Message {
	return stateChangeCard(
		"Forgotten. That memory is no longer supplied to investigations.",
		"*Forgotten.* The saved value was permanently deleted and will no longer be supplied to future investigations.",
		"The audit trail retains only the memory entry ID and deletion outcome.",
	)
}

// memoryRecallFact reports whether a saved memory has ever been used.
//
// It is the fact that decides whether an entry is worth keeping, it has been
// recorded all along, and no card has ever shown it: a directory of forty
// entries where six were ever recalled looked exactly like one where all forty
// were.
func memoryRecallFact(entry core.MemoryEntry) string {
	if entry.LastRecalledAt.IsZero() {
		return "never used"
	}
	used := "last used " + compactDuration(time.Since(entry.LastRecalledAt)) + " ago"
	if entry.RecallCount > 0 {
		used = fmt.Sprintf("used %d× · %s", entry.RecallCount, used)
	}
	return used
}

func memoryDirectoryEntry(entry core.MemoryEntry) directoryEntry {
	text := "*" + escapeSlackText(entry.SubjectKey) + "* `" +
		entry.Predicate + "` `" + entry.Value + "`"
	scope := "scope `" + entry.ScopeKind + ":" + entry.ScopeKey + "`"
	if entry.Predicate == "guidance" {
		text = "*Guidance: " +
			escapeSlackText(strings.ReplaceAll(entry.SubjectKey, "_", " ")) +
			"* — " + escapeSlackText(entry.Value)
		scope = "applies to " + guidanceEntryScopeLabel(entry)
	}
	return directoryEntry{
		Text: text + "\n" + joinFacts([]string{
			scope,
			expiryFact(entry.ExpiresAt),
			memoryRecallFact(entry),
		}),
		Actions: []Action{{
			ID:      ActionForgetMemory,
			Label:   "Forget",
			Value:   entry.ID,
			Style:   "danger",
			Confirm: "Permanently forget this saved memory? The audit trail will retain only the entry ID and outcome, not its value.",
		}},
	}
}

func MemoryDirectoryMessage(entries []core.MemoryEntry) Message {
	message := Message{
		Text:      "Responder has " + countLabel(len(entries), "active memory entry", "active memory entries") + " visible here.",
		Header:    "What Responder remembers here",
		Temporary: true,
	}
	if len(entries) == 0 {
		message.Context = []string{"Saved memory guides investigations; current evidence decides health."}
		message.Sections = []string{
			"No active memory matches this channel, its configured repository, and your visibility.",
			"Tell Responder to remember guidance, an alias, a repository binding, an evidence route, or an entity relationship correction. It will show exactly what it plans to remember before anything is saved.",
		}
		return message
	}
	message.Context = []string{"Saved memory guides investigations; current evidence decides health."}
	directoryEntries := make([]directoryEntry, 0, len(entries))
	for _, entry := range entries {
		directoryEntries = append(directoryEntries, memoryDirectoryEntry(entry))
	}
	return directoryCard(message, directoryEntries, "nearest this channel first.")
}

func MemoryHealthMessage(
	entries []core.MemoryEntry,
	rollups []core.MemoryRollup,
	health core.MemoryHealth,
) Message {
	message := MemoryDirectoryMessage(entries)
	lastDreamed := "not run yet"
	if !health.LastDreamedAt.IsZero() {
		lastDreamed = slackDate(health.LastDreamedAt, "2006-01-02 15:04 UTC")
	}
	// The health strip is counters, and counters are context. It used to be the
	// tallest section on the card, above the memories it was counting.
	message.Context = append([]string{fmt.Sprintf(
		"%d confirmed · %d recalled · %d recent conversation summaries · %d continuity rollups · last consolidation %s",
		health.ExplicitActive,
		health.ExplicitRecalled,
		health.ConversationSummaries,
		health.Rollups,
		lastDreamed,
	)}, message.Context...)
	// The nudge leads, because it is the only thing on this card that asks for
	// anything, and it carries its own button instead of pooling one at the
	// bottom among the Forget buttons.
	if health.PendingReviews > 0 {
		message.Rows = append([]Row{{
			Text: fmt.Sprintf("*%s ready for review.*",
				countLabel(health.PendingReviews, "saved memory item")),
			Actions: []Action{{
				ID: ActionReviewMemory, Label: "Review", Value: "next", Style: "primary",
			}},
		}}, message.Rows...)
	}
	if len(rollups) > 0 {
		message.Sections = append(message.Sections, "*Older conversation continuity*")
		for _, rollup := range rollups[:min(len(rollups), 4)] {
			summary := strings.TrimSpace(rollup.State.SituationSummary)
			if summary == "" {
				summary = displayOr(strings.TrimSpace(rollup.State.Goal), "No situation summary")
			}
			message = AppendRow(message, fmt.Sprintf(
				"*%s* · %s to %s · %s\n> %s",
				escapeSlackText(rollup.ScopeKind+":"+rollup.ScopeKey),
				slackDate(rollup.PeriodStart, "2006-01-02"),
				slackDate(rollup.PeriodEnd, "2006-01-02"),
				countLabel(rollup.SourceCount, "source summary", "source summaries"),
				escapeSlackText(summary),
			), []Action{{
				ID: ActionForgetMemoryRollup, Label: "Discard",
				Value: rollup.ID, Style: "danger",
				Confirm: "Permanently discard this continuity summary?",
			}})
		}
		message.Context = append(message.Context,
			"Continuity rollups summarize older conversations.")
	}
	return message
}

func MemoryRollupForgottenMessage() Message {
	return stateChangeCard(
		"Discarded. That continuity summary will not appear in future context.",
		"*Discarded.* The selected synthesized summary was removed and will no longer appear in future context.",
		"",
	)
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
	// A shelf-style summary first: how much is waiting and of what kind, in one
	// line, so the reader can decide whether to engage with the list at all.
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Product feedback awaiting a decision (%d)*\n%s",
		len(items), escapeSlackText(strings.Join(counts, " · ")),
	))
	for index, item := range items {
		if index >= 5 {
			message.Context = append(message.Context, fmt.Sprintf(
				"%d more feedback items are open; the App Home lists them.",
				len(items)-5,
			))
			break
		}
		// No leading number. The number existed only because the buttons were
		// pooled at the bottom of the page and had to point back at a list —
		// "Always be briefer 1" beside "Dismiss 3" beside a preference toggle,
		// nineteen of them, none next to what it acted on. The controls sit on
		// their item now, so the number is noise that reads like a ranking.
		line := fmt.Sprintf(
			"%s\n_%s · %s_",
			escapeSlackText(item.Summary),
			escapeSlackText(item.Category),
			escapeSlackText(item.Sentiment),
		)
		if item.SourceRef != "" {
			line += " · " + escapeSlackText(item.SourceRef)
		}
		actions := make([]Action, 0, 3)
		// Tone feedback is the one category a typed preference can actually
		// express: response_detail is enforced, where guidance is only weighed.
		// The direction is NOT inferred from the text — "be more concise" and
		// "too terse" are both tone, and guessing between them from prose is
		// how an agent starts confidently doing the opposite of what was asked.
		// The operator picks.
		if item.Category == "tone" {
			actions = append(actions, Action{
				ID:    ActionConvertFeedbackBrief,
				Label: "Always be briefer",
				Value: item.ID,
				Confirm: "Set a standing preference for briefer replies in this workspace? " +
					"This is enforced, not a hint, and you can change it any time.",
			})
		}
		actions = append(actions,
			Action{
				ID: ActionConvertFeedback, Label: "Make it guidance",
				Value: item.ID, Style: "primary",
				Confirm: "Turn this feedback into saved guidance and review the exact wording next?",
			},
			Action{
				ID: ActionDismissFeedback, Label: "Dismiss",
				Value: item.ID,
			},
		)
		message = AppendRow(message, line, actions)
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
	// Honest about where these came from. "A moment I was told I got something
	// wrong" describes human feedback, and four of the five on the page were
	// the host's own validator rejecting Responder's output. Both are worth
	// pinning as tests; only one of them is somebody telling you off.
	message.Sections = append(message.Sections,
		"*Improve Responder* — corrections waiting to become tests\nEach is a time an "+
			"answer was rejected, by the host's checks or by a person. Keep one and it "+
			"becomes a regression test so the mistake cannot return. Discard it if it "+
			"was situational.",
	)
	// Three, then a count. Judging a lesson is slow work and nobody does five of
	// them in a sitting, so the fourth onward is a queue rather than a prompt —
	// and each one costs two blocks on a surface with a hard ceiling.
	for _, item := range items[:min(len(items), 3)] {
		line := escapeSlackText(truncateUTF8(correctionSummary(item.Correction), 300))
		if item.Capability != "" {
			line += " · " + escapeSlackText(item.Capability)
		}
		// A row, so Keep sits under the correction it keeps. The buttons used to
		// be numbered because they were pooled at the bottom and needed to point
		// back at a list; now they are next to their item and the number is noise.
		message = AppendRow(message, line, []Action{
			{
				ID: ActionKeepFixtureCandidate, Label: "Keep",
				Value: item.ID, Style: "primary",
				Confirm: "Turn this correction into a regression test? " +
					"It will be reviewed once more before it reaches a release gate.",
			},
			{
				ID: ActionDiscardFixtureCandidate, Label: "Discard",
				Value: item.ID,
			},
		})
	}
	if extra := len(items) - 3; extra > 0 {
		message.Context = append(message.Context, fmt.Sprintf(
			"%d more corrections are waiting to be judged.", extra,
		))
	}
	return message
}

// correctionSummary drops the machinery prefix a validation failure carries.
//
// Four of five corrections on the App Home began "the structured Slack response
// is invalid:", which is the same words every time and pushes the part that
// differs — the actual rule that was broken — to the right of the colon.
func correctionSummary(correction string) string {
	trimmed := strings.TrimSpace(correction)
	for _, prefix := range []string{
		"the structured Slack response is invalid:",
		"the structured response is invalid:",
	} {
		if len(trimmed) > len(prefix) && strings.EqualFold(trimmed[:len(prefix)], prefix) {
			trimmed = strings.TrimSpace(trimmed[len(prefix):])
			break
		}
	}
	if trimmed == "" {
		return strings.TrimSpace(correction)
	}
	// Rune-aware: a correction can begin with a multi-byte character, and
	// slicing the first byte off one would corrupt it.
	first, width := utf8.DecodeRuneInString(trimmed)
	if first == utf8.RuneError {
		return trimmed
	}
	return string(unicode.ToUpper(first)) + trimmed[width:]
}

package slackui

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

const (
	IncidentCardRevision = "2026-07-28.1"

	ActionUpdate              = "responder_update"
	ActionChanges             = "responder_changes"
	ActionChangesPrevious     = "responder_changes_previous"
	ActionChangesNext         = "responder_changes_next"
	ActionChangesRefresh      = "responder_changes_refresh"
	ActionReview              = "responder_review"
	ActionPublishPR           = "responder_publish_pr"
	ActionViewPR              = "responder_view_pr"
	ActionDiscardWork         = "responder_discard_work"
	ActionStop                = "responder_stop"
	ActionExtend              = "responder_extend"
	ActionResolve             = "responder_resolve"
	ActionHelp                = "responder_help"
	ActionOpenIncident        = "responder_open_incident"
	ActionStartTask           = "responder_start_engineering_task"
	ActionApproveProposal     = "responder_approve_proposal"
	ActionRejectProposal      = "responder_reject_proposal"
	ActionOpenApproval        = "responder_open_emisar_approval"
	ActionRememberMemory      = "responder_remember_memory"
	ActionForgetMemory        = "responder_forget_memory"
	ActionRememberPreference  = "responder_remember_preference"
	ActionTogglePreference    = "responder_toggle_preference"
	ActionEditPreference      = "responder_edit_preference"
	ActionDeletePreference    = "responder_delete_preference"
	ActionRememberRule        = "responder_remember_rule"
	ActionToggleRule          = "responder_toggle_rule"
	ActionEditRule            = "responder_edit_rule"
	ActionDeleteRule          = "responder_delete_rule"
	ActionSaveChannelConfig   = "responder_save_channel_config"
	ActionRestartChannelSetup = "responder_restart_channel_setup"
	ActionCancelChannelSetup  = "responder_cancel_channel_setup"
	ActionSetupQuickMentions  = "responder_setup_quick_mentions"
	ActionSetupQuickProactive = "responder_setup_quick_proactive"
	ActionSetupCustomize      = "responder_setup_customize"
	ActionSetupMentions       = "responder_setup_participation_mentions"
	ActionSetupProactive      = "responder_setup_participation_proactive"
	ActionSetupShadow         = "responder_setup_participation_shadow"
	ActionSetupRepository     = "responder_setup_repository_"
	ActionSetupDefaultRepo    = "responder_setup_repository_default"
	ActionSetupAlertReply     = "responder_setup_alert_reply"
	ActionSetupAlertOffer     = "responder_setup_alert_offer"
	ActionSetupAlertAutomatic = "responder_setup_alert_automatic"
	ActionSetupOperatorsOnly  = "responder_setup_audience_operators"
	ActionSetupIncludeMe      = "responder_setup_audience_include_me"

	ActionCommandStatus            = "responder_command_status"
	ActionCommandOpenIncidents     = "responder_command_incidents_open"
	ActionCommandAllIncidents      = "responder_command_incidents_all"
	ActionCommandPreviousIncidents = "responder_command_incidents_previous"
	ActionCommandNextIncidents     = "responder_command_incidents_next"
)

var (
	ansiPattern   = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)
	tokenPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b`),
		regexp.MustCompile(`(?i)\bxapp-[A-Za-z0-9-]{10,}\b`),
		regexp.MustCompile(`\bemk-[A-Za-z0-9_-]{10,}\b`),
		regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}\b`),
		regexp.MustCompile(`\bAKIA[A-Z0-9]{16}\b`),
	}
	slackMentionPattern = regexp.MustCompile(`<(?:@[A-Z0-9]+|![^>]+)>`)
)

type Message struct {
	Text     string   `json:"text"`
	Header   string   `json:"header,omitempty"`
	Markdown string   `json:"markdown,omitempty"`
	Sections []string `json:"sections,omitempty"`
	Fields   []Field  `json:"fields,omitempty"`
	Context  []string `json:"context,omitempty"`
	Actions  []Action `json:"actions,omitempty"`
}

type Field struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

type Action struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Value   string `json:"value"`
	Style   string `json:"style,omitempty"`
	Confirm string `json:"confirm,omitempty"`
	URL     string `json:"url,omitempty"`
}

type ChangesNavigation struct {
	Page          int
	Pages         int
	FirstByte     int64
	LastByte      int64
	TotalBytes    int64
	Digest        string
	PreviousValue string
	NextValue     string
	RefreshValue  string
}

type Sanitizer struct {
	maxBytes int
	secrets  []string
}

func NewSanitizer(maxBytes int, secrets ...string) *Sanitizer {
	filtered := make([]string, 0, len(secrets))
	for _, secret := range secrets {
		if len(secret) >= 8 {
			filtered = append(filtered, secret)
		}
	}
	return &Sanitizer{maxBytes: maxBytes, secrets: filtered}
}

func (s *Sanitizer) Text(value string) string {
	value = ansiPattern.ReplaceAllString(value, "")
	value = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || !unicode.IsControl(r) {
			return r
		}
		return ' '
	}, value)
	for _, secret := range s.secrets {
		value = strings.ReplaceAll(value, secret, "[REDACTED]")
	}
	for _, pattern := range tokenPatterns {
		value = pattern.ReplaceAllString(value, "[REDACTED]")
	}
	value = slackMentionPattern.ReplaceAllStringFunc(value, func(match string) string {
		return "`" + strings.TrimSuffix(strings.TrimPrefix(match, "<"), ">") + "`"
	})
	value = strings.TrimSpace(value)
	if s.maxBytes > 0 && len(value) > s.maxBytes {
		value = truncateUTF8(value, s.maxBytes-24) + "\n\n_Response truncated._"
	}
	return value
}

func (s *Sanitizer) Message(message Message) Message {
	message.Text = s.Text(message.Text)
	message.Header = s.Text(message.Header)
	message.Markdown = s.Text(message.Markdown)
	for index := range message.Sections {
		message.Sections[index] = s.Text(message.Sections[index])
	}
	for index := range message.Fields {
		message.Fields[index].Label = s.Text(message.Fields[index].Label)
		message.Fields[index].Value = s.Text(message.Fields[index].Value)
	}
	for index := range message.Context {
		message.Context[index] = s.Text(message.Context[index])
	}
	return message
}

func truncateUTF8(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	if len(value) <= limit {
		return value
	}
	value = value[:limit]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return strings.TrimSpace(value)
}

func Encode(message Message) ([]byte, error) {
	return json.Marshal(message)
}

func Decode(data []byte) (Message, error) {
	var message Message
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&message); err != nil {
		return Message{}, err
	}
	if strings.TrimSpace(message.Text) == "" {
		return Message{}, fmt.Errorf("Slack message fallback text is required")
	}
	return message, nil
}

func (m Message) Blocks() []slack.Block {
	blocks := make([]slack.Block, 0, 12)
	if m.Header != "" {
		blocks = append(blocks, slack.NewHeaderBlock(
			slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(singleLine(m.Header), 150), false, false),
		))
	}
	if m.Markdown != "" {
		blocks = append(blocks, slack.NewMarkdownBlock(
			"",
			truncateMarkdown(m.Markdown, 12000),
		))
	}
	for _, section := range m.Sections {
		if section == "" {
			continue
		}
		blocks = append(blocks, slack.NewSectionBlock(
			slack.NewTextBlockObject(slack.MarkdownType, truncateUTF8(section, 2900), false, true),
			nil, nil,
		))
	}
	if len(m.Fields) > 0 {
		fields := make([]*slack.TextBlockObject, 0, len(m.Fields))
		for _, field := range m.Fields {
			fields = append(fields, slack.NewTextBlockObject(
				slack.MarkdownType,
				fmt.Sprintf("*%s*\n%s", truncateUTF8(field.Label, 100), truncateUTF8(field.Value, 500)),
				false, true,
			))
		}
		blocks = append(blocks, slack.NewSectionBlock(nil, fields, nil))
	}
	if len(m.Context) > 0 {
		elements := make([]slack.MixedElement, 0, len(m.Context))
		for _, text := range m.Context {
			elements = append(elements, slack.NewTextBlockObject(
				slack.MarkdownType, truncateUTF8(text, 500), false, true,
			))
		}
		blocks = append(blocks, slack.NewContextBlock("", elements...))
	}
	if len(m.Actions) > 0 {
		blocks = append(blocks, slack.NewDividerBlock())
		for start := 0; start < len(m.Actions); start += 4 {
			end := min(start+4, len(m.Actions))
			elements := make([]slack.BlockElement, 0, end-start)
			for _, action := range m.Actions[start:end] {
				button := slack.NewButtonBlockElement(
					action.ID,
					action.Value,
					slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(action.Label, 75), false, false),
				)
				switch action.Style {
				case "primary":
					button.WithStyle(slack.StylePrimary)
				case "danger":
					button.WithStyle(slack.StyleDanger)
				}
				if action.URL != "" {
					button.WithURL(action.URL)
				}
				if action.Confirm != "" {
					button.WithConfirm(slack.NewConfirmationBlockObject(
						slack.NewTextBlockObject(slack.PlainTextType, "Confirm action", false, false),
						slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(action.Confirm, 300), false, false),
						slack.NewTextBlockObject(slack.PlainTextType, "Confirm", false, false),
						slack.NewTextBlockObject(slack.PlainTextType, "Cancel", false, false),
					))
				}
				elements = append(elements, button)
			}
			blocks = append(blocks, slack.NewActionBlock(
				fmt.Sprintf("responder_incident_actions_%d", start/4+1),
				elements...,
			))
		}
	}
	return blocks
}

func IncidentCard(
	incident core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
) Message {
	return IncidentCardWithPublication(
		incident, repositoryName, signals, hasCodeChanges, core.Publication{},
	)
}

func IncidentCardWithPublication(
	incident core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
	publication core.Publication,
) Message {
	if incident.IsEngineeringTask() {
		return engineeringTaskCard(
			incident, repositoryName, signals, hasCodeChanges, publication,
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
		Actions: incidentActions(incident, hasCodeChanges, publication),
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

func engineeringTaskCard(
	task core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
	publication core.Publication,
) Message {
	workflow := workflowStateLabel(task.Workflow)
	if task.Workflow == core.WorkflowProvisioningChannel {
		if task.IsThreadScoped() {
			workflow = "Starting task"
		} else {
			workflow = "Creating working room"
		}
	}
	state := "Open"
	if task.Status == core.IncidentClosed {
		state = "Closed"
	}
	fallback := fmt.Sprintf(
		"Engineering task %s: %s. %s; Responder %s in %s.",
		ShortID(task.ID), escapeSlackText(task.Title), state, workflow,
		escapeSlackText(repositoryName),
	)
	if task.LastError != "" {
		fallback += " Action needed: " + truncateUTF8(escapeSlackText(task.LastError), 500)
	}
	message := Message{
		Text:   truncateUTF8(fallback, 4000),
		Header: truncateUTF8(singleLine(task.Title), 150),
		Sections: []string{
			fmt.Sprintf("*Engineering task: %s*  |  Responder: *%s*", state, workflow),
		},
		Fields: []Field{
			{Label: "Task", Value: ShortID(task.ID)},
			{Label: "Repository", Value: escapeSlackText(repositoryName)},
		},
		Context: []string{
			"Continue in this thread; replies here go to the same isolated task session.",
			"Updated " + task.UpdatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		},
		Actions: incidentActions(task, hasCodeChanges, publication),
	}
	if !task.CreatedAt.IsZero() {
		message.Fields = append(message.Fields, Field{
			Label: "Started", Value: task.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		})
	}
	if task.CoopForkName != "" {
		message.Fields = append(message.Fields, Field{Label: "Fork", Value: "`" + task.CoopForkName + "`"})
	}
	if signal, ok := primarySignal(signals); ok && strings.TrimSpace(signal.Summary) != "" {
		message.Sections = append(
			message.Sections,
			"*Requested change*\n"+truncateUTF8(escapeSlackText(signal.Summary), 1200),
		)
	}
	switch {
	case publication.Published():
		message.Sections = append(message.Sections,
			fmt.Sprintf(
				"*Draft PR ready*\n<%s|Open draft PR #%d>. The reviewed task tree is now "+
					"durable in GitHub. Responder still cannot merge or deploy it.",
				publication.PRURL, publication.PRNumber,
			),
		)
	case publication.State == "failed":
		message.Sections = append(message.Sections,
			"*Draft PR needs attention*\n"+truncateUTF8(
				escapeSlackText(publication.LastError), 800,
			)+"\n\nCorrect the configuration or remote branch issue, then use *Retry draft PR*.",
		)
	case !hasCodeChanges && task.CoopSessionID != "" &&
		task.Workflow != core.WorkflowInvestigating && task.ActiveTurnID == "":
		message.Sections = append(message.Sections,
			"*Delivery state*\nThe isolated task has no code changes. There is nothing to "+
				"inspect, review, or publish yet. Reply in this thread with the exact change "+
				"you want, or close the task if no repository change is needed.",
		)
	case hasCodeChanges && task.Status != core.IncidentClosed &&
		task.Workflow != core.WorkflowInvestigating && task.ActiveTurnID == "":
		message.Sections = append(message.Sections,
			"*Delivery state*\nCode changes are preserved in the isolated fork. Use *View diff* "+
				"to inspect them or *Create draft PR* to run a fresh readiness review and "+
				"publish the exact approved tree for external review.",
		)
	}
	if task.LastError != "" {
		sections := []string{
			message.Sections[0],
			"*Action needed*\n" + truncateUTF8(escapeSlackText(task.LastError), 800),
		}
		message.Sections = append(sections, message.Sections[1:]...)
	}
	return message
}

func correlationExplanation(incident core.Incident, signals []core.Signal) string {
	if len(signals) < 2 || incident.Route == "manual" {
		return ""
	}
	labels := make([]string, 0, 4)
	for _, name := range []string{"cluster", "namespace", "service", "job"} {
		value := signals[0].Labels[name]
		if value == "" {
			continue
		}
		same := true
		for _, signal := range signals[1:] {
			if signal.Labels[name] != value {
				same = false
				break
			}
		}
		if same {
			labels = append(labels, fmt.Sprintf("`%s=%s`", name, value))
		}
	}
	reason := "The source supplied the same stable incident grouping key."
	if len(labels) > 0 {
		reason += " Shared topology labels: " + strings.Join(labels, ", ") + "."
	}
	reason += " This groups alert signals only; Responder still verifies whether they share a runtime cause."
	return reason
}

func AssistantResponse(text string, sanitizer *Sanitizer) Message {
	text = sanitizer.Text(text)
	if text == "" {
		text = "No response was returned."
	}
	return Message{
		Text:     truncateUTF8("Investigation update: "+text, 4000),
		Header:   "Investigation update",
		Markdown: truncateMarkdown(text, 12000),
		Context:  []string{"Responder reply. Internal tool output and hidden reasoning are omitted."},
	}
}

func ConversationResponse(text string, sanitizer *Sanitizer) Message {
	text = sanitizer.Text(text)
	if text == "" {
		text = "I could not produce a response."
	}
	return Message{
		Text:     truncateUTF8(text, 4000),
		Markdown: truncateMarkdown(text, 12000),
	}
}

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
	message.Sections = append(message.Sections, fmt.Sprintf(
		"*Proposed standing rule*\n"+
			"When `%s` matches a `%s` message, run `%s` against repository `%s` "+
			"and reply in that message's thread.\n\n"+
			"Scope: This channel · Expires: %s",
		offer.Trigger,
		offer.SourceKind,
		offer.Action,
		offer.Repository,
		expiresLabel,
	))
	message.Context = append(
		message.Context,
		"Nothing is saved yet. This rule listens only for its typed trigger, even when broad proactive triage is off. It is read-only and cannot create an incident, edit files, deploy, approve, or mutate infrastructure.",
	)
	message.Actions = append(message.Actions, Action{
		ID:    ActionRememberRule,
		Label: "Enable standing rule",
		Value: actionValue,
		Style: "primary",
		Confirm: "Enable this read-only standing rule in the current channel for " +
			expiresLabel + "? Matching messages will start a bounded investigation and receive a threaded reply.",
	})
	return message
}

func WithEmisarApproval(message Message, approval core.EmisarApproval) Message {
	message.Header = "Approval required in Emisar"
	message.Text = truncateUTF8(
		"Emisar approval required for "+approval.ActionID+
			". Nothing has executed. Review the request in Emisar: "+approval.ApprovalURL,
		4000,
	)
	followup := "After approval or rejection, reply `check approval` here. " +
		"I’ll continue the same run and report the result."
	if approval.IncidentID != "" {
		followup = "After approval or rejection, reply `check approval` in this incident, or choose " +
			"*Ask agent for update* on the pinned card. I’ll continue the same run and report the result."
	}
	message.Sections = append(message.Sections,
		"Emisar paused `"+safeInlineCode(approval.ActionID)+"` before it ran. "+
			"Review the exact target, arguments, evidence, blast radius, and policy decision in Emisar.",
		fmt.Sprintf(
			"*Approval expires:* %s\n*Runner:* `%s`\n*Pack:* `%s`",
			approval.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
			safeInlineCode(approval.RunnerRef),
			safeInlineCode(approval.PackRef),
		),
		followup,
	)
	message.Context = append(
		message.Context,
		"Run `"+safeInlineCode(approval.RunID)+"` is waiting. Approval happens only in Emisar; "+
			"opening the link does not execute it.",
	)
	actions := message.Actions[:0]
	for _, action := range message.Actions {
		if action.ID != ActionApproveProposal && action.ID != ActionRejectProposal {
			actions = append(actions, action)
		}
	}
	message.Actions = append(actions, Action{
		ID:    ActionOpenApproval,
		Label: "Review approval in Emisar",
		Value: approval.RequestID,
		Style: "primary",
		URL:   approval.ApprovalURL,
	})
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

func behaviorToggleValue(id string, enabled bool) string {
	data, _ := json.Marshal(struct {
		ID      string `json:"id"`
		Enabled bool   `json:"enabled"`
	}{ID: id, Enabled: enabled})
	return string(data)
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

func guidanceEntryScopeLabel(entry core.MemoryEntry) string {
	switch {
	case entry.ScopeKind == "workspace" && entry.VisibilityKind == "operator":
		return "only you, across this workspace"
	case entry.ScopeKind == "workspace" && entry.VisibilityKind == "workspace":
		return "everyone in this workspace"
	case entry.ScopeKind == "channel":
		return "<#" + escapeSlackText(entry.ScopeKey) + ">"
	case entry.ScopeKind == "repository" && entry.VisibilityKind == "operator":
		return "only you, for repository `" + escapeSlackText(entry.ScopeKey) + "`"
	case entry.ScopeKind == "repository":
		return "repository `" + escapeSlackText(entry.ScopeKey) + "`"
	default:
		return "`" + escapeSlackText(entry.ScopeKind+":"+entry.ScopeKey) + "`"
	}
}

func PublicationMessage(publication core.Publication, updated bool) Message {
	action := "created"
	header := "Draft PR ready"
	if updated {
		action = "updated"
		header = "Draft PR updated"
	}
	return Message{
		Text: fmt.Sprintf(
			"Responder %s draft PR #%d for this engineering task: %s",
			action, publication.PRNumber, publication.PRURL,
		),
		Header: header,
		Sections: []string{
			fmt.Sprintf(
				"<%s|Open draft PR #%d>\n\nThe branch contains the exact tree approved by "+
					"the latest Coop readiness review. Publication used lease protection, so "+
					"Responder would refuse to overwrite an unexpected remote change.",
				publication.PRURL, publication.PRNumber,
			),
		},
		Context: []string{
			"Draft only. Responder did not merge, deploy, sign, or change infrastructure.",
		},
	}
}

func ConversationResponseWithIncidentOffer(
	text string,
	sourceInputID string,
	sanitizer *Sanitizer,
) Message {
	message := ConversationResponse(text, sanitizer)
	message.Context = []string{
		"No incident has been created. Opening one creates a dedicated Slack room and isolated Coop working copy; it does not merge, push, deploy, or change infrastructure.",
	}
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

func EvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	proposals []core.ActionProposal,
	sanitizer *Sanitizer,
) Message {
	proposals = proposals[:min(len(proposals), 4)]
	message := ConversationResponse(text, sanitizer)
	message.Markdown = truncateMarkdown(
		message.Markdown+evidenceMarkdown(evidence, coverage, proposals),
		12000,
	)
	message.Text = truncateUTF8(message.Text+evidenceFallback(evidence, coverage, proposals), 4000)
	for _, proposal := range proposals {
		message.Actions = append(message.Actions,
			Action{
				ID: ActionApproveProposal, Label: "Approve: " + truncateUTF8(proposal.Title, 48),
				Value: proposal.ID, Style: "primary",
				Confirm: fmt.Sprintf(
					"Approve %s for %s? Required approvals: %d. Emisar policy remains authoritative.",
					proposal.ActionName, proposal.Target, proposal.Required,
				),
			},
			Action{
				ID: ActionRejectProposal, Label: "Reject: " + truncateUTF8(proposal.Title, 48),
				Value: proposal.ID, Style: "danger",
				Confirm: "Reject this proposed action? No operational action will run.",
			},
		)
	}
	return message
}

func ConciseEvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	proposals []core.ActionProposal,
	sanitizer *Sanitizer,
) Message {
	message := EvidenceResponse(text, nil, nil, proposals, sanitizer)
	if summary := evidenceRecordSummary(evidence, coverage); summary != "" {
		message.Context = append(message.Context, summary)
	}
	return message
}

func EvidenceResponseWithIncidentOffer(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sourceInputID string,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, nil, sanitizer)
	message.Context = []string{
		"No incident has been created. Opening one creates a dedicated Slack room and isolated Coop working copy; it does not merge, push, deploy, or change infrastructure.",
	}
	message.Actions = []Action{{
		ID: ActionOpenIncident, Label: "Open incident room", Value: sourceInputID,
		Style: "primary",
		Confirm: "Create a dedicated incident room and isolated Coop working copy from this message? " +
			"No merge, push, deployment, or infrastructure change will occur.",
	}}
	return message
}

func EvidenceResponseWithTaskOffer(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sourceInputID string,
	repositoryLabel string,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, nil, sanitizer)
	message.Context = []string{
		"No engineering task has been created. Starting one keeps the work in this Slack thread and creates an isolated writable Coop working copy for " +
			repositoryLabel + ". It does not merge, push, deploy, or change infrastructure.",
	}
	message.Actions = []Action{{
		ID: ActionStartTask, Label: "Start engineering task", Value: sourceInputID,
		Style: "primary",
		Confirm: "Start an engineering task for " + repositoryLabel +
			" in this thread with an isolated Coop working copy? " +
			"The agent may edit, test, and commit inside that fork under Coop policy. " +
			"No merge, push, deployment, or infrastructure change will occur.",
	}}
	return message
}

func IncidentEvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	proposals []core.ActionProposal,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, proposals, sanitizer)
	message.Header = "Investigation update"
	message.Text = truncateUTF8("Investigation update: "+message.Text, 4000)
	message.Context = append(
		message.Context,
		"Use `/responder evidence` for the detailed source ledger. Internal tool output and hidden reasoning are omitted.",
	)
	return message
}

func evidenceRecordSummary(evidence []core.Evidence, coverage []core.Coverage) string {
	var parts []string
	if len(evidence) > 0 {
		parts = append(parts, countLabel(len(evidence), "finding"))
	}
	if len(coverage) > 0 {
		parts = append(parts, countLabel(len(coverage), "system area checked", "system areas checked"))
	}
	if len(parts) == 0 {
		return ""
	}
	return "Details saved: " + strings.Join(parts, " and ") + "."
}

func countLabel(count int, singular string, plural ...string) string {
	label := singular
	if count != 1 {
		label = singular + "s"
		if len(plural) > 0 {
			label = plural[0]
		}
	}
	return fmt.Sprintf("%d %s", count, label)
}

func evidenceMarkdown(
	evidence []core.Evidence,
	coverage []core.Coverage,
	proposals []core.ActionProposal,
) string {
	var output strings.Builder
	if len(coverage) > 0 {
		output.WriteString("\n\n## Coverage\n\n| Layer | State | Source |\n|---|---|---|\n")
		for _, item := range coverage[:min(len(coverage), 12)] {
			fmt.Fprintf(
				&output,
				"| %s | %s | %s |\n",
				markdownCell(item.Layer),
				markdownCell(item.Status),
				markdownCell(displayOr(item.Source, item.Detail)),
			)
		}
	}
	if len(evidence) > 0 {
		output.WriteString("\n\n## Evidence\n")
		for index, item := range evidence[:min(len(evidence), 10)] {
			source := "`" + strings.ReplaceAll(item.SourceName, "`", "'") + "`"
			if link := sourceLink(item.SourceURL); link != "" {
				source = link
			}
			when := ""
			if !item.ObservedAt.IsZero() {
				when = ", observed " + item.ObservedAt.UTC().Format("2006-01-02 15:04 UTC")
			}
			fmt.Fprintf(
				&output,
				"\n%d. **%s** %s (%s%s)",
				index+1,
				item.Claim,
				item.Observation,
				source,
				when,
			)
		}
	}
	for _, proposal := range proposals[:min(len(proposals), 4)] {
		fmt.Fprintf(
			&output,
			"\n\n## Proposed action: %s\n\n"+
				"**Target:** `%s`  \n**Risk:** %s  \n**Approval:** %d operator%s  \n"+
				"**Why:** %s  \n**Blast radius:** %s  \n**Rollback:** %s  \n"+
				"**Verification:** %s\n\nNo action runs until the configured approval is complete; "+
				"Emisar still applies its own policy and approval controls.",
			proposal.Title,
			strings.ReplaceAll(proposal.Target, "`", "'"),
			proposal.Risk,
			proposal.Required,
			map[bool]string{true: "s", false: ""}[proposal.Required != 1],
			proposal.Summary,
			proposal.BlastRadius,
			proposal.Rollback,
			proposal.Verification,
		)
	}
	return output.String()
}

func evidenceFallback(
	evidence []core.Evidence,
	coverage []core.Coverage,
	proposals []core.ActionProposal,
) string {
	var parts []string
	if len(coverage) > 0 {
		parts = append(parts, fmt.Sprintf("%d infrastructure layers assessed", len(coverage)))
	}
	if len(evidence) > 0 {
		parts = append(parts, fmt.Sprintf("%d evidence sources recorded", len(evidence)))
	}
	if len(proposals) > 0 {
		parts = append(parts, fmt.Sprintf("%d operator-controlled actions proposed", len(proposals)))
	}
	if len(parts) == 0 {
		return ""
	}
	return " " + strings.Join(parts, "; ") + "."
}

func markdownCell(value string) string {
	value = singleLine(value)
	value = strings.ReplaceAll(value, "|", "\\|")
	return truncateUTF8(value, 220)
}

func TurnFailureMessage(state, detail string) Message {
	header := "Investigation could not finish"
	if state == "cancelled" {
		header = "Investigation stopped"
	}
	detail = strings.TrimSpace(detail)
	if detail == "" {
		detail = state
	}
	return Message{
		Text:   header + ": " + escapeSlackText(detail),
		Header: header,
		Sections: []string{
			escapeSlackText(detail),
			"The isolated fork and collected evidence are preserved. Reply in this thread to continue or use the incident controls.",
		},
		Context: []string{"No merge, push, signing, or deployment occurred."},
	}
}

func AgentReportFailureMessage(detail string) Message {
	detail = strings.TrimSpace(detail)
	if detail == "" {
		detail = "the final response did not match the structured report format"
	}
	detail = strings.ReplaceAll(truncateUTF8(detail, 800), "`", "'")
	return Message{
		Text:   "Responder completed the agent turn but could not publish a clean result.",
		Header: "Result needs a clean summary",
		Sections: []string{
			"Coop completed the agent turn, but the final response did not match Responder's structured report format.",
			"Format error: `" + detail + "`",
			"The isolated working copy and full turn output are preserved. Reply in this thread to ask Responder for a fresh summary.",
		},
		Context: []string{
			"Raw agent transcripts, tool output, and hidden reasoning are not posted to Slack.",
		},
	}
}
func TimelineMessage(incident core.Incident, events []core.TimelineEvent) Message {
	var body strings.Builder
	body.WriteString("## Incident timeline\n")
	if len(events) == 0 {
		body.WriteString("\nNo timeline events have been recorded yet.")
	}
	for _, event := range events[:min(len(events), 40)] {
		fmt.Fprintf(
			&body,
			"\n- **%s** - %s",
			event.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			event.Title,
		)
		if event.Detail != "" {
			fmt.Fprintf(&body, "  \n  %s", truncateUTF8(event.Detail, 600))
		}
	}
	return Message{
		Text: fmt.Sprintf(
			"Incident %s timeline with %d recorded events.",
			ShortID(incident.ID), len(events),
		),
		Markdown: truncateMarkdown(body.String(), 12000),
		Context: []string{
			"The timeline is generated from Responder's durable event records, newest first.",
		},
	}
}

func EvidenceDirectoryMessage(
	incident core.Incident,
	evidence []core.Evidence,
	coverage []core.Coverage,
) Message {
	message := EvidenceResponse(
		fmt.Sprintf(
			"## Evidence for incident `%s`\n\nThe entries below are the latest durable "+
				"observations and coverage assessments.",
			ShortID(incident.ID),
		),
		evidence,
		coverage,
		nil,
		NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"Evidence is retained separately from agent prose so operators can audit freshness and source coverage.",
	)
	return message
}

func HandoffMessage(
	incident core.Incident,
	events []core.TimelineEvent,
	evidence []core.Evidence,
	coverage []core.Coverage,
) Message {
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
		for _, event := range events[:min(len(events), 8)] {
			fmt.Fprintf(
				&body,
				"\n- **%s:** %s",
				event.CreatedAt.UTC().Format("15:04 UTC"),
				event.Title,
			)
		}
	}
	message := EvidenceResponse(
		body.String(), evidence[:min(len(evidence), 6)], coverage[:min(len(coverage), 12)],
		nil, NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"This handoff is generated from durable incident state; unknown coverage remains explicit.",
	)
	return message
}

func PostmortemDraft(
	incident core.Incident,
	events []core.TimelineEvent,
	evidence []core.Evidence,
	coverage []core.Coverage,
) Message {
	var body strings.Builder
	fmt.Fprintf(
		&body,
		"## Post-incident draft: %s\n\n"+
			"**Incident:** `%s`  \n**Severity:** %s  \n**Started:** %s  \n**Closed:** %s\n\n"+
			"### What is verified\n",
		escapeSlackText(incident.Title),
		ShortID(incident.ID),
		displayOr(incident.Severity, "unclassified"),
		incident.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		time.Now().UTC().Format("2006-01-02 15:04 UTC"),
	)
	if len(evidence) == 0 {
		body.WriteString("\nNo structured evidence was recorded. Root cause must remain unassigned.")
	} else {
		for _, item := range evidence[:min(len(evidence), 8)] {
			fmt.Fprintf(&body, "\n- **%s:** %s", item.Claim, item.Observation)
		}
	}
	body.WriteString("\n\n### Timeline\n")
	for _, event := range events[:min(len(events), 20)] {
		fmt.Fprintf(
			&body,
			"\n- **%s:** %s",
			event.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			event.Title,
		)
	}
	body.WriteString(
		"\n\n### Follow-up\n\n- [ ] Confirm impact and affected users\n" +
			"- [ ] Confirm root cause from cited evidence\n" +
			"- [ ] Assign corrective actions and owners\n" +
			"- [ ] Add or improve detection and recovery validation\n",
	)
	message := EvidenceResponse(
		body.String(), nil, coverage[:min(len(coverage), 12)], nil, NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"This is an evidence-grounded draft. It deliberately does not invent impact, root cause, owners, or corrective actions.",
	)
	return message
}

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

func commitmentStateLabel(state core.CommitmentState) string {
	switch state {
	case core.CommitmentQueued:
		return "Queued"
	case core.CommitmentWorking:
		return "Working"
	case core.CommitmentFinishing:
		return "Finishing"
	case core.CommitmentBlocked:
		return "Blocked"
	case core.CommitmentDone:
		return "Done"
	default:
		return "Cancelled"
	}
}

func CommitmentDirectoryMessage(items []core.Commitment) Message {
	if len(items) == 0 {
		return Message{
			Text:   "Emisar has no unfinished commitments.",
			Header: "No unfinished commitments",
			Markdown: "I do not currently owe the team an investigation, response, or retry. " +
				"Closed incidents and completed engineering tasks remain available in the work history.",
		}
	}
	var body strings.Builder
	body.WriteString(
		"These are durable agent runs that are queued, active, finishing, or blocked. " +
			"Emisar resumes them after restarts and returns to the originating conversation.\n",
	)
	for _, item := range items {
		location := ""
		if item.ChannelID != "" {
			location = " in <#" + item.ChannelID + ">"
		}
		fmt.Fprintf(
			&body,
			"\n- **%s**%s\n  %s - %s",
			escapeSlackText(item.Title),
			location,
			commitmentStateLabel(item.State),
			escapeSlackText(item.Status),
		)
		if item.NextAction != "" {
			fmt.Fprintf(
				&body,
				"\n  Next: %s",
				escapeSlackText(item.NextAction),
			)
		}
	}
	return Message{
		Text:     fmt.Sprintf("%d unfinished Emisar commitments.", len(items)),
		Header:   "What Emisar owes the team",
		Markdown: body.String(),
		Context: []string{
			"Blocked work remains visible until it is retried, resolved, or removed by retention cleanup.",
		},
	}
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
		ID: ActionPublishPR, Label: "Create draft PR", Value: incident.ID, Style: "primary",
		Confirm: "Run a fresh Coop readiness review, recreate the exact approved tree in an isolated checkout, push a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
	}
	if publication.Published() {
		publish.Label = "Update draft PR"
		publish.Confirm = "Run a fresh Coop readiness review and update the existing Responder draft PR using lease-protected branch publication? This cannot merge or deploy."
	} else if publication.State == "failed" {
		publish.Label = "Retry draft PR"
	}
	viewPR := Action{
		ID: ActionViewPR, Label: "View draft PR", Value: incident.ID,
		URL: publication.PRURL,
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
		if hasCodeChanges {
			actions := []Action{changes}
			if publication.Published() {
				actions = append(actions, viewPR)
			} else if incident.IsEngineeringTask() {
				actions = append(actions, Action{
					ID: ActionDiscardWork, Label: "Discard retained work",
					Value: incident.ID, Style: "danger",
					Confirm: "Permanently delete this closed task's unpublished committed work and isolated Coop state? This cannot be undone. Dirty uncommitted work is never discarded.",
				})
			}
			return actions
		}
		return nil
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
			if publication.Published() {
				actions = append(actions, viewPR)
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

func workflowStateLabel(workflow core.WorkflowState) string {
	switch workflow {
	case core.WorkflowProvisioningChannel:
		return "Creating incident room"
	case core.WorkflowProvisioningSession:
		return "Preparing isolated workspace"
	case core.WorkflowHolding:
		return "Queued for capacity"
	case core.WorkflowInvestigating:
		return "Investigating"
	case core.WorkflowParked:
		return "Waiting for input"
	case core.WorkflowBlocked:
		return "Needs operator action"
	case core.WorkflowClosed:
		return "Closed"
	default:
		return displayOr(strings.ReplaceAll(string(workflow), "_", " "), "Unknown")
	}
}

func workflowStateDescription(incident core.Incident) string {
	switch incident.Workflow {
	case core.WorkflowProvisioningChannel:
		if incident.IsThreadScoped() {
			return "Responder is attaching a durable task card and isolated work session to this Slack thread."
		}
		return "Slack is creating and preparing the dedicated incident room."
	case core.WorkflowProvisioningSession:
		return "Responder is creating an isolated Coop session and working copy. Investigation has not started yet."
	case core.WorkflowHolding:
		return "The incident is queued because the configured active-agent capacity is currently full."
	case core.WorkflowInvestigating:
		return "An agent turn is running or waiting to run against the isolated incident context."
	case core.WorkflowParked:
		return "No agent turn is running. The incident remains open and Responder is waiting for operator input."
	case core.WorkflowBlocked:
		return "Responder cannot continue until an operator addresses the blocker shown on the pinned card."
	case core.WorkflowClosed:
		return "The incident session is closed. Its isolated working copy remains preserved."
	default:
		return "Responder reported a state it cannot yet describe. Check the pinned card and service logs before taking action."
	}
}

func signalStateSummary(incident core.Incident) string {
	if incident.IsEngineeringTask() {
		if incident.Status == core.IncidentClosed {
			return "Engineering task closed; the isolated fork is preserved."
		}
		return "Engineering task is open."
	}
	switch incident.Status {
	case core.IncidentMonitoring:
		if !incident.ResolveDueAt.IsZero() {
			return "All signals recovered. Responder is monitoring until " +
				incident.ResolveDueAt.UTC().Format("2006-01-02 15:04 UTC") + "."
		}
		return "All signals recovered. Responder is monitoring for a stable recovery."
	case core.IncidentResolved:
		return "All alert signals have recovered."
	case core.IncidentClosed:
		if incident.FiringCount > 0 {
			return fmt.Sprintf(
				"Incident closed with %d of %d signals still firing; the isolated fork is preserved.",
				incident.FiringCount, incident.SignalCount,
			)
		}
		return "Incident closed; the isolated fork is preserved."
	default:
		return fmt.Sprintf(
			"%d of %d alert signals are firing.",
			incident.FiringCount, incident.SignalCount,
		)
	}
}

func primarySignal(signals []core.Signal) (core.Signal, bool) {
	for index := len(signals) - 1; index >= 0; index-- {
		if signals[index].Status == core.SignalFiring {
			return signals[index], true
		}
	}
	if len(signals) == 0 {
		return core.Signal{}, false
	}
	return signals[len(signals)-1], true
}

func sourceLink(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 300 || strings.ContainsAny(value, "<>|") {
		return ""
	}
	parsed, err := url.ParseRequestURI(value)
	if err != nil || parsed.Host == "" || parsed.User != nil ||
		(parsed.Scheme != "https" && parsed.Scheme != "http") {
		return ""
	}
	hostname := parsed.Hostname()
	if hostname == "" {
		return ""
	}
	parsed.RawQuery = ""
	parsed.ForceQuery = false
	parsed.Fragment = ""
	return "<" + parsed.String() + "|Open " + escapeSlackText(hostname) + ">"
}

func singleLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func escapeSlackText(value string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(value)
}

func safeInlineCode(value string) string {
	return escapeSlackText(strings.ReplaceAll(value, "`", "'"))
}

func ChangesMessage(
	incident core.Incident,
	summary string,
	patch []byte,
	navigation ChangesNavigation,
) Message {
	context := "The fork remains isolated. No merge, signing, push, or deployment occurred."
	if incident.CoopForkName != "" {
		context = "Fork `" + incident.CoopForkName + "`. No merge, signing, push, or deployment occurred."
	}
	work := "incident"
	if incident.IsEngineeringTask() {
		work = "engineering task"
	}
	var markdown strings.Builder
	markdown.WriteString(summary)
	if navigation.TotalBytes > 0 {
		page := max(navigation.Page, 1)
		pages := max(navigation.Pages, 1)
		markdown.WriteString(fmt.Sprintf(
			"\n\n*Patch page %d of %d* · bytes %d-%d of %d",
			page,
			pages,
			navigation.FirstByte+1,
			navigation.LastByte,
			navigation.TotalBytes,
		))
		if len(navigation.Digest) >= 12 {
			markdown.WriteString(" · snapshot `" + safeInlineCode(navigation.Digest[:12]) + "`")
		}
	}
	if len(patch) > 0 {
		diff := strings.ToValidUTF8(string(patch), "\uFFFD")
		diff = strings.ReplaceAll(diff, "```", "` ` `")
		markdown.WriteString("\n\n```diff\n")
		markdown.WriteString(diff)
		markdown.WriteString("\n```")
	} else if navigation.TotalBytes == 0 {
		markdown.WriteString(
			"\n\n_No tracked text patch is available. Untracked or binary files may still " +
				"appear in the change summary._",
		)
	}
	message := Message{
		Text:     "Code changes for " + work + " " + ShortID(incident.ID) + ": " + summary,
		Header:   "Code changes",
		Markdown: truncateMarkdown(markdown.String(), 12000),
		Context:  []string{context},
	}
	if navigation.PreviousValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesPrevious, Label: "Previous page",
			Value: navigation.PreviousValue,
		})
	}
	if navigation.NextValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesNext, Label: "Next page",
			Value: navigation.NextValue,
		})
	}
	if navigation.RefreshValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesRefresh, Label: "Refresh diff",
			Value: navigation.RefreshValue,
		})
	}
	return message
}

func ReviewMessage(incident core.Incident, summary string, publishable bool) Message {
	state := "Not ready for review"
	if publishable {
		state = "Ready for external review"
	}
	work := "incident"
	if incident.IsEngineeringTask() {
		work = "engineering task"
	}
	message := Message{
		Text:     state + " for " + work + " " + ShortID(incident.ID),
		Header:   state,
		Sections: []string{summary},
		Context:  []string{"No branch was pushed and no pull request was created."},
	}
	if publishable && incident.IsEngineeringTask() {
		message.Context = []string{"The reviewed tree is pinned. Creating a draft PR will not merge or deploy it."}
		message.Actions = []Action{{
			ID: ActionPublishPR, Label: "Create draft PR", Value: incident.ID, Style: "primary",
			Confirm: "Run a fresh readiness review, publish the exact approved tree on a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
		}}
	}
	return message
}

func WithEngineeringTaskDelivery(
	message Message,
	incident core.Incident,
	hasCodeChanges bool,
) Message {
	if !incident.IsEngineeringTask() {
		return message
	}
	if !hasCodeChanges {
		message.Context = append(
			message.Context,
			"No code changes were produced. There is no diff or draft PR to deliver.",
		)
		return message
	}
	message.Context = append(
		message.Context,
		"Changes are preserved in the isolated task fork. View the diff, then create a draft PR for external review.",
	)
	message.Actions = append(message.Actions,
		Action{ID: ActionChanges, Label: "View diff", Value: incident.ID},
		Action{
			ID: ActionPublishPR, Label: "Create draft PR", Value: incident.ID, Style: "primary",
			Confirm: "Run Coop's readiness review, publish the exact approved tree on a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
		},
	)
	return message
}

func HelpMessage(incident core.Incident) Message {
	conversation := "*Conversation*\nReply normally anywhere in this incident channel. Responder reads " +
		"operator messages as part of the incident conversation; an `@mention` is not required."
	controls := "*Lifecycle controls*\nUse the pinned incident card to stop the active turn or close the incident. " +
		"`/responder stop` cancels the active turn but preserves its work. `/responder close` closes " +
		"the session and schedules ownership-checked retention."
	channelBehavior := "*Channel behavior*\n`/responder status` explains what Responder reads here and why. " +
		"`/responder proactive ...` configures normal-channel triage; it does not disable " +
		"conversation in an attached incident room."
	noun := "incident"
	if incident.IsThreadScoped() {
		noun = "engineering task"
		conversation = "*Conversation*\nKeep replying in this Slack thread. Every authorized reply continues " +
			"the same isolated engineering session; an `@mention` is not required."
		controls = "*Lifecycle controls*\nUse the task card in this thread to stop the active turn, inspect " +
			"changes, check fix readiness, publish a draft PR, or close the task. Slack slash commands do not carry thread " +
			"context, so they cannot select this task from the channel composer."
		channelBehavior = "*Thread scope*\nOnly this source thread is attached to the writable task. Other " +
			"messages in the shared channel continue through its normal read-only triage settings."
	}
	return Message{
		Text:   "Responder controls for " + noun + " " + ShortID(incident.ID),
		Header: "How to work with Responder",
		Sections: []string{
			conversation,
			"*Read-only inspection*\n`/responder update` requests a fresh " +
				"evidence-based summary.\n`/responder changes` shows the isolated working " +
				"copy's diff.\n`/responder review` compares a proposed change with the current " +
				"repository and runs rebase, validation, and policy checks.\n`/responder publish` " +
				"creates or updates a draft PR from the exact reviewed tree for a channel-scoped task.",
			controls,
			"*Automatic capacity*\nResponder allocates turns automatically when authorized work " +
				"arrives. `/responder turn-limit` explains the current channel's lifetime " +
				"safety ceiling; operators do not estimate how many turns a task requires.",
			channelBehavior,
			"Legacy deterministic controls such as `!respond status` and `!respond stop` also " +
				"work when sent as the entire message.",
		},
		Context: []string{
			"Controls never merge, sign, or deploy. Draft PR publication can push only a verified, lease-protected Responder branch. Coop and Emisar policy still govern infrastructure access and approvals.",
		},
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

func Notice(text string) Message {
	return Message{Text: text, Sections: []string{text}}
}

func truncateMarkdown(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	const marker = "\n\n_Response truncated._"
	return truncateUTF8(value, limit-len(marker)) + marker
}

func ShortID(id string) string {
	if index := strings.IndexByte(id, '_'); index >= 0 {
		id = id[index+1:]
	}
	if len(id) > 10 {
		return id[:10]
	}
	return id
}

func displayOr(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func ChannelName(prefix string, incident core.Incident) string {
	title := strings.ToLower(incident.Title)
	var slug strings.Builder
	lastDash := false
	for _, r := range title {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			slug.WriteRune(r)
			lastDash = false
		case !lastDash:
			slug.WriteByte('-')
			lastDash = true
		}
		if slug.Len() >= 36 {
			break
		}
	}
	name := strings.Trim(slug.String(), "-")
	if name == "" {
		name = "incident"
	}
	createdAt := incident.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Unix(0, 0)
	}
	result := fmt.Sprintf("%s-%s-%s", prefix, createdAt.UTC().Format("0102"), name)
	suffix := "-" + ShortID(incident.ID)[:min(10, len(ShortID(incident.ID)))]
	if len(result)+len(suffix) > 80 {
		result = result[:80-len(suffix)]
		result = strings.TrimRight(result, "-")
	}
	return result + suffix
}

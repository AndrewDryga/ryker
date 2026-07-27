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
	ActionUpdate  = "responder_update"
	ActionChanges = "responder_changes"
	ActionReview  = "responder_review"
	ActionStop    = "responder_stop"
	ActionExtend  = "responder_extend"
	ActionResolve = "responder_resolve"
	ActionHelp    = "responder_help"
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

func IncidentCard(incident core.Incident, repositoryName string, signals []core.Signal) Message {
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
		Actions: incidentActions(incident),
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
	if incident.LastError != "" {
		sections := []string{
			message.Sections[0],
			"*Action needed*\n" + truncateUTF8(escapeSlackText(incident.LastError), 800),
		}
		message.Sections = append(sections, message.Sections[1:]...)
	}
	return message
}

func AssistantResponse(text string, sanitizer *Sanitizer) Message {
	text = sanitizer.Text(text)
	if text == "" {
		text = "No response was returned."
	}
	return Message{
		Text:     truncateUTF8("Investigation update: "+text, 4000),
		Header:   "Investigation update",
		Sections: splitSections(text, 2800, 5),
		Context:  []string{"Responder reply. Internal tool output and hidden reasoning are omitted."},
	}
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

func incidentActions(incident core.Incident) []Action {
	if incident.RootTS == "" {
		return nil
	}
	changes := Action{ID: ActionChanges, Label: "View changes", Value: incident.ID}
	review := Action{ID: ActionReview, Label: "Review fix", Value: incident.ID}
	closeIncident := Action{
		ID: ActionResolve, Label: "Close incident", Value: incident.ID, Style: "danger",
		Confirm: "Close the Coop session and preserve its fork for review?",
	}
	if incident.Status == core.IncidentClosed {
		actions := make([]Action, 0, 3)
		if incident.CoopForkName != "" {
			actions = append(actions, changes)
		}
		if incident.CoopSessionID != "" {
			actions = append(actions, review)
		}
		return actions
	}
	if incident.CoopSessionID == "" {
		return []Action{closeIncident}
	}
	extend := Action{
		ID: ActionExtend, Label: "Extend budget", Value: incident.ID,
		Confirm: "Add the configured turn allowance to this incident session?",
	}
	if incident.ActiveTurnID != "" {
		actions := []Action{{
			ID: ActionStop, Label: "Stop turn", Value: incident.ID, Style: "danger",
			Confirm: "Stop the active agent turn? The fork and queued work are preserved.",
		}}
		if incident.CoopForkName != "" {
			actions = append(actions, changes)
		}
		return append(actions, extend)
	}
	if incident.Workflow == core.WorkflowInvestigating {
		actions := make([]Action, 0, 3)
		if incident.CoopForkName != "" {
			actions = append(actions, changes)
		}
		return append(actions, extend)
	}
	actions := make([]Action, 0, 4)
	if incident.Workflow == core.WorkflowBlocked {
		extend.Style = "primary"
		actions = append(actions, extend)
	} else {
		actions = append(actions, Action{
			ID: ActionUpdate, Label: "Get update", Value: incident.ID, Style: "primary",
		})
	}
	if incident.CoopForkName != "" {
		actions = append(actions, changes)
	}
	actions = append(actions, review)
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

func signalStateSummary(incident core.Incident) string {
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

func ChangesMessage(incident core.Incident, summary string) Message {
	context := "The fork remains isolated. No merge, signing, push, or deployment occurred."
	if incident.CoopForkName != "" {
		context = "Fork `" + incident.CoopForkName + "`. No merge, signing, push, or deployment occurred."
	}
	return Message{
		Text:     "Code changes for incident " + ShortID(incident.ID),
		Header:   "Code changes",
		Sections: []string{summary},
		Context:  []string{context},
	}
}

func ReviewMessage(incident core.Incident, summary string, publishable bool) Message {
	state := "Not ready for review"
	if publishable {
		state = "Ready for external review"
	}
	return Message{
		Text:     state + " for incident " + ShortID(incident.ID),
		Header:   state,
		Sections: []string{summary},
		Context:  []string{"This is Coop review evidence, not permission to merge or deploy."},
	}
}

func HelpMessage(incidentID string) Message {
	return Message{
		Text:   "Responder controls for incident " + ShortID(incidentID),
		Header: "Responder controls",
		Sections: []string{
			"Reply in this thread to continue the investigation. Deterministic commands must be the entire message:",
			"`!respond status`\n`!respond update`\n`!respond changes`\n`!respond review`\n`!respond stop`\n`!respond extend`\n`!respond close`\n`!respond help`",
		},
		Context: []string{"Natural-language approximations never execute control actions."},
	}
}

func Notice(text string) Message {
	return Message{Text: text, Sections: []string{text}}
}

func splitSections(value string, max, limit int) []string {
	if value == "" {
		return []string{"No response was returned."}
	}
	var result []string
	remaining := value
	for remaining != "" && len(result) < limit {
		if len(remaining) <= max {
			result = append(result, remaining)
			break
		}
		cut := strings.LastIndex(remaining[:max], "\n\n")
		if cut < max/2 {
			cut = strings.LastIndex(remaining[:max], "\n")
		}
		if cut < max/2 {
			cut = max
		}
		for cut > 0 && !utf8.ValidString(remaining[:cut]) {
			cut--
		}
		result = append(result, strings.TrimSpace(remaining[:cut]))
		remaining = strings.TrimSpace(remaining[cut:])
	}
	if remaining != "" && len(result) > 0 {
		const marker = "\n\n_Response truncated._"
		last := len(result) - 1
		result[last] = truncateUTF8(result[last], max-len(marker)) + marker
	}
	return result
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

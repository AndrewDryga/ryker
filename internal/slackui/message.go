package slackui

import (
	"bytes"
	"encoding/json"
	"fmt"
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
	blocks := make([]slack.Block, 0, 8)
	if m.Header != "" {
		blocks = append(blocks, slack.NewHeaderBlock(
			slack.NewTextBlockObject(slack.PlainTextType, truncateUTF8(m.Header, 150), false, false),
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
		elements := make([]slack.BlockElement, 0, len(m.Actions))
		for _, action := range m.Actions {
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
		blocks = append(blocks, slack.NewActionBlock("responder_incident_actions", elements...))
	}
	return blocks
}

func IncidentCard(incident core.Incident, repositoryName string) Message {
	status := strings.ReplaceAll(string(incident.Status), "_", " ")
	workflow := strings.ReplaceAll(string(incident.Workflow), "_", " ")
	message := Message{
		Text:   fmt.Sprintf("Incident %s: %s (%s)", ShortID(incident.ID), incident.Title, status),
		Header: truncateUTF8(incident.Title, 150),
		Sections: []string{
			"Responder is keeping the investigation and code work in this thread. Reply here to collaborate.",
		},
		Fields: []Field{
			{Label: "Incident", Value: ShortID(incident.ID)},
			{Label: "Severity", Value: displayOr(incident.Severity, "unclassified")},
			{Label: "Alert state", Value: status},
			{Label: "Responder", Value: workflow},
			{Label: "Signals", Value: fmt.Sprintf("%d firing / %d total", incident.FiringCount, incident.SignalCount)},
			{Label: "Repository", Value: repositoryName},
		},
		Context: []string{
			"Only allowlisted operators can steer the agent. Infrastructure authority remains enforced by Emisar.",
			"Updated " + incident.UpdatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		},
		Actions: []Action{
			{ID: ActionChanges, Label: "Changes", Value: incident.ID},
			{ID: ActionReview, Label: "Review fix", Value: incident.ID},
			{ID: ActionHelp, Label: "Controls", Value: incident.ID},
		},
	}
	if incident.CoopForkName != "" {
		message.Fields = append(message.Fields, Field{Label: "Fork", Value: "`" + incident.CoopForkName + "`"})
	}
	if incident.Status != core.IncidentClosed {
		message.Actions = append([]Action{{
			ID: ActionUpdate, Label: "Get update", Value: incident.ID, Style: "primary",
		}}, message.Actions...)
	}
	if incident.ActiveTurnID != "" && incident.Status != core.IncidentClosed {
		message.Actions = append(message.Actions, Action{
			ID: ActionStop, Label: "Stop turn", Value: incident.ID, Style: "danger",
			Confirm: "Stop the active agent turn? The fork and queued work are preserved.",
		})
	}
	if incident.Status != core.IncidentClosed {
		message.Actions = append(message.Actions, Action{
			ID: ActionExtend, Label: "Extend budget", Value: incident.ID,
			Confirm: "Add the configured turn allowance to this incident session?",
		})
		message.Actions = append(message.Actions, Action{
			ID: ActionResolve, Label: "Close incident", Value: incident.ID,
			Confirm: "Close the Coop session and preserve its fork for review?",
		})
	}
	if incident.LastError != "" {
		message.Sections = append(message.Sections, "*Needs attention*\n"+truncateUTF8(incident.LastError, 800))
	}
	return message
}

func AssistantResponse(text string, sanitizer *Sanitizer) Message {
	text = sanitizer.Text(text)
	if text == "" {
		text = "No response was returned."
	}
	return Message{
		Text:     truncateUTF8(text, 4000),
		Sections: splitSections(text, 2800, 5),
		Context:  []string{"Agent response. Tool output and hidden reasoning are not forwarded."},
	}
}

func SignalUpdate(incident core.Incident, signals []core.Signal) Message {
	lines := make([]string, 0, len(signals))
	for _, signal := range signals {
		lines = append(lines, fmt.Sprintf("• *%s* — %s", truncateUTF8(signal.Title, 180), signal.Status))
		if len(lines) == 8 {
			break
		}
	}
	return Message{
		Text:     fmt.Sprintf("Signal update for incident %s", ShortID(incident.ID)),
		Sections: []string{"*Signal update*\n" + strings.Join(lines, "\n")},
		Context:  []string{fmt.Sprintf("%d firing / %d total", incident.FiringCount, incident.SignalCount)},
	}
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

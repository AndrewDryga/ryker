package slackui

import (
	"net/url"
	"strings"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
)

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

// safeActionURL drops anything that is not an ordinary web link. Slack renders
// a button URL directly, so a non-HTTPS scheme would be an unreviewed escape
// from the host-owned control surface.
func safeActionURL(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return ""
	}
	return value
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

const (
	maxSlackHeaderBytes  = 150
	maxSlackSectionBytes = 3000
	maxSlackFieldBytes   = 2000
	maxSlackContextBytes = 2000
	maxSlackButtonBytes  = 75
)

// Message redacts and bounds every field of an outgoing message.
//
// The bounds are Slack's Block Kit limits. A payload over any of them is
// rejected at delivery — after the work is done, and in a way the agent cannot
// explain to whoever is waiting. Not every field that reaches a card is
// bounded upstream (a preference value and a standing-rule trigger are not),
// so the bound belongs here, at the one point every outgoing message passes
// through.
func (s *Sanitizer) Message(message Message) Message {
	// Message is passed by value but its slices share a backing array with the
	// caller's. Clone them so sanitizing a copy cannot rewrite the original,
	// which would silently change what a caller logs, re-renders, or compares.
	message.Sections = append([]string(nil), message.Sections...)
	message.Fields = append([]Field(nil), message.Fields...)
	message.Context = append([]string(nil), message.Context...)
	message.Actions = append([]Action(nil), message.Actions...)
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
	// Bound to Slack's block limits last, after redaction, so a truncation can
	// never leave half of a secret behind.
	message.Header = core.TruncateUTF8(message.Header, maxSlackHeaderBytes)
	for index := range message.Sections {
		message.Sections[index] = truncateMarkdown(message.Sections[index], maxSlackSectionBytes)
	}
	for index := range message.Fields {
		message.Fields[index].Label = core.TruncateUTF8(message.Fields[index].Label, maxSlackFieldBytes)
		message.Fields[index].Value = truncateMarkdown(message.Fields[index].Value, maxSlackFieldBytes)
	}
	for index := range message.Context {
		message.Context[index] = truncateMarkdown(message.Context[index], maxSlackContextBytes)
	}
	// Every button is host-owned today, but redaction must not depend on that
	// staying true: a label or confirmation that later carries a repository,
	// memory subject, or model-proposed title would otherwise skip the filter.
	for index := range message.Actions {
		message.Actions[index].Label = core.TruncateUTF8(
			s.Text(message.Actions[index].Label), maxSlackButtonBytes,
		)
		message.Actions[index].Confirm = s.Text(message.Actions[index].Confirm)
		message.Actions[index].URL = safeActionURL(message.Actions[index].URL)
	}
	return message
}

// safeActionURL drops anything that is not an ordinary web link. Slack renders
// a button URL directly, so a non-HTTPS scheme would be an unreviewed escape
// from the host-owned control surface.

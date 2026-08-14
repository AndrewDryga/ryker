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
		// <!channel>, <!here> and <!subteam^…> address people, and a message
		// built from text this process did not write must never emit one.
		// <!date^…> is the one bang form that addresses nobody: it is a
		// client-side timestamp, and it is how every card now renders a wall
		// time in the reader's own zone. Neutering it protected no one and
		// turned each footer into backticked noise — which is what it had been
		// doing to every card written since the helper landed, unnoticed
		// because no card used the helper yet.
		//
		// Matched against the exact shape slackDate emits rather than a
		// prefix, so a hostile string cannot smuggle a broadcast through by
		// opening with one: anything carrying an angle bracket of its own
		// fails the match and is neutered like the rest.
		if slackDatePattern.MatchString(match) {
			return match
		}
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
	// The tail is a section that renders last, and it holds the one thing on
	// the card that is entirely somebody else's words — the request as it was
	// written, pasted logs and all. Sanitizing Sections and stopping there
	// would put the least trusted text on the card outside the redaction pass.
	message.Tail = append([]string(nil), message.Tail...)
	message.Text = s.Text(message.Text)
	message.Header = s.Text(message.Header)
	message.Markdown = s.Text(message.Markdown)
	for index := range message.Sections {
		message.Sections[index] = s.Text(message.Sections[index])
	}
	for index := range message.Tail {
		message.Tail[index] = s.Text(message.Tail[index])
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
	for index := range message.Tail {
		message.Tail[index] = truncateMarkdown(message.Tail[index], maxSlackSectionBytes)
	}
	for index := range message.Fields {
		message.Fields[index].Label = core.TruncateUTF8(message.Fields[index].Label, maxSlackFieldBytes)
		message.Fields[index].Value = truncateMarkdown(message.Fields[index].Value, maxSlackFieldBytes)
	}
	for index := range message.Context {
		message.Context[index] = truncateMarkdown(message.Context[index], maxSlackContextBytes)
	}
	// Rows, the overflow menu, and the ledger were added as renderer
	// primitives with no caller, so nothing carried operator-visible text
	// through them until the work cards did. A row now holds the requester's
	// own words and a ledger line holds alert labels — both arrive from
	// outside this process, and a redaction pass that stops at Sections would
	// be a hole that opened the moment the first caller appeared.
	message.Rows = append([]Row(nil), message.Rows...)
	for index := range message.Rows {
		message.Rows[index].Text = truncateMarkdown(
			s.Text(message.Rows[index].Text), maxSlackSectionBytes,
		)
		message.Rows[index].Actions = s.actions(message.Rows[index].Actions)
		message.Rows[index].Overflow = s.actions(message.Rows[index].Overflow)
	}
	message.Overflow = s.actions(message.Overflow)
	message.Ledger = s.ledger(message.Ledger)
	// Every button is host-owned today, but redaction must not depend on that
	// staying true: a label or confirmation that later carries a repository,
	// memory subject, or model-proposed title would otherwise skip the filter.
	message.Actions = s.actions(message.Actions)
	return message
}

func (s *Sanitizer) actions(actions []Action) []Action {
	if len(actions) == 0 {
		return actions
	}
	cleaned := append([]Action(nil), actions...)
	for index := range cleaned {
		cleaned[index].Label = core.TruncateUTF8(
			s.Text(cleaned[index].Label), maxSlackButtonBytes,
		)
		cleaned[index].Confirm = s.Text(cleaned[index].Confirm)
		cleaned[index].URL = safeActionURL(cleaned[index].URL)
	}
	return cleaned
}

func (s *Sanitizer) ledger(steps []LedgerStep) []LedgerStep {
	if len(steps) == 0 {
		return steps
	}
	cleaned := append([]LedgerStep(nil), steps...)
	for index := range cleaned {
		cleaned[index].Label = s.Text(cleaned[index].Label)
		cleaned[index].Detail = s.Text(cleaned[index].Detail)
		cleaned[index].When = s.Text(cleaned[index].When)
		cleaned[index].Owner = s.Text(cleaned[index].Owner)
		cleaned[index].Children = s.ledger(cleaned[index].Children)
	}
	return cleaned
}

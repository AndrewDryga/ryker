// Package taskcard prepares human-readable updates for durable task cards.
package taskcard

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// Update extracts presentation text without carrying over one-off controls.
func Update(message slackui.Message, replyParts []string, sanitize func(string) string) string {
	if len(replyParts) > 0 {
		return core.BoundedText(sanitize(strings.Join(replyParts, "\n\n")), 6000)
	}
	parts := make([]string, 0, 2+len(message.Sections)+len(message.Rows)+len(message.Fields)+len(message.Context))
	appendPart := func(value string) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		for _, existing := range parts {
			if existing == value {
				return
			}
		}
		parts = append(parts, value)
	}
	if markdown := strings.TrimSpace(message.Markdown); markdown != "" {
		appendPart(markdown)
	} else if message.Header != "" || len(message.Sections) > 0 || len(message.Rows) > 0 || len(message.Fields) > 0 || len(message.Context) > 0 {
		appendPart(message.Header)
	} else {
		appendPart(message.Text)
	}
	for _, value := range message.Sections {
		appendPart(value)
	}
	for _, row := range message.Rows {
		appendPart(row.Text)
	}
	for _, field := range message.Fields {
		value := strings.TrimSpace(field.Value)
		if value == "" {
			continue
		}
		if label := strings.TrimSpace(field.Label); label != "" {
			value = "*" + label + "*\n" + value
		}
		appendPart(value)
	}
	for _, value := range message.Context {
		appendPart(value)
	}
	return core.BoundedText(sanitize(strings.Join(parts, "\n\n")), 6000)
}

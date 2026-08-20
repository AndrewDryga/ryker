// Package operationalkey gives external operational lifecycle messages a
// stable source-agnostic identity for correlation and bounded coalescing.
package operationalkey

import (
	"crypto/sha256"
	"encoding/hex"
	"html"
	"regexp"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/lifecycle"
)

var operationalLabelPattern = regexp.MustCompile(
	`(?i)(?:^|[|[:space:]])(service|component|alert|alertname)[[:space:]]*:[[:space:]]*([a-z0-9][a-z0-9._:/-]{1,127})`,
)

var operationalPhasePattern = regexp.MustCompile(
	`(?i)\b(firing|resolved|recovered|recovery|critical|warning|warn|ok|error|errored|failed|failure|applied|applying|planned|planning|needs confirmation)\b`,
)

var operationalCounterPattern = regexp.MustCompile(
	`(?i)(?:\[[^\]]*(?:firing|resolved|critical|warning)[^\]]*\]|\b[0-9]+\s+alerts?\b|\b[0-9]+\s+of\s+[0-9]+\b)`,
)

var operationalLinkPattern = regexp.MustCompile(`<((?:https?://)[^>|]+)(?:\|[^>]*)?>`)

var grafanaStartedPattern = regexp.MustCompile(
	`(?im)(?:^|\n)[[:space:]]*\*{0,2}Started:\*{0,2}[^\n]*<!date\^([0-9]{9,})\^`,
)

func stableAlertLink(text string) string {
	for _, match := range operationalLinkPattern.FindAllStringSubmatch(text, -1) {
		if len(match) < 2 {
			continue
		}
		link := html.UnescapeString(strings.TrimSpace(match[1]))
		if !strings.Contains(strings.ToLower(link), "/alerting/") {
			continue
		}
		if index := strings.IndexAny(link, "?#"); index >= 0 {
			link = link[:index]
		}
		return link
	}
	return ""
}

// grafanaOccurrence returns the provider's stable start epoch when the card
// describes exactly one alert occurrence. FIRING and RESOLVED cards retain
// this value, while a later recurrence of a generic rule receives a new one.
// Multi-alert aggregate cards can contain several starts, so they deliberately
// retain the rule-level fallback instead of inventing an unstable identity.
func grafanaOccurrence(text string) string {
	starts := map[string]struct{}{}
	for _, match := range grafanaStartedPattern.FindAllStringSubmatch(text, -1) {
		if len(match) > 1 {
			starts[match[1]] = struct{}{}
		}
	}
	if len(starts) != 1 {
		return ""
	}
	for started := range starts {
		return started
	}
	return ""
}

func alertTitle(text string) string {
	for _, raw := range strings.Split(text, "\n") {
		line := strings.ToLower(strings.Join(strings.Fields(raw), " "))
		if line == "" {
			continue
		}
		line = operationalCounterPattern.ReplaceAllString(line, " ")
		line = operationalPhasePattern.ReplaceAllString(line, " ")
		line = strings.Trim(strings.Join(strings.Fields(line), " "), " -|:[]")
		if line == "" || strings.HasPrefix(line, "run notification for ") ||
			strings.HasPrefix(line, "added by ") {
			continue
		}
		return core.TruncateUTF8(line, 160)
	}
	return ""
}

func bounded(value string) string {
	if len(value) <= 220 {
		return value
	}
	sum := sha256.Sum256([]byte(value))
	return core.TruncateUTF8(value, 180) + ":sha256:" + hex.EncodeToString(sum[:8])
}

// Key prefers a stable alert URL over mutable dashboard ranges, then exact
// provider lifecycle identity, then phase-free alert labels and title.
func Key(input core.SlackInput) string {
	if decisionpkg.OperationalAlertEvent(input.Text) {
		if key := stableAlertLink(input.Text); key != "" {
			if occurrence := grafanaOccurrence(input.Text); occurrence != "" {
				key += ":started:" + occurrence
			}
			return bounded("alert-link:" + key)
		}
	}
	if key := lifecycle.CorrelationKey(input.Text); key != "" {
		return bounded("lifecycle:" + key)
	}
	if !decisionpkg.OperationalAlertEvent(input.Text) {
		return ""
	}
	labels := make([]string, 0, 4)
	for _, match := range operationalLabelPattern.FindAllStringSubmatch(input.Text, -1) {
		if len(match) < 3 {
			continue
		}
		labels = append(labels,
			strings.ToLower(match[1])+":"+strings.ToLower(strings.Trim(match[2], ".,;")),
		)
	}
	identity := strings.Join(labels, "|")
	if title := alertTitle(input.Text); title != "" {
		identity += "|title:" + title
	}
	if identity == "" {
		return ""
	}
	return bounded("alert:" + input.UserID + ":" + identity)
}

// BroadBurstCoalescingAllowed is false for exact provider lifecycle streams;
// discarding one can silently lose an Applied or Errored result.
func BroadBurstCoalescingAllowed(input core.SlackInput) bool {
	return lifecycle.CorrelationKey(input.Text) == ""
}

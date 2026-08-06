package service

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const operationalBurstWindow = 90 * time.Second

var operationalLabelPattern = regexp.MustCompile(
	`(?i)(?:^|[|[:space:]])(service|component|alert|alertname)[[:space:]]*:[[:space:]]*([a-z0-9][a-z0-9._:/-]{1,127})`,
)

var operationalPhasePattern = regexp.MustCompile(
	`(?i)\b(firing|resolved|recovered|recovery|critical|warning|warn|ok|error|errored|failed|failure|applied|applying|planned|planning|needs confirmation)\b`,
)

var operationalCounterPattern = regexp.MustCompile(
	`(?i)(?:\[[^\]]*(?:firing|resolved|critical|warning)[^\]]*\]|\b[0-9]+\s+alerts?\b|\b[0-9]+\s+of\s+[0-9]+\b)`,
)

func (s *Service) obviousHumanDialogue(input core.SlackInput, state watchTurnState) bool {
	if input.Kind != "message" || state.ConversationFollowup ||
		len(state.MatchedRules) > 0 || len(input.Attachments) > 0 {
		return false
	}
	mentionedAnotherHuman := false
	for _, match := range slackUserMentionPattern.FindAllStringSubmatch(input.Text, -1) {
		if len(match) < 2 {
			continue
		}
		if match[1] == s.identity.BotUserID {
			return false
		}
		mentionedAnotherHuman = true
	}
	return mentionedAnotherHuman
}

// operationalCorrelationKey is deliberately source-agnostic. Exact external
// lifecycle IDs win; alert apps fall back to stable alert/service/component
// labels and a phase-free title. FIRING and RESOLVED updates therefore share a
// stream without grouping unrelated alerts merely because they share a channel.
func operationalCorrelationKey(input core.SlackInput) string {
	if key := externalLifecycleCorrelationKey(input.Text); key != "" {
		return boundedCorrelationKey("lifecycle:" + key)
	}
	if !operationalAlertEvent(input.Text) {
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
	title := operationalAlertTitle(input.Text)
	identity := strings.Join(labels, "|")
	if title != "" {
		identity += "|title:" + title
	}
	if identity == "" {
		return ""
	}
	return boundedCorrelationKey("alert:" + input.UserID + ":" + identity)
}

func operationalAlertTitle(text string) string {
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
		if len(line) > 160 {
			line = line[:160]
		}
		return line
	}
	return ""
}

func boundedCorrelationKey(value string) string {
	if len(value) <= 220 {
		return value
	}
	sum := sha256.Sum256([]byte(value))
	return value[:180] + ":sha256:" + hex.EncodeToString(sum[:8])
}

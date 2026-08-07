package slackui

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

const (
	IncidentCardRevision = "2026-07-28.1"

	ActionUpdate             = "responder_update"
	ActionChanges            = "responder_changes"
	ActionChangesPrevious    = "responder_changes_previous"
	ActionChangesNext        = "responder_changes_next"
	ActionChangesRefresh     = "responder_changes_refresh"
	ActionReview             = "responder_review"
	ActionRepairReview       = "responder_repair_review"
	ActionPublishPR          = "responder_publish_pr"
	ActionViewPR             = "responder_view_pr"
	ActionCheckDelivery      = "responder_check_delivery"
	ActionDiscardWork        = "responder_discard_work"
	ActionStop               = "responder_stop"
	ActionExtend             = "responder_extend"
	ActionResolve            = "responder_resolve"
	ActionHelp               = "responder_help"
	ActionOpenIncident       = "responder_open_incident"
	ActionStartTask          = "responder_start_engineering_task"
	ActionReviewPullRequest  = "responder_review_pull_request"
	ActionApproveProposal    = "responder_approve_proposal"
	ActionRejectProposal     = "responder_reject_proposal"
	ActionOpenApproval       = "responder_open_emisar_approval"
	ActionRememberMemory     = "responder_remember_memory"
	ActionForgetMemory       = "responder_forget_memory"
	ActionForgetMemoryRollup = "responder_forget_memory_rollup"
	ActionDismissFeedback    = "responder_dismiss_feedback"
	ActionConvertFeedback    = "responder_convert_feedback"
	// ActionConvertFeedbackBrief turns tone feedback into a typed response_detail
	// preference rather than guidance. Guidance is advisory — the model weighs
	// it. A preference is enforced by the host. "Be more concise", said three
	// times, should stop being a suggestion.
	ActionConvertFeedbackBrief = "responder_convert_feedback_brief"
	// Reviewing a correction that Responder was told was wrong, and deciding
	// whether the lesson is worth keeping as a regression fixture.
	ActionKeepFixtureCandidate    = "responder_keep_fixture_candidate"
	ActionDiscardFixtureCandidate = "responder_discard_fixture_candidate"
	ActionReviewMemory            = "responder_review_memory"
	ActionKeepMemoryReview        = "responder_keep_memory_review"
	ActionForgetMemoryReview      = "responder_forget_memory_review"
	ActionMergeMemoryReview       = "responder_merge_memory_review"
	ActionDismissMemoryReview     = "responder_dismiss_memory_review"
	ActionRememberPreference      = "responder_remember_preference"
	ActionTogglePreference        = "responder_toggle_preference"
	ActionEditPreference          = "responder_edit_preference"
	ActionDeletePreference        = "responder_delete_preference"
	ActionRememberRule            = "responder_remember_rule"
	ActionToggleRule              = "responder_toggle_rule"
	ActionEditRule                = "responder_edit_rule"
	ActionDeleteRule              = "responder_delete_rule"
	ActionRememberSchedule        = "responder_remember_schedule"
	ActionToggleSchedule          = "responder_toggle_schedule"
	ActionRunSchedule             = "responder_run_schedule"
	ActionEditSchedule            = "responder_edit_schedule"
	ActionDeleteSchedule          = "responder_delete_schedule"
	ActionSaveChannelConfig       = "responder_save_channel_config"
	ActionRestartChannelSetup     = "responder_restart_channel_setup"
	ActionCancelChannelSetup      = "responder_cancel_channel_setup"
	ActionSetupQuickMentions      = "responder_setup_quick_mentions"
	ActionSetupQuickProactive     = "responder_setup_quick_proactive"
	ActionSetupCustomize          = "responder_setup_customize"
	ActionSetupMentions           = "responder_setup_participation_mentions"
	ActionSetupProactive          = "responder_setup_participation_proactive"
	ActionSetupShadow             = "responder_setup_participation_shadow"
	ActionSetupRepository         = "responder_setup_repository_"
	ActionSetupDefaultRepo        = "responder_setup_repository_default"
	ActionSetupAlertReply         = "responder_setup_alert_reply"
	ActionSetupAlertOffer         = "responder_setup_alert_offer"
	ActionSetupAlertAutomatic     = "responder_setup_alert_automatic"
	ActionSetupOperatorsOnly      = "responder_setup_audience_operators"
	ActionSetupIncludeMe          = "responder_setup_audience_include_me"

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
	slackMentionPattern       = regexp.MustCompile(`<(?:@[A-Z0-9]+|![^>]+)>`)
	scheduleCommitmentPattern = regexp.MustCompile(`(?i)^\s*i(?:['’]ll| will)\s+`)
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

// Slack's Block Kit limits. A payload over any of them is rejected at
// delivery — after the work is done, and in a way the agent cannot explain to
// whoever is waiting. Not every field that reaches a card is bounded upstream
// (a preference value and a standing-rule trigger are not), so the bound
// belongs here, at the one point every outgoing message passes through.
// Slack's Block Kit limits. A payload over any of them is rejected at
// delivery — after the work is done, and in a way the agent cannot explain to
// whoever is waiting. Not every field that reaches a card is bounded upstream
// (a preference value and a standing-rule trigger are not), so the bound
// belongs here, at the one point every outgoing message passes through.

// safeActionURL drops anything that is not an ordinary web link. Slack renders
// a button URL directly, so a non-HTTPS scheme would be an unreviewed escape
// from the host-owned control surface.
func truncateUTF8(value string, limit int) string {
	return core.TruncateUTF8(value, limit)
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

func (m Message) FileBlocks() []slack.Block {
	blocks := m.Blocks()
	result := make([]slack.Block, 0, len(blocks)+4)
	for _, block := range blocks {
		markdown, ok := block.(*slack.MarkdownBlock)
		if !ok {
			result = append(result, block)
			continue
		}
		for _, chunk := range splitSlackBlockText(markdown.Text, 2900) {
			result = append(result, slack.NewSectionBlock(
				slack.NewTextBlockObject(slack.MarkdownType, chunk, false, true),
				nil,
				nil,
			))
		}
	}
	return result
}

func splitSlackBlockText(value string, limit int) []string {
	value = strings.TrimSpace(value)
	if value == "" || limit < 1 {
		return nil
	}
	result := make([]string, 0, len(value)/limit+1)
	for len(value) > limit {
		end := limit
		for !utf8.ValidString(value[:end]) {
			end--
		}
		if split := strings.LastIndexByte(value[:end], '\n'); split >= limit/2 {
			end = split + 1
		}
		chunk := strings.TrimSpace(value[:end])
		if chunk != "" {
			result = append(result, chunk)
		}
		value = strings.TrimSpace(value[end:])
	}
	if value != "" {
		result = append(result, value)
	}
	return result
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

func timeLocation(name string) *time.Location {
	location, err := time.LoadLocation(name)
	if err != nil {
		return time.UTC
	}
	return location
}

func firstNonemptyUI(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func behaviorToggleValue(id string, enabled bool) string {
	data, _ := json.Marshal(struct {
		ID      string `json:"id"`
		Enabled bool   `json:"enabled"`
	}{ID: id, Enabled: enabled})
	return string(data)
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

func shortSHA(value string) string {
	if len(value) > 12 {
		return value[:12]
	}
	return value
}

func WithRepositoryGateRecommendation(message Message) Message {
	message.Context = append(message.Context,
		"Recommendation: add `gate:` to `.agent/project.yaml` so future draft-PR reviews run the repository's validation command.",
	)
	return message
}

func WithIncompleteValidationWarning(message Message) Message {
	message.Context = append(message.Context,
		"Validation warning: the repository gate did not complete cleanly. Review the PR diff and GitHub checks before merging.",
	)
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

func WithBlockedAssessment(
	message Message,
	summary string,
	materialGaps []string,
	attempts []string,
	nextAction string,
	sanitizer *Sanitizer,
) Message {
	clean := func(value string) string {
		value = strings.TrimSpace(value)
		if sanitizer != nil {
			value = sanitizer.Text(value)
		}
		return escapeSlackText(value)
	}
	// Completion gaps and attempted routes remain typed episode data for audit,
	// replay, and operator inspection. The model's completion message is the
	// human-facing explanation; projecting the whole ledger again makes Slack
	// replies repetitive and bureaucratic.
	_ = materialGaps
	_ = attempts
	parts := make([]string, 0, 2)
	if summary = clean(summary); summary != "" {
		parts = append(parts, "Blocked: "+summary)
	}
	if nextAction = clean(nextAction); nextAction != "" {
		parts = append(parts, "Next: "+nextAction)
	}
	if len(parts) > 0 {
		message.Context = append(message.Context, truncateUTF8(strings.Join(parts, " · "), 700))
	}
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

// AgentReportFailureMessage is what an operator sees when Responder exhausted
// its corrections and still could not read its own model's result.
//
// It takes no detail argument on purpose. An earlier version accepted one "for
// callers with something operator-facing to add", and the only thing callers
// ever had was the parse error — so the parameter was a hole that put
// `json: cannot unmarshal ...` in front of someone waiting on an incident.
// What they need is what survived, that nothing changed, and what to do next.
func AgentReportFailureMessage() Message {
	return Message{
		Text:   "I could not publish a clean summary of that turn.",
		Header: "Summary needs another pass",
		Sections: []string{
			"The investigation ran and its findings are preserved, but the final " +
				"summary did not come back in a form I could publish.",
			"Reply in this thread and I will write it up again from the same work — " +
				"nothing was lost and nothing was changed.",
		},
		Context: []string{
			"No merge, push, signing, or deployment occurred. " +
				"Raw transcripts and tool output are not posted to Slack.",
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

func Notice(text string) Message {
	return Message{Text: text, Sections: []string{text}}
}

func truncateMarkdown(value string, limit int) string {
	return core.TruncateUTF8WithSuffix(value, limit, "\n\n_Response truncated._")
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

// CommitmentOverdueMessage tells a thread that accepted work has stopped
// reporting progress.
//
// The tone matters here: this is Responder admitting it has not delivered
// something it took on, so it states the fact and what the operator can do,
// without apologising at length or implying the work is lost.
// CommitmentOverdueMessage tells a thread that accepted work has stopped
// reporting progress.
//
// The tone matters here: this is Responder admitting it has not delivered
// something it took on, so it states the fact and what the operator can do,
// without apologising at length or implying the work is lost.
// CommitmentOverdueMessage tells a thread that accepted work has stopped
// reporting progress.
//
// The tone matters here: this is Responder admitting it has not delivered
// something it took on, so it states the fact and what the operator can do,
// without apologising at length or implying the work is lost.
// CommitmentOverdueMessage tells a thread that accepted work has stopped
// reporting progress.
//
// The tone matters here: this is Responder admitting it has not delivered
// something it took on, so it states the fact and what the operator can do,
// without apologising at length or implying the work is lost.
func CommitmentOverdueMessage(episode core.WorkEpisode, overdueBy time.Duration) Message {
	objective := displayOr(episode.Objective, "this request")
	return Message{
		Text: "Still working on " + objective + ", but I have not made progress recently.",
		Sections: []string{
			fmt.Sprintf(
				"*No progress for %s.* I am still holding this request, but it has not advanced "+
					"since my last update.",
				roundedDuration(overdueBy),
			),
			"*Current state:* " + displayOr(episode.Status, "working") +
				"\n*Next action:* " + displayOr(episode.NextAction, "none recorded"),
		},
		Context: []string{
			"Ask me to retry, narrow the request, or close it. Nothing has been lost.",
		},
	}
}

// roundedDuration renders a duration the way a person would say it.
// roundedDuration renders a duration the way a person would say it.
// roundedDuration renders a duration the way a person would say it.
// roundedDuration renders a duration the way a person would say it.
func roundedDuration(value time.Duration) string {
	switch {
	case value >= 2*time.Hour:
		return fmt.Sprintf("%d hours", int(value.Hours()))
	case value >= time.Hour:
		return "an hour"
	case value >= 2*time.Minute:
		return fmt.Sprintf("%d minutes", int(value.Minutes()))
	default:
		return "a minute"
	}
}

// FeedbackSummary is one open feedback item as the App Home shows it.

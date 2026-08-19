package slackui

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// Report is a long-form document plus the three things a card has to say about
// it once the document itself lives somewhere else.
//
// The four reports were already Markdown documents that happened to be posted
// as messages: a forty-event timeline, a postmortem draft carrying its own
// follow-up checklist. Pasted into a channel they push every other message off
// the screen, and a day later nobody can find them. A canvas is where a
// document of that length belongs. What stays in the room is a card — the one
// judgement the reader needs, the counts standing behind it, and a way in.
//
// Message is the same report rendered the way it is rendered today, and it is
// not a second-class fallback. A workspace whose token cannot make canvases
// keeps exactly what it has now; the canvas is an escalation on top, never a
// replacement underneath.
type Report struct {
	// Title names the document. It is the report's own header line rather than
	// a second name invented here, so the canvas and the card cannot come to
	// disagree about what the reader is opening.
	Title string
	// Markdown is the document. It is whatever the report already builds.
	Markdown string
	// Headline is the one sentence the reader needs if they read nothing else,
	// and for the drafts it is the sentence stating what the draft refuses to
	// claim.
	Headline string
	// Counts is the arithmetic behind the headline, as a context line.
	Counts string
	// Preview is a bounded set of real record entries kept on the Slack card
	// when an oversized document moves to Canvas.
	Preview string
	// Message is the report posted the way it is posted today.
	Message Message
}

func TimelineReport(record core.RemediationRecord) Report {
	message := TimelineMessage(record)
	events := core.RemediationTimeline(record)
	headline := "No " + workNoun(record.Incident) + " activity has been recorded yet."
	if len(events) > 0 {
		headline = fmt.Sprintf(
			"%s, from %s to %s.",
			countLabel(len(events), "recorded event"),
			events[0].CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			events[len(events)-1].CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		)
	}
	return Report{
		Title:    reportTitle(message.Markdown, "Remediation timeline"),
		Markdown: message.Markdown,
		Headline: headline,
		Counts:   reportCounts(record),
		Preview:  timelineReportPreview(core.RemediationTimeline(record)),
		Message:  message,
	}
}

func HandoffReport(record core.RemediationRecord) Report {
	incident := record.Incident
	message := HandoffMessage(record)
	// The clause after the dash is the alert's, and an engineering task has no
	// alert: it read "0 of 0 signals firing, severity unclassified", which is a
	// recovered outage rather than a change nobody paged for.
	headline := fmt.Sprintf(
		"%s, Responder %s — %d of %d signals firing, severity %s.",
		incidentStatusLabel(incident.Status),
		workActivityLabel(incident),
		incident.FiringCount, incident.SignalCount,
		displayOr(incident.Severity, "unclassified"),
	)
	if incident.IsEngineeringTask() {
		headline = fmt.Sprintf(
			"%s, Responder %s.",
			incidentStatusLabel(incident.Status),
			workActivityLabel(incident),
		)
	}
	return Report{
		Title: reportTitle(
			message.Markdown, "Shift handoff: "+escapeSlackText(incident.Title),
		),
		Markdown: message.Markdown,
		Headline: headline,
		Counts:   reportCounts(record),
		Preview:  timelineReportPreview(core.RemediationTimeline(record)),
		Message:  message,
	}
}

// PostmortemReport leads with the sentence the draft exists to protect.
//
// The draft never assigns a root cause — its own follow-up list carries
// "Confirm root cause from cited evidence" as an unticked box — and a card that
// summarised it as "postmortem ready" would quietly promote a document of open
// questions into a finding. So the headline says what is not assigned and names
// what was never checked, which is the reading a person would otherwise have to
// reach the bottom of the canvas to reach.
func PostmortemReport(record core.RemediationRecord) Report {
	message := PostmortemDraft(record)
	headline := "Root cause is not assigned — no structured evidence was recorded."
	if len(record.Evidence) > 0 {
		headline = fmt.Sprintf(
			"Root cause is not assigned — %s recorded, and confirming a cause from them is a human judgement.",
			countLabel(len(record.Evidence), "observation"),
		)
	}
	if unchecked := uncheckedLayers(record.Coverage); unchecked != "" {
		headline = strings.TrimSuffix(headline, ".") + "; " + unchecked + " never checked."
	}
	draft := "Post-incident draft: "
	if record.Incident.IsEngineeringTask() {
		draft = "Engineering task review draft: "
	}
	return Report{
		Title: reportTitle(
			message.Markdown,
			draft+escapeSlackText(record.Incident.Title),
		),
		Markdown: message.Markdown,
		Headline: headline,
		Counts:   reportCounts(record),
		Preview:  reportRecordPreview(record),
		Message:  message,
	}
}

func EvidenceReport(
	incident core.Incident,
	evidence []core.Evidence,
	coverage []core.Coverage,
) Report {
	message := EvidenceDirectoryMessage(incident, evidence, coverage)
	headline := "No evidence has been recorded for this " + workNoun(incident) + " yet."
	if len(evidence) > 0 {
		headline = fmt.Sprintf(
			"%s across %s.",
			countLabel(len(evidence), "durable observation"),
			countLabel(len(coverage), "coverage layer"),
		)
	}
	return Report{
		Title: reportTitle(
			message.Markdown,
			"Evidence for "+workNoun(incident)+" "+ShortID(incident.ID),
		),
		Markdown: message.Markdown,
		Headline: headline,
		Counts: countsLine(
			countLabel(len(evidence), "observation"),
			countLabel(len(coverage), "coverage layer"),
			unknownCoverageCount(coverage),
		),
		Preview: evidenceReportPreview(evidence),
		Message: message,
	}
}

// ReportCanvasCard is what the room sees once the document is a canvas.
//
// Grey, and with no primary: a report is a document, and a document holds
// custody of nothing. Nobody is being asked for anything here — the card exists
// so a reader can decide, from one sentence, whether the rest is worth opening.
//
// There is one control and it is the way in. A "post it here instead" button
// would need a handler that could rebuild the report from scratch at click
// time, and a button that cannot do what its label says is worse than no
// button; the seam for it is the Report value itself, which already carries the
// message form beside the document.
func ReportCanvasCard(report Report, canvasURL string) Message {
	message := Message{
		Text:      report.Title + " — " + report.Headline,
		Header:    report.Title,
		Stripe:    StripeIdle,
		Sections:  []string{report.Headline},
		Temporary: true,
	}
	if report.Counts != "" {
		message.Context = append(message.Context, report.Counts)
	}
	message.Markdown = truncateMarkdown(strings.TrimSpace(report.Preview), 2400)
	if canvasURL != "" {
		message.Actions = []Action{{
			ID: ActionOpenCanvas, Label: "Open the canvas", URL: canvasURL,
		}}
	}
	return message
}

func timelineReportPreview(events []core.TimelineEvent) string {
	if len(events) == 0 {
		return ""
	}
	var preview strings.Builder
	preview.WriteString("*Latest events*")
	for _, event := range events[max(0, len(events)-5):] {
		fmt.Fprintf(&preview, "\n- *%s* — %s",
			event.CreatedAt.UTC().Format("15:04 UTC"), escapeSlackText(event.Title))
		if detail := strings.TrimSpace(event.Detail); detail != "" {
			fmt.Fprintf(&preview, "\n  %s", truncateUTF8(escapeSlackText(detail), 240))
		}
	}
	return preview.String()
}

func evidenceReportPreview(evidence []core.Evidence) string {
	if len(evidence) == 0 {
		return ""
	}
	var preview strings.Builder
	preview.WriteString("*Latest evidence*")
	for _, item := range evidence[max(0, len(evidence)-4):] {
		fmt.Fprintf(&preview, "\n- *%s* — %s",
			escapeSlackText(item.Claim),
			truncateUTF8(escapeSlackText(item.Observation), 320),
		)
	}
	return preview.String()
}

func reportRecordPreview(record core.RemediationRecord) string {
	parts := []string{
		evidenceReportPreview(record.Evidence),
		timelineReportPreview(core.RemediationTimeline(record)),
	}
	kept := parts[:0]
	for _, part := range parts {
		if strings.TrimSpace(part) != "" {
			kept = append(kept, part)
		}
	}
	return strings.Join(kept, "\n\n")
}

// reportTitle takes the document's name from the document.
//
// Every one of the four reports opens with a Markdown heading that already
// names it, and re-deriving that name here would be a second copy free to drift
// from the first. The literal is only reached when a report stops opening with
// a heading, which is a rendering change rather than a reason to leave the
// canvas untitled.
func reportTitle(markdown, fallback string) string {
	for line := range strings.SplitSeq(markdown, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "#") {
			continue
		}
		if title := strings.TrimSpace(strings.TrimLeft(line, "#")); title != "" {
			return strings.ReplaceAll(title, "`", "")
		}
	}
	return fallback
}

func reportCounts(record core.RemediationRecord) string {
	return countsLine(
		countLabel(len(core.RemediationTimeline(record)), "event"),
		countLabel(len(record.Evidence), "observation"),
		countLabel(len(record.Coverage), "coverage layer"),
		unknownCoverageCount(record.Coverage),
	)
}

func countsLine(parts ...string) string {
	kept := make([]string, 0, len(parts))
	for _, part := range parts {
		if strings.TrimSpace(part) != "" {
			kept = append(kept, part)
		}
	}
	return strings.Join(kept, " · ")
}

func unknownCoverageCount(coverage []core.Coverage) string {
	unknown := 0
	for _, item := range coverage {
		if item.Status == "unknown" || item.Status == "degraded" {
			unknown++
		}
	}
	if unknown == 0 {
		return ""
	}
	return fmt.Sprintf("%d unresolved", unknown)
}

// uncheckedLayers names what nobody looked at, because that is the part of an
// unassigned root cause a reader can act on.
func uncheckedLayers(coverage []core.Coverage) string {
	var layers []string
	for _, item := range coverage {
		if item.Status != "unknown" {
			continue
		}
		if layer := strings.TrimSpace(item.Layer); layer != "" {
			layers = append(layers, escapeSlackText(layer))
		}
		if len(layers) == 3 {
			break
		}
	}
	switch len(layers) {
	case 0:
		return ""
	case 1:
		return layers[0] + " was"
	default:
		return strings.Join(layers[:len(layers)-1], ", ") +
			" and " + layers[len(layers)-1] + " were"
	}
}

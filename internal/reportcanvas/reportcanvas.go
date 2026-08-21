// Package reportcanvas decides where a long-form report goes.
//
// The four incident reports — timeline, handoff, postmortem draft, evidence
// directory — were already Markdown documents that happened to be posted as
// messages. A forty-event timeline pasted into a channel pushes every other
// message off the screen and is unfindable a day later. A canvas is where a
// document of that length belongs.
//
// What this package owns is the escalation policy, which is one decision made
// carefully:
//
// Feature detection is the attempt itself. There is no setting asking whether
// this workspace has canvases, because a setting would be a second answer to a
// question the installed token already answers, and the two would disagree the
// moment somebody reinstalls the app with a different grant — leaving an
// operator debugging a missing canvas against a flag insisting it should be
// there. So the report is offered to Slack and Slack's answer decides.
// missing_scope, canvases disabled for the plan, a socket that never opened:
// all the same answer here, which is "post the message".
//
// One attempt, never a retry. A canvas that could not be made a moment ago will
// not be made by asking twice, and the person waiting on the report should not
// pay a second round trip to arrive at the message they were always going to
// get.
package reportcanvas

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// Canvases publishes a document. Narrow on purpose: this package decides where
// a report goes and must not be able to reach the rest of Slack while deciding.
type Canvases interface {
	CreateCanvas(ctx context.Context, channelID, title, markdown string) (string, error)
}

type Records interface {
	LoadRemediationRecord(context.Context, string) (core.RemediationRecord, error)
}

func NavigationAction(actionID string) bool {
	switch slackui.BaseActionID(actionID) {
	case slackui.ActionRecordTimeline, slackui.ActionRecordEvidence,
		slackui.ActionRecordHandoff, slackui.ActionRecordPostmortem,
		slackui.ActionRecordBack:
		return true
	default:
		return false
	}
}

func Navigate(
	ctx context.Context,
	records Records,
	canvases Canvases,
	log *slog.Logger,
	input core.SlackInput,
) (slackui.Message, error) {
	record, err := records.LoadRemediationRecord(ctx, strings.TrimSpace(input.ActionValue))
	if err != nil {
		return slackui.Message{}, err
	}
	if slackui.BaseActionID(input.ActionID) == slackui.ActionRecordBack {
		return slackui.RecordDirectoryMessage(record), nil
	}
	command := map[string]string{
		slackui.ActionRecordTimeline:   "timeline",
		slackui.ActionRecordEvidence:   "evidence",
		slackui.ActionRecordHandoff:    "handoff",
		slackui.ActionRecordPostmortem: "postmortem",
	}[slackui.BaseActionID(input.ActionID)]
	if command == "" {
		return slackui.Message{}, fmt.Errorf("unknown private record control %q", input.ActionID)
	}
	report, ok := For(command, record)
	if !ok {
		return slackui.Message{}, errors.New("unknown incident record")
	}
	return Publish(ctx, canvases, log, input.ChannelID, report), nil
}

// For names the report a command asks for.
//
// The mapping lives here rather than beside the command parser because the four
// reports are one family — they read the same durable record, they escalate the
// same way, and a fifth would be added here — and because a caller that only
// knows a verb should not also have to know which constructor and which
// arguments that verb implies.
func For(command string, record core.RemediationRecord) (slackui.Report, bool) {
	switch command {
	case "timeline":
		return slackui.TimelineReport(record), true
	case "postmortem":
		return slackui.PostmortemReport(record), true
	case "handoff":
		return slackui.HandoffReport(record), true
	case "evidence":
		return slackui.EvidenceReport(record.Incident, record.Evidence, record.Coverage), true
	}
	return slackui.Report{}, false
}

// Publish escalates a report to a canvas, or keeps the message form the report
// has always had.
//
// The failure is logged at Warn with Slack's own words, because "the reports
// stopped being canvases" is otherwise invisible: every one of them still
// arrives, in the older form, and nothing on the surface says why.
func Publish(
	ctx context.Context,
	canvases Canvases,
	log *slog.Logger,
	channelID string,
	report slackui.Report,
) slackui.Message {
	// Most records are short enough to be useful in the private Slack answer.
	// Canvas is an overflow surface, not the default destination for four lines.
	if utf8.RuneCountInString(report.Markdown) <= 6000 {
		return report.Message
	}
	// A canvas nobody can open is worse than a long message, and read access is
	// granted to the room the report was asked for. With no room — the App Home
	// answers reports too — there is nothing to grant it to, so the message
	// form is not a fallback here but the only correct answer.
	if canvases == nil || strings.TrimSpace(channelID) == "" {
		return report.Message
	}
	canvasURL, err := canvases.CreateCanvas(ctx, channelID, report.Title, report.Markdown)
	if err != nil {
		if log != nil {
			log.Warn(
				"could not publish a report as a canvas; posted it as a message instead",
				"error", err.Error(), "channel", channelID, "report", report.Title,
			)
		}
		return report.Message
	}
	return slackui.ReportCanvasCard(report, canvasURL)
}

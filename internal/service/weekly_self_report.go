package service

import (
	"context"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/selfreport"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// postWeeklySelfReport posts one digest a week saying how Responder's own week
// went, when the operator has asked for one.
//
// The instruments it reads all existed and nobody read them on a schedule: the
// correction rate behind a CLI, feedback and graded reactions in a table, the
// quality watcher's findings in another, learned knowledge and open loops in
// structured memory. A teammate who never says how their week went is a
// teammate you stop trusting, and an operator skimming the digest is also free
// human review of the numbers the self-improving loop turns on.
//
// It rides the maintenance sweep rather than a work item of its own. The sweep
// already runs every few minutes and already carries the periodic host jobs
// that need no queue semantics; a work kind would buy a retry ladder for
// something that is correct to simply try again on the next sweep.
//
// No model composes it. Every number is counted by SQL in
// internal/store/selfreportstore and rendered by internal/selfreport, so the
// digest cannot state a good week that the tables do not support.
func (s *Service) postWeeklySelfReport(ctx context.Context, now time.Time) error {
	settings := s.cfg.Report.WeeklySelfReport
	if !settings.Enabled || strings.TrimSpace(settings.Channel) == "" {
		return nil
	}
	hour, minute := settings.Clock()
	occurrence := selfreport.PreviousOccurrence(
		now, settings.Location(), settings.Day(), hour, minute,
	)
	if occurrence.IsZero() {
		return nil
	}
	sent, err := s.store.SelfReport.LastSent(ctx)
	if err != nil {
		return err
	}
	switch {
	case sent.IsZero():
		// Switching the digest on must not itself post one. An operator who
		// enables this on a Friday means "from Monday", not "right now", and a
		// feature whose deploy is indistinguishable from its first scheduled
		// message teaches a channel to mute the bot on day one.
		return s.store.SelfReport.MarkSent(ctx, occurrence)
	case !sent.Before(occurrence):
		return nil
	}
	week, err := s.store.SelfReport.Gather(ctx, occurrence.AddDate(0, 0, -7), occurrence)
	if err != nil {
		return err
	}
	body := selfreport.Render(week)
	lead, _, _ := strings.Cut(body, "\n")
	// postConfigurationMessage rather than a bare Post: it recovers the
	// timestamp when the post succeeded and the response was lost, which is the
	// difference between one digest and two.
	if _, err := s.postConfigurationMessage(
		ctx,
		"weekly_self_report_"+occurrence.UTC().Format("2006-01-02"),
		settings.Channel,
		"",
		slackui.Message{
			// The notification line is the lead sentence without its emphasis
			// markers, so the sidebar shows the number that moved rather than
			// the name of a report.
			Text:     strings.ReplaceAll(lead, "**", ""),
			Markdown: body,
		},
	); err != nil {
		return err
	}
	// Recorded only after the post landed. Marking it first would turn one
	// transient Slack failure into a week that silently never reported, which
	// nothing retries and nothing notices.
	return s.store.SelfReport.MarkSent(ctx, occurrence)
}

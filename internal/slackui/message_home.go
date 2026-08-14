package slackui

import (
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func OperationsHome(
	openIncidents int,
	totalIncidents int,
	openSessions int,
	failedWork int,
	publishedPRs int,
	cleanupPending int,
	cleanupBlocked int,
	memoryActive int,
	preferenceActive int,
	ruleActive int,
	scheduleActive int,
	commitmentActive int,
	incidents []core.Incident,
	commitments []core.Commitment,
	situations []core.ChannelMemory,
	memories []core.MemoryEntry,
	preferences []core.ResponderPreference,
	rules []core.StandingRule,
) Message {
	// This page answers one question: what needs me?
	//
	// It used to answer four at once — what needs you, a cleanup chore, how the
	// workspace is configured, and which of Responder's own mistakes to pin as
	// tests — with nothing marking where one ended and the next began. Four
	// jobs in one scroll reads as a mess of text and buttons no matter how well
	// each line is written, so the page now leads with the answer and every
	// secondary job is demoted to a counted line pointing at the command that
	// opens it.
	//
	// RENDERING CONSTRAINT — this surface is published with views.publish, and
	// Slack validates the whole view: one illegal block blanks the entire tab
	// with no error anyone sees. That failure sat unnoticed for two days once
	// (the fields-chunking comment in message.go records it). So the "In flight"
	// strip below is deliberately ordinary mrkdwn section text, NOT a
	// rich_text_preformatted block and NOT Message.Ledger or Message.Activity.
	// Do not "upgrade" it: the monospace strip those produce is a message-card
	// affordance, and the App Home is the one surface where getting a block
	// wrong costs the reader everything rather than one card. Message-channel
	// cards are unaffected by this rule.

	// Only work a person can move. A failed run belongs to the retry machinery
	// and to the failure count, not to a list titled with what is owed to the
	// team — that framing put a Coop idempotency conflict in front of an
	// operator as a task.
	// The same alert firing twice produces two commitments with the same
	// headline and nothing to tell them apart on the page, which reads as a
	// rendering fault. Collapse them and say how many.
	owedItems := make([]core.Commitment, 0, len(commitments))
	repeats := make(map[string]int, len(commitments))
	seenHeadline := make(map[string]bool, len(commitments))
	for _, commitment := range commitments {
		if !operatorActionable(commitment.State) {
			continue
		}
		key := commitmentHeadline(commitment.Title)
		repeats[key]++
		if seenHeadline[key] {
			continue
		}
		seenHeadline[key] = true
		owedItems = append(owedItems, commitment)
	}

	// The count in the header is the count of rows below it. It used to be
	// commitmentActive, which counts every active commitment including the ones
	// this page deliberately does not list and the duplicates it collapses — so
	// the headline promised seven things and showed four, and a page whose first
	// line does not survive contact with its own body teaches the reader to
	// distrust the rest of it.
	needs := len(owedItems)
	state := "Nothing needs you"
	if needs > 0 {
		thing := "things"
		verb := "need"
		if needs == 1 {
			thing, verb = "thing", "needs"
		}
		state = fmt.Sprintf("✋ %d %s %s you", needs, thing, verb)
	}

	message := Message{
		// State word first: notifications and the sidebar strip the glyph, so
		// the fallback has to carry the answer in words.
		Text:   strings.TrimPrefix(state, "✋ ") + " — Emisar operations",
		Header: state,
	}

	// The ask, before anything else on the page. These are rows anchored at
	// After 0, which Blocks renders ahead of every section — that is what keeps
	// them above the coverage-gap warning AppendCoverageGaps prepends later.
	for _, commitment := range owedItems[:min(len(owedItems), 5)] {
		headline := commitmentHeadline(commitment.Title)
		line := "*" + headline + "*"
		if count := repeats[headline]; count > 1 {
			line += fmt.Sprintf(" ×%d", count)
		}
		if commitment.ChannelID != "" {
			line += " · <#" + commitment.ChannelID + ">"
		}
		// What to do, not why Responder stopped. The status paragraph is
		// Responder reasoning about itself; five of them made a wall to mine
		// for the one line that was an instruction. It stays in the thread,
		// and is used here only when there is no next action to show.
		switch {
		case !genericProgressText(commitment.NextAction):
			line += "\n" + escapeSlackText(shortInstruction(commitment.NextAction))
		case !genericProgressText(commitment.Status):
			line += "\n" + escapeSlackText(shortInstruction(commitment.Status))
		}
		message = AppendRow(message, line, openThreadAction(commitment))
	}
	// The overflow note is a footer line rather than a section, because a
	// section here would land between the rows and the coverage-gap warning
	// that has to sit directly beneath them.
	if extra := len(owedItems) - 5; extra > 0 {
		message.Context = append(message.Context,
			fmt.Sprintf("%d more need you — `/responder work`", extra))
	}

	// In flight: what Responder is carrying, so the reader can tell an idle
	// system from a busy one without opening anything. One line per task —
	// glyph, title, room, age — and the whole strip is one section block, which
	// is the difference between eight blocks and one on a page with a ceiling.
	if len(incidents) > 0 {
		shown := incidents[:min(len(incidents), 8)]
		var current strings.Builder
		fmt.Fprintf(&current, "*In flight* — %d open", max(openIncidents, len(shown)))
		if openIncidents > len(shown) {
			fmt.Fprintf(&current, ", showing %d", len(shown))
		}
		now := time.Now()
		for _, incident := range shown {
			room := "#" + displayOr(incident.ChannelName, "room pending")
			if incident.ChannelID != "" && incident.ChannelWritable() {
				room = "<#" + incident.ChannelID + ">"
			}
			// Never colour alone, and never glyph alone either: the state word
			// comes from incidentDirectoryStatus so the line still reads when
			// the glyph does not render.
			// commitmentHeadline escapes what it returns, so this must not escape
			// it again: a title carrying an ampersand would reach the reader as
			// "&amp;" rather than as "&".
			fmt.Fprintf(
				&current,
				"\n%s *%s* · %s · %s",
				incidentCardState(incident).Glyph,
				commitmentHeadline(incident.Title),
				room,
				incidentDirectoryStatus(incident),
			)
			if !incident.CreatedAt.IsZero() {
				fmt.Fprintf(&current, " · %s", compactDuration(now.Sub(incident.CreatedAt)))
			}
		}
		message.Sections = append(message.Sections, current.String())
	}

	// A channel with no summary and no goal has nothing to report, and
	// "Context retained; no current summary" is a placeholder wearing the
	// costume of content — three of them filled a section that said nothing.
	described := make([]core.ChannelMemory, 0, len(situations))
	for _, situation := range situations {
		if strings.TrimSpace(situation.State.SituationSummary) != "" ||
			strings.TrimSpace(situation.State.Goal) != "" {
			described = append(described, situation)
		}
	}
	if len(described) > 0 {
		var current strings.Builder
		current.WriteString("*Channel situations*")
		for _, situation := range described[:min(len(described), 3)] {
			summary := strings.TrimSpace(situation.State.SituationSummary)
			if summary == "" {
				summary = strings.TrimSpace(situation.State.Goal)
			}
			fmt.Fprintf(
				&current,
				"\n<#%s> · %s",
				situation.ChannelID,
				escapeSlackText(summary),
			)
			if count := len(situation.State.OpenLoops); count > 0 {
				suffix := "s"
				if count == 1 {
					suffix = ""
				}
				fmt.Fprintf(&current, " · %d open loop%s", count, suffix)
			}
		}
		message.Sections = append(message.Sections, current.String())
	}
	if len(preferences) > 0 {
		message.Sections = append(message.Sections, "*Settings* — how Responder behaves here")
		for _, preference := range preferences[:min(len(preferences), 3)] {
			state := "disabled"
			if preference.Enabled {
				state = "enabled"
			}
			// One row per preference, so its controls sit under it. Two channel
			// preferences read as identical duplicates when the scope says only
			// "channel scope", so the row names the channel it applies to.
			scope := preference.ScopeKind + " scope"
			if preference.ScopeKind == "channel" && preference.ScopeKey != "" {
				scope = "<#" + preference.ScopeKey + ">"
			}
			message = AppendRow(message, fmt.Sprintf(
				"*`%s` = `%s`* — %s\n%s; expires %s",
				preference.Name,
				preference.Value,
				state,
				scope,
				expiryStamp(preference.ExpiresAt, "2006-01-02"),
			), preferenceRowActions(preference))
		}
	}
	if len(rules) > 0 {
		message.Sections = append(message.Sections, "*Standing rules* — what Responder does automatically")
		for _, rule := range rules[:min(len(rules), 3)] {
			state := "disabled"
			if rule.Enabled {
				state = "enabled"
			}
			message = AppendRow(message, fmt.Sprintf(
				"*`%s` -> `%s`* — %s\n<#%s>; %d runs; expires %s",
				rule.Trigger,
				rule.Action,
				state,
				rule.ChannelID,
				rule.TriggerCount,
				expiryStamp(rule.ExpiresAt, "2006-01-02"),
			), ruleRowActions(rule))
		}
	}

	// The shelf: where everything this page is not about actually lives.
	//
	// It replaces the inline lists that used to be rendered in full here. Twenty
	// saved memories emitted twenty sections and twenty danger buttons, which by
	// itself is a quarter of Slack's 100-block view ceiling for content nobody
	// opened this page to read — and a page that renders nothing because it
	// exceeded the ceiling answers no questions at all.
	//
	// Each entry names its command rather than carrying a button. That is not a
	// stylistic choice: a Block Kit action on the App Home arrives with no
	// channel (Slack sends a view container, not a conversation), so the slash
	// path has nowhere to post an answer and repaints this same page instead —
	// see finishSlashMessage in internal/service/slash.go and the test
	// TestChannellessInteractionRepaintsTheAppHomeInsteadOfFailing. A "Manage"
	// button here would look like navigation and silently do nothing. The
	// buttons that DO remain on this page — toggle, edit, delete, keep, dismiss
	// — all change state and then repaint, which is the one thing this surface
	// can honestly offer. Give the shelf real buttons when it can open a modal.
	shelf := make([]string, 0, 3)
	// memoryActive is the true total; memories is the page-sized sample the
	// caller already had in hand. They come from two separate queries, so
	// prefer the count and fall back rather than report zero beside a list.
	if saved := max(memoryActive, len(memories)); saved > 0 {
		shelf = append(shelf, fmt.Sprintf(
			"*Memory* · %d saved · `/responder memory`", saved,
		))
	}
	if preferenceActive > 0 || ruleActive > 0 {
		shelf = append(shelf, fmt.Sprintf(
			"*Settings & rules* · %d %s · %d standing %s · `/responder preferences`",
			preferenceActive, pluralize(preferenceActive, "setting", "settings"),
			ruleActive, pluralize(ruleActive, "rule", "rules"),
		))
	}
	if scheduleActive > 0 {
		shelf = append(shelf, fmt.Sprintf(
			"*Schedules* · %d scheduled %s · `/responder schedules`",
			scheduleActive, pluralize(scheduleActive, "task", "tasks"),
		))
	}
	if len(shelf) > 0 {
		message.Sections = append(message.Sections,
			"*Everything else*\n"+strings.Join(shelf, "\n"))
	}

	// The footer. Everything the page is not about, on one line, each with a
	// command that exists — `/responder failures` and `/responder sessions` were
	// printed here for months and neither has ever been a subcommand, so both
	// answered "Unknown `/responder` subcommand" to anyone who followed the
	// advice this page gave them.
	elsewhere := make([]string, 0, 4)
	if failedWork > 0 {
		elsewhere = append(elsewhere, fmt.Sprintf("%d failed", failedWork))
	}
	if cleanupBlocked > 0 {
		elsewhere = append(elsewhere, fmt.Sprintf("%d retained workspaces", cleanupBlocked))
	}
	if publishedPRs > 0 {
		elsewhere = append(elsewhere, fmt.Sprintf("%d draft PRs", publishedPRs))
	}
	elsewhere = append(elsewhere, "`/responder status` for everything in flight")
	message.Context = append(message.Context, strings.Join(elsewhere, " · "))

	if memoryActive > 0 || len(memories) > 0 {
		message.Context = append(
			message.Context,
			"Saved memory is an operator-confirmed hint, never current health evidence. Fresh live observations and repository state take precedence.",
		)
	}
	return message
}

func pluralize(count int, singular, plural string) string {
	if count == 1 {
		return singular
	}
	return plural
}

// OperationsHomeRestricted is the page for a reader who cannot see this one.
//
// It is a refusal, and a refusal is short: what is withheld, what is still
// available, and who can change it. Two sections and a paragraph each was the
// same answer given twice at the length of a page that had something to show —
// and nothing here is waiting on the reader, so the header states what this is
// rather than raising a hand.
func OperationsHomeRestricted() Message {
	return Message{
		Text:   "Operations access is limited to configured operators — Emisar.",
		Header: "Operations access is restricted",
		Sections: []string{
			"Incident titles, active work, failures, and session state are visible only to " +
				"configured Responder operators.\n" +
				"You can still ask Responder read-only operational questions in a channel or " +
				"direct message where the app is available.",
		},
		Context: []string{
			"An administrator can grant access by adding your Slack user ID to `slack.operators` and restarting Responder.",
		},
	}
}

// commitmentHeadline turns a work title into something readable in a list.
//
// A title is often the Slack message that started the work, so it arrives as
// raw markup: an alert row renders as the whole
// "<https://grafana…/view?orgId=1|[VA1 FIRING:1] WARNING | …> *FIRING - 1 ale…"
// and fills three lines with a URL nobody can act on. Keep the link text,
// which is the alert name, and drop the address.
func commitmentHeadline(title string) string {
	cleaned := slackLinkTextPattern.ReplaceAllString(strings.TrimSpace(title), "$1")
	cleaned = strings.TrimSpace(bareURLPattern.ReplaceAllString(cleaned, ""))
	cleaned = singleLine(cleaned)
	// The source message's own emphasis leaks in as stray * and _ once the
	// surrounding text is cut, and a template that did not resolve arrives as
	// "[no value]". Both read as corruption in a list.
	cleaned = strings.NewReplacer("*", "", "_", "", "`", "").Replace(cleaned)
	cleaned = strings.ReplaceAll(cleaned, "[no value]", "")
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	if cleaned == "" {
		cleaned = "Untitled work"
	}
	// Cut on a word so a headline does not end mid-token like "…for 24h FI".
	if trimmed := truncateUTF8(cleaned, 110); trimmed != cleaned {
		if cut := strings.LastIndex(trimmed, " "); cut > 40 {
			trimmed = trimmed[:cut]
		}
		cleaned = strings.TrimRight(trimmed, " ,;:-") + "…"
	}
	return escapeSlackText(cleaned)
}

// genericProgressText reports whether a status or next action says nothing the
// reader can act on. "Needs operator attention" beside a Blocked label is the
// label again, and "Review the blocker or retry" is a restatement of the word
// blocked — six of those in a row was most of the App Home's owed-work list.
func genericProgressText(value string) bool {
	normalized := strings.ToLower(strings.Join(strings.Fields(value), " "))
	normalized = strings.TrimRight(normalized, ".")
	switch normalized {
	case "",
		"needs operator attention",
		"review the blocker or retry",
		"retry the same investigation from its saved evidence",
		"the host could not validate the final structured result",
		"needs attention",
		"blocked":
		return true
	}
	// Internal machinery, not a sentence for an operator. A transport error
	// names a component the reader does not operate and cannot act on, so it
	// belongs in the failure record rather than in a list of things to do.
	for _, marker := range []string{
		"coop api", "idempotency", "dial unix", "context deadline exceeded",
		"connection refused", "acp request was rejected", "500 internal",
	} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

// operatorActionable reports whether a work item is waiting on a person.
//
// A failed run is not a promise owed to the team; it is a run that died, and
// the retry is Responder's job. Listing failures as owed work is what put a
// Coop idempotency conflict in front of an operator as something to do.
func operatorActionable(state core.CommitmentState) bool {
	switch state {
	case core.CommitmentBlocked, core.CommitmentQueued,
		core.CommitmentWorking, core.CommitmentFinishing:
		return true
	default:
		return false
	}
}

// openThreadAction is the button that makes an item on this page actionable.
//
// A page headed "needs a decision from you" that offers no way to reach the
// conversation is a list of homework. app_redirect is used rather than a
// workspace permalink because it needs no team domain, which this process does
// not store, and Slack resolves it to the same message.
func openThreadAction(commitment core.Commitment) []Action {
	if commitment.ChannelID == "" {
		return nil
	}
	url := "https://slack.com/app_redirect?channel=" + commitment.ChannelID
	if anchor := strings.TrimSpace(commitment.ThreadTS); anchor != "" {
		url += "&message_ts=" + anchor
	}
	return []Action{{ID: ActionOpenWorkThread, Label: "Open", Value: commitment.ID, URL: url}}
}

// shortInstruction keeps the first sentence of a next action.
//
// These arrive as a paragraph — "read the run holding the lock: if it is stuck
// in Applying with a dead executor, force-unlock and queue a fresh run; if it
// is genuinely applying, wait. Say which workspace and I can carry the rest."
// The first sentence is the instruction; the rest is the caveats, which belong
// in the thread the Open button now reaches.
func shortInstruction(value string) string {
	trimmed := singleLine(strings.TrimSpace(value))
	if trimmed == "" {
		return ""
	}
	if cut := strings.IndexAny(trimmed, ".!?"); cut > 30 && cut < len(trimmed)-1 {
		trimmed = trimmed[:cut+1]
	}
	if len(trimmed) > 160 {
		trimmed = truncateUTF8(trimmed, 160)
		if space := strings.LastIndex(trimmed, " "); space > 60 {
			trimmed = trimmed[:space]
		}
		trimmed = strings.TrimRight(trimmed, " ,;:-") + "…"
	}
	return "→ " + trimmed
}

// AppendCoverageGaps names channels Responder is configured for but cannot see.
//
// This is the quietest kind of broken. The configuration says Responder is
// participating in a channel; Slack says the bot is not a member. Neither
// record looks wrong on its own, nothing fails, no error is raised, and every
// alert posted in that room reaches nobody. One channel sat in exactly this
// state for two days — configured proactive, absent, and invisible from both
// sides.
//
// It outranks everything else the page reports, because it says Responder is
// not doing what the operator believes it is doing — a whole channel's worth of
// alerts reaching nobody outranks any single one of them. The one thing it does
// not outrank is the direct ask: a named decision with somebody waiting on it is
// still the more urgent of the two, and the reader who scrolls past their own
// name to read a configuration warning has been served the page backwards.
//
// So it lands as the first section, which Blocks renders after the rows
// anchored at After 0 — the needs-you items — and before every other section.
// That severity argument is the reason this is a prepend rather than an append;
// keep it if the insertion point moves again.
func AppendCoverageGaps(message Message, channelIDs []string) Message {
	rooms := make([]string, 0, len(channelIDs))
	for index, channelID := range channelIDs {
		channelID = strings.TrimSpace(channelID)
		if channelID == "" {
			continue
		}
		if index >= 10 {
			rooms = append(rooms, fmt.Sprintf("and %d more", len(channelIDs)-index))
			break
		}
		rooms = append(rooms, "<#"+escapeSlackText(channelID)+">")
	}
	if len(rooms) == 0 {
		return message
	}
	subject := "these channels"
	if len(rooms) == 1 {
		subject = "this channel"
	}
	message.Sections = append([]string{fmt.Sprintf(
		"*:warning: Configured but not joined (%d)*\n%s\n"+
			"Responder is configured to participate in %s but is not a member, so nothing "+
			"posted there is seen. Invite the bot to close the gap, or remove the "+
			"configuration if the channel is no longer wanted.",
		len(rooms),
		strings.Join(rooms, " · "),
		subject,
	)}, message.Sections...)
	// A row remembers its position as the number of sections that preceded it,
	// so inserting a section at the front silently moves every row one heading
	// further down: "Settings" would be followed by a standing rule, and the
	// last heading on the page would be followed by nothing. The rows anchored
	// at 0 stay at 0 — they belong above the insert, which is the whole point of
	// putting them there.
	for index, row := range message.Rows {
		if row.After > 0 {
			message.Rows[index].After = row.After + 1
		}
	}
	return message
}
